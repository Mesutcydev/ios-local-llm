import Foundation

// MARK: - FastVLMModelState
// Lifecycle state for a single model component.

enum FastVLMModelState: Equatable {
    case unloaded
    case loading
    case ready
    case failed(String)   // associated String so Equatable works without custom impl

    var isReady: Bool { self == .ready }
    var isLoading: Bool { self == .loading }

    var statusLabel: String {
        switch self {
        case .unloaded:        return "Not loaded"
        case .loading:         return "Loading…"
        case .ready:           return "Ready"
        case .failed(let msg): return "Error: \(msg)"
        }
    }
}

// MARK: - FastVLMComponentStatus
// Aggregated status for all four pipeline components.

struct FastVLMComponentStatus: Equatable {
    var encoder:   FastVLMModelState = .unloaded
    var projector: FastVLMModelState = .unloaded
    var decoder:   FastVLMModelState = .unloaded
    var tokenizer: FastVLMModelState = .unloaded

    /// True when the full VLM pipeline (encoder + projector + decoder + tokenizer) is ready.
    /// This is the ONLY condition under which FastVLM language generation runs.
    var canGenerate: Bool {
        encoder.isReady && projector.isReady && decoder.isReady && tokenizer.isReady
    }

    /// Human-readable list of which components are not yet ready.
    var missingComponentsDescription: String {
        var missing: [String] = []
        if !projector.isReady { missing.append("projector") }
        if !decoder.isReady   { missing.append("decoder") }
        if !tokenizer.isReady { missing.append("tokenizer") }
        if !encoder.isReady   { missing.append("encoder") }
        return missing.isEmpty ? "none" : missing.joined(separator: ", ")
    }

    /// True when at least one component is still loading.
    var isLoading: Bool {
        [encoder, projector, decoder, tokenizer].contains(.loading)
    }
}
