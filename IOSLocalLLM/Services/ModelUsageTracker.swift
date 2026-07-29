import Foundation
import Combine

// MARK: - ModelUsageTracker
// Persists per-model usage stats so the "history" surface shows real numbers
// across app launches (not just the last generation in memory).
//
// What we track per model:
//   • lastUsedAt
//   • runCount        — total generations
//   • avgTPS          — running average of tokens-per-second
//   • lastTPS
//   • totalTokens     — lifetime tokens generated
//   • avgLoadTimeMs   — running average of load time
//
// Storage: a single JSON blob in UserDefaults. Tiny (<5 KB).

@MainActor
final class ModelUsageTracker: ObservableObject {

    static let shared = ModelUsageTracker()

    @Published private(set) var stats: [String: Stat] = [:]

    struct Stat: Codable, Equatable {
        var lastUsedAt: Date
        var runCount: Int
        var totalTokens: Int
        var avgTPS: Double
        var lastTPS: Double
        var avgLoadTimeMs: Double
    }

    private let storageKey = "modelUsageStats.v1"

    // MARK: - Init

    private init() { load() }

    // MARK: - Recording

    /// Record a single generation run.
    func recordGeneration(modelID: String, tokens: Int, tokensPerSecond: Double) {
        var s = stats[modelID] ?? Stat(
            lastUsedAt: .now, runCount: 0, totalTokens: 0,
            avgTPS: 0, lastTPS: 0, avgLoadTimeMs: 0
        )
        s.lastUsedAt   = .now
        s.runCount    += 1
        s.totalTokens += tokens
        s.lastTPS      = tokensPerSecond
        // Running average — gives recent runs more weight than ancient ones.
        let alpha = 0.3
        s.avgTPS = s.avgTPS == 0
            ? tokensPerSecond
            : (1 - alpha) * s.avgTPS + alpha * tokensPerSecond
        stats[modelID] = s
        persist()
    }

    /// Record a model load time (milliseconds).
    func recordLoadTime(modelID: String, ms: Double) {
        var s = stats[modelID] ?? Stat(
            lastUsedAt: .now, runCount: 0, totalTokens: 0,
            avgTPS: 0, lastTPS: 0, avgLoadTimeMs: 0
        )
        let alpha = 0.4
        s.avgLoadTimeMs = s.avgLoadTimeMs == 0
            ? ms
            : (1 - alpha) * s.avgLoadTimeMs + alpha * ms
        stats[modelID] = s
        persist()
    }

    func resetAll() {
        stats.removeAll()
        persist()
    }

    // MARK: - Read helpers

    func lastUsed(for id: String) -> Date? { stats[id]?.lastUsedAt }
    func lastTPS(for id: String) -> Double? { stats[id]?.lastTPS }
    func avgTPS(for id: String) -> Double? { stats[id]?.avgTPS }
    func runCount(for id: String) -> Int   { stats[id]?.runCount ?? 0 }

    var topRecentlyUsed: [(id: String, stat: Stat)] {
        stats.map { ($0.key, $0.value) }
            .sorted { $0.stat.lastUsedAt > $1.stat.lastUsedAt }
    }

    // MARK: - Persist

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Stat].self, from: data)
        else { return }
        stats = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// MARK: - Date relative formatter

extension Date {
    var relativeShort: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: self, relativeTo: .now)
    }
}
