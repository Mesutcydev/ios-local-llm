import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - AppleFoundationModel
//
// Thin wrapper over Apple's on-device Foundation Models framework (iOS 26+).
// Gives CodeLens a zero-download, instant model on eligible devices — no 1.5 GB
// first-run fetch — and powers the headless "Quick Ask" App Intent that returns
// an answer straight into Siri / Shortcuts without launching the app.
//
// The whole framework is iOS 26+, so every call is double-gated:
//   • `#if canImport(FoundationModels)` — compiles only when the SDK has it
//   • `if #available(iOS 26.0, *)`       — runs only on a capable OS
// On anything older these reduce to "unavailable", and the rest of the app
// (MLX / llama.cpp models) is unaffected.

enum AppleFoundationModel {

    /// True when Apple's system model can answer right now (device eligible,
    /// Apple Intelligence on, weights downloaded).
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Human-readable reason the model can't be used (nil when available).
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return "This device doesn't support Apple Intelligence."
                case .appleIntelligenceNotEnabled:
                    return "Turn on Apple Intelligence in Settings to use the system model."
                case .modelNotReady:
                    return "Apple's system model is still downloading — try again shortly."
                @unknown default:
                    return "Apple's on-device model is unavailable."
                }
            }
        }
        #endif
        return "Apple's on-device model requires iOS 26 or later."
    }

    enum AppleFMError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let reason): return reason }
        }
    }

    /// One-shot, fully on-device answer. `instructions`, when provided, is
    /// folded into the prompt so we don't depend on the session-instructions
    /// API surface. Throws `AppleFMError.unavailable` when the model can't run.
    static func answer(to prompt: String, instructions: String? = nil) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                throw AppleFMError.unavailable(unavailableReason ?? "Apple's on-device model is unavailable.")
            }
            let session = LanguageModelSession()
            let composed: String
            if let instructions, !instructions.isEmpty {
                composed = "\(instructions)\n\n\(prompt)"
            } else {
                composed = prompt
            }
            let response = try await session.respond(to: composed)
            return response.content
        }
        #endif
        throw AppleFMError.unavailable(unavailableReason ?? "Apple's on-device model requires iOS 26 or later.")
    }
}

// MARK: - Safe on-device analysis routing

/// Runs background/diagnostics analysis independently of the assistant model
/// selected for chat. Heavy user-selected weights are reclaimed first; Apple's
/// on-device system model is preferred, with a temporary lightweight MLX model
/// as the offline fallback. The fallback never changes the saved chat model.
@MainActor
final class SafeOnDeviceAnalysisCoordinator {
    static let shared = SafeOnDeviceAnalysisCoordinator()

    private static let preferredFallbackIDs = [
        "qwen3-1.7b",
        "qwen2.5-1.5b",
        "qwen2.5-coder-1.5b",
        "bonsai-4b-1bit",
        "qwen3-0.6b",
        "qwen2.5-0.5b",
        "bonsai-1.7b-1bit",
    ]
    private static let defaultFallbackID = "qwen2.5-1.5b"

    private var task: Task<Void, Never>?

    private init() {}

    func analyze(
        prompt: String,
        instructions: String,
        maxTokens: Int = 700,
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (String?) -> Void
    ) {
        guard task == nil else {
            onComplete("Another on-device analysis is already running.")
            return
        }

        task = Task { [weak self] in
            guard let self else { return }
            let assistant = CodingAssistantService.shared

            // Never make Apple's system model compete with multi-GB MLX/Metal
            // weights. This is the crash build 43 exposed with Bonsai 27B.
            await assistant.unloadAndWaitForCleanup()
            guard !Task.isCancelled else {
                self.finish(error: nil, onComplete: onComplete)
                return
            }

            if AppleFoundationModel.isAvailable {
                do {
                    Diagnostics.shared.breadcrumb(
                        "safe analysis route · apple-system",
                        category: "analysis"
                    )
                    let answer = try await AppleFoundationModel.answer(
                        to: prompt,
                        instructions: instructions
                    )
                    guard !Task.isCancelled else {
                        self.finish(error: nil, onComplete: onComplete)
                        return
                    }
                    onToken(answer)
                    self.finish(
                        error: answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Apple's on-device model returned an empty response."
                            : nil,
                        onComplete: onComplete
                    )
                    return
                } catch is CancellationError {
                    self.finish(error: nil, onComplete: onComplete)
                    return
                } catch {
                    Diagnostics.shared.warning(
                        "Apple system analysis unavailable; using lightweight local fallback · \(error.localizedDescription)",
                        category: "analysis"
                    )
                }
            }

            guard let fallback = Self.lightweightFallbackModel() else {
                self.finish(
                    error: "No safe lightweight analysis model is available.",
                    onComplete: onComplete
                )
                return
            }

            Diagnostics.shared.breadcrumb(
                "safe analysis route · local · \(fallback.id)",
                category: "analysis"
            )
            guard let original = await assistant.prepareTemporaryAnalysisModel(fallback) else {
                let detail: String
                if case .failed(let message) = assistant.state {
                    detail = message
                } else {
                    detail = "The lightweight analysis model could not be prepared."
                }
                self.finish(error: detail, onComplete: onComplete)
                return
            }

            if Task.isCancelled {
                await assistant.finishTemporaryAnalysis(restoring: original)
                self.finish(error: nil, onComplete: onComplete)
                return
            }

            let messages = [
                ChatMessage(role: .system, content: instructions),
                ChatMessage(role: .user, content: prompt),
            ]
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                assistant.generate(
                    messages: messages,
                    maxTokensOverride: maxTokens,
                    forceNoThinking: true,
                    onToken: onToken,
                    onComplete: { _ in continuation.resume() }
                )
            }

            let localError: String?
            if case .failed(let message) = assistant.state {
                localError = message
            } else {
                localError = nil
            }
            await assistant.finishTemporaryAnalysis(restoring: original)
            self.finish(error: localError, onComplete: onComplete)
        }
    }

    func cancel() {
        task?.cancel()
        CodingAssistantService.shared.stopGeneration()
    }

    private func finish(
        error: String?,
        onComplete: @escaping @Sendable (String?) -> Void
    ) {
        task = nil
        onComplete(error)
    }

    /// Prefer an already-installed lightweight model. If none is installed,
    /// Qwen2.5 1.5B is the stable general-purpose fallback and may be fetched
    /// through the existing Hub loader (about 900 MB rather than multi-GB).
    private static func lightweightFallbackModel() -> AssistantModel? {
        let readyIDs = Set(
            ModelDownloadCenter.shared.models
                .filter { $0.category == .assistant && $0.isReady }
                .map(\.id)
        )
        for id in preferredFallbackIDs where readyIDs.contains(id) {
            if let model = AssistantModelCatalog.model(forID: id),
               model.approxRAMBytes <= 1_600_000_000,
               model.platformCompatibility?.supportsCurrentPlatform ?? true {
                return model
            }
        }
        return AssistantModelCatalog.model(forID: defaultFallbackID)
    }
}
