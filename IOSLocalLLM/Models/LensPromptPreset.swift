import Foundation

// MARK: - LensPromptPreset
// Curated prompt presets the user can swap in for the camera tab's visual
// mode. The rawValue is what gets persisted in AppStorage; `prompt` is the
// actual text sent to the VLM. Designed for short, on-device VLMs (SmolVLM,
// Qwen2-VL etc.) — keep instructions terse so small models don't wander.

enum LensPromptPreset: String, CaseIterable, Identifiable {
    case describe
    case shortDescription
    case detailedDescription
    case whatIsOnScreen
    case translate
    case solve
    case extractCode
    case reviewCode
    case explainUI
    case findErrors

    var id: String { rawValue }

    /// Short label for chips and rows. Lowercase to match the camera tab's
    /// mono-pill aesthetic.
    var label: String {
        switch self {
        case .describe:            return "describe"
        case .shortDescription:    return "short"
        case .detailedDescription: return "detailed"
        case .whatIsOnScreen:      return "what's on screen"
        case .translate:           return "translate"
        case .solve:               return "solve"
        case .extractCode:         return "extract code"
        case .reviewCode:          return "review code"
        case .explainUI:           return "explain ui"
        case .findErrors:          return "find errors"
        }
    }

    /// One-line hint shown in the picker sheet.
    var hint: String {
        switch self {
        case .describe:            return "one short sentence — default"
        case .shortDescription:    return "ten words or fewer"
        case .detailedDescription: return "richer multi-sentence answer"
        case .whatIsOnScreen:      return "literal inventory of what's visible"
        case .translate:           return "translate visible text to English"
        case .solve:               return "solve the problem or question shown"
        case .extractCode:         return "transcribe visible code/text"
        case .reviewCode:          return "spot bugs or improvements"
        case .explainUI:           return "describe the UI elements & layout"
        case .findErrors:          return "highlight visible errors or warnings"
        }
    }

    /// Actual instruction sent to the VLM. The system prompt in MLXVisionService
    /// already tells the model to be terse; presets just steer the focus.
    var prompt: String {
        switch self {
        case .describe:
            return "Describe what's in this image clearly and concisely."
        case .shortDescription:
            return "Describe this image in ten words or fewer."
        case .detailedDescription:
            return "Describe this image in detail. Mention the setting, objects, colours, and any text visible."
        case .whatIsOnScreen:
            return "List the objects and text visible in this image."
        case .translate:
            return "Translate all text visible in this image into English. Give only the translation."
        case .solve:
            return "Solve the problem, question, or equation shown in this image. Give the answer and a brief explanation."
        case .extractCode:
            return "Transcribe ALL visible source code or text exactly as shown. Preserve formatting. No explanation."
        case .reviewCode:
            return "Review the code visible in this image. List bugs, issues, or suggested improvements as short bullets."
        case .explainUI:
            return "Describe the user-interface elements visible in this image: buttons, labels, sections, and layout."
        case .findErrors:
            return "Identify any errors, warnings, or red text visible in this image. Quote them verbatim."
        }
    }

    /// True when the preset reads better with a monospaced result card
    /// (code transcription / review / error text).
    var prefersMonospace: Bool {
        switch self {
        case .extractCode, .reviewCode, .findErrors: return true
        default: return false
        }
    }

    static let `default`: LensPromptPreset = .describe

    /// Safe accessor — falls back to `.describe` when the persisted rawValue
    /// no longer matches a known case (e.g. after a downgrade).
    static func from(rawValue: String) -> LensPromptPreset {
        LensPromptPreset(rawValue: rawValue) ?? .default
    }
}
