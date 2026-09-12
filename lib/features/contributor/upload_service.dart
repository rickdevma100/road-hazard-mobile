import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'evidence_queue.dart';

class UploadService {
  UploadService(this.queue, this.installationId, this.onStatus);
  final EvidenceQueue queue;
  final String installationId;
  final void Function(String) onStatus;
  final _client = http.Client();
  Uri? base;
  String? authorization;
  bool _busy = false;
  void configure(String url, String auth) {
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' && !(kDebugMode && ['localhost', '127.0.0.1'].contains(uri.host))) {
      throw ArgumentError('Use an HTTPS server address.');
    }
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) throw ArgumentError('Invalid server address');
    base = uri; authorization = auth;
  }
  Future<void> flush() async {
    if (_busy || base == null || authorization == null) return;
    _busy = true;
    try {
      final pending = await queue.pending();
      if (pending.isEmpty) return;
      final registration = await _client.post(base!.resolve('/api/v1/installations'),
        headers: {'Authorization': authorization!, 'Content-Type': 'application/json'},
        body: jsonEncode({'installationId': installationId})).timeout(const Duration(seconds: 15));
      if (registration.statusCode != 200) throw StateError('Sign in or check installation access (${registration.statusCode})');
      for (final row in pending) {
        try {
          final request = http.MultipartRequest('POST', base!.resolve('/api/v1/detections'));
          request.headers.addAll({'Authorization': authorization!, 'X-Correlation-Id': row['id'] as String});
          request.files.add(http.MultipartFile.fromString('metadata', await queue.metadata(row), contentType: MediaType('application', 'json')));
          request.files.add(http.MultipartFile.fromBytes('image', await queue.image(row), filename: '${row['id']}.jpg', contentType: MediaType('image', 'jpeg')));
          final response = await http.Response.fromStream(await _client.send(request).timeout(const Duration(seconds: 30)))
            .timeout(const Duration(seconds: 30));
          if (response.statusCode != 202) throw StateError('Upload requires attention (${response.statusCode}). Evidence retained.');
          final receipt = jsonDecode(response.body) as Map<String, dynamic>;
          if (receipt['detectionId'] is! String || receipt['status'] is! String) throw StateError('Invalid server receipt');
          await queue.acknowledge(row['id'] as String, row['image_path'] as String);
          onStatus('Upload accepted. Local evidence removed.');
        } catch (error) {
          await queue.retry(row);
          onStatus('Upload retry pending. $error');
          break;
        }
      }
    } catch (error) {
      onStatus('Offline or sign-in required. Evidence retained. $error');
    } finally { _busy = false; }
  }
  void dispose() => _client.close();
}
