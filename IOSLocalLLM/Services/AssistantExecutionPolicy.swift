import Foundation
import MLX
import MLXLMCommon

// MARK: - Per-family Assistant execution policy

/// Text generation has a very different memory envelope from image analysis,
/// even when both roles come from one unified model package. Keep the large
/// families useful in Assistant by bounding their context/KV cache instead of
/// forcing every text load through Lens's much larger vision admission gate.
struct MLXAssistantExecutionProfile: Equatable, Sendable {
    let maxContextTokens: Int
    let maxOutputTokens: Int?
    let maxKVSize: Int?
    let kvBits: Int
    let prefillStepSize: Int
    let cacheLimitBytes: Int

    /// Prompt budget for this execution policy.
    ///
    /// A rotating KV cache bounds memory independently of total generation
    /// length. For profiles that intentionally leave output uncapped, do not
    /// subtract the user's entire response allowance from the prompt window;
    /// doing so reduced Qwen 3.5 to the 512-token floor and discarded the
    /// immediately preceding turn on ordinary follow-ups.
    func inputBudget(
        modelContextWindowTokens: Int,
        deviceContextCap: Int,
        requestedOutputTokens: Int
    ) -> Int {
        let contextLimit = min(
            modelContextWindowTokens,
            min(deviceContextCap, maxContextTokens)
        )
        if maxKVSize != nil, maxOutputTokens == nil {
            return max(512, contextLimit - 512)
        }
        let safeOutput = maxOutputTokens.map {
            min(requestedOutputTokens, $0)
        } ?? requestedOutputTokens
        return max(512, contextLimit - safeOutput - 256)
    }

    static func resolve(repoID: String, architecture: String? = nil) -> Self {
        let identity = "\(repoID) \(architecture ?? "")".lowercased()
        if identity.contains("ornith") {
            // Ornith 9B fits the 12 GB Pro Max load envelope, but an unbounded
            // 16K 8-bit KV cache can push it back over the process budget on
            // the first long chat. Keep useful context while bounding both
            // cache growth and transient prefill allocations.
            return .init(
                maxContextTokens: 4_096,
                maxOutputTokens: 256,
                maxKVSize: 4_096,
                kvBits: 4,
                prefillStepSize: 128,
                cacheLimitBytes: 0
            )
        }
        if identity.contains("bonsai-27b") {
            // Bonsai 27B fits as a tightly-bounded text model on high-memory
            // iPhones, but its vision activations do not. A rotating 2K cache,
            // 4-bit KV, and small prefill chunks keep chat below the process
            // watermark while Lens independently chooses a smaller VLM.
            return .init(
                maxContextTokens: 2_048,
                maxOutputTokens: 128,
                maxKVSize: 2_048,
                kvBits: 4,
                prefillStepSize: 128,
                cacheLimitBytes: 0
            )
        }
        if identity.contains("qwen3_5") || identity.contains("qwen3.5") {
            // Qwen 3.5 reasoning models need room for both their hidden
            // reasoning trace and the visible answer. Sharing Bonsai 27B's
            // 128-token output cap left only a few dozen visible tokens and
            // routinely stopped mid-sentence. Keep the same memory-bounded
            // rotating KV cache, but let the user's response-length setting
            // (and the thermal advisor) control generation length. Because
            // maxKVSize remains fixed, longer replies do not grow the KV cache
            // past this profile's 2K-token memory envelope.
            return .init(
                maxContextTokens: 2_048,
                maxOutputTokens: nil,
                maxKVSize: 2_048,
                kvBits: 4,
                prefillStepSize: 128,
                cacheLimitBytes: 0
            )
        }
        return .init(
            maxContextTokens: .max,
            maxOutputTokens: nil,
            maxKVSize: nil,
            kvBits: 8,
            prefillStepSize: 512,
            cacheLimitBytes: 64 * 1_024 * 1_024
        )
    }
}

/// TokenAI-style allocator policy for large MLX models. This is deliberately
/// separate from GGUF paging: MLX still loads every weight, but its allocator
/// is prevented from retaining a large reusable cache or exceeding the
/// entitlement-aware process ceiling.
struct MLXLowMemoryPolicy: Equatable, Sendable {
    let memoryLimitBytes: Int?
    let cacheLimitBytes: Int?

