import CoreML
import Foundation
import ImageIO
import Vision

/// A small, CPU-only classifier used after diffusion weights have been drained.
/// It never uploads, saves, or logs an image. No user setting disables this check.
actor GeneratedImageSafety {
    static let shared = GeneratedImageSafety()

    enum Failure: LocalizedError {
        case unavailable, invalidImage, invalidScores, sensitiveContent

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "The local image safety checker is unavailable. Image generation cannot continue."
            case .invalidImage, .invalidScores:
                return "The generated image could not be checked safely. Try another prompt."
            case .sensitiveContent:
                return "This image was withheld by the local content check. Try a non-explicit prompt."
            }
        }
    }

    nonisolated static var modelURL: URL? {
        Bundle.main.url(forResource: "GeneratedImageSafety", withExtension: "mlmodelc")
    }

    /// Upstream order: drawings, hentai, neutral, porn, sexy. Reject malformed
    /// results and uncertain/sensitive classifications; do not treat failure as safe.
    nonisolated static func validate(scores: [Double]) throws {
        guard scores.count == 5,
              scores.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(scores.reduce(0, +) - 1) < 0.001 else {
            throw Failure.invalidScores
        }
        let explicit = scores[1] + scores[3]
        let sensitive = explicit + scores[4]
        guard explicit < 0.10, sensitive < 0.25 else {
            throw Failure.sensitiveContent
        }
    }

    func check(pngData: Data) throws {
        try Self.validate(scores: scores(pngData: pngData))
    }

    /// Kept internal for inference-parity tests; scores aren't persisted or logged.
    func scores(pngData: Data) throws -> [Double] {
        try Task.checkCancellation()
        guard let url = Self.modelURL else { throw Failure.unavailable }
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure.invalidImage
        }
        // Create per check and release on return: the classifier doesn't become
        // another resident runtime competing with chat/vision/diffusion models.
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: url, configuration: configuration)
        guard model.modelDescription.metadata[.creatorDefinedKey] is [String: String],
              (model.modelDescription.metadata[.creatorDefinedKey] as? [String: String])?["class_labels"]
                == "drawings,hentai,neutral,porn,sexy" else {
            throw Failure.invalidScores
        }
        let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        guard let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
              let values = observation.featureValue.multiArrayValue else {
            throw Failure.invalidScores
        }
        return (0..<values.count).map { values[$0].doubleValue }
    }
}
