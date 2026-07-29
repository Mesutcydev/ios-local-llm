import Foundation

// MARK: - MacroChain
// Sequential, multi-step prompts where the output of step N becomes context
// for step N+1. Models a "lint → refactor → test" pipeline as a named macro
// the user can fire with one tap.
//
// Wire flow:
//   chain.steps = [
//     MacroStep(name: "lint", prompt: "Find issues in: {{input}}"),
//     MacroStep(name: "fix",  prompt: "Apply these fixes: {{step1}}\nto this code:\n{{input}}"),
//   ]
//   chain.run(input: code) → returns final assistant reply, all intermediates
//                            accessible via chain.intermediates
//
// `{{step1}}`, `{{step2}}` etc. interpolate the previous steps' outputs.
// `{{input}}` substitutes the user's initial input throughout.

struct MacroStep: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var prompt: String
}

struct Macro: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var subtitle: String
    var steps: [MacroStep]
}

@MainActor
final class MacroStore: ObservableObject {

    static let shared = MacroStore()

    @Published private(set) var macros: [Macro] = []
    private let storageKey = "codelens.macros.v1"

    private init() {
        load()
        if macros.isEmpty { seedDefaults() }
    }

    // MARK: - CRUD

    func add(_ m: Macro) {
        macros.append(m)
        save()
    }

    func update(_ m: Macro) {
        if let i = macros.firstIndex(where: { $0.id == m.id }) {
            macros[i] = m
            save()
        }
    }

    func delete(_ id: UUID) {
        macros.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Macro].self, from: data)
        else { return }
        macros = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(macros) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - Seed defaults

    private func seedDefaults() {
        macros = [
            Macro(
                title: "lint → refactor",
                subtitle: "find issues, then fix them",
                steps: [
                    MacroStep(
                        name: "lint",
                        prompt: "Review this code and list the top 5 issues (bugs, performance, style). Bullet-point only.\n\n```\n{{input}}\n```"
                    ),
                    MacroStep(
                        name: "refactor",
                        prompt: "Rewrite the code to fix the issues you listed:\n\n{{step1}}\n\nOriginal code:\n```\n{{input}}\n```\n\nReturn ONLY the corrected code in a single fenced block."
                    )
                ]
            ),
            Macro(
                title: "explain → test",
                subtitle: "explain code then generate unit tests",
                steps: [
                    MacroStep(
                        name: "explain",
                        prompt: "Explain what this code does in plain language. 3-5 sentences.\n\n```\n{{input}}\n```"
                    ),
                    MacroStep(
                        name: "test",
                        prompt: "Now write unit tests for that code. Cover edge cases. Output the tests as fenced code.\n\nExplanation: {{step1}}\n\nCode under test:\n```\n{{input}}\n```"
                    )
                ]
            ),
        ]
        save()
    }
}

// MARK: - Runner

@MainActor
final class MacroRunner: ObservableObject {

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var intermediates: [String] = []

    /// Set by `cancel()`. Checked between steps so an in-flight chain stops
    /// cleanly the moment the current step's generation returns.
    private var cancelRequested = false

    enum Phase: Equatable {
        case idle
        case running(stepIndex: Int, stepName: String)
        case finished(String)
        case failed(String)
    }

    /// Request cancellation of the running chain. Stops the active step's
    /// token stream (which lets its continuation resume), then the loop bails
    /// before the next step. Safe to call when nothing is running.
    func cancel() {
        guard case .running = phase else { return }
        cancelRequested = true
        CodingAssistantService.shared.stopGeneration()
    }

    func run(macro: Macro, input: String) async {
        guard !macro.steps.isEmpty else { return }
        cancelRequested = false
        intermediates = []
        var stepOutputs: [String] = []

        for (i, step) in macro.steps.enumerated() {
            if cancelRequested { phase = .idle; return }
            phase = .running(stepIndex: i, stepName: step.name)
            let rendered = render(template: step.prompt, input: input, steps: stepOutputs)
            do {
                let out = try await callAssistant(prompt: rendered)
                if cancelRequested { phase = .idle; return }
                stepOutputs.append(out)
                intermediates.append(out)
            } catch {
                phase = .failed("Step \(step.name) failed: \(error.localizedDescription)")
                return
            }
        }
        phase = .finished(stepOutputs.last ?? "")
    }

    private func render(template: String, input: String, steps: [String]) -> String {
        var s = template.replacingOccurrences(of: "{{input}}", with: input)
        for (i, out) in steps.enumerated() {
            s = s.replacingOccurrences(of: "{{step\(i + 1)}}", with: out)
        }
        return s
    }

    private func callAssistant(prompt: String) async throws -> String {
        let assistant = CodingAssistantService.shared
        guard case .ready = assistant.state else {
            throw NSError(domain: "MacroRunner", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Assistant model not loaded."
            ])
        }
        final class Acc: @unchecked Sendable { var value = "" }
        let acc = Acc()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let messages: [ChatMessage] = [
                ChatMessage(role: .system, content: "You execute one step of a multi-step macro. Be concise."),
                ChatMessage(role: .user, content: prompt)
            ]
            assistant.generate(
                messages: messages,
                onToken: { token in acc.value += token },
                onComplete: { _ in cont.resume() }
            )
        }
        return acc.value
    }
}
