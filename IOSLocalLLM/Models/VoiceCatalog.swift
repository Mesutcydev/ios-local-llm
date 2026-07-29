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

    var isDownloadEnabled: Bool {
        runtimeAvailable && legacyDownloadID != nil
            && (supportLevel == .production || supportLevel == .experimental)
    }

    var statusLabel: String {
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
