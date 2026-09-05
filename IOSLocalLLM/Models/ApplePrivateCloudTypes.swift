import Foundation

// MARK: - Apple Private Cloud — shared value types
//
// Pure metadata for the optional "Apple Private Cloud" advanced-reasoning
// model (Apple Private Cloud Compute, via FoundationModels' iOS-27
// `PrivateCloudComputeLanguageModel`). NONE of this file imports
// FoundationModels — it's plain data so the catalog, picker filters, status
// pills and Settings can reason about PCC even on a build/OS where the PCC
// runtime isn't compiled in.
//
// The runtime itself (the part that touches FoundationModels) lives in
// Services/ApplePrivateCloudRuntime.swift behind `#if FM_PCC`. See that file
// and Docs/PCC_INTEGRATION.md for why PCC is double-gated:
//   • `#if FM_PCC`            — `PrivateCloudComputeLanguageModel` exists ONLY
//                               in the iOS 27 beta SDK (Xcode 27). The GA SDK
//                               (Xcode 26.x) has no such symbol, so PCC code
//                               must be flag-gated, not just `@available`-gated.
//   • `if #available(iOS 27)` — runs only on a capable OS at runtime.
// On a GA build the flag is unset, every `#if FM_PCC` block vanishes, and the
// app is byte-for-byte unchanged. The enums below stay, harmlessly.

// MARK: - ModelExecutionLocation
//
// Where a selected model actually runs. The existing app only ever ran models
// locally (MLX / llama.cpp / Apple's on-device system model), so this axis was
// implicit. PCC is the first non-local option, so we name the axis explicitly.
// Deliberately separate from `ModelRuntime` (mlx/llamaCpp) and `LocalModelOrigin`
// (downloaded/bundled/…): a PCC "model" has no file, no repo, no size, no
// quantization, no unload — forcing it into those structures would be a lie.

public enum ModelExecutionLocation: String, Codable, Hashable, Sendable {
    case localDownloaded   // user-downloaded MLX/GGUF weights
    case localCoreAI       // user-downloaded Core AI .aimodel resource pack
    case localSystem       // Apple on-device system model (FoundationModels)
    case applePrivateCloud // Apple Private Cloud Compute (this file)
    case externalCloud     // reserved — third-party API providers (none today)

    /// Classifies a stored assistant-model selection id. Everything that isn't
    /// the PCC identity is treated as a local model — the existing default.
    /// Pure function over the id, so it needs no new persisted field on
    /// `AssistantModel` (which is embedded in Codable records elsewhere).
    public static func of(assistantModelID id: String) -> ModelExecutionLocation {
        if id == ApplePrivateCloud.modelID { return .applePrivateCloud }
        if id.hasPrefix("coreai:") { return .localCoreAI }
        return .localDownloaded
    }

    /// True when the model runs off-device and therefore needs network +
    /// explicit user consent before any content leaves the device.
    public var isCloud: Bool {
        self == .applePrivateCloud || self == .externalCloud
    }
}

// MARK: - ApplePCCStatus
//
// One flattened status the whole app reads (picker, active-model header, send
// button, Settings, diagnostics) instead of each surface re-deriving from the
// raw FoundationModels availability + quota types. Computed by
// `ApplePrivateCloud.currentStatus()`.

public enum ApplePCCStatus: Equatable, Sendable {
    case ready
    case approachingLimit
    case limitReached
    case unsupportedOS              // OS < iOS 27, or built without FM_PCC
    case unsupportedDevice          // device not eligible
    case appleIntelligenceUnavailable
    case offline
    case temporarilyUnavailable
    case entitlementUnavailable
    case unknown

    /// True only when a PCC request can actually be started right now.
    public var canSend: Bool { self == .ready || self == .approachingLimit }
}

// MARK: - ApplePCCReasoningLevel
//
// App-level reasoning selector. Maps onto FoundationModels'
// `ContextOptions.ReasoningLevel` (.light/.moderate/.deep) in the runtime —
// `.automatic` is OUR concept (the app picks a level from task shape) and has
// no SDK counterpart. We never expose the SDK's `.custom(String)`.

public enum ApplePCCReasoningLevel: String, Codable, CaseIterable, Sendable {
    case automatic
    case light
    case moderate
    case deep
}

public enum ApplePCCGenerationState: Equatable, Sendable {
    case idle
    case generating
    case failed(ApplePCCError)
}

// MARK: - ApplePrivateCloud — identity
//
// Stable identity constants for the single PCC "model". Not added to
// `AssistantModelCatalog.presets` yet — picker/Settings wiring is a later
// phase, and surfacing it on a build that can't run it would be misleading.

public enum ApplePrivateCloud {
    public static let providerID  = "apple"
    public static let modelID     = "apple-private-cloud"
    public static let displayName = "Apple Private Cloud"
    public static let subtitle    = "Advanced reasoning with Apple Private Cloud Compute"
    public static let privacyDisclosureVersion = 1

    public static func hasCurrentPrivacyConsent(version: Int) -> Bool {
        version >= privacyDisclosureVersion
    }

    /// Input-token allowance after reserving room for the visible answer,
    /// hidden reasoning, and request framing. The real SDK context size is
    /// always supplied by the caller; this function never guesses one.
    public static func inputBudget(
        contextSize: Int,
        maximumResponseTokens: Int
    ) -> Int {
        max(512, contextSize - max(1, maximumResponseTokens) - 512)
    }

