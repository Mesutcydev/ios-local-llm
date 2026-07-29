import Foundation
import SwiftUI

// MARK: - BenchmarkService
// Runs a deterministic prompt suite against the currently loaded assistant
// model and records latency, throughput, memory, and thermal metrics.
//
// Why we don't run pre-canned MLPerf-style suites: those need controlled
// kernels and hardware introspection we don't have on iOS. Instead we measure
// what actually matters to the user — TTFT, decode t/s, peak RSS, and whether
// the run pushed the device into a hotter thermal bucket.

@MainActor
final class BenchmarkService: ObservableObject {

    static let shared = BenchmarkService()

    // MARK: - Result models

    /// Single prompt run.
    struct PromptRun: Codable, Identifiable, Hashable {
        var id = UUID()
        let label: String                // "short" / "medium" / "long"
        let prompt: String
        let outputTokens: Int            // tokens produced (approximate)
        let ttftMs: Double               // time-to-first-token in milliseconds
        let decodeTokensPerSec: Double   // sustained decode throughput
        let totalWallMs: Double          // generate() call to onComplete
        let peakRSSBytes: Int64          // process resident memory peak during run
        /// Throughput samples over time — one entry per second of generation.
        /// Records (elapsedSecond, tokensPerSec) pairs for plotting.
        var throughputSamples: [ThroughputSample] = []

        struct ThroughputSample: Codable, Hashable {
            let elapsedSec: Double
            let tokensPerSec: Double
        }
    }

    /// A whole benchmark — one or more prompt runs against one model.
    struct BenchmarkResult: Codable, Identifiable, Hashable {
        var id = UUID()
        let modelID: String              // AssistantModel.id (or repo id)
        let modelDisplayName: String
        let deviceModel: String          // e.g. "iPhone17,3"
        let osVersion: String            // e.g. "iOS 26.5"
        let totalRAMBytes: Int64
        let timestamp: Date
        let thermalStart: Int            // ProcessInfo.ThermalState.rawValue
        let thermalEnd: Int
        let runs: [PromptRun]
        /// Name of the benchmark pack used (e.g. "default", "humaneval-lite").
        var packName: String = "default"

        // Aggregates — easier than recomputing every time the UI renders.
        var avgTTFT: Double {
            runs.isEmpty ? 0 : runs.map(\.ttftMs).reduce(0, +) / Double(runs.count)
        }
        var avgDecode: Double {
            runs.isEmpty ? 0 : runs.map(\.decodeTokensPerSec).reduce(0, +) / Double(runs.count)
        }
        var peakRSS: Int64 {
            runs.map(\.peakRSSBytes).max() ?? 0
        }
        /// Combined throughput samples across all runs, sorted by elapsed time.
        var allThroughputSamples: [PromptRun.ThroughputSample] {
            runs.flatMap { $0.throughputSamples }.sorted { $0.elapsedSec < $1.elapsedSec }
        }
    }

    // MARK: - Prompts

    /// Three sizes — short / medium / long. Wording is plain and steers the
    /// model into deterministic-ish completions so cross-model comparisons
    /// stay meaningful.
    struct BenchmarkPrompt: Hashable {
        let label: String
        let prompt: String
        let maxTokens: Int
    }

    nonisolated static let defaultPrompts: [BenchmarkPrompt] = [
        BenchmarkPrompt(
            label: "short",
            prompt: "Write a 4-line haiku about a quiet morning. No commentary, just the poem.",
            maxTokens: 64
        ),
        BenchmarkPrompt(
            label: "medium",
            prompt: "Explain in 5 sentences what a hash table is and when not to use one.",
            maxTokens: 256
        ),
        BenchmarkPrompt(
            label: "long",
            prompt: "Write a Python function that performs in-place quicksort on an integer array. Include docstring, type hints, and 2 example calls. No explanation outside the code block.",
            maxTokens: 512
        ),
    ]

    // MARK: - Published state

    enum Phase: Equatable {
        case idle
        case preparing                   // loading or switching model
        case running(promptIndex: Int, label: String)
        case finished(BenchmarkResult)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveOutput: String = ""
    /// Past benchmarks, newest first. Persisted across launches.
    @Published private(set) var history: [BenchmarkResult] = []