    static func resolve(
        enabled: Bool,
        physicalMemoryBytes: UInt64,
        processCeilingBytes: Int64
    ) -> Self {
        guard enabled else {
            return .init(memoryLimitBytes: nil, cacheLimitBytes: nil)
        }
        let tokenAISafeLimit = Int(Double(physicalMemoryBytes) * 0.74)
        let appCeiling = processCeilingBytes > 0
            ? Int(min(Int64(Int.max), processCeilingBytes))
            : tokenAISafeLimit
        return .init(
            memoryLimitBytes: max(0, min(tokenAISafeLimit, appCeiling)),
            cacheLimitBytes: 0
        )
    }
}

/// Chooses between the normal accelerated GGUF path and the opt-in,
/// storage-backed path for models larger than the process memory ceiling.
///
/// llama.cpp memory-maps GGUF weights in both modes. Paging mode additionally
/// keeps every transformer layer off Metal, allowing iOS to reclaim clean
/// file-backed pages instead of retaining a second GPU copy of the weights.
struct GGUFLoadPolicy: Equatable, Sendable {
    let minimumAvailableBytes: Int64
    let gpuLayers: Int32
    let storageBacked: Bool

    /// Runtime, KV cache, sampler, and a bounded window of file-backed pages.
    /// The full GGUF size is deliberately excluded in storage-backed mode:
    /// clean mmap pages are reclaimable and do not need to remain resident.
    static let storageBackedHeadroom: Int64 = 1_500_000_000

    static func resolve(fileBytes: Int64, pagingEnabled: Bool) -> Self {
        if pagingEnabled {
            return .init(
                minimumAvailableBytes: storageBackedHeadroom,
                gpuLayers: 0,
                storageBacked: true
            )
        }

        let minimum = Int64(Double(fileBytes) * 1.15) + 500_000_000
        let threeGiB = Int64(3 * 1_024 * 1_024 * 1_024)
        return .init(
            minimumAvailableBytes: minimum,
            gpuLayers: fileBytes > threeGiB ? 12 : 999,
            storageBacked: false
        )
    }
}

// MARK: - GGUFGenerationProfile

/// Per-model context / output budget policy for imported llama.cpp GGUF
/// assistants.
///
/// Recurrent Gemma GGUF quants (Gemma 3n + Gemma 4 E2B/E4B) are only
/// stable on iOS with a deliberately compact context — they abort while
/// reserving larger ones — so they keep the 512 / 128 / 320 profile that
/// workaround was built for. Every OTHER imported GGUF (Qwen, Llama, Phi,
/// dense Gemma 4 12B/31B, …) runs fine with a normal bounded 4K window;
/// applying the compact profile to them truncated every reply to ~128
/// tokens mid-sentence.
enum GGUFPrefixCache {
    static func commonPrefixLength<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        let limit = min(a.count, b.count)
        var index = 0
        while index < limit, a[index] == b[index] {
            index += 1
        }
        return index
    }

    /// How many leading tokens of `next` are already in the KV cache.
    /// Compact / recreate runtimes always return 0 so they full-prefill.
    static func reuseOffset<T: Equatable>(cached: [T], next: [T], reuseContext: Bool) -> Int {
        guard reuseContext, !cached.isEmpty, !next.isEmpty else { return 0 }
        return commonPrefixLength(cached, next)
    }

    /// The first token sampled after a cached sequence is decoded at the
    /// sequence length, not at `length - 1` (the latter is the position of
    /// the last token already present in the KV cache).
    static func continuationDecodePosition(
        cachedTokenCount: Int,
        generatedSinceResume: Int
    ) -> Int {
        max(0, cachedTokenCount + generatedSinceResume)
    }

    static func continuationLimit(
        contextSize: Int,
        cachedTokenCount: Int,
        requested: Int
    ) -> Int {
        guard contextSize > 0, requested > 0 else { return 0 }
        return min(requested, max(0, contextSize - cachedTokenCount - 1))
    }
}

/// Applies only the cap owned by the selected backend. MLX family profiles
/// describe MLX allocator/KV behavior; they must never silently shorten a
/// llama.cpp GGUF request merely because both models share a display name.
enum AssistantGenerationBudget {
    static func maxTokens(
        runtime: ModelRuntime,
        requested: Int,
        thermalCap: Int,
        backendCap: Int?
    ) -> Int {
        let thermalLimited = min(max(1, requested), max(1, thermalCap))
        guard runtime == .mlx, let backendCap else { return thermalLimited }
        return min(thermalLimited, max(1, backendCap))
    }
}

enum GGUFGenerationProfile: Equatable, Sendable {
    case compact   // recurrent Gemma 3n / Gemma 4 E-series
    case standard  // every other imported GGUF