    /// Resolve the app-level `.automatic` option without sending an extra
    /// classification request or inspecting content off-device. Explicit
    /// user choices always win; only `.automatic` reaches the local router.
    public static func resolvedReasoningLevel(
        requested: ApplePCCReasoningLevel,
        prompt: String
    ) -> ApplePCCReasoningLevel {
        guard requested == .automatic else { return requested }
        return automaticReasoningLevel(for: prompt)
    }

    /// Small, deterministic task-shape router for PCC reasoning effort.
    ///
    /// The policy intentionally uses broad structural signals rather than
    /// trying to understand or retain prompt content:
    /// - long or multi-constraint analysis → deep
    /// - code/technical work or medium-length prompts → moderate
    /// - short conversational requests → light
    ///
    /// This runs locally and returns only an enum. Prompt text is never logged,
    /// persisted, or sent anywhere by the router.
    public static func automaticReasoningLevel(for prompt: String) -> ApplePCCReasoningLevel {
        let normalized = prompt.lowercased()

        let deepSignals = [
            "formal proof",
            "prove that",
            "root cause",
            "race condition",
            "deadlock",
            "threat model",
            "migration plan",
            "architecture",
            "trade-offs",
            "tradeoffs",
        ]
        if prompt.count >= 4_000
            || deepSignals.contains(where: normalized.contains) {
            return .deep
        }

        let technicalSignals = [
            "```",
            "compiler",
            "stack trace",
            "exception",
            "refactor",
            "implement",
            "debug",
            "algorithm",
            "function",
            "class ",
            "struct ",
            "actor ",
            "swift",
            "objective-c",
            "python",
            "javascript",
            "typescript",
            "sql",
            "api",
        ]
        if prompt.count >= 700
            || technicalSignals.contains(where: normalized.contains) {
            return .moderate
        }

        return .light
    }

    /// Compiled with PCC support? `true` only when built with the iOS 27 SDK
    /// (FM_PCC set). Lets non-gated UI decide whether to show PCC at all.
    public static var isCompiledIn: Bool {
        #if FM_PCC
        return true
        #else
        return false
        #endif
    }

    /// True only when both the future-SDK implementation is present and this
    /// device is running an OS that exposes the PCC model. Picker visibility
    /// and persisted-selection restoration use this stricter gate.
    public static var isSupportedOnCurrentOS: Bool {
        #if FM_PCC
        if #available(iOS 27.0, *) { return true }
        #endif
        return false
    }

    /// FoundationModels streams CUMULATIVE content snapshots, but the app's
    /// token sink appends deltas. Returns the new suffix to append. Pure so the
    /// runtime's streaming stays correct under test without a device/SDK.
    /// Falls back to the full string if the snapshot didn't extend the previous
    /// one (a model rewrite — rare for plain String generation).
    public static func streamDelta(previous: String, full: String) -> String {
        full.hasPrefix(previous) ? String(full.dropFirst(previous.count)) : full
    }
}

// MARK: - Request / error value types
//
// Self-contained so the runtime can be type-checked in isolation against the
// SDK and so non-gated callers can construct a request without importing
// FoundationModels. Attachments (image/document translation) are intentionally
// NOT here yet — text + instructions only this phase; see Docs/PCC_INTEGRATION.md.

public struct ApplePCCRequest: Sendable {
    public let id: UUID
    public let prompt: String
    public let instructions: String?
    public let reasoning: ApplePCCReasoningLevel
    public let maximumResponseTokens: Int?
    public let temperature: Double?

    public init(id: UUID = UUID(),
                prompt: String,
                instructions: String? = nil,
                reasoning: ApplePCCReasoningLevel = .automatic,
                maximumResponseTokens: Int? = nil,
                temperature: Double? = nil) {
        self.id = id
        self.prompt = prompt
        self.instructions = instructions
        self.reasoning = reasoning
        self.maximumResponseTokens = maximumResponseTokens
        self.temperature = temperature
    }

    /// Concrete level passed to FoundationModels after resolving the app's
    /// `.automatic` option from the request shape.
    public var resolvedReasoning: ApplePCCReasoningLevel {
        ApplePrivateCloud.resolvedReasoningLevel(
            requested: reasoning,
            prompt: prompt
        )
    }
}

// MARK: - ApplePCCError
//
// Maps the FoundationModels PCC failure surface into a small, user-facing set.
// (Folding into the app's common model-error system is a later phase; for now
// these carry localizable descriptions and never leak prompt/attachment text.)

public enum ApplePCCError: LocalizedError, Equatable, Sendable {
    case notCompiledIn          // built without FM_PCC
    case unsupportedOS          // OS < iOS 27
    case unavailable(String)    // model.availability == .unavailable(reason)
    case offline                // network failure
    case quotaExceeded          // daily allowance reached
    case contextExceeded        // input too large for the model
    case safety                 // guardrail / refusal
    case temporary(String)      // transient service failure
    case cancelled
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .notCompiledIn:
            return "Apple Private Cloud isn't included in this build."
        case .unsupportedOS:
            return "Apple Private Cloud requires iOS 27 or later."
        case .unavailable(let reason):
            return reason
        case .offline:
            return "Apple Private Cloud needs an internet connection."
        case .quotaExceeded:
            return "Today's Apple Private Cloud usage limit has been reached. Local models remain available."
        case .contextExceeded:
            return "This conversation is too large for Apple Private Cloud. Try sending less context."
        case .safety:
            return "Apple Private Cloud couldn't complete this request."
        case .temporary(let detail):
            return detail.isEmpty ? "Apple Private Cloud is temporarily unavailable." : detail
        case .cancelled:
            return "Request cancelled."
        case .unknown(let detail):
            return detail.isEmpty ? "Apple Private Cloud is unavailable." : detail
        }
    }
}
