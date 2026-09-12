import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'evidence_queue.dart';
import 'location.dart';
import 'upload_service.dart';

enum SessionState { idle, requestingPermissions, gpsCalibrating, collecting, cameraInterrupted, gpsDegraded, storageFull, finished }

class SessionController extends ChangeNotifier {
  static const native = MethodChannel('road_hazard/control');
  static const events = EventChannel('road_hazard/events');
  static final maxAccuracy = double.parse(const String.fromEnvironment('MAX_ACCURACY_METERS', defaultValue: '30'));
  final trajectory = TrajectoryBuffer();
  final queue = EvidenceQueue();
  late UploadService uploader;
  SessionState state = SessionState.idle;
  String message = 'Mount your phone with a clear view of the road.';
  LocationFix? fix;
  int queued = 0, captured = 0;
  bool ready = false, _handling = false, _active = false;
  Timer? _timer;
  StreamSubscription<dynamic>? _subscription;
  final _uuid = const Uuid();
  late String installationId;
  Future<void> initialize() async {
    await queue.open();
    const secure = FlutterSecureStorage();
    installationId = await secure.read(key: 'installation-id') ?? _uuid.v4();
    await secure.write(key: 'installation-id', value: installationId);
    uploader = UploadService(queue, installationId, (s) { message = s; notifyListeners(); });
    final url = await secure.read(key: 'api-url');
    final auth = await secure.read(key: 'authorization');
    if (url != null && auth != null) uploader.configure(url, auth);
    _subscription = events.receiveBroadcastStream().listen(_onEvent, onError: (Object error) {
      message = '$error'; state = SessionState.cameraInterrupted; notifyListeners();
    });
    _timer = Timer.periodic(const Duration(seconds: 5), (_) async {
      await uploader.flush(); queued = await queue.count();
      if (_active && trajectory.nearest(DateTime.now().toUtc(), maxAccuracy: maxAccuracy) == null) state = SessionState.gpsDegraded;
      notifyListeners();
    });
    final recovered = await native.invokeListMethod<dynamic>('recover') ?? [];
    for (final event in recovered) { await _onEvent(event); }
    queued = await queue.count(); ready = true; notifyListeners();
  }
  Future<void> configure(String url, String auth) async {
    uploader.configure(url, auth);
    const secure = FlutterSecureStorage();
    await secure.write(key: 'api-url', value: url);
    await secure.write(key: 'authorization', value: auth);
    message = 'Server settings saved securely.'; notifyListeners();
    await uploader.flush();
  }
  Future<void> start() async {
    if (!ready || _active) return;
    if (!await queue.hasRoom()) { state = SessionState.storageFull; notifyListeners(); return; }
    state = SessionState.requestingPermissions; notifyListeners();
    try {
      await native.invokeMethod<void>('start', {
        'fps': const int.fromEnvironment('DETECTION_FPS', defaultValue: 3),
        'threshold': double.parse(const String.fromEnvironment('DETECTION_THRESHOLD', defaultValue: '0.10')),
        'cooldownSeconds': const int.fromEnvironment('DETECTION_COOLDOWN_SECONDS', defaultValue: 5),
      });
      _active = true; state = SessionState.gpsCalibrating;
      message = 'Waiting for an accurate GPS fix. Keep this screen open.';
    } catch (error) { state = SessionState.cameraInterrupted; message = '$error'; }
    notifyListeners();
  }
  Future<void> stop({bool interrupted = false}) async {
    _active = false;
    await native.invokeMethod<void>('stop');
    state = interrupted ? SessionState.cameraInterrupted : SessionState.finished;
    message = interrupted ? 'Collection paused. Return to the foreground and start again.' : 'Session finished. Pending evidence will keep retrying.';
    notifyListeners();
  }
  Future<void> _onEvent(dynamic raw) async {
    final data = Map<dynamic, dynamic>.from(raw as Map);
    if (data['type'] == 'location') {
      fix = LocationFix.fromMap(data); trajectory.add(fix!);
      if (_active) state = trajectory.nearest(DateTime.now().toUtc(), maxAccuracy: maxAccuracy) != null ? SessionState.collecting : SessionState.gpsDegraded;
      notifyListeners(); return;
    }
    if (data['type'] == 'error') {
      message = data['message'] as String; state = SessionState.cameraInterrupted; notifyListeners(); return;
    }
    if (data['type'] != 'candidate') return;
    final imagePath = data['path'] as String;
    if (_handling || (!_active && data['recovered'] != true)) { await _discard(imagePath); return; }
    _handling = true;
    try {
      for (final saved in (data['locations'] as List<dynamic>? ?? [])) { trajectory.add(LocationFix.fromMap(saved as Map)); }
      final at = DateTime.parse(data['capturedAt'] as String);
      final closest = trajectory.nearest(at, maxAccuracy: maxAccuracy);
      final trace = trajectory.trace(at);
      if (closest == null || trace.length < 2) {
        state = SessionState.gpsDegraded; message = 'Waiting for accurate trajectory. Candidate was not accepted.';
        await _discard(imagePath); return;
      }
      final id = data['eventId'] as String? ?? _uuid.v4();
      await queue.enqueue(id, {
        'clientEventId': id, 'installationId': installationId, 'capturedAt': at.toUtc().toIso8601String(),
        'position': {'latitude': closest.latitude, 'longitude': closest.longitude, 'horizontalAccuracyMeters': closest.accuracy},
        'movement': {'courseDegrees': closest.course, 'courseAccuracyDegrees': closest.courseAccuracy,
          'speedMps': closest.speed, 'speedAccuracyMps': closest.speedAccuracy},
        'trajectory': trace,
        'detection': {'class': data['class'], 'confidence': data['confidence'], 'modelName': data['modelName'], 'modelVersion': data['modelVersion']},
        'evidence': {'imageId': data['imageId'] ?? _uuid.v4(), 'contentType': 'image/jpeg'},
        'client': {'appVersion': '0.1.0', 'platform': 'ios'},
      }, imagePath);
      await _discard(imagePath);
      captured++; queued = await queue.count();
      message = 'Candidate saved securely. Uploading when connected.';
      if (!await queue.hasRoom()) { await stop(); state = SessionState.storageFull; }
      await uploader.flush();
    } catch (error) {
      await stop(); state = SessionState.storageFull; message = '$error';
      // Native protected file is retained if durable enqueue did not finish.
    } finally { _handling = false; notifyListeners(); }
  }
  Future<void> _discard(String path) async {
    for (final name in [path, '$path.json']) { final file = File(name); if (await file.exists()) await file.delete(); }
  }
  @override void dispose() { _timer?.cancel(); _subscription?.cancel(); if (ready) uploader.dispose(); super.dispose(); }
}
