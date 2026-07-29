import Foundation

// MARK: - FastVLMGenerationSettings
// User-configurable parameters for autoregressive token generation.

struct FastVLMGenerationSettings: Equatable {
    var maxTokens: Int
    var temperature: Float
    var topP: Float
    var repetitionPenalty: Float
    var stopOnEOS: Bool

    static let `default` = FastVLMGenerationSettings(
        maxTokens: FastVLMConfig.defaultMaxTokens,
        temperature: FastVLMConfig.defaultTemperature,
        topP: FastVLMConfig.defaultTopP,
        repetitionPenalty: FastVLMConfig.defaultRepetitionPenalty,
        stopOnEOS: true
    )

    /// Convenience: build from AppSettings values.
    static func fromAppSettings() -> FastVLMGenerationSettings {
        FastVLMGenerationSettings(
            maxTokens: AppSettings.shared.fastvlmMaxTokens,
            temperature: Float(AppSettings.shared.fastvlmTemperature),
            topP: 0.9,
            repetitionPenalty: 1.05,
            stopOnEOS: true
        )
    }
}
