import Foundation
import SwiftUI

// MARK: - ModelQualityEval
//
// The quality counterpart to BenchmarkService. The benchmark answers "how
// FAST does this model run on my device" (TTFT, decode t/s, RAM, thermal).
// This answers "how GOOD is it" — using deterministic, on-device graders,
// no cloud and no judge model.
//
// We can't grade prose objectively without a judge model, so we don't try.
// Instead we test the things a small local model most often gets wrong AND
// that code can verify: strict output format, instruction adherence, simple
// arithmetic, and emitting parseable JSON / code. A model that's quick but
// can't follow "reply with only the number" is a poor agent brain, and the
// speed benchmark alone never surfaced that. Each task returns partial
// credit (0…1) plus a hard pass/fail; the headline is the average score and
// an "N/M passed" tally, kept in a per-model history so the user can watch a
// quant / model swap move the number.

@MainActor
final class ModelQualityEval: ObservableObject {

    static let shared = ModelQualityEval()

    // MARK: - Task model

    /// One verifiable instruction + its deterministic grader.
    struct QualityCheck {
        let label: String
        let title: String          // human-readable row title
        let prompt: String
        let maxTokens: Int
        /// (passed, score 0…1, detail) for the model's raw output.
        let grade: @Sendable (String) -> (Bool, Double, String)
    }

    // MARK: - Results

    struct TaskResult: Codable, Identifiable, Hashable {
        var id = UUID()
        let label: String
        let title: String
        let passed: Bool
        let score: Double          // 0…1
        let detail: String
        let output: String         // first ~300 chars of the answer
    }

    struct EvalResult: Codable, Identifiable, Hashable {
        var id = UUID()
        let modelID: String
        let modelDisplayName: String
        let deviceModel: String
        let timestamp: Date
        let tasks: [TaskResult]

        /// Mean partial-credit score across tasks (0…1).
        var score: Double {
            tasks.isEmpty ? 0 : tasks.map(\.score).reduce(0, +) / Double(tasks.count)
        }
        var passedCount: Int { tasks.filter(\.passed).count }
        var totalCount: Int { tasks.count }
    }

    // MARK: - Phase

    enum Phase: Equatable {
        case idle
        case running(taskIndex: Int, title: String)
        case finished(EvalResult)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveOutput: String = ""
    @Published private(set) var history: [EvalResult] = []

    private init() { load() }

    // MARK: - Task pack

    nonisolated static let tasks: [QualityCheck] = [
        // 1. JSON adherence — parseable object with both keys and age == 30.
        QualityCheck(
            label: "json",
            title: "Strict JSON output",
            prompt: "Return ONLY a JSON object with keys \"name\" (string) and \"age\" (number) describing a 30-year-old named Ada. No prose, no markdown fences.",
            maxTokens: 80,
            grade: { out in
                guard let obj = firstJSONObject(in: out) else {
                    return (false, 0, "no parseable JSON object")
                }
                let hasName = obj["name"] != nil
                let hasAge = obj["age"] != nil
                let ageOK = (obj["age"] as? NSNumber)?.intValue == 30
                let score = (hasName ? 0.34 : 0) + (hasAge ? 0.33 : 0) + (ageOK ? 0.33 : 0)
                let passed = hasName && hasAge && ageOK
                return (passed, score,
                        passed ? "valid {name, age:30}"
                               : "name:\(hasName) age:\(hasAge) age==30:\(ageOK)")
            }
        ),
        // 2. Word-count constraint — exactly three words, no punctuation.
        QualityCheck(
            label: "constraint",
            title: "Follow an exact constraint",
            prompt: "Reply with exactly three words and nothing else. No punctuation.",
            maxTokens: 32,
            grade: { out in
                let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
                let words = cleaned.split { $0 == " " || $0 == "\n" }.filter { !$0.isEmpty }
                let hasPunct = cleaned.contains { ".,;:!?".contains($0) }
                let exactly3 = words.count == 3
                let score = (exactly3 ? 0.7 : max(0, 0.7 - 0.2 * Double(abs(words.count - 3))))
                          + (hasPunct ? 0 : 0.3)
                return (exactly3 && !hasPunct, max(0, min(1, score)),
                        "\(words.count) words, punctuation:\(hasPunct)")
            }
        ),
        // 3. Exact arithmetic — "391" must appear, terser is better.
        QualityCheck(
            label: "math",
            title: "Exact answer extraction",
            prompt: "What is 17 multiplied by 23? Reply with only the number.",
            maxTokens: 32,
            grade: { out in
                let correct = out.contains("391")
                let terse = out.trimmingCharacters(in: .whitespacesAndNewlines).count <= 6
                let score = (correct ? 0.7 : 0) + (correct && terse ? 0.3 : 0)
                return (correct, score,
                        correct ? (terse ? "391, terse" : "391, but verbose") : "wrong / missing")
            }
        ),
        // 4. Numbered-list format — exactly five "N." lines.
        QualityCheck(
            label: "format",
            title: "Produce an exact format",
            prompt: "List exactly five fruits as a numbered list, one per line, formatted '1. apple'. Output only the list.",
            maxTokens: 96,
            grade: { out in
                let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                let numbered = lines.filter { line in
                    guard let first = line.first, first.isNumber else { return false }
                    return line.contains(".")
                }
                let exactly5 = numbered.count == 5
                let score = exactly5 ? 1.0 : max(0, 1.0 - 0.2 * Double(abs(numbered.count - 5)))
                return (exactly5, score, "\(numbered.count) numbered lines")
            }
        ),
        // 5. Code emission — fenced python block with the requested def.
        QualityCheck(
            label: "code",
            title: "Emit runnable code",
            prompt: "Write a Python function `is_even(n)` that returns True when n is even. Output only a single fenced ```python code block.",
            maxTokens: 160,
            grade: { out in
                let hasFence = out.contains("```")
                let hasDef = out.contains("def is_even")
                let hasMod = out.contains("% 2") || out.contains("%2")
                let score = (hasFence ? 0.3 : 0) + (hasDef ? 0.4 : 0) + (hasMod ? 0.3 : 0)
                return (hasFence && hasDef, score, "fence:\(hasFence) def:\(hasDef) mod:\(hasMod)")
            }
        ),
    ]

