import Foundation

struct AiderModelMetadata: Codable, Equatable, Sendable {
    let maxTokens: Int
    let maxInputTokens: Int
    let maxOutputTokens: Int
    let inputCostPerToken: Double
    let outputCostPerToken: Double
    let litellmProvider: String
    let mode: String
    let supportsFunctionCalling: Bool
    let supportsVision: Bool

    enum CodingKeys: String, CodingKey {
        case maxTokens = "max_tokens"
        case maxInputTokens = "max_input_tokens"
        case maxOutputTokens = "max_output_tokens"
        case inputCostPerToken = "input_cost_per_token"
        case outputCostPerToken = "output_cost_per_token"
        case litellmProvider = "litellm_provider"
        case mode
        case supportsFunctionCalling = "supports_function_calling"
        case supportsVision = "supports_vision"
    }
}

struct AiderConfigurationExport: Equatable, Sendable {
    let modelName: String
    let metadataJSON: String
    let settingsYAML: String
    let launchCommand: String

    var metadataObject: [String: AiderModelMetadata] {
        guard let data = metadataJSON.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: AiderModelMetadata].self, from: data)) ?? [:]
    }
}

enum AiderConfigurationExporter {
    static func modelName(for modelID: String) -> String {
        modelID.hasPrefix("openai/") ? modelID : "openai/\(modelID)"
    }

    static func export(
        modelID: String,
        profile: ModelCapabilityProfile,
        supportsFunctionCalling: Bool,
        supportsVision: Bool,
        effectiveMaximumOutputTokens: Int? = nil,
        baseURL: String = "http://127.0.0.1:11434/v1"
    ) -> AiderConfigurationExport {
        let modelName = modelName(for: modelID)
        let maxOutput = max(1, min(profile.maximumOutputTokens, effectiveMaximumOutputTokens ?? profile.maximumOutputTokens))
        let metadata = AiderModelMetadata(
            maxTokens: maxOutput,
            maxInputTokens: profile.effectiveContextWindow,
            maxOutputTokens: maxOutput,
            inputCostPerToken: 0,
            outputCostPerToken: 0,
            litellmProvider: "openai",
            mode: "chat",
            supportsFunctionCalling: supportsFunctionCalling,
            supportsVision: supportsVision
        )
        let metadataObject = [modelName: metadata]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataJSON = (try? encoder.encode(metadataObject))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{}"
        let settingsYAML = """
        - name: "\(yamlString(modelName))"
          edit_format: whole
          streaming: true
          use_repo_map: true
          extra_params:
            max_tokens: \(maxOutput)
        """
        let launchCommand = "AIDER_API_BASE=\(shellString(baseURL)) AIDER_API_KEY=YOUR_LOCAL_API_KEY aider --model \(shellString(modelName)) --model-metadata-file .aider.model.metadata.json --model-settings-file .aider.model.settings.yml"
        return AiderConfigurationExport(
            modelName: modelName,
            metadataJSON: metadataJSON,
            settingsYAML: settingsYAML,
            launchCommand: launchCommand
        )
    }

    private static func yamlString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func shellString(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
