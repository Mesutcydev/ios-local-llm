import Foundation
import CoreGraphics
import CoreImage
import UIKit

// MARK: - YOLO Detection

struct Detection: Identifiable, Equatable {
    let id: UUID
    /// Normalized bounding box (0–1) in image coordinate space
    let boundingBox: CGRect
    let confidence: Float
    let label: String
    let classIndex: Int
    let frameIndex: Int

    init(
        id: UUID = UUID(),
        boundingBox: CGRect,
        confidence: Float,
        label: String,
        classIndex: Int,
        frameIndex: Int = 0
    ) {
        self.id = id
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.label = label
        self.classIndex = classIndex
        self.frameIndex = frameIndex
    }

    static func == (lhs: Detection, rhs: Detection) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - AnalysisMode
// Controls what the FastVLM pipeline is asked to do.

enum AnalysisMode: String, CaseIterable, Identifiable {
    case code   = "code"    // Extract code + generate review (default)
    case visual = "visual"  // Describe what's visible — no code extraction

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .code:   return "Code"
        case .visual: return "Visual"
        }
    }

    var systemImage: String {
        switch self {
        case .code:   return "chevron.left.forwardslash.chevron.right"
        case .visual: return "eye"
        }
    }
}

// MARK: - Analysis Result

struct AnalysisResult: Identifiable {
    let id: UUID
    let detection: Detection
    /// In code mode: the extracted source code.
    /// In visual mode: the scene description from FastVLM.
    /// Mutable so streaming token-by-token updates can mutate in place.
    var extractedCode: String
    /// In code mode: markdown review. In visual mode: empty.
    var reviewMarkdown: String
    /// Which analysis mode produced this result.
    let mode: AnalysisMode
    /// True when result came from OCR, not from the FastVLM language model.
    let ocrFallback: Bool
    /// Non-nil only when ocrFallback is true — explains WHY the fallback was used.
    var fallbackReason: String?
    /// Optional one-tap action surfaced by the result panel when the
    /// fallback is something the user can fix (missing visual model,
    /// FastVLM disabled, etc.). Lets us turn a passive error banner
    /// into an actionable inline button.
    var suggestedAction: SuggestedAction? = nil
    let timestamp: Date
    /// Small thumbnail of the cropped capture (used for history gallery).
    let thumbnail: UIImage?
    /// The CIImage used for analysis. Kept around so the user can ask
    /// follow-up questions about the same capture without re-shooting.
    let ciImage: CIImage?
    /// True while the FastVLM is still streaming tokens into `extractedCode`.
    /// Set to false when generation completes (or errors).
    var isStreaming: Bool
    /// Free-form user follow-up Q&A; populated by askQuestion(_:about:).
    var questionAnswers: [QAExchange]

    /// Inline action surfaced by the panel under a fallback banner.
    /// Each case maps to a single button with a clear next step the
    /// user can tap to recover from the error.
    enum SuggestedAction: String, Equatable {
        /// "Pick a visual model" — opens the onboarding model picker
        /// so the user can choose a visual VLM without leaving the
        /// camera tab.
        case pickVisualModel
        /// "Download FastVLM" — switches to the Models tab Catalog
        /// section where the FastVLM entry's Download button is one
        /// tap away.
        case downloadFastVLM
        /// "Enable in Settings" — opens the Settings sheet so the
        /// user can flip the FastVLM toggle back on.
        case enableFastVLM
    }

    struct QAExchange: Identifiable {
        let id = UUID()
        let question: String
        var answer: String
        var isStreaming: Bool
    }

    init(
        id: UUID = UUID(),
        detection: Detection,
        extractedCode: String,
        reviewMarkdown: String,
        mode: AnalysisMode = .code,
        ocrFallback: Bool = false,
        fallbackReason: String? = nil,
        timestamp: Date = .now,
        thumbnail: UIImage? = nil,
        ciImage: CIImage? = nil,
        isStreaming: Bool = false,
        questionAnswers: [QAExchange] = []
    ) {
        self.id = id
        self.detection = detection
        self.extractedCode = extractedCode
        self.reviewMarkdown = reviewMarkdown
        self.mode = mode
        self.ocrFallback = ocrFallback
        self.fallbackReason = fallbackReason
        self.timestamp = timestamp
        self.thumbnail = thumbnail
        self.ciImage = ciImage
        self.isStreaming = isStreaming
        self.questionAnswers = questionAnswers
    }

    /// Full shareable markdown.
    var fullMarkdown: String {
        switch mode {
        case .code:
            return """
            ## Extracted Code
            ```
            \(extractedCode)
            ```

            ---

            \(reviewMarkdown)
            """
        case .visual:
            return "## Visual Description\n\n\(extractedCode)"
        }
    }
}

// Note: the per-frame text-region detector and its auto-capture tracker were
// removed when Code Mode became tap-to-capture (CodeModeController). `Detection`
// itself is retained because AnalysisResult still carries one (a full-frame
// placeholder) for the visual-caption and imported-image paths.
