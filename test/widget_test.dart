import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:road_hazard/features/contributor/evidence_queue.dart';
import 'package:road_hazard/features/contributor/session_controller.dart';
import 'package:road_hazard/features/contributor/upload_service.dart';

class MemoryQueue extends EvidenceQueue {
  bool room = true;
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
}