    /// Set by `cancel()`. Checked between prompt runs so an in-flight
    /// benchmark stops without recording a partial, misleading result.
    private var cancelRequested = false

    /// Request cancellation of the running benchmark. Stops the current
    /// prompt's generation (resuming its continuation) and bails before the
    /// next prompt without persisting a partial result. No-op when idle.
    func cancel() {
        switch phase {
        case .preparing, .running:
            cancelRequested = true
            CodingAssistantService.shared.stopGeneration()
        default:
            break
        }
    }

    // MARK: - Init

    private init() {
        load()
    }

    // MARK: - Run

    /// Runs the benchmark against the currently loaded model. Delegates to
    /// the pack-based runner with the default pack.
    func run() async {
        await run(prompts: Self.defaultPrompts, packName: "default")
    }

    // MARK: - Single run

    private func runSingle(prompt: BenchmarkPrompt) async throws -> PromptRun {
        let assistant = CodingAssistantService.shared

        // We need a few values pulled from the streaming callbacks. They run
        // off the main actor, so wrap them in a Sendable box.
        actor RunMetrics {
            var ttftMs: Double? = nil
            var lastTokenCount = 0
            var outputBuffer = ""
            var peakRSS: Int64 = 0
            var throughputSamples: [PromptRun.ThroughputSample] = []
            var lastSampleTime: Date = Date()
            func setTTFT(_ v: Double) { if ttftMs == nil { ttftMs = v } }
            func bumpTokens() { lastTokenCount += 1 }
            func appendOutput(_ s: String) { outputBuffer += s }
            func updatePeakRSS(_ s: Int64) { if s > peakRSS { peakRSS = s } }
            func recordThroughput(tokensPerSec: Double, elapsedSec: Double) {
                throughputSamples.append(PromptRun.ThroughputSample(elapsedSec: elapsedSec, tokensPerSec: tokensPerSec))
            }
            func snapshot() -> (Double?, Int, String, Int64, [PromptRun.ThroughputSample]) {
                (ttftMs, lastTokenCount, outputBuffer, peakRSS, throughputSamples)
            }
        }
        let metrics = RunMetrics()

        // Override the user's max_tokens for this run so different settings
        // don't skew comparisons across runs.
        let originalMax = AppSettings.shared.assistantMaxTokens
        AppSettings.shared.assistantMaxTokens = prompt.maxTokens
        defer { AppSettings.shared.assistantMaxTokens = originalMax }

        // Memory sampler — polls RSS every 200ms during the run.
        let samplerTask = Task { @MainActor in
            while !Task.isCancelled {
                let rss = MemoryAdvisor.deviceTotalRAM - MemoryAdvisor.nonResidentRAMEstimate
                await metrics.updatePeakRSS(rss)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { samplerTask.cancel() }

        let wallStart = Date()
        // Box rate in a reference type so concurrent capture is safe.
        final class RateBox: @unchecked Sendable { var value: Double = 0 }
        let decodeRateBox = RateBox()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PromptRun, Error>) in
            let messages: [ChatMessage] = [
                ChatMessage(role: .system, content: "You are a benchmark target. Reply only with the requested content. No preamble."),
                ChatMessage(role: .user, content: prompt.prompt)
            ]
            assistant.generate(
                messages: messages,
                onToken: { token in
                    let now = Date()
                    Task {
                        await metrics.setTTFT(now.timeIntervalSince(wallStart) * 1000)
                        await metrics.bumpTokens()
                        await metrics.appendOutput(token)
                        // Main-actor work (UI update + reading the @MainActor
                        // tokenRate) stays in a *synchronous* MainActor.run;
                        // the actor call that records the sample happens after,
                        // since MainActor.run can't host an `await`.
                        let (tps, elapsed): (Double, Double) = await MainActor.run {
                            BenchmarkService.shared.liveOutput += token
                            let elapsed = Date().timeIntervalSince(wallStart)
                            let tps = CodingAssistantService.shared.tokenRate
                            return (tps, elapsed)
                        }
                        await metrics.recordThroughput(tokensPerSec: tps, elapsedSec: elapsed)
                    }
                },
                onComplete: { rate in
                    decodeRateBox.value = rate
                    let wallMs = Date().timeIntervalSince(wallStart) * 1000
                    Task {
                        let snap = await metrics.snapshot()
                        let run = PromptRun(
                            label: prompt.label,
                            prompt: prompt.prompt,
                            outputTokens: snap.1,
                            ttftMs: snap.0 ?? wallMs,
                            decodeTokensPerSec: decodeRateBox.value,
                            totalWallMs: wallMs,
                            peakRSSBytes: snap.3,
                            throughputSamples: snap.4
                        )
                        continuation.resume(returning: run)
                    }
                }
            )
        }
    }

