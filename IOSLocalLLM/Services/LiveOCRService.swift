import Foundation
@preconcurrency import Vision
import CoreImage
import UIKit

// MARK: - LiveOCRService
// Continuously recognises text in incoming camera frames at a throttled rate
// (default ~2 fps). Publishes the result as an array of bounding boxes +
// recognised strings so the overlay view can render selectable highlights.

@MainActor
final class LiveOCRService: ObservableObject {

    static let shared = LiveOCRService()

    @Published private(set) var recognised: [OCRBox] = []
    @Published var enabled: Bool = false {
        didSet { if !enabled { recognised = [] } }
    }

    struct OCRBox: Identifiable, Hashable {
        let id = UUID()
        let text: String
        /// Normalised 0–1 rect in image coordinates (origin bottom-left, Vision convention)
        let rect: CGRect
        let confidence: Float
    }

    private var lastProcessedAt: Date = .distantPast
    /// Frames per second cap for OCR — anything over ~2 fps makes the phone
    /// hotter without materially improving tap targets.
    private let throttleFPS: Double = 2.0
    private let recognitionQueue = DispatchQueue(label: "com.mesutcydev.ioslocalllm.live-ocr",
                                                 qos: .utility)
    private var recognitionInFlight = false

    private init() {}

    // MARK: - Frame entry

    /// Called by AnalysisService for every camera frame. Throttles itself
    /// and runs VNRecognizeTextRequest in fast mode.
    func process(pixelBuffer: CVPixelBuffer) {
        guard enabled else { return }
        guard !recognitionInFlight else { return }
        let now = Date()
        if now.timeIntervalSince(lastProcessedAt) < 1.0 / throttleFPS { return }
        lastProcessedAt = now

        // Copy out of the capture pool before handing the frame to Vision on a
        // background queue. The handler wraps the buffer and reads it lazily in
        // perform(); AVFoundation can recycle the pooled buffer for the next
        // frame meanwhile (alwaysDiscardsLateVideoFrames + a small pool),
        // tearing/blending the OCR input. The copy runs at most `throttleFPS`
        // (2) times/sec and only while this opt-in overlay is enabled, so the
        // cost is negligible.
        guard let frame = AnalysisService.deepCopyPixelBuffer(pixelBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: frame,
                                             orientation: .right, options: [:])
        let request = VNRecognizeTextRequest { [weak self] req, error in
            guard let self, error == nil,
                  let results = req.results as? [VNRecognizedTextObservation]
            else { return }

            let boxes: [OCRBox] = results.compactMap { obs in
                guard let top = obs.topCandidates(1).first,
                      top.confidence > 0.3 else { return nil }
                return OCRBox(
                    text: top.string,
                    rect: obs.boundingBox,
                    confidence: top.confidence
                )
            }
            Task { @MainActor [weak self] in
                guard let self, self.enabled else { return }
                self.recognised = boxes
            }
        }
        request.recognitionLevel = .fast       // accuracy < .accurate but ~5x faster
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]

        recognitionInFlight = true

        // Run on one utility queue so Vision jobs never stack up when a frame
        // takes longer than the throttle interval.
        recognitionQueue.async { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.recognitionInFlight = false
                }
            }
            try? handler.perform([request])
        }
    }

    func clear() { recognised = [] }
}
