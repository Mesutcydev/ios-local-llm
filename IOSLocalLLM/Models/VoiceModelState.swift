import Foundation

// MARK: - VoiceModelState
// Mirrors FastVLMModelState but scoped to voice engine loading.

enum VoiceModelState: Equatable {
    case unloaded
    case loading
    case ready
    case failed(String)

    // MARK: - Display

    var statusLabel: String {
        switch self {
        case .unloaded:        return "Not loaded"
        case .loading:         return "Loading…"
        case .ready:           return "Ready"
        case .failed(let msg): return "Error: \(msg)"
        }
    }

    var isReady: Bool { self == .ready }
    var isLoading: Bool { self == .loading }
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    // MARK: - Equatable

    static func == (lhs: VoiceModelState, rhs: VoiceModelState) -> Bool {
        switch (lhs, rhs) {
        case (.unloaded, .unloaded): return true
        case (.loading,  .loading):  return true
        case (.ready,    .ready):    return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}
