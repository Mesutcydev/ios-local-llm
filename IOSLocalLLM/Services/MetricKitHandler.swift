import Foundation
import MetricKit

// MARK: - MetricKitHandler
// Receives daily-rolled crash and performance reports from iOS via MetricKit.
// Stores them locally so the user can see what happened — no telemetry,
// nothing leaves the device. Useful for diagnosing crashes after the fact.
//
// To opt in: add to AppDelegate-equivalent (here we just call subscribe()
// from IOSLocalLLMApp.init).

@MainActor
final class MetricKitHandler: NSObject, ObservableObject, MXMetricManagerSubscriber {

    static let shared = MetricKitHandler()

    /// On-disk persisted summary lines. Capped at 50 to bound storage.
    @Published private(set) var entries: [Entry] = []

    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        let timestamp: Date
        let kind: String          // "crash", "metric"
        let summary: String       // 1-2 sentence summary
        let json: String          // raw JSON payload for debugging
    }

    private let storageKey = "ioslocalllm.metrickit.entries.v1"

    override private init() {
        super.init()
        load()
    }

    /// Subscribe to MetricKit reports. Idempotent — safe to call multiple times.
    func subscribe() {
        MXMetricManager.shared.add(self)
    }

    // MARK: - MXMetricManagerSubscriber

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        let lines = payloads.map { p -> Entry in
            let summary = Self.summarize(metric: p)
            let json = String(data: p.jsonRepresentation(), encoding: .utf8) ?? ""
            return Entry(timestamp: p.timeStampEnd, kind: "metric", summary: summary, json: json)
        }
        Task { @MainActor [weak self] in self?.append(lines) }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var out: [Entry] = []
        for p in payloads {
            // Crashes
            if let crashes = p.crashDiagnostics, !crashes.isEmpty {
                for c in crashes {
                    let summary = "Crash: \(c.exceptionType?.intValue ?? -1) sig=\(c.signal?.intValue ?? -1) reason=\(c.terminationReason ?? "n/a")"
                    let json = String(data: c.jsonRepresentation(), encoding: .utf8) ?? ""
                    out.append(Entry(timestamp: p.timeStampEnd, kind: "crash", summary: summary, json: json))
                }
            }
            // Hangs
            if let hangs = p.hangDiagnostics, !hangs.isEmpty {
                for h in hangs {
                    let summary = "Hang: \(h.hangDuration.description)"
                    let json = String(data: h.jsonRepresentation(), encoding: .utf8) ?? ""
                    out.append(Entry(timestamp: p.timeStampEnd, kind: "hang", summary: summary, json: json))
                }
            }
            // CPU exceptions
            if let cpus = p.cpuExceptionDiagnostics, !cpus.isEmpty {
                for _ in cpus {
                    out.append(Entry(timestamp: p.timeStampEnd, kind: "cpu", summary: "CPU exception", json: ""))
                }
            }
        }
        Task { @MainActor [weak self, out] in self?.append(out) }
    }

    // MARK: - Storage

    private func append(_ new: [Entry]) {
        guard !new.isEmpty else { return }
        entries.insert(contentsOf: new, at: 0)
        if entries.count > 50 { entries = Array(entries.prefix(50)) }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: - Helpers

    nonisolated private static func summarize(metric p: MXMetricPayload) -> String {
        var parts: [String] = []
        if let cpu = p.cpuMetrics?.cumulativeCPUTime {
            parts.append("cpu \(cpu.description)")
        }
        if let mem = p.memoryMetrics?.peakMemoryUsage {
            parts.append("peak \(mem.description)")
        }
        if let app = p.applicationLaunchMetrics?.histogrammedTimeToFirstDraw {
            parts.append("ttfd buckets=\(app.bucketEnumerator.allObjects.count)")
        }
        return parts.isEmpty ? "metric report" : parts.joined(separator: " · ")
    }
}
