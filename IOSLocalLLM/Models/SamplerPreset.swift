import Foundation
import SwiftUI

// MARK: - SamplerPreset
// Pre-configured sampler combos for one-tap switching. Each preset bundles
// temperature, topP, topK, minP, repetitionPenalty, frequencyPenalty,
// presencePenalty, and an optional fixed seed for deterministic runs.

struct SamplerPreset: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var icon: String              // SF Symbol
    var description: String
    var temperature: Double
    var topP: Double
    var topK: Int
    var minP: Double
    var repetitionPenalty: Double
    var frequencyPenalty: Double
    var presencePenalty: Double
    var seed: UInt64?
    var colorName: String         // "accent" / "good" / "warn" / "creative"

    var color: Color {
        switch colorName {
        case "good":      return .green
        case "warn":      return .orange
        case "creative":  return .purple
        default:          return .blue
        }
    }

    static let presets: [SamplerPreset] = [
        SamplerPreset(
            id: "precise",
            name: "Precise",
            icon: "target",
            description: "Low temp, deterministic — best for code & facts",
            temperature: 0.1, topP: 0.9, topK: 40, minP: 0.0,
            repetitionPenalty: 1.05, frequencyPenalty: 0.0, presencePenalty: 0.0,
            seed: 42, colorName: "accent"
        ),
        SamplerPreset(
            id: "balanced",
            name: "Balanced",
            icon: "equal.circle",
            description: "Default all-rounder — good for general chat",
            temperature: 0.6, topP: 0.95, topK: 50, minP: 0.0,
            repetitionPenalty: 1.05, frequencyPenalty: 0.0, presencePenalty: 0.0,
            seed: nil, colorName: "accent"
        ),
        SamplerPreset(
            id: "creative",
            name: "Creative",
            icon: "sparkles",
            description: "High temp, wide nucleus — stories & brainstorming",
            temperature: 1.0, topP: 0.98, topK: 80, minP: 0.0,
            repetitionPenalty: 1.02, frequencyPenalty: 0.1, presencePenalty: 0.1,
            seed: nil, colorName: "creative"
        ),
        SamplerPreset(
            id: "deterministic",
            name: "Deterministic",
            icon: "lock.circle",
            description: "Fixed seed, temp 0 — exactly reproducible",
            temperature: 0.0, topP: 1.0, topK: 0, minP: 0.0,
            repetitionPenalty: 1.0, frequencyPenalty: 0.0, presencePenalty: 0.0,
            seed: 42, colorName: "good"
        ),
        SamplerPreset(
            id: "code",
            name: "Code",
            icon: "chevron.left.forwardslash.chevron.right",
            description: "Low temp + repeat penalty — minimizes syntax loops",
            temperature: 0.2, topP: 0.92, topK: 50, minP: 0.0,
            repetitionPenalty: 1.10, frequencyPenalty: 0.1, presencePenalty: 0.0,
            seed: nil, colorName: "accent"
        ),
    ]

    static func preset(for id: String) -> SamplerPreset? {
        presets.first { $0.id == id }
    }
}

// MARK: - SamplerConfig (runtime parameters, not persisted)
// Union of a preset override or individual knob settings. Used to pass
// sampler configuration from the UI to CodingAssistantService.generate().

struct SamplerConfig: Equatable {
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var minP: Double?
    var repetitionPenalty: Double?
    var frequencyPenalty: Double?
    var presencePenalty: Double?
    var seed: UInt64?

    /// Build from a preset — fills all fields.
    static func fromPreset(_ p: SamplerPreset) -> SamplerConfig {
        SamplerConfig(
            temperature: p.temperature,
            topP: p.topP,
            topK: p.topK,
            minP: p.minP,
            repetitionPenalty: p.repetitionPenalty,
            frequencyPenalty: p.frequencyPenalty,
            presencePenalty: p.presencePenalty,
            seed: p.seed
        )
    }

    /// Empty config — generate() falls back to AppSettings defaults.
    static let `default` = SamplerConfig()
}

// MARK: - Persistent per-model generation settings

/// A complete Assistant generation profile saved for one model repository.
///
/// Absence from `AssistantModelSettingsStore` intentionally means "follow the
/// app-wide Assistant settings." This keeps the existing Settings page as the
/// default source of truth while allowing individual models to diverge.
struct AssistantModelGenerationSettings: Codable, Equatable, Sendable {
    var maxTokens: Int
    var temperature: Double
    var topP: Double
    var topK: Int
    var minP: Double
    var repetitionPenalty: Double
    var thinkingEnabled: Bool

    static let standard = AssistantModelGenerationSettings(
        maxTokens: 2_048,
        temperature: 0.6,
        topP: 0.95,
        topK: 50,
        minP: 0,
        repetitionPenalty: 1.05,
        thinkingEnabled: false
    )

    static func appDefaults(
        from settings: AppSettings,
        supportsThinking: Bool
    ) -> Self {
        AssistantModelGenerationSettings(
            maxTokens: settings.assistantMaxTokens,
            temperature: settings.assistantTemperature,
            topP: settings.assistantTopP,
            topK: settings.assistantTopK,
            minP: settings.assistantMinP,
            repetitionPenalty: settings.assistantRepetitionPenalty,
            thinkingEnabled: supportsThinking && settings.assistantThinking
        )
    }

    func clamped(supportsThinking: Bool) -> Self {
        AssistantModelGenerationSettings(
            maxTokens: min(4_096, max(128, maxTokens)),
            temperature: min(1.5, max(0, temperature)),
            topP: min(1, max(0.05, topP)),
            topK: min(100, max(0, topK)),
            minP: min(0.5, max(0, minP)),
            repetitionPenalty: min(1.3, max(1, repetitionPenalty)),
            thinkingEnabled: supportsThinking && thinkingEnabled
        )
    }
}

/// UserDefaults-backed repository of model-specific Assistant profiles.
///
/// Repository IDs are canonicalized so a model selected through a catalog
/// preset and the same model selected from Downloads share one saved profile.
@MainActor
final class AssistantModelSettingsStore: ObservableObject {
    static let shared = AssistantModelSettingsStore()

    private struct Payload: Codable {
        var version: Int = 1
        var settingsByRepository: [String: AssistantModelGenerationSettings]
    }

    @Published private(set) var overrides: [String: AssistantModelGenerationSettings]

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "assistantModelGenerationSettings.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let payload = try? JSONDecoder().decode(Payload.self, from: data),
           payload.version == 1 {
            overrides = payload.settingsByRepository
        } else {
            overrides = [:]
        }
    }

    func settings(for repositoryID: String) -> AssistantModelGenerationSettings? {
        overrides[canonicalID(repositoryID)]
    }

    func save(
        _ settings: AssistantModelGenerationSettings,
        for repositoryID: String,
        supportsThinking: Bool
    ) {
        var updated = overrides
        updated[canonicalID(repositoryID)] = settings.clamped(
            supportsThinking: supportsThinking
        )
        overrides = updated
        persist()
    }

    func reset(repositoryID: String) {
        var updated = overrides
        updated.removeValue(forKey: canonicalID(repositoryID))
        overrides = updated
        persist()
    }

    func effectiveSettings(
        for repositoryID: String,
        supportsThinking: Bool,
        appSettings: AppSettings
    ) -> AssistantModelGenerationSettings {
        settings(for: repositoryID)
            ?? .appDefaults(from: appSettings, supportsThinking: supportsThinking)
    }

    private func persist() {
        let payload = Payload(settingsByRepository: overrides)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func canonicalID(_ repositoryID: String) -> String {
        repositoryID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
