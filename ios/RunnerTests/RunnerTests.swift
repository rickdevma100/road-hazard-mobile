import Flutter
import UIKit
import XCTest
import CoreML
import Vision

class RunnerTests: XCTestCase {

  func testBundledDetectorRunsThroughVision() throws {
    let url = try XCTUnwrap(Bundle.main.url(forResource: "RoadHazard", withExtension: "mlmodelc"))
    let config = MLModelConfiguration()
    config.computeUnits = .cpuOnly
    let model = try MLModel(contentsOf: url, configuration: config)
    let metadata = try XCTUnwrap(model.modelDescription.metadata[.creatorDefinedKey] as? [String: String])
    XCTAssertEqual(metadata["modelName"], "india-rdd2022-yolov12s")
    XCTAssertFalse(try XCTUnwrap(metadata["modelVersion"]).isEmpty)
    let vision = try VNCoreMLModel(for: model)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640)).image { context in
      UIColor.black.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
    }
    for threshold in [0.1, 0.0] {
      vision.featureProvider = try MLDictionaryFeatureProvider(dictionary: [
        "confidenceThreshold": threshold, "iouThreshold": 0.7
      ])
      let request = VNCoreMLRequest(model: vision)
      request.imageCropAndScaleOption = .scaleFit
      try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
      let objects = try XCTUnwrap(request.results as? [VNRecognizedObjectObservation])
      if threshold == 0.1 { XCTAssertTrue(objects.isEmpty) }
      if threshold == 0.0 { XCTAssertFalse(objects.isEmpty, "NMS threshold override must take effect") }
      let supported = Set(["Longitudinal", "Transverse", "Alligator", "Pothole"])
      for observation in objects {
        XCTAssertTrue(supported.contains(try XCTUnwrap(observation.labels.first).identifier))
      }
    }
  }

}
