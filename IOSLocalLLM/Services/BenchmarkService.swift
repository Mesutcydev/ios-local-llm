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
        var outputCountKind: String? = nil

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

        enum Event: Sendable {
            case chunk(String, Date)
            case completed(Double, Date)
            case failed(String)
        }
        let (events, producer) = AsyncStream<Event>.makeStream()
        let wallStart = Date()
        var firstTokenMs: Double?
        var chunks = 0
        var peakRSS: Int64 = 0
        var samples: [PromptRun.ThroughputSample] = []
        var lastSample = -1.0
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                peakRSS = max(peakRSS, MemoryAdvisor.deviceTotalRAM - MemoryAdvisor.nonResidentRAMEstimate)
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            }
        }
        defer { sampler.cancel() }
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You are a benchmark target. Reply only with the requested content. No preamble."),
            ChatMessage(role: .user, content: prompt.prompt)
        ]
        // A per-request override preserves the user's saved settings.
        assistant.generate(
            messages: messages,
            maxTokensOverride: prompt.maxTokens,
            onToken: { producer.yield(.chunk($0, Date())) },
            onComplete: {
                producer.yield(.completed($0, Date()))
                producer.finish()
            },
            onError: {
                producer.yield(.failed($0))
                producer.finish()
            }
        )
        // One consumer applies callbacks in order before finalizing the run.
        for await event in events {
            peakRSS = max(peakRSS, MemoryAdvisor.deviceTotalRAM - MemoryAdvisor.nonResidentRAMEstimate)
            switch event {
            case let .chunk(text, time):
                let elapsed = time.timeIntervalSince(wallStart)
                if firstTokenMs == nil { firstTokenMs = elapsed * 1000 }
                chunks += 1
                liveOutput += text
                if elapsed - lastSample >= 1 {
                    samples.append(.init(elapsedSec: elapsed, tokensPerSec: assistant.tokenRate))
                    lastSample = elapsed
                }
            case let .completed(rate, time):
                let wallMs = time.timeIntervalSince(wallStart) * 1000
                return PromptRun(
                    label: prompt.label,
                    prompt: prompt.prompt,
                    outputTokens: assistant.lastOutputTokens > 0 ? assistant.lastOutputTokens : chunks,
                    ttftMs: firstTokenMs ?? wallMs,
                    decodeTokensPerSec: rate,
                    totalWallMs: wallMs,
                    peakRSSBytes: peakRSS,
                    throughputSamples: samples,
                    outputCountKind: assistant.lastOutputTokens > 0 ? "runtime" : "streamChunks"
                )
            case let .failed(message):
                throw NSError(domain: "Benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        throw CancellationError()
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
