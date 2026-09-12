import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:road_hazard/features/contributor/evidence_queue.dart';
import 'package:road_hazard/features/contributor/session_controller.dart';
import 'package:road_hazard/features/contributor/upload_service.dart';

class MemoryQueue extends EvidenceQueue {
  bool room = true;
  @override Future<void> open() async {}
  @override Future<int> count() async => 0;
  @override Future<List<Map<String, Object?>>> pending() async => [];
  @override Future<bool> hasRoom() async => room;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SessionController session;
  late MemoryQueue queue;
  setUp(() {
    queue = MemoryQueue();
    session = SessionController(evidenceQueue: queue)..ready = true;
    session.uploader = UploadService(queue, 'test', (_) {});
  });
  tearDown(() {
    session.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SessionController.native, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('road_hazard/events'), null);
  });
  test('one native start while permission prompt is pending', () async {
    final pending = Completer<void>();
    var starts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SessionController.native, (call) async {
      if (call.method == 'start') { starts++; await pending.future; }
      return null;
    });
    final first = session.start();
    await Future<void>.delayed(Duration.zero);
    await session.start();
    expect(starts, 1);
    pending.complete();
    await first;
    expect(session.isActive, isTrue);
  });
  test('stop during a pending start cannot reactivate collection', () async {
    final pending = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SessionController.native, (call) async {
      if (call.method == 'start') await pending.future;
      return null;
    });
    final starting = session.start();
    await Future<void>.delayed(Duration.zero);
    await session.stop(interrupted: true);
    pending.complete();
    await starting;
    expect(session.isActive, isFalse);
    expect(session.state, SessionState.cameraInterrupted);
  });
  test('failed native setup permits a subsequent start', () async {
    var starts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SessionController.native, (call) async {
      if (call.method == 'start' && ++starts == 1) {
        throw PlatformException(code: 'CAMERA_PERMISSION');
      }
      return null;
    });
    await session.start();
    expect(session.isActive, isFalse);
    await session.start();
    expect(session.isActive, isTrue);
  });
  test('full storage does not invoke the camera', () async {
    queue.room = false;
    await session.start();
    expect(session.state, SessionState.storageFull);
    expect(session.isActive, isFalse);
  });
  test('native interruption permits restart through the event channel', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('road_hazard/events'), (_) async => null);
    messenger.setMockMethodCallHandler(SessionController.native, (call) async => call.method == 'recover' ? [] : null);
    session.uploader.dispose();
    await session.initialize();
    await session.start();
    expect(session.isActive, isTrue);
    final delivered = Completer<void>();
    messenger.handlePlatformMessage('road_hazard/events',
        const StandardMethodCodec().encodeSuccessEnvelope({'type': 'error', 'message': 'Camera interrupted'}),
        (_) => delivered.complete());
    await delivered.future;
    expect(session.isActive, isFalse);
    await session.start();
    expect(session.isActive, isTrue);
  });
}
