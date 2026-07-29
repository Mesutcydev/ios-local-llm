import Foundation

// MARK: - Apple Private Cloud runtime
//
// The only place in the app that touches FoundationModels' PCC surface
// (`PrivateCloudComputeLanguageModel`, `ContextOptions`, quota types). Kept out
// of any SwiftUI view per the integration brief.
//
// DOUBLE-GATED (see ApplePrivateCloudTypes.swift for the full rationale):
//   • `#if FM_PCC`            — the PCC symbols exist ONLY in the iOS 27 SDK
//                               (Xcode 27). `canImport(FoundationModels)` is
//                               TRUE on the GA SDK too, so it can't gate PCC —
//                               we use the FM_PCC build flag instead.
//   • `if #available(iOS 27)` — runtime capability.
//
// `ApplePrivateCloud.{currentStatus,stream,answer,cancel,…}` is the always-
// compiled facade callers use. On a GA build (no FM_PCC) it reports
// `.unsupportedOS` and fails generation with a clean error — the rest of the
// app (MLX / llama.cpp / on-device system model) is untouched.

// MARK: - Public facade (always compiled)

extension ApplePrivateCloud {

    /// Flattened status for pickers / headers / send button / Settings.
    static func currentStatus() async -> ApplePCCStatus {
        #if FM_PCC
        if #available(iOS 27.0, *) {
            return await ApplePrivateCloudRuntime.shared.currentStatus()
        }
        #endif
        return .unsupportedOS
    }

    /// Model's context window, fetched from the SDK (`nil` when PCC isn't
    /// usable). Never hardcode — the brief requires reading the real size.
    static func contextSize() async -> Int? {
        #if FM_PCC
        if #available(iOS 27.0, *) {
            return await ApplePrivateCloudRuntime.shared.contextSize()
        }
        #endif
        return nil
    }

    /// Streams reply deltas (suffix-only chunks, ready to append) so it drops
    /// straight into the app's existing `onToken: (String) -> Void` contract.
    /// Cancel by cancelling the consuming task or calling `cancel(_:)`.
    static func stream(_ request: ApplePCCRequest) async -> AsyncThrowingStream<String, Error> {
        #if FM_PCC
        if #available(iOS 27.0, *) {
            return await ApplePrivateCloudRuntime.shared.stream(request)
        }
        #endif
        return AsyncThrowingStream { $0.finish(throwing: unavailableError) }
    }

    /// One-shot, non-streaming answer (App Intents / tests).
    static func answer(_ request: ApplePCCRequest) async throws -> String {
        #if FM_PCC
        if #available(iOS 27.0, *) {
            return try await ApplePrivateCloudRuntime.shared.answer(request)
        }
        #endif
        throw unavailableError
    }

    /// Cancel an in-flight request by id (used by the model-switch coordinator).
    static func cancel(_ requestID: UUID) {
        #if FM_PCC
        if #available(iOS 27.0, *) {
            Task { await ApplePrivateCloudRuntime.shared.cancel(requestID: requestID) }
        }
        #endif
    }

    /// Presents Apple's own "increase your limit" UI when the SDK offers one
    /// (the brief's "Show Options"). No-op when unavailable.
    static func showLimitIncreaseOptions() {
        #if FM_PCC
        if #available(iOS 27.0, *) {
            Task { await ApplePrivateCloudRuntime.shared.showLimitIncreaseOptions() }
        }
        #endif
    }

    static var unavailableError: ApplePCCError {
        isCompiledIn ? .unsupportedOS : .notCompiledIn
    }
}

#if FM_PCC
import FoundationModels

// MARK: - Reasoning mapping

@available(iOS 27.0, *)
extension ApplePCCReasoningLevel {
    /// Requests resolve the app's `.automatic` option before reaching this
    /// mapping. Keep the nil fallback defensive for direct/internal use.
    var sdkLevel: ContextOptions.ReasoningLevel? {
        switch self {
        case .automatic: return nil
        case .light:     return .light
        case .moderate:  return .moderate
        case .deep:      return .deep
        }
    }
}

// MARK: - Runtime actor

