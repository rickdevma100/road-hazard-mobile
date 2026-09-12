# iPhone contributor app

Use Flutter 3.35.7 or newer compatible stable, Xcode with iOS SDK, CocoaPods, and a physical iPhone on iOS 15+. Android and web capture are not implemented.

```sh
flutter pub get
flutter analyze
flutter test test/location_test.dart
open ios/Runner.xcworkspace
```

CI builds an unsigned iPhone release with Xcode and checks that `RoadHazard.mlmodelc`
is inside the app bundle. It also runs `flutter analyze`, the full `flutter test`
suite (including permission/start/stop regression cases), and an actual Core ML
inference test through Apple Vision on macOS. You can run the latter with
`swift scripts/verify_model.swift ios/Runner/Models/RoadHazard.mlpackage`.
The synthetic-image test verifies model loading, Vision object observations, and
confidence overrides; it does not measure pothole recognition accuracy.

The app includes `RoadHazard.mlpackage`, an NMS-enabled Core ML YOLOv12s detector fine-tuned with India-labelled RDD2022 road-damage images. Xcode compiles it into `RoadHazard.mlmodelc` when you build the Runner target. It detects four classes—longitudinal crack, transverse crack, alligator crack, and pothole—but the contributor capture flow creates reports only for the `Pothole` class. Model provenance, licensing, evaluation limits, and the artifact hash are recorded in [the ML model descriptor](https://github.com/rickdevma100/road-hazard-ml/blob/main/model-descriptor.json).

Then run `flutter run` on the phone. Open Server settings, enter an HTTPS API origin and `Bearer <access-token>`. Use a token with the configured audience and `contributor:write` scope. Values are kept in Keychain. The prototype expects token renewal through these settings; a provider-specific login/refresh UI remains to be connected. Never supply credentials through `--dart-define` or commit them.

A debug simulator build may use `http://localhost:8080` and a Basic header for demo mode, but the simulator cannot validate camera detection. A physical device needs a reachable HTTPS endpoint and trusted certificate. The Docker API binds only to localhost by default.

Configuration examples:

```sh
flutter run --dart-define=DETECTION_FPS=3 --dart-define=DETECTION_THRESHOLD=0.10 \
  --dart-define=MAX_ACCURACY_METERS=30 --dart-define=MAX_QUEUE_ITEMS=100
```

Detection uses a serial native capture queue with throttling and cooldown. The same frame used by Vision becomes the evidence JPEG. GPS comes from `CLLocation.course`, never magnetic heading. Unknown course/speed fields are null. Camera presentation time is converted from host-clock time before inference, and Dart chooses the closest accurate location within three seconds.

Captured files use iOS complete file protection and are excluded from backup. A protected native journal allows interrupted handoff to be recovered. After acceptance into the local queue, both image and metadata use AES-GCM with a Keychain key. Pending evidence survives network loss and retries on foreground timer ticks. A durable server receipt is recorded before local deletion. Queue bounds pause collection visibly. If the app is interrupted, camera collection stops and must be restarted in the foreground.

Hardware QA still needs to establish timestamp alignment, model output compatibility, pause/resume behavior, crash recovery, Keychain accessibility, file protection, battery/thermal behavior and actual detection quality. No production readiness claim is implied by passing Dart tests.