    // MARK: - Persistence

    private let storageKey = "ioslocalllm.benchmark.history.v1"

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([BenchmarkResult].self, from: data)
        else { return }
        history = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    func delete(_ result: BenchmarkResult) {
        history.removeAll { $0.id == result.id }
        save()
    }

    // MARK: - Community Benchmark Packs (Feature #12)

    /// Named benchmark packs that users can pick from.
    struct BenchmarkPack: Identifiable, Hashable {
        let id: String
        let name: String
        let description: String
        let prompts: [BenchmarkPrompt]
    }

    /// Pre-built benchmark packs for community use.
    nonisolated static let communityPacks: [BenchmarkPack] = [
        BenchmarkPack(
            id: "default",
            name: "Default Suite",
            description: "Short, medium, and long prompts covering poetry, explanation, and code.",
            prompts: defaultPrompts
        ),
        BenchmarkPack(
            id: "code-lite",
            name: "Code-Lite",
            description: "Three coding tasks of increasing complexity.",
            prompts: [
                BenchmarkPrompt(label: "fizzbuzz", prompt: "Write a Python function fizzbuzz(n) that returns a list of strings: numbers, 'Fizz', 'Buzz', or 'FizzBuzz'. Include type hints and a docstring.", maxTokens: 256),
                BenchmarkPrompt(label: "binary-search", prompt: "Implement binary search in Python with type hints and an example. Return the index or -1.", maxTokens: 256),
                BenchmarkPrompt(label: "async-fetch", prompt: "Write a Python async function that fetches JSON from a URL using aiohttp, handles errors, and returns the parsed dict.", maxTokens: 384),
            ]
        ),
        BenchmarkPack(
            id: "reasoning",
            name: "Reasoning",
            description: "Multi-step logic and math problems.",
            prompts: [
                BenchmarkPrompt(label: "logic", prompt: "If all A are B, and some B are C, what can we conclude about A and C? Explain step by step.", maxTokens: 256),
                BenchmarkPrompt(label: "math", prompt: "A train leaves at 60 mph. Another train leaves 2 hours later at 90 mph on the same track. When do they meet? Show your work.", maxTokens: 256),
                BenchmarkPrompt(label: "paradox", prompt: "Explain the Monty Hall problem and why switching doors gives a 2/3 chance. Include probability calculations.", maxTokens: 384),
            ]
        ),
        BenchmarkPack(
            id: "creative",
            name: "Creative Writing",
            description: "Tests creativity, coherence, and style.",
            prompts: [
                BenchmarkPrompt(label: "story", prompt: "Write a 100-word micro-story that begins with: 'The last library on Earth had no books.'", maxTokens: 256),
                BenchmarkPrompt(label: "dialogue", prompt: "Write a dialogue between a time traveler and a medieval blacksmith. Each speaks 3 times. Make it feel real.", maxTokens: 384),
            ]
        ),
        BenchmarkPack(
            id: "quick",
            name: "Quick Smoke Test",
            description: "Two short prompts for a rapid model sanity check.",
            prompts: [
                BenchmarkPrompt(label: "greet", prompt: "Say hello and introduce yourself in one sentence.", maxTokens: 64),
                BenchmarkPrompt(label: "fact", prompt: "What is 17 × 23? Answer with just the number.", maxTokens: 32),
            ]
        ),
    ]

    /// Run a specific benchmark pack.
    func run(pack: BenchmarkPack) async {
        await run(prompts: pack.prompts, packName: pack.name)
    }