@available(iOS 27.0, *)
actor ApplePrivateCloudRuntime {
    static let shared = ApplePrivateCloudRuntime()

    // A single model handle. PCC carries no local weights, so this is cheap to
    // hold and never participates in MLX/RAM unload paths.
    private let model = PrivateCloudComputeLanguageModel()

    // In-flight generation tasks, keyed by request id, so the switch
    // coordinator can cancel a specific request without touching local models.
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func currentStatus() -> ApplePCCStatus {
        switch model.availability {
        case .available:
            let quota = model.quotaUsage
            if quota.isLimitReached { return .limitReached }
            if case .belowLimit(let below) = quota.status, below.isApproachingLimit {
                return .approachingLimit
            }
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unsupportedDevice
            case .systemNotReady:    return .appleIntelligenceUnavailable
            @unknown default:        return .unknown
            }
        @unknown default:
            return .unknown
        }
    }

    func contextSize() async -> Int? {
        do { return try await model.contextSize } catch { return nil }
    }

    func showLimitIncreaseOptions() {
        model.quotaUsage.limitIncreaseSuggestion?.show()
    }

    func cancel(requestID: UUID) {
        tasks[requestID]?.cancel()
        tasks[requestID] = nil
    }

    func answer(_ request: ApplePCCRequest) async throws -> String {
        guard currentStatus().canSend else { throw statusError(currentStatus()) }
        let session = LanguageModelSession(model: model, instructions: request.instructions)
        do {
            let response = try await session.respond(
                to: request.prompt,
                options: FoundationModels.GenerationOptions(
                    temperature: request.temperature,
                    maximumResponseTokens: request.maximumResponseTokens
                ),
                contextOptions: ContextOptions(reasoningLevel: request.resolvedReasoning.sdkLevel)
            )
            return response.content
        } catch {
            throw Self.map(error)
        }
    }

    func stream(_ request: ApplePCCRequest) -> AsyncThrowingStream<String, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        let task = Task { [weak self] in
            guard let self else {
                continuation.finish(throwing: ApplePCCError.cancelled)
                return
            }
            await self.run(request, into: continuation)
        }
        tasks[request.id] = task
        continuation.onTermination = { @Sendable [weak self] _ in
            task.cancel()
            guard let self else { return }
            Task {
                await self.cancel(requestID: request.id)
            }
        }
        return stream
    }

    private func run(_ request: ApplePCCRequest,
                     into continuation: AsyncThrowingStream<String, Error>.Continuation) async {
        defer { tasks[request.id] = nil }

        guard currentStatus().canSend else {
            continuation.finish(throwing: statusError(currentStatus()))
            return
        }

        let session = LanguageModelSession(model: model, instructions: request.instructions)
        let context = ContextOptions(reasoningLevel: request.resolvedReasoning.sdkLevel)
        let options = FoundationModels.GenerationOptions(
            temperature: request.temperature,
            maximumResponseTokens: request.maximumResponseTokens
        )
        do {
            // FoundationModels yields CUMULATIVE snapshots; we diff to deltas so
            // callers can append, matching the app's token-append contract.
            var previous = ""
            for try await snapshot in session.streamResponse(
                to: request.prompt,
                options: options,
                contextOptions: context
            ) {
                try Task.checkCancellation()
                let full = snapshot.content
                let delta = ApplePrivateCloud.streamDelta(previous: previous, full: full)
                previous = full
                if !delta.isEmpty { continuation.yield(delta) }
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish(throwing: ApplePCCError.cancelled)
        } catch {
            continuation.finish(throwing: Self.map(error))
        }
    }

    private func statusError(_ status: ApplePCCStatus) -> ApplePCCError {
        switch status {
        case .limitReached:               return .quotaExceeded
        case .unsupportedDevice:          return .unavailable("This device isn't eligible for Apple Private Cloud.")
        case .appleIntelligenceUnavailable: return .unavailable("Apple Intelligence isn't ready yet. Try again shortly.")
        case .offline:                    return .offline
        default:                          return .unknown("")
        }
    }

    // Maps the SDK failure surface to our small set. Never surfaces raw prompt
    // or attachment content — only generic, localizable categories.
    static func map(_ error: Error) -> ApplePCCError {
        if error is CancellationError { return .cancelled }

        if let pcc = error as? PrivateCloudComputeLanguageModel.Error {
            switch pcc {
            case .networkFailure:     return .offline
            case .quotaLimitReached:  return .quotaExceeded
            case .serviceUnavailable: return .temporary("")
            @unknown default:         return .temporary("")
            }
        }
        // iOS 27 replacement for the deprecated `GenerationError`.
        if let lm = error as? LanguageModelError {
            switch lm {
            case .contextSizeExceeded:                  return .contextExceeded
            case .guardrailViolation, .refusal:         return .safety
            case .rateLimited:                          return .quotaExceeded
            case .timeout:                              return .temporary("")
            case .unsupportedCapability,
                 .unsupportedTranscriptContent,
                 .unsupportedGenerationGuide,
                 .unsupportedLanguageOrLocale:          return .unknown("")
            @unknown default:                           return .unknown("")
            }
        }
        if let pccError = error as? ApplePCCError { return pccError }
        return .unknown((error as? LocalizedError)?.errorDescription ?? "")
    }
}
#endif
