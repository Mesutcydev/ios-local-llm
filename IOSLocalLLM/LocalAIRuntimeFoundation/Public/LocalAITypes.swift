import Foundation
import UIKit

// MARK: - Public model metadata

public struct LocalModel: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var repoID: String
    public var displayName: String
    public var familyID: String
    public var runtime: ModelRuntime
    public var capabilities: Set<ModelCapability>
    public var approxRAMBytes: Int64
    public var contextWindowTokens: Int
    public var isRiskyAfterCrash: Bool

    public init(
        id: String,
        repoID: String,
        displayName: String,
        familyID: String,
        runtime: ModelRuntime,
        capabilities: Set<ModelCapability> = [],
        approxRAMBytes: Int64 = 0,
        contextWindowTokens: Int = 8_192,
        isRiskyAfterCrash: Bool = false
    ) {
        self.id = id
        self.repoID = repoID
        self.displayName = displayName
        self.familyID = familyID
        self.runtime = runtime
        self.capabilities = capabilities
        self.approxRAMBytes = approxRAMBytes
        self.contextWindowTokens = contextWindowTokens
        self.isRiskyAfterCrash = isRiskyAfterCrash
    }
}

extension LocalModel {
    init(assistantModel: AssistantModel, config: LocalAIFoundationConfig = .default) {
        self.init(
            id: assistantModel.id,
            repoID: assistantModel.repoID,
            displayName: assistantModel.displayName,
            familyID: ModelFamily.inferID(from: assistantModel.repoID),
            runtime: assistantModel.runtime,
            capabilities: assistantModel.capabilities,
            approxRAMBytes: assistantModel.approxRAMBytes,
            contextWindowTokens: assistantModel.contextWindowTokens,
            isRiskyAfterCrash: config.riskyModelIDs.contains(assistantModel.id)
                || config.riskyModelIDs.contains(assistantModel.repoID)
        )
    }
}

// MARK: - Messages and attachments

public struct MessageAttachment: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case image
        case video
        case file
        case text
    }

    public let id: UUID
    public var kind: Kind
    public var filename: String?
    public var mimeType: String?
    public var data: Data?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        filename: String? = nil,
        mimeType: String? = nil,
        data: Data? = nil
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public typealias PlatformImage = UIImage

// MARK: - Generation options and events

public enum ThinkingMode: String, Codable, Hashable, Sendable {
    case automatic
    case enabled
    case disabled
}

public enum ToolMode: String, Codable, Hashable, Sendable {
    case disabled
    case automatic
    case required
}

public struct GenerationOptions: Codable, Hashable, Sendable {
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double
    public var repetitionPenalty: Double?
    public var seed: UInt64?
    public var jsonMode: Bool
    public var thinkingMode: ThinkingMode
    public var toolMode: ToolMode
    public var kvCacheBits: Int?

    public init(
        maxTokens: Int = 1_024,
        temperature: Double = 0.7,
        topP: Double = 0.9,
        repetitionPenalty: Double? = nil,
        seed: UInt64? = nil,
        jsonMode: Bool = false,
        thinkingMode: ThinkingMode = .automatic,
        toolMode: ToolMode = .disabled,
        kvCacheBits: Int? = 8
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.seed = seed
        self.jsonMode = jsonMode
        self.thinkingMode = thinkingMode
        self.toolMode = toolMode
        self.kvCacheBits = kvCacheBits
    }

    public static let `default` = GenerationOptions()
}

public enum TokenEvent: Sendable, Equatable {
    case started
    case token(String)
    case partialText(String)
    case usage(tokensPerSecond: Double, inputTokens: Int?, outputTokens: Int?)
    case warning(String)
    case completed
}

// MARK: - Controller state

public enum LoadState: Equatable, Sendable {
    case unloaded
    case loading(String)
    case ready
    case failed(String)
}

public enum GenerationState: Equatable, Sendable {
    case idle
    case generating
    case cancelling
    case failed(String)
}

public struct ResourceStatus: Equatable, Sendable {
    public var availableMemoryBytes: Int64
    public var physFootprintBytes: Int64
    public var thermalStateDescription: String
    public var isLowPowerModeEnabled: Bool
    public var shouldStopHeavyWork: Bool

    public init(
        availableMemoryBytes: Int64 = 0,
        physFootprintBytes: Int64 = 0,
        thermalStateDescription: String = "unknown",
        isLowPowerModeEnabled: Bool = false,
        shouldStopHeavyWork: Bool = false
    ) {
        self.availableMemoryBytes = availableMemoryBytes
        self.physFootprintBytes = physFootprintBytes
        self.thermalStateDescription = thermalStateDescription
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.shouldStopHeavyWork = shouldStopHeavyWork
    }
}

public struct DownloadProgress: Equatable, Sendable {
    public var repoID: String
    public var fractionCompleted: Double
    public var downloadedBytes: Int64
    public var totalBytes: Int64
    public var currentFile: String?

    public init(
        repoID: String = "",
        fractionCompleted: Double = 0,
        downloadedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        currentFile: String? = nil
    ) {
        self.repoID = repoID
        self.fractionCompleted = fractionCompleted
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.currentFile = currentFile
    }
}

// MARK: - Preheat and vector modes

public enum PreheatTarget: Equatable, Sendable {
    case text(modelID: String)
    case vision(modelID: String)
}

public enum PreheatStatus: Equatable, Sendable {
    case idle
    case preparing(PreheatTarget)
    case ready(PreheatTarget)
    case blocked(String)
    case failed(String)
}

public enum VectorStorageMode: String, Codable, Hashable, Sendable {
    case automatic
    case sqliteVec
    case sqliteBlob
    case json
}

public enum VectorQuantizationMode: String, Codable, Hashable, Sendable {
    case float32
    case int8
    case binary
    case automatic
}

// MARK: - Repo compatibility scan

public struct CompatibilityResult: Equatable, Sendable {
    public enum Verdict: String, Equatable, Sendable {
        case runnable   // loads and runs
        case marginal   // loads but tight — expect throttling
        case blocked    // can't run on this device
    }

    public let repoID: String
    public let verdict: Verdict
    public let notes: String

    public init(repoID: String, verdict: Verdict, notes: String) {
        self.repoID = repoID
        self.verdict = verdict
        self.notes = notes
    }
}

extension CompatibilityResult {
    // Bridges the app's internal verdict engine to the foundation type.
    init(repoID: String, verdict: OnDeviceCompatibility.Verdict) {
        switch verdict {
        case .runnable(let notes): self.init(repoID: repoID, verdict: .runnable, notes: notes)
        case .marginal(let notes): self.init(repoID: repoID, verdict: .marginal, notes: notes)
        case .blocked(let reason): self.init(repoID: repoID, verdict: .blocked, notes: reason)
        }
    }
}
