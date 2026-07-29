import Foundation
import Combine

// MARK: - NetworkActivityMonitor
// Tracks in-flight URLSession requests originating from CodeLens so the UI
// can show a trust indicator: "local-first" means a visible signal whenever
// ANY network request is happening (model download, HF search, Bridge POST).
//
// Use:
//   1. Wrap any network-touching code:
//        NetworkActivityMonitor.shared.track {
//            let (data, _) = try await URLSession.shared.data(from: url)
//        }
//   2. Or manually:
//        NetworkActivityMonitor.shared.begin(label: "HF Search")
//        defer { NetworkActivityMonitor.shared.end(label: "HF Search") }
//
// The UI observes `inFlightCount` and `activeLabels` to render the dot pill.

@MainActor
final class NetworkActivityMonitor: ObservableObject {

    static let shared = NetworkActivityMonitor()

    @Published private(set) var inFlightCount: Int = 0
    @Published private(set) var activeLabels: [String: Int] = [:]
    @Published private(set) var lastFinished: Date?

    private init() {}

    var isActive: Bool { inFlightCount > 0 }

    /// Combine `activeLabels` keys for tooltip display.
    var topLabel: String? { activeLabels.keys.sorted().first }

    func begin(label: String) {
        inFlightCount += 1
        activeLabels[label, default: 0] += 1
    }

    func end(label: String) {
        inFlightCount = Swift.max(0, inFlightCount - 1)
        if let n = activeLabels[label] {
            if n <= 1 { activeLabels.removeValue(forKey: label) }
            else      { activeLabels[label] = n - 1 }
        }
        lastFinished = Date()
    }

    /// Convenience wrapper. Captures both success and throwing paths.
    func track<T>(label: String, _ block: () async throws -> T) async rethrows -> T {
        begin(label: label)
        defer { end(label: label) }
        return try await block()
    }
}