    /// Run with a named pack (used internally).
    private func run(prompts: [BenchmarkPrompt], packName: String) async {
        let assistant = CodingAssistantService.shared
        guard case .ready = assistant.state else {
            phase = .failed("Load a model before running the benchmark.")
            return
        }

        let safety = DeviceSafetyMonitor.shared
        if safety.shouldStopHeavyWork {
            phase = .failed("Device is too warm for an accurate benchmark. Let it cool, then retry.")
            return
        }

        phase = .preparing
        liveOutput = ""
        cancelRequested = false
        let thermalStart = ProcessInfo.processInfo.thermalState
        if thermalStart == .serious || thermalStart == .critical {
            ToastCenter.shared.info(
                "Device is warm",
                detail: "iOS may throttle clocks — benchmark results can read lower than normal."
            )
        }

        // A benchmark is a sustained workload; if auto-lock fires mid-run the
        // app backgrounds and GPU access is revoked, killing the run.
        safety.setKeepAwake(true, reason: "benchmark")
        defer { safety.setKeepAwake(false, reason: "benchmark") }

        var runs: [PromptRun] = []
        for (i, p) in prompts.enumerated() {
            if cancelRequested { phase = .idle; return }
            if safety.shouldStopHeavyWork {
                phase = .failed("Stopped — device too hot mid-run. Let it cool, then retry.")
                return
            }
            phase = .running(promptIndex: i, label: p.label)
            do {
                let run = try await runSingle(prompt: p)
                if cancelRequested { phase = .idle; return }
                runs.append(run)
            } catch {
                phase = .failed("\(p.label) failed: \(error.localizedDescription)")
                return
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        let thermalEnd = ProcessInfo.processInfo.thermalState
        let device = UIDevice.current
        let result = BenchmarkResult(
            modelID: assistant.activeModel.id,
            modelDisplayName: assistant.activeModel.displayName,
            deviceModel: hardwareModel(),
            osVersion: "\(device.systemName) \(device.systemVersion)",
            totalRAMBytes: MemoryAdvisor.deviceTotalRAM,
            timestamp: Date(),
            thermalStart: thermalStart.rawValue,
            thermalEnd: thermalEnd.rawValue,
            runs: runs,
            packName: packName
        )
        history.insert(result, at: 0)
        if history.count > 50 { history = Array(history.prefix(50)) }
        save()
        phase = .finished(result)
    }

    // MARK: - CSV Export (Feature #12)

    /// Export all benchmark history as a CSV string suitable for sharing.
    func exportCSV() -> String {
        var csv = "model,pack,device,os,date,ttft_ms,decode_tps,peak_rss_mb,thermal_start,thermal_end\n"
        let formatter = ISO8601DateFormatter()
        for result in history {
            for run in result.runs {
                let ttft = String(format: "%.1f", run.ttftMs)
                let tps = String(format: "%.1f", run.decodeTokensPerSec)
                let rss = String(format: "%.0f", Double(run.peakRSSBytes) / 1_000_000)
                csv += "\(result.modelDisplayName),\(result.packName),\(result.deviceModel),\(result.osVersion),\(formatter.string(from: result.timestamp)),\(ttft),\(tps),\(rss),\(result.thermalStart),\(result.thermalEnd)\n"
            }
        }
        return csv
    }

    /// Export the most recent benchmark result as CSV.
    func exportLatestCSV() -> String? {
        guard let latest = history.first else { return nil }
        var csv = "model,pack,device,os,date,ttft_ms,decode_tps,peak_rss_mb,thermal_start,thermal_end\n"
        let formatter = ISO8601DateFormatter()
        for run in latest.runs {
            let ttft = String(format: "%.1f", run.ttftMs)
            let tps = String(format: "%.1f", run.decodeTokensPerSec)
            let rss = String(format: "%.0f", Double(run.peakRSSBytes) / 1_000_000)
            csv += "\(latest.modelDisplayName),\(latest.packName),\(latest.deviceModel),\(latest.osVersion),\(formatter.string(from: latest.timestamp)),\(ttft),\(tps),\(rss),\(latest.thermalStart),\(latest.thermalEnd)\n"
        }
        return csv
    }

    // MARK: - Helpers

    /// Hardware model identifier like "iPhone17,3". Useful for grouping
    /// benchmarks across users with the same device class.
    private func hardwareModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, child in
            if let value = child.value as? Int8, value != 0 {
                result.append(String(UnicodeScalar(UInt8(value))))
            }
        }
    }
}
