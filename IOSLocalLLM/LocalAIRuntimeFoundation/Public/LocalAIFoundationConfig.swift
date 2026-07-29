import Foundation

// MARK: - LocalAIFoundationConfig

public struct LocalAIFoundationConfig: Codable, Hashable, Sendable {
    public var uiBufferIntervalMs: Int
    public var loadSpikeMultiplier: Double
    public var workingSetOverhead: Double
    public var lowPowerMemoryMultiplier: Double
    public var seriousThermalMaxTokens: Int
    public var criticalThermalMaxTokens: Int
    public var defaultContextWindowTokens: Int
    public var ragSemanticWeight: Double
    public var ragLexicalWeight: Double
    public var ragRecencyWeight: Double
    public var bulkIngestionBatchSize: Int
    public var bulkIngestionCoolingSleepMs: Int
    public var downloadRetryLimit: Int
    public var downloadTightDiskHeadroomBytes: Int64
    public var vlmPreheatTimeoutMs: Int
    public var riskyModelIDs: Set<String>

    public init(
        uiBufferIntervalMs: Int = 80,
        loadSpikeMultiplier: Double = 1.6,
        workingSetOverhead: Double = 1.3,
        lowPowerMemoryMultiplier: Double = 0.82,
        seriousThermalMaxTokens: Int = 1_536,
        criticalThermalMaxTokens: Int = 512,
        defaultContextWindowTokens: Int = 8_192,
        ragSemanticWeight: Double = 0.72,
        ragLexicalWeight: Double = 0.18,
        ragRecencyWeight: Double = 0.10,
        bulkIngestionBatchSize: Int = 5,
        bulkIngestionCoolingSleepMs: Int = 100,
        downloadRetryLimit: Int = 3,
        downloadTightDiskHeadroomBytes: Int64 = 200_000_000,
        vlmPreheatTimeoutMs: Int = 30_000,
        riskyModelIDs: Set<String> = []
    ) {
        self.uiBufferIntervalMs = uiBufferIntervalMs
        self.loadSpikeMultiplier = loadSpikeMultiplier
        self.workingSetOverhead = workingSetOverhead
        self.lowPowerMemoryMultiplier = lowPowerMemoryMultiplier
        self.seriousThermalMaxTokens = seriousThermalMaxTokens
        self.criticalThermalMaxTokens = criticalThermalMaxTokens
        self.defaultContextWindowTokens = defaultContextWindowTokens
        self.ragSemanticWeight = ragSemanticWeight
        self.ragLexicalWeight = ragLexicalWeight
        self.ragRecencyWeight = ragRecencyWeight
        self.bulkIngestionBatchSize = bulkIngestionBatchSize
        self.bulkIngestionCoolingSleepMs = bulkIngestionCoolingSleepMs
        self.downloadRetryLimit = downloadRetryLimit
        self.downloadTightDiskHeadroomBytes = downloadTightDiskHeadroomBytes
        self.vlmPreheatTimeoutMs = vlmPreheatTimeoutMs
        self.riskyModelIDs = riskyModelIDs
    }

    public static let `default` = LocalAIFoundationConfig()
}
