# iPhone contributor app

Use Flutter 3.35.7 or newer compatible stable, Xcode with iOS SDK, CocoaPods, and a physical iPhone on iOS 15+. Android and web capture are not implemented.

```sh
flutter pub get
flutter analyze
flutter test test/location_test.dart
open ios/Runner.xcworkspace
```

In Xcode, choose your signing team and a unique bundle identifier. Add a **road-damage Core ML object detector** named `RoadHazard.mlpackage` or `RoadHazard.mlmodel` to the Runner target. It must expose object observations (NMS enabled) and creator metadata `modelName` and `modelVersion`. See [https://github.com/rickdevma100/road-hazard-ml/blob/main/README.md](https://github.com/rickdevma100/road-hazard-ml/blob/main/README.md). No trained model is bundled. Without one, Start reports a setup error and does not pretend to detect hazards.

Then run `flutter run` on the phone. Open Server settings, enter an HTTPS API origin and `Bearer <access-token>`. Use a token with the configured audience and `contributor:write` scope. Values are kept in Keychain. The prototype expects token renewal through these settings; a provider-specific login/refresh UI remains to be connected. Never supply credentials through `--dart-define` or commit them.

A debug simulator build may use `http://localhost:8080` and a Basic header for demo mode, but the simulator cannot validate camera detection. A physical device needs a reachable HTTPS endpoint and trusted certificate. The Docker API binds only to localhost by default.

Configuration examples:

```sh
flutter run --dart-define=DETECTION_FPS=3 --dart-define=DETECTION_THRESHOLD=0.65 \
  --dart-define=MAX_ACCURACY_METERS=30 --dart-define=MAX_QUEUE_ITEMS=100
```

Detection uses a serial native capture queue with throttling and cooldown. The same frame used by Vision becomes the evidence JPEG. GPS comes from `CLLocation.course`, never magnetic heading. Unknown course/speed fields are null. Camera presentation time is converted from host-clock time before inference, and Dart chooses the closest accurate location within three seconds.

Captured files use iOS complete file protection and are excluded from backup. A protected native journal allows interrupted handoff to be recovered. After acceptance into the local queue, both image and metadata use AES-GCM with a Keychain key. Pending evidence survives network loss and retries on foreground timer ticks. A durable server receipt is recorded before local deletion. Queue bounds pause collection visibly. If the app is interrupted, camera collection stops and must be restarted in the foreground.

Hardware QA still needs to establish timestamp alignment, model output compatibility, pause/resume behavior, crash recovery, Keychain accessibility, file protection, battery/thermal behavior and actual detection quality. No production readiness claim is implied by passing Dart tests.