    static let compactContextTokens = 512
    static let compactMaxOutputTokens = 128
    static let compactInputBudget = 320
    /// Bounded window for standard imports: large enough for real
    /// conversations, small enough to keep the KV cache modest on iOS.
    static let standardContextTokens = 4_096

    /// Picks the profile from the imported model's identity (repo ID or
    /// display name) so `local_gemma-4-e4b-…`-style imports are covered
    /// regardless of how the user named the folder.
    static func resolve(repoID: String, displayName: String) -> Self {
        isRecurrentGemma("\(repoID) \(displayName)") ? .compact : .standard
    }

    /// Gemma 3n (all sizes) and Gemma 4 E2B/E4B share the recurrent /
    /// sliding-window path that aborts on a 4K iOS context. Dense Gemma 4
    /// 12B/26B/31B do not, so they keep the standard window.
    static func isRecurrentGemma(_ identity: String) -> Bool {
        let id = identity.lowercased()
        if id.contains("gemma-3n") || id.contains("gemma3n") { return true }
        let isGemma4 = id.contains("gemma-4") || id.contains("gemma4")
        guard isGemma4 else { return false }
        let isDenseOrLarge = id.contains("12b")
            || id.contains("26b")
            || id.contains("31b")
        return !isDenseOrLarge
    }

    var contextTokens: Int {
        switch self {
        case .compact:  return Self.compactContextTokens
        case .standard: return Self.standardContextTokens
        }
    }

    /// Prompt budget for message-level trimming. The bridge re-clamps with
    /// exact tokenizer counts, so this estimate only steers trimming.
    func inputBudget(requestedOutputTokens: Int) -> Int {
        switch self {
        case .compact:
            return Self.compactInputBudget
        case .standard:
            let outputReserve = min(requestedOutputTokens, Self.standardContextTokens / 2)
            return max(256, Self.standardContextTokens - outputReserve - 16)
        }
    }

    /// Clamps a requested output budget to what the profile allows.
    func clampedOutputTokens(_ requested: Int) -> Int {
        switch self {
        case .compact:  return min(requested, Self.compactMaxOutputTokens)
        case .standard: return requested
        }
    }

    /// Combines the user setting, GGUF profile, and thermal advisor into
    /// the output budget the UI should advertise.
    static func outputTokenCap(
        isGGUF: Bool,
        profile: GGUFGenerationProfile,
        requested: Int,
        thermalCap: Int
    ) -> Int {
        let profileCap = isGGUF ? profile.clampedOutputTokens(requested) : requested
        return min(requested, thermalCap, profileCap)
    }

    /// Compact / recurrent Gemma templates reject system turns. Recast only
    /// our bounded conversation-memory record as ordinary chat context so
    /// long-thread memory survives; persona and tool-use instructions stay
    /// excluded. Standard-profile GGUFs (Qwen, Llama, Phi, …) handle system
    /// turns and keep them via their chat template.
    func messagesForRuntime(_ messages: [ChatMessage]) -> [ChatMessage] {
        switch self {
        case .standard:
            return messages
        case .compact:
            return messages.compactMap { message in
                guard message.role == .system else { return message }
                guard message.content.hasPrefix("[CONVERSATION MEMORY]") else {
                    return nil
                }
                return ChatMessage(
                    id: message.id,
                    role: .user,
                    content: message.content,
                    timestamp: message.timestamp
                )
            }
        }
    }

    /// Builds the string the llama.cpp tokenizer actually sees.
    /// Standard imports get their real chat template (ChatML, Llama 3, …)
    /// including the generation cue. Compact / recurrent Gemma stays on
    /// plain `role: text` plus an `assistant:` cue — their embedded
    /// tool-oriented special tokens can be invalid for the quantized
    /// embedding table.
    func prompt(
        from messages: [ChatMessage],
        template: ChatTemplate,
        enableThinking: Bool,
        leaveLastAssistantOpen: Bool = false
    ) -> String {
        switch self {
        case .standard:
            return messages.formattedWithTemplate(
                template,
                enableThinking: enableThinking,
                leaveLastAssistantOpen: leaveLastAssistantOpen
            )
        case .compact:
            let body = messages
                .filter { $0.role != .system }
                .map { "\($0.role.rawValue): \($0.contentForModel)" }
                .joined(separator: "\n\n")
            let grounded = body.isEmpty
                ? CodingAssistantService.compactGroundingPrompt
                : CodingAssistantService.compactGroundingPrompt + "\n\n" + body
            if leaveLastAssistantOpen, messages.last?.role == .assistant {
                return grounded
            }
            return grounded + "\n\nassistant:"
        }
    }
}
