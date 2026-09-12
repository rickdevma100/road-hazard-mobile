import Foundation
import CoreML
import Vision
import CoreGraphics

// Runs the same Core ML -> Vision object-observation path as the iPhone app.
// Synthetic images validate runtime compatibility, not pothole accuracy.
let package = URL(fileURLWithPath: CommandLine.arguments[1])
let compiled = try MLModel.compileModel(at: package)
defer { try? FileManager.default.removeItem(at: compiled) }
let configuration = MLModelConfiguration()
configuration.computeUnits = .cpuOnly
let model = try MLModel(contentsOf: compiled, configuration: configuration)
let metadata = model.modelDescription.metadata[.creatorDefinedKey] as! [String: String]
precondition(metadata["modelName"] == "india-rdd2022-yolov12s")
precondition(metadata["modelVersion"]?.isEmpty == false)
let vision = try VNCoreMLModel(for: model)
let context = CGContext(data: nil, width: 640, height: 640, bitsPerComponent: 8,
                        bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
let image = context.makeImage()!
for threshold in [0.1, 0.0] {
    vision.featureProvider = try MLDictionaryFeatureProvider(dictionary: [
        "confidenceThreshold": threshold, "iouThreshold": 0.7
    ])
    let request = VNCoreMLRequest(model: vision)
    request.imageCropAndScaleOption = .scaleFit
    try VNImageRequestHandler(cgImage: image).perform([request])
    guard let objects = request.results as? [VNRecognizedObjectObservation] else {
        fatalError("Model did not return Vision object observations")
    }
    if threshold == 0.1 { precondition(objects.isEmpty, "Blank image produced a candidate") }
    if threshold == 0.0 { precondition(!objects.isEmpty, "Threshold override was ignored") }
    let labels = Set(["Longitudinal", "Transverse", "Alligator", "Pothole"])
    for object in objects {
        precondition(labels.contains(object.labels.first!.identifier))
        precondition(object.boundingBox.width.isFinite && object.boundingBox.height.isFinite)
    }
    print("Vision inference passed: threshold=\(threshold), observations=\(objects.count)")
}
