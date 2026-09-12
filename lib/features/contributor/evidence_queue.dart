import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class EvidenceQueue {
  static const maxItems = int.fromEnvironment('MAX_QUEUE_ITEMS', defaultValue: 100);
  static const maxBytes = int.fromEnvironment('MAX_QUEUE_BYTES', defaultValue: 256 * 1024 * 1024);
  final _cipher = AesGcm.with256bits();
  late SecretKey _key;
  late Database _db;
  late Directory _directory;
  Future<void> open() async {
    const secure = FlutterSecureStorage();
    var encoded = await secure.read(key: 'evidence-key');
    if (encoded == null) {
      encoded = base64Encode(await (await _cipher.newSecretKey()).extractBytes());
      await secure.write(key: 'evidence-key', value: encoded);
    }
    _key = SecretKey(base64Decode(encoded));
    _directory = Directory(path.join((await getApplicationSupportDirectory()).path, 'evidence'));
    await _directory.create(recursive: true);
    _db = await openDatabase(path.join(_directory.path, 'queue.sqlite'), version: 1,
      onCreate: (db, _) => db.execute('CREATE TABLE evidence(id TEXT PRIMARY KEY, metadata BLOB NOT NULL, '
        'image_path TEXT NOT NULL, bytes INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, '
        'next_attempt INTEGER NOT NULL DEFAULT 0, acknowledged INTEGER NOT NULL DEFAULT 0)'));
    // Recover encrypted files written before a crash between file write and SQLite commit.
    final rows = await _db.query('evidence', columns: ['image_path']);
    final known = rows.map((r) => r['image_path']).toSet();
    await for (final file in _directory.list()) {
      if (file.path.endsWith('.enc') && !known.contains(file.path)) await file.delete();
    }
    for (final row in await _db.query('evidence', where: 'acknowledged=1')) {
      await acknowledge(row['id'] as String, row['image_path'] as String);
    }
  }
  Future<Uint8List> _encrypt(List<int> bytes) async => (await _cipher.encrypt(bytes, secretKey: _key)).concatenation();
  Future<List<int>> _decrypt(List<int> bytes) => _cipher.decrypt(
      SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16), secretKey: _key);
  Future<int> count() async => Sqflite.firstIntValue(await _db.rawQuery('SELECT count(*) FROM evidence')) ?? 0;
  Future<bool> hasRoom() async {
    final bytes = Sqflite.firstIntValue(await _db.rawQuery('SELECT coalesce(sum(bytes),0) FROM evidence')) ?? 0;
    return await count() < maxItems && bytes + 8 * 1024 * 1024 <= maxBytes;
  }
  Future<void> enqueue(String id, Map<String, dynamic> metadata, String sourcePath) async {
    if ((await _db.query('evidence', where: 'id=?', whereArgs: [id])).isNotEmpty) { return; }
    if (!await hasRoom()) throw StateError('Offline storage is full. Collection is paused until uploads finish.');
    final source = File(sourcePath);
    final bytes = await source.readAsBytes();
    if (bytes.length > 8 * 1024 * 1024) throw StateError('Evidence exceeds upload limit');
    final target = File(path.join(_directory.path, '$id.enc'));
    await target.writeAsBytes(await _encrypt(bytes), flush: true);
    await _db.insert('evidence', {'id': id, 'metadata': await _encrypt(utf8.encode(jsonEncode(metadata))),
      'image_path': target.path, 'bytes': bytes.length});
    // Only the encrypted durable copy owns the evidence now.
    await source.delete();
  }
  Future<List<Map<String, Object?>>> pending() => _db.query('evidence',
      where: 'acknowledged=0 AND next_attempt<=?', whereArgs: [DateTime.now().millisecondsSinceEpoch], orderBy: 'rowid', limit: 10);
  Future<String> metadata(Map<String, Object?> row) async => utf8.decode(await _decrypt(row['metadata'] as List<int>));
  Future<List<int>> image(Map<String, Object?> row) async => _decrypt(await File(row['image_path'] as String).readAsBytes());
  Future<void> retry(Map<String, Object?> row) async {
    final attempts = (row['attempts'] as int) + 1;
    final seconds = attempts >= 8 ? 300 : 1 << attempts;
    await _db.update('evidence', {'attempts': attempts, 'next_attempt': DateTime.now().add(Duration(seconds: seconds)).millisecondsSinceEpoch},
      where: 'id=?', whereArgs: [row['id']]);
  }
  Future<void> acknowledge(String id, String imagePath) async {
    await _db.update('evidence', {'acknowledged': 1}, where: 'id=?', whereArgs: [id]);
    final image = File(imagePath);
    if (await image.exists()) await image.delete();
    await _db.delete('evidence', where: 'id=?', whereArgs: [id]);
  }
}