    // MARK: - Run

    /// Runs the full quality pack against the currently loaded assistant
    /// model. Caller should ensure the model is `.ready` (we surface a clear
    /// failure otherwise rather than silently loading).
    func run() async {
        let assistant = CodingAssistantService.shared
        guard case .ready = assistant.state else {
            phase = .failed("Load a model before running the quality eval.")
            return
        }
        let safety = DeviceSafetyMonitor.shared
        if safety.shouldStopHeavyWork {
            phase = .failed("Device is too warm. Let it cool, then retry.")
            return
        }

        liveOutput = ""
        var results: [TaskResult] = []
        for (i, task) in Self.tasks.enumerated() {
            phase = .running(taskIndex: i, title: task.title)
            liveOutput = ""
            let output = await generate(prompt: task.prompt, maxTokens: task.maxTokens)
            let (passed, score, detail) = task.grade(output)
            results.append(TaskResult(
                label: task.label,
                title: task.title,
                passed: passed,
                score: max(0, min(1, score)),
                detail: detail,
                output: String(output.prefix(300))
            ))
            try? await _Concurrency.Task.sleep(nanoseconds: 600_000_000)
        }

        let result = EvalResult(
            modelID: assistant.activeModel.id,
            modelDisplayName: assistant.activeModel.displayName,
            deviceModel: UIDevice.current.model,
            timestamp: Date(),
            tasks: results
        )
        history.insert(result, at: 0)
        if history.count > 50 { history = Array(history.prefix(50)) }
        save()
        phase = .finished(result)
    }

    /// One generation, accumulating the full answer. Low temperature for
    /// grading stability (we want repeatable verdicts, not creativity).
    private func generate(prompt: String, maxTokens: Int) async -> String {
        final class Box: @unchecked Sendable { var text = "" }
        let box = Box()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            CodingAssistantService.shared.generate(
                messages: [
                    ChatMessage(role: .system, content: "You follow instructions exactly. No preamble, no commentary."),
                    ChatMessage(role: .user, content: prompt)
                ],
                maxTokensOverride: maxTokens,
                temperatureOverride: 0.2,
                onToken: { token in
                    box.text += token
                    _Concurrency.Task { @MainActor [weak self] in
                        self?.liveOutput += token
                    }
                },
                onComplete: { _ in cont.resume() }
            )
        }
        return box.text
    }

    // MARK: - JSON helper

    /// Extracts and parses the first balanced `{…}` object from arbitrary
    /// model output (which may wrap it in prose or fences).
    nonisolated static func firstJSONObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { end = i; break }
            }
            i = text.index(after: i)
        }
        guard let end else { return nil }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    // MARK: - Mutating

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    func delete(_ result: EvalResult) {
        history.removeAll { $0.id == result.id }
        save()
    }

    // MARK: - Persistence

    private let storageKey = "codelens.qualityeval.history.v1"

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([EvalResult].self, from: data)
        else { return }
        history = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
