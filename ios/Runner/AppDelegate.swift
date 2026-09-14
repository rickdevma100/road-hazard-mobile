import Flutter
import UIKit
import AVFoundation
import CoreLocation
import CoreML
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate {
    private var collector: RoadCollector?
    override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        let controller = window?.rootViewController as! FlutterViewController
        let collector = RoadCollector()
        self.collector = collector
        FlutterMethodChannel(name: "road_hazard/control", binaryMessenger: controller.binaryMessenger).setMethodCallHandler { call, result in
            if call.method == "start" { collector.start(call.arguments as? [String: Any] ?? [:], result: result) }
            else if call.method == "recover" { collector.recover(result: result) }
            else if call.method == "stop" { collector.stop(); result(nil) }
            else { result(FlutterMethodNotImplemented) }
        }
        FlutterEventChannel(name: "road_hazard/events", binaryMessenger: controller.binaryMessenger).setStreamHandler(collector)
        registrar(forPlugin: "RoadPreview")?.register(PreviewFactory(session: collector.session), withId: "road_hazard/preview")
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
}

final class RoadCollector: NSObject, FlutterStreamHandler, CLLocationManagerDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let location = CLLocationManager()
    private let captureQueue = DispatchQueue(label: "road.capture")
    private let context = CIContext()
    private var sink: FlutterEventSink?
    private var model: VNCoreMLModel?
    private var modelName = "", modelVersion = ""
    private var fps = 3.0, threshold: Float = 0.10, cooldown = 5.0
    private var lastFrame = 0.0, lastCandidate = 0.0
    // Access only on captureQueue, including cancellation while permissions are pending.
    private var startGeneration = 0
    private var running = false
    // Location permission completion is owned by the main thread.
    private var locationPermissionCompletion: ((Bool) -> Void)?
    private var recentLocations: [[String: Any]] = []
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.activityType = .automotiveNavigation
        location.distanceFilter = kCLDistanceFilterNone
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: .AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? { sink = events; return nil }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }
    private func emit(_ event: [String: Any]) { DispatchQueue.main.async { self.sink?(event) } }
    @objc private func interrupted() { stop(); emit(["type": "error", "message": "Camera interrupted. Return to the app and restart collection."]) }
    func start(_ options: [String: Any], result: @escaping FlutterResult) {
        captureQueue.async {
            self.startGeneration += 1
            let generation = self.startGeneration
            DispatchQueue.main.async {
                self.requestCamera(options, generation: generation, result: result)
            }
        }
    }
    private func requestCamera(_ options: [String: Any], generation: Int, result: @escaping FlutterResult) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { DispatchQueue.main.async { result(FlutterError(code: "CAMERA_PERMISSION", message: "Camera access is required.", details: nil)) }; return }
            DispatchQueue.main.async {
                let completion: (Bool) -> Void = { allowed in
                    guard allowed else {
                        result(FlutterError(code: "LOCATION_PERMISSION", message: "Location access is required to collect road evidence.", details: nil))
                        return
                    }
                    self.configureCapture(options, generation: generation, result: result)
                }
                if self.location.authorizationStatus == .notDetermined {
                    self.locationPermissionCompletion?(false)
                    self.locationPermissionCompletion = completion
                    self.location.requestWhenInUseAuthorization()
                } else {
                    completion(self.location.authorizationStatus == .authorizedAlways || self.location.authorizationStatus == .authorizedWhenInUse)
                }
            }
        }
    }
    private func configureCapture(_ options: [String: Any], generation: Int, result: @escaping FlutterResult) {
        self.captureQueue.async {
                do {
                    guard generation == self.startGeneration else {
                        DispatchQueue.main.async { result(FlutterError(code: "CAPTURE_CANCELLED", message: "Collection was cancelled.", details: nil)) }
                        return
                    }
                    self.fps = max(1, min(10, (options["fps"] as? NSNumber)?.doubleValue ?? 3))
                    self.threshold = max(0, min(1, (options["threshold"] as? NSNumber)?.floatValue ?? 0.10))
                    self.cooldown = max(1, (options["cooldownSeconds"] as? NSNumber)?.doubleValue ?? 5)
                    if self.model == nil {
                        guard let url = Bundle.main.url(forResource: "RoadHazard", withExtension: "mlmodelc") else {
                            throw NSError(domain: "Roadwatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Add a versioned RoadHazard Core ML object detector to the Runner target. See mobile/README.md."])
                        }
                        let ml = try MLModel(contentsOf: url)
                        guard let metadata = ml.modelDescription.metadata[.creatorDefinedKey] as? [String: String],
                              let name = metadata["modelName"], let version = metadata["modelVersion"] else {
                            throw NSError(domain: "Roadwatch", code: 2, userInfo: [NSLocalizedDescriptionKey: "Model must declare modelName and modelVersion metadata."])
                        }
                        self.modelName = name; self.modelVersion = version
                        self.model = try VNCoreMLModel(for: ml)
                    }
                    // Supply NMS inputs explicitly; changing the Dart threshold must also
                    // affect Core ML, otherwise detections can be discarded before Vision.
                    self.model?.featureProvider = try MLDictionaryFeatureProvider(dictionary: [
                        "confidenceThreshold": Double(self.threshold), "iouThreshold": 0.7
                    ])
                    if self.session.inputs.isEmpty {
                        self.session.beginConfiguration()
                        defer { self.session.commitConfiguration() }
                        self.session.sessionPreset = .hd1280x720
                        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                            throw NSError(domain: "Roadwatch", code: 3, userInfo: [NSLocalizedDescriptionKey: "Rear camera unavailable."])
                        }
                        let input = try AVCaptureDeviceInput(device: camera)
                        guard self.session.canAddInput(input) else { throw NSError(domain: "Camera", code: 4) }
                        self.session.addInput(input)
                        let output = AVCaptureVideoDataOutput()
                        output.alwaysDiscardsLateVideoFrames = true
                        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                        output.setSampleBufferDelegate(self, queue: self.captureQueue)
                        guard self.session.canAddOutput(output) else { throw NSError(domain: "Camera", code: 5) }
                        self.session.addOutput(output)
                    }
                    self.lastFrame = 0; self.lastCandidate = 0
                    self.recentLocations.removeAll()
                    self.session.startRunning()
                    self.running = self.session.isRunning
                    DispatchQueue.main.async {
                        guard self.captureQueue.sync(execute: { generation == self.startGeneration && self.running }) else {
                            result(FlutterError(code: "CAPTURE_CANCELLED", message: "Collection was cancelled before the camera started.", details: nil))
                            return
                        }
                        UIApplication.shared.isIdleTimerDisabled = true
                        self.location.startUpdatingLocation(); result(nil)
                    }
                } catch { DispatchQueue.main.async { result(FlutterError(code: "CAPTURE_SETUP", message: error.localizedDescription, details: nil)) } }
        }
    }
    func recover(result: @escaping FlutterResult) {
        captureQueue.async {
            do {
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("capture", isDirectory: true)
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                var recovered: [[String: Any]] = []
                for file in files where file.pathExtension == "json" {
                    guard var event = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
                        throw NSError(domain: "Roadwatch", code: 7, userInfo: [NSLocalizedDescriptionKey: "Stored capture journal is invalid."])
                    }
                    if let path = event["path"] as? String, FileManager.default.fileExists(atPath: path) {
                        event["recovered"] = true; recovered.append(event)
                    } else { try FileManager.default.removeItem(at: file) }
                }
                recovered.sort { ($0["capturedAt"] as? String ?? "") < ($1["capturedAt"] as? String ?? "") }
                DispatchQueue.main.async { result(recovered) }
            } catch { DispatchQueue.main.async { result(FlutterError(code: "RECOVERY", message: error.localizedDescription, details: nil)) } }
        }
    }
    func stop() {
        captureQueue.async { self.startGeneration += 1; self.running = false; self.session.stopRunning() }
        DispatchQueue.main.async {
            let completion = self.locationPermissionCompletion
            self.locationPermissionCompletion = nil
            completion?(false)
            self.location.stopUpdatingLocation(); UIApplication.shared.isIdleTimerDisabled = false
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus != .notDetermined {
            let completion = locationPermissionCompletion
            locationPermissionCompletion = nil
            completion?(manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse)
        }
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            stop()
            emit(["type": "error", "message": "Location access is required. Enable it in Settings."])
        }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A temporary unavailable fix is common during GPS acquisition.
        if (error as? CLError)?.code == .locationUnknown { return }
        stop()
        emit(["type": "error", "message": "Location unavailable: \(error.localizedDescription)"])
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for fix in locations where fix.horizontalAccuracy >= 0 {
            var event: [String: Any] = ["type": "location", "latitude": fix.coordinate.latitude,
                "longitude": fix.coordinate.longitude, "accuracy": fix.horizontalAccuracy, "timestamp": formatter.string(from: fix.timestamp)]
            if fix.course >= 0 { event["course"] = fix.course }
            if fix.courseAccuracy >= 0 { event["courseAccuracy"] = fix.courseAccuracy }
            if fix.speed >= 0 { event["speed"] = fix.speed }
            if fix.speedAccuracy >= 0 { event["speedAccuracy"] = fix.speedAccuracy }
            let snapshot = event
            captureQueue.async {
                self.recentLocations.append(snapshot)
                if self.recentLocations.count > 30 { self.recentLocations.removeFirst(self.recentLocations.count - 30) }
            }
            emit(event)
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let monotonic = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        guard running, monotonic - lastFrame >= 1/fps, monotonic - lastCandidate >= cooldown,
              let pixel = CMSampleBufferGetImageBuffer(sampleBuffer), let model = model else { return }
        lastFrame = monotonic
        // Convert the camera's host-clock presentation timestamp to wall time before inference.
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let at = Date().addingTimeInterval(pts - monotonic)
        do {
            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .scaleFit
            try VNImageRequestHandler(cvPixelBuffer: pixel, orientation: .right).perform([request])
            guard let results = request.results as? [VNRecognizedObjectObservation] else {
                throw NSError(domain: "Roadwatch", code: 6, userInfo: [NSLocalizedDescriptionKey: "Model must return Vision object observations. Export with NMS enabled."])
            }
            var bestCandidate: VNClassificationObservation?
            for observation in results {
                guard let label = observation.labels.first,
                      label.identifier.caseInsensitiveCompare("Pothole") == ComparisonResult.orderedSame,
                      label.confidence >= self.threshold else { continue }
                if label.confidence > (bestCandidate?.confidence ?? -1) {
                    bestCandidate = label
                }
            }
            guard let candidate = bestCandidate else { return }
            let image = CIImage(cvPixelBuffer: pixel).oriented(.right)
            guard let cg = context.createCGImage(image, from: image.extent), let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.8) else { return }
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("capture", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excluded = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try excluded.setResourceValues(values)
            let file = directory.appendingPathComponent(UUID().uuidString + ".jpg")
            try jpeg.write(to: file, options: [.atomic, .completeFileProtection])
            lastCandidate = monotonic
            let event: [String: Any] = ["type": "candidate", "path": file.path, "capturedAt": formatter.string(from: at),
                  "eventId": UUID().uuidString, "imageId": UUID().uuidString, "locations": recentLocations,
                  "class": candidate.identifier, "confidence": candidate.confidence,
                  "modelName": modelName, "modelVersion": modelVersion]
            try JSONSerialization.data(withJSONObject: event).write(to: URL(fileURLWithPath: file.path + ".json"), options: [.atomic, .completeFileProtection])
            emit(event)
        } catch { stop(); emit(["type": "error", "message": error.localizedDescription]) }
    }
}

final class CameraPreview: UIView, FlutterPlatformView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    init(frame: CGRect, session: AVCaptureSession) {
        super.init(frame: frame)
        let preview = layer as! AVCaptureVideoPreviewLayer
        preview.session = session; preview.videoGravity = .resizeAspectFill
        if preview.connection?.isVideoOrientationSupported == true {
            preview.connection?.videoOrientation = .portrait
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func view() -> UIView { self }
}
final class PreviewFactory: NSObject, FlutterPlatformViewFactory {
    let session: AVCaptureSession
    init(session: AVCaptureSession) { self.session = session }
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        CameraPreview(frame: frame, session: session)
    }
}
