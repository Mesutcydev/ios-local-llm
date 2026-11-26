import Foundation

enum VoiceCatalogTask: String, Codable, CaseIterable {
    case textToSpeech
    case speechRecognition
}

enum VoiceCatalogSupportLevel: String, Codable {
    case production
    case experimental
    case catalogOnly
    case macOnly
    case licenseReview
}

struct VoiceCatalogEntry: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let task: VoiceCatalogTask
    let summary: String
    let sourceURL: String?
    let supportLevel: VoiceCatalogSupportLevel
    let runtimeAvailable: Bool
    let legacyDownloadID: String?
    let sizeLabel: String?

    /// The engine this entry downloads for, inferred the same way the registry
    /// infers an installed model's engine.
    var voiceEngine: VoiceEngineKind? {
        LocalModelRegistry.voiceEngine(repoID: legacyDownloadID ?? id, displayName: name)
    }

    /// False when the entry's engine has no runtime on this platform — the
    /// ONNX voices on Mac Catalyst. Offering their download would be a dead
    /// end that only fails after a few hundred megabytes.
    var isRunnableOnThisPlatform: Bool {
        voiceEngine?.isSupportedOnThisPlatform ?? true
    }

    var isDownloadEnabled: Bool {
        runtimeAvailable && legacyDownloadID != nil
            && (supportLevel == .production || supportLevel == .experimental)
            && isRunnableOnThisPlatform
    }

    var statusLabel: String {
        if runtimeAvailable, !isRunnableOnThisPlatform { return "Runtime Not Available" }
        switch supportLevel {
        case .production:    return runtimeAvailable ? "Available" : "Runtime Not Available"
        case .experimental:  return runtimeAvailable ? "Experimental" : "Runtime Required"
        case .catalogOnly:   return "Runtime Required"
        case .macOnly:       return "Mac Only"
        case .licenseReview: return "License Review Required"
        }
    }
}

struct VoiceCatalogDocument: Codable {
    let schemaVersion: Int
    let entries: [VoiceCatalogEntry]
}

enum VoiceCatalogLoadState: Equatable {
    case idle, loading, loaded, failed
}
