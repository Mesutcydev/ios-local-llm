import Vision
import CoreImage
import UIKit
import Foundation

// MARK: - TextRegionDetector
// On-device text-region detection using Apple's Vision framework — replaces
// the legacy YOLO11n detector. Returns `Detection` objects with the same
// shape so `AnalysisService` doesn't need to change call sites.
//
// Why this replaces YOLO:
//   • Apple Vision is system-provided, MIT-friendly licensing
//   • VNDetectTextRectanglesRequest finds text-shaped regions which is
//     exactly the use case (we analyse code/text on screens)
//   • No model file to bundle (saves ~5 MB) and no Neural Engine load
//   • Nearby small rectangles are merged into larger meaningful regions
//
// Public API mirrors YOLOService so the swap is one line in AnalysisService.

final class TextRegionDetector: @unchecked Sendable {

    /// Required by AnalysisService — Vision needs no explicit load, so this
    /// is a no-op that simply flips the loaded flag.
    private(set) var isLoaded = false

    /// Minimum confidence we keep. Vision's text-rect confidences cluster
    /// in 0.4–0.95 range; lower than 0.4 is usually noise.
    private static let minConfidence: Float = 0.4

    /// Maximum number of regions we surface per frame. Detection above this
    /// gets merged or trimmed so the UI stays scannable.
    private static let maxRegions: Int = 8

    /// Distance (in normalised coords) within which adjacent boxes are merged
    /// into a single region. Larger ⇒ fewer, broader regions.
    private static let mergeRadius: CGFloat = 0.03

    // MARK: - Load (no-op for Vision)

    func load() throws {
        // VNDetectTextRectanglesRequest needs no model files — it's bundled
        // in the OS. We just mark ready.
        isLoaded = true
    }

    // MARK: - Detect

    func detect(pixelBuffer: CVPixelBuffer, frameIndex: Int) -> [Detection] {
        guard isLoaded else { return [] }

        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = false

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .right,     // match the camera's portrait orientation
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let observations = request.results else { return [] }

        // Map Vision observations to a simple internal struct so we can
        // merge them without fighting Vision's non-constructible types.
        let raw: [RegionRect] = observations
            .filter { $0.confidence >= Self.minConfidence }
            .map { RegionRect(box: $0.boundingBox, confidence: $0.confidence) }

        let merged = mergeNearby(raw)

        return merged
            .sorted { weight($0) > weight($1) }
            .prefix(Self.maxRegions)
            .map { region in
                Detection(
                    boundingBox: region.box,
                    confidence: region.confidence,
                    label: "text region",
                    classIndex: -1,
                    frameIndex: frameIndex
                )
            }
    }

    // MARK: - Merging

    private struct RegionRect {
        var box: CGRect
        var confidence: Float
    }

    /// Greedily merges rectangles whose centres are within `mergeRadius`.
    private func mergeNearby(_ regions: [RegionRect]) -> [RegionRect] {
        guard !regions.isEmpty else { return [] }
        var groups: [[RegionRect]] = []
        for r in regions {
            if let i = groups.firstIndex(where: { group in
                group.contains(where: { centerDistance(r.box, $0.box) < Self.mergeRadius })
            }) {
                groups[i].append(r)
            } else {
                groups.append([r])
            }
        }
        return groups.map { group -> RegionRect in
            let union = group.reduce(group[0].box) { acc, next in
                acc.union(next.box)
            }
            let maxConf = group.map { $0.confidence }.max() ?? 0
            return RegionRect(box: union, confidence: maxConf)
        }
    }

    private func centerDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return sqrt(dx * dx + dy * dy)
    }

    private func weight(_ region: RegionRect) -> Float {
        let area = Float(region.box.width * region.box.height)
        return region.confidence * (1.0 + area * 4)
    }
}
