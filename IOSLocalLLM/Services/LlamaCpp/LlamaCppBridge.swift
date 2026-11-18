import Foundation
import UIKit
import CoreImage
import os   // OSAllocatedUnfairLock

// MARK: - LlamaCppBridge
//
// Swift wrapper for llama.cpp + mtmd (multimodal) C APIs. Loads
// a GGUF LLM + mmproj pair and runs full image-prompt → tokens
// inference. The C calls below are bridged via
// IOSLocalLLM-Bridging-Header.h.
//
// Threading: this type isn't Sendable; the convention is that
// `LlamaCppVLMService` constructs and drives one instance from a
// background `Task.detached`. The cancellation flag is written from
// the MainActor and read from the inference thread, so it's guarded
// by an unfair lock.

/// Errors surfaced by the bridge.
enum LlamaCppError: Error, LocalizedError {
    case backendInitFailed
    case modelLoadFailed(String)
    case mmprojLoadFailed(String)
    case contextInitFailed
    case tokenizeFailed(Int32)
    case invalidToken(Int32)
    case decodeFailed(Int32)
    case bitmapInitFailed
    case visionUnsupported
    case promptTooLong(Int)
    case generationInProgress
    case noOutput
    case cancelled
    case samplerInitFailed

    var errorDescription: String? {
        switch self {
        case .backendInitFailed:           return "llama.cpp backend init failed"
        case .modelLoadFailed(let p):      return "Failed to load LLM at \(p)"
        case .mmprojLoadFailed(let p):     return "Failed to load mmproj at \(p)"
        case .contextInitFailed:           return "Failed to create llama context"
        case .samplerInitFailed:           return "Failed to create llama sampler"
        case .tokenizeFailed(let code):    return "mtmd_tokenize failed with code \(code)"
        case .invalidToken(let token):     return "Tokenizer produced invalid token id \(token)"
        case .decodeFailed(let code):      return "llama_decode failed with code \(code)"
        case .bitmapInitFailed:            return "Image RGB conversion failed (mtmd_bitmap_init)"
        case .visionUnsupported:           return "Loaded model does not support vision (mmproj mismatch?)"
        case .promptTooLong(let count):    return "Prompt is too long for the GGUF context (\(count) tokens)"
        case .generationInProgress:        return "A GGUF generation is already in progress"
        case .noOutput:                    return "Inference produced no output tokens"
        case .cancelled:                   return "Inference cancelled"
        }
    }
}

extension LlamaCppError: Equatable {
    static func == (lhs: LlamaCppError, rhs: LlamaCppError) -> Bool {
        switch (lhs, rhs) {
        case (.backendInitFailed, .backendInitFailed),
             (.contextInitFailed, .contextInitFailed),
             (.bitmapInitFailed, .bitmapInitFailed),
             (.visionUnsupported, .visionUnsupported),
             (.generationInProgress, .generationInProgress),
             (.noOutput, .noOutput),
             (.cancelled, .cancelled),
             (.samplerInitFailed, .samplerInitFailed):
            return true
        case (.modelLoadFailed(let a), .modelLoadFailed(let b)):     return a == b
        case (.mmprojLoadFailed(let a), .mmprojLoadFailed(let b)):   return a == b
        case (.tokenizeFailed(let a), .tokenizeFailed(let b)):       return a == b
        case (.invalidToken(let a), .invalidToken(let b)):           return a == b
        case (.decodeFailed(let a), .decodeFailed(let b)):           return a == b
        case (.promptTooLong(let a), .promptTooLong(let b)):         return a == b
        default: return false
        }
    }
}

/// One loaded VLM, ready for image + prompt → token streaming.
final class LlamaCppVLM: @unchecked Sendable {

    // MARK: - C handles

    private var model: OpaquePointer?      // llama_model *
    private var ctx: OpaquePointer?        // llama_context *
    private var mtmdCtx: OpaquePointer?    // mtmd_context *
    // Swift bridges `llama_sampler` as a named C struct, so the
    // pointer type Swift expects is `UnsafeMutablePointer<llama_sampler>`,
    // not `OpaquePointer`. Same applies to llama_batch (handled
    // inline in describe).
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private let configuredThreads: Int32
    private let configuredContextSize: UInt32
    /// 8-bit K/V cache with flash attention (text-only contexts).
    private let usesQuantizedKV: Bool
    /// Context window this runtime was created with.
    var contextSize: Int { Int(configuredContextSize) }
    /// LFM3-VL needs the publisher's non-thinking vision prompt and its
    /// low-temperature sampler; the generic caption defaults are too loose.
    private var usesLFM3VisionTemplate = false
    private let textGenerationActive = OSAllocatedUnfairLock(initialState: false)
    private var cachedSequence: [llama_token] = []
    private var cacheUsableForContinue = false

    var hasContinuableCache: Bool {
        cacheUsableForContinue && ctx != nil && !cachedSequence.isEmpty && mtmdCtx == nil
    }

    func invalidateTokenCache() {
        cachedSequence = []
        cacheUsableForContinue = false
    }

    var supportsVision: Bool { mtmdCtx.map { mtmd_support_vision($0) } ?? false }

    // MARK: - Cancellation

    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)

    /// Request the in-flight `describe` call to exit at the next
    /// token boundary. Safe from any thread.
    func cancelCurrent() { cancelFlag.withLock { $0 = true } }

    /// Blocks until no other decode owns this context. A cancelled describe
    /// can still be inside mtmd prefill, which is not interruptible; a retry
    /// decoding the same context meanwhile crashed in ggml_metal_synchronize
    /// (build 144, LFM3-VL). The old run exits at its next token boundary.
    private func waitForGenerationSlot(claim: Bool) throws {
        while !textGenerationActive.withLock({ active -> Bool in
            if active { return false }
            if claim { active = true }
            return true
        }) {
            if Task.isCancelled { throw LlamaCppError.cancelled }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    // MARK: - Backend init (one-shot per process)

    private static var backendInitDone = false
    private static let backendInitLock = NSLock()

    private static func ensureBackendInit() {
        backendInitLock.lock(); defer { backendInitLock.unlock() }
        if !backendInitDone {
            // Upstream debug logs can contain rendered prompts. Keep content
            // out of logs; the app records only its own bounded diagnostics.
            llama_log_set({ _, _, _ in }, nil)
            ggml_log_set({ _, _, _ in }, nil)
            mtmd_helper_log_set({ _, _, _ in }, nil)
            llama_backend_init()
            backendInitDone = true
        }
    }

    /// Normalize the model's file path or metadata name so imported and
    /// renamed LFM3-VL files still select the publisher's vision prompt.
    private static func isLFM3VisionIdentity(_ identity: String) -> Bool {
        let normalized = identity.lowercased().filter {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }
        return normalized.contains("lfm3vl2b")
    }

    private static func modelName(_ model: OpaquePointer) -> String? {
        metaString(model, "general.name")
    }

    private static func metaString(_ model: OpaquePointer, _ key: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        let length = buffer.withUnsafeMutableBufferPointer { ptr in
            llama_model_meta_val_str(model, key, ptr.baseAddress, ptr.count)
        }
        guard length > 0 else { return nil }
        return String(
            decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    // MARK: - Context sizing

    private static func contextParams(
        nCtx: UInt32, batch: UInt32, threads: Int32, quantizedKV: Bool
    ) -> llama_context_params {
        var params = llama_context_default_params()
        params.n_ctx = nCtx
        params.n_batch = batch
        params.n_ubatch = batch
        params.n_threads = threads
        params.n_threads_batch = threads
        if quantizedKV {
            params.type_k = GGML_TYPE_Q8_0
            params.type_v = GGML_TYPE_Q8_0
            params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        }
        return params
    }

    /// Largest 8-bit-KV context the budget holds. Uses the GGUF's real key /
    /// value head sizes and counts every layer, so hybrid and sliding-window
    /// models get a conservative (smaller) answer.
    private static func memorySizedContext(
        model m: OpaquePointer, floor: UInt32, ceiling: UInt32, kvBudgetBytes: Int64
    ) -> UInt32 {
        let heads = Int(llama_model_n_head(m))
        let kvHeads = Int(llama_model_n_head_kv(m))
        let layers = Int(llama_model_n_layer(m))
        guard heads > 0, kvHeads > 0, layers > 0 else { return floor }
        let arch = metaString(m, "general.architecture") ?? ""
        let keyDim = metaString(m, "\(arch).attention.key_length").flatMap { Int($0) }
            ?? Int(llama_model_n_embd(m)) / heads
        let valueDim = metaString(m, "\(arch).attention.value_length").flatMap { Int($0) } ?? keyDim
        return kvSizedContext(
            perTokenBytes: Double(layers * kvHeads * (keyDim + valueDim)) * 34 / 32,  // q8_0
            kvBudgetBytes: kvBudgetBytes, floor: floor, ceiling: ceiling,
            trainedContext: llama_model_n_ctx_train(m))
    }

    /// Pure sizing rule: tokens the budget holds, rounded down to 256, within
    /// [floor, min(ceiling, trained)]. Never below `floor` (the old fixed size).
    static func kvSizedContext(
        perTokenBytes: Double, kvBudgetBytes: Int64,
        floor: UInt32, ceiling: UInt32, trainedContext: Int32
    ) -> UInt32 {
        let cap = trainedContext > 0 ? min(ceiling, UInt32(trainedContext)) : ceiling
        guard perTokenBytes > 0, cap > floor else { return floor }
        let fitting = UInt32(clamping: Int64(Double(max(0, kvBudgetBytes)) / perTokenBytes)) / 256 * 256
        return max(floor, min(cap, fitting))
    }

    // MARK: - Init / deinit

    /// Loads LLM + mmproj into RAM/Metal, creates the inference
    /// context, prepares the sampler chain. Heavy — caller should
    /// dispatch on a background Task. Throws and cleans up on any
    /// step's failure.
    init(
        llmPath: String,
        mmprojPath: String? = nil,
        nThreads: Int32 = Int32(ProcessInfo.processInfo.activeProcessorCount),
        contextSize: UInt32 = 4096,
        gpuLayers: Int32 = 999,
        enableAudio: Bool = false,
        maxContextSize: UInt32? = nil,
        kvBudgetBytes: Int64 = 0
    ) throws {
        self.configuredThreads = nThreads
        Self.ensureBackendInit()

        // 1. Load the text LLM. Default params enable mmap on iOS
        //    which lets the OS page weight bytes out under
        //    pressure — friendly to our memory gate.
        var modelParams = llama_model_default_params()
        modelParams.load_mode = LLAMA_LOAD_MODE_MMAP
        modelParams.n_gpu_layers = gpuLayers
        #if targetEnvironment(simulator)
        if enableAudio { modelParams.n_gpu_layers = 0 }
        #endif
        guard let m = llama_model_load_from_file(llmPath, modelParams) else {
            throw LlamaCppError.modelLoadFailed(llmPath)
        }
        self.model = m
        self.usesLFM3VisionTemplate = Self.isLFM3VisionIdentity(llmPath)
            || Self.modelName(m).map(Self.isLFM3VisionIdentity) == true

        // 2. Create the inference context. n_batch is the max
        //    tokens per llama_decode call; image embeddings can
        //    arrive in larger batches than typical text, so we
        //    bump above the 32-token default.
        //    A text-only assistant context (maxContextSize set) uses an 8-bit
        //    K/V cache — half of f16, so the same memory holds twice the
        //    context — sized to the caller's KV budget.
        var quantizedKV = maxContextSize != nil && mmprojPath == nil && !enableAudio
        var nCtx = contextSize
        if quantizedKV, let maxContextSize {
            nCtx = Self.memorySizedContext(model: m, floor: contextSize,
                                           ceiling: maxContextSize, kvBudgetBytes: kvBudgetBytes)
        }
        var ctxParams = Self.contextParams(nCtx: nCtx, batch: 512, threads: nThreads, quantizedKV: quantizedKV)
        if enableAudio {
            ctxParams.embeddings = true
            ctxParams.pooling_type = LLAMA_POOLING_TYPE_NONE
        }
        var created = llama_init_from_model(m, ctxParams)
        if created == nil, quantizedKV {
            // 8-bit V needs flash attention, which some architectures lack.
            // Retry with the f16 cache in the same memory: half the context.
            quantizedKV = false
            nCtx = max(contextSize, nCtx / 2 / 256 * 256)
            ctxParams = Self.contextParams(nCtx: nCtx, batch: 512, threads: nThreads, quantizedKV: false)
            created = llama_init_from_model(m, ctxParams)
        }
        self.configuredContextSize = nCtx
        self.usesQuantizedKV = quantizedKV
        guard let c = created else {
            llama_model_free(m)
            self.model = nil
            throw LlamaCppError.contextInitFailed
        }
        self.ctx = c

        // A standalone text GGUF is complete without an mmproj. Keep the
        // llama context and build the normal sampler, then return before the
        // multimodal setup. This chain serves describe()-less text fallback
        // paths; per-request chains with user settings are built in
        // generateText().
        guard let mmprojPath else {
            let samplerParams = llama_sampler_chain_default_params()
            guard let chain = llama_sampler_chain_init(samplerParams) else {
                llama_free(c)
                llama_model_free(m)
                self.ctx = nil; self.model = nil
                throw LlamaCppError.samplerInitFailed
            }
            llama_sampler_chain_add(chain, llama_sampler_init_temp(0.7))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))
            self.sampler = chain
            return
        }

        // 3. Load the multimodal projector. mtmd_init_from_file
        //    binds it to the LLM and returns a context that
        //    handles tokenization + image-to-embedding as one unit.
        var mtmdParams = mtmd_context_params_default()
        if usesLFM3VisionTemplate {
            // Keep the projector on the same device as the backbone. The
            // LFM3 VL projector is small; loading it on Metal while the LLM
            // runs CPU-only has produced failed prefill on low-memory paths.
            mtmdParams.use_gpu = gpuLayers != 0
        } else {
            mtmdParams.use_gpu = enableAudio ? gpuLayers != 0 : true
        }
        #if targetEnvironment(simulator)
        if enableAudio || usesLFM3VisionTemplate { mtmdParams.use_gpu = false }
        #endif
        mtmdParams.print_timings = false
        mtmdParams.n_threads = nThreads
        mtmdParams.image_marker = nil           // deprecated; use media_marker
        mtmdParams.media_marker = mtmd_default_marker()
        mtmdParams.warmup = true                // run a dummy encode to flush Metal pipelines
        guard let mc = mtmd_init_from_file(mmprojPath, m, mtmdParams) else {
            llama_free(c)
            llama_model_free(m)
            self.ctx = nil; self.model = nil
            throw LlamaCppError.mmprojLoadFailed(mmprojPath)
        }
        self.mtmdCtx = mc

        // 4. Vision-support sanity check — catches the case where
        //    the user paired a wrong mmproj (e.g. audio) with the
        //    LLM. Better to fail load than to hit a confusing
        //    decode error later.
        guard enableAudio ? mtmd_support_audio(mc) : mtmd_support_vision(mc) else {
            mtmd_free(mc)
            llama_free(c)
            llama_model_free(m)
            self.mtmdCtx = nil; self.ctx = nil; self.model = nil
            throw LlamaCppError.visionUnsupported
        }

        // 5. Sampler chain: temperature 0.7 + top-p 0.9 + dist
        //    seeding (random per-instance). Mirrors mtmd-cli's
        //    defaults — produces grounded, low-repetition captions
        //    without runaway top-k weirdness.
        let samplerParams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(samplerParams) else {
            mtmd_free(mc)
            llama_free(c)
            llama_model_free(m)
            self.mtmdCtx = nil; self.ctx = nil; self.model = nil
            throw LlamaCppError.samplerInitFailed
        }
        if usesLFM3VisionTemplate {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(
                llama_vocab_n_tokens(llama_model_get_vocab(m)), 64, 1.1, 0, 0
            ))
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(50))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(1.0, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(0.1))
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_temp(0.7))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.9, 1))
        }
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max)))
        self.sampler = chain
    }

    deinit {
        if let s = sampler { llama_sampler_free(s) }
        if let mc = mtmdCtx { mtmd_free(mc) }
        if let c = ctx { llama_free(c) }
        if let m = model { llama_model_free(m) }
    }

    // MARK: - Text generation

    /// Sampler settings for one text-generation request. Built into a fresh
    /// llama.cpp chain per call in the canonical order (penalties → top-k →
    /// top-p → temp → dist), so the user's settings actually reach imported
    /// GGUF models — the previous init-time chain hardcoded temp 0.7 /
    /// top-p 0.9 and silently ignored every sampler knob.
    struct GGUFSamplerSpec: Sendable {
        var temperature: Float = 0.7
        var topP: Float = 0.9
        var topK: Int32 = 0                // 0 = disabled
        var repetitionPenalty: Float = 1.0 // 1.0 = disabled
        var seed: UInt32? = nil            // nil = random per request
    }

    /// Result of a text-generation run.
    struct GGUFTextResult: Sendable {
        let tokensPerSecond: Double
        /// True when the run ended because the output/context budget ran out
        /// rather than at an end-of-generation token — the reply is truncated
        /// and the UI should say so instead of presenting it as complete.
        let hitTokenLimit: Bool
        let promptTokens: Int
        let outputTokens: Int
        var audioSamples: [Float] = []
        var audioSampleRate: Double = 24_000
    }

    /// Runs an already chat-formatted prompt through a standalone text GGUF.
    ///
    /// - parameter reuseContext: standard (non-recurrent) models clear and
    ///   reuse the load-time context instead of freeing/recreating it per
    ///   request. The recreate exists only for the recurrent Gemma quants
    ///   whose per-layer input path aborts on physical batches above 64.
    func generateText(
        prompt: String,
        maxTokens: Int,
        sampler spec: GGUFSamplerSpec = .init(),
        reuseContext: Bool = false,
        onToken: @escaping (String) -> Void
    ) throws -> GGUFTextResult {
        guard mtmdCtx == nil, let m = model else {
            throw LlamaCppError.contextInitFailed
        }
        let acquired = textGenerationActive.withLock { active -> Bool in
            guard !active else { return false }
            active = true
            return true
        }
        guard acquired else { throw LlamaCppError.generationInProgress }
        defer { textGenerationActive.withLock { $0 = false } }
        cancelFlag.withLock { $0 = false }
        // Swift task cancellation stays sticky even if a queued request starts
        // after Stop has set (and this entry point has reset) the native flag.
        if Task.isCancelled { throw LlamaCppError.cancelled }

        // Per-request sampler chain in llama.cpp's canonical order
        // (penalties → top-k → top-p → temp → dist).
        guard let samp = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw LlamaCppError.samplerInitFailed
        }
        defer { llama_sampler_free(samp) }
        if spec.repetitionPenalty != 1.0 {
            llama_sampler_chain_add(samp, llama_sampler_init_penalties(
                llama_vocab_n_tokens(llama_model_get_vocab(m)),
                -1, spec.repetitionPenalty, 0.0, 0.0
            ))
        }
        if spec.topK > 0 {
            llama_sampler_chain_add(samp, llama_sampler_init_top_k(spec.topK))
        }
        llama_sampler_chain_add(samp, llama_sampler_init_top_p(spec.topP, 1))
        llama_sampler_chain_add(samp, llama_sampler_init_temp(spec.temperature))
        llama_sampler_chain_add(samp, llama_sampler_init_dist(spec.seed ?? LLAMA_DEFAULT_SEED))

        let vocab = llama_model_get_vocab(m)
        // The caller supplies the fully chat-formatted prompt (template or
        // plain role prefixes, depending on the model profile);
        // add_special=true below still supplies BOS.
        let formattedPrompt = prompt

        // utf8CString + explicit byte count: withCString/strlen would
        // silently truncate a prompt containing an embedded NUL.
        let promptCString = formattedPrompt.utf8CString
        let promptByteCount = Int32(promptCString.count - 1)
        let required: Int32 = promptCString.withUnsafeBufferPointer { ptr in
            llama_tokenize(vocab, ptr.baseAddress, promptByteCount, nil, 0, true, true)
        }
        guard required < 0 else { throw LlamaCppError.tokenizeFailed(required) }
        var tokens = [llama_token](repeating: 0, count: Int(-required))
        let written: Int32 = promptCString.withUnsafeBufferPointer { ptr in
            tokens.withUnsafeMutableBufferPointer { buffer in
                llama_tokenize(
                    vocab, ptr.baseAddress, promptByteCount, buffer.baseAddress,
                    Int32(buffer.count), true, true
                )
            }
        }
        guard written > 0 else { throw LlamaCppError.tokenizeFailed(written) }
        tokens.removeSubrange(Int(written)..<tokens.count)
        let tokenizedPromptCount = tokens.count
        Diagnostics.shared.breadcrumb(
            "GGUF tokenized · characters=\(formattedPrompt.count) · tokens=\(tokenizedPromptCount) · context=\(configuredContextSize)",
            category: "assistant"
        )

        // Retain the newest conversational tokens when an existing thread is
        // longer than this bounded context. Message-level trimming in the
        // service keeps normal requests small; this tokenizer-exact clamp is
        // the final guard because character estimates vary substantially by
        // language and community tokenizer.
        //
        // Reserve up to half the context for the reply (the caller's
        // maxTokens permitting) rather than a flat quarter — with the old /4
        // policy a 4K-context GGUF could never emit more than 1024 tokens,
        // even when the user asked for more and the prompt was tiny, so
        // answers stopped mid-sentence. When trimming is needed, preserve the
        // first special token (BOS), then take the newest prompt suffix.
        let requestedOutputTokens = max(1, min(maxTokens, Int(configuredContextSize) / 2))
        let promptTokenLimit = max(1, Int(configuredContextSize) - requestedOutputTokens - 1)
        if tokens.count > promptTokenLimit {
            if promptTokenLimit > 1, let firstToken = tokens.first {
                tokens = [firstToken] + tokens.suffix(promptTokenLimit - 1)
            } else {
                tokens = Array(tokens.suffix(promptTokenLimit))
            }
            Diagnostics.shared.breadcrumb(
                "GGUF prompt trimmed · before=\(tokenizedPromptCount) · after=\(tokens.count) · outputReserve=\(requestedOutputTokens)",
                category: "assistant"
            )
        }
        let vocabularySize = llama_vocab_n_tokens(vocab)
        if let invalid = tokens.first(where: { $0 < 0 || $0 >= vocabularySize }) {
            throw LlamaCppError.invalidToken(invalid)
        }
        // The user's output preference may equal/exceed this GGUF's bounded
        // runtime context (for example 4096). Clamp output to the space left
        // after prompt tokenization instead of failing every first send —
        // and when the prompt is shorter than the reserve, let the reply use
        // the slack (still bounded by the caller's maxTokens).
        let generationLimit = min(maxTokens, Int(configuredContextSize) - tokens.count - 1)
        guard generationLimit > 0 else { throw LlamaCppError.promptTooLong(tokens.count) }

        // Context strategy per model family:
        //  • Standard models reuse the load-time context — clear the
        //    sequence/position metadata (same pattern as describe()) and
        //    prefill in 128-token chunks, well under its n_batch of 512.
        //  • Recurrent Gemma quants recreate the cheap context per request
        //    with n_batch/n_ubatch capped at 64: their per-layer input path
        //    aborts inside ggml_backend_blas_graph_compute on larger
        //    physical batches, before Swift can catch it.
        // Keep text prefill below the larger 256-token burst introduced by
        // the context-reuse path. It preserves the full logical output
        // budget while reducing instantaneous CPU/GPU heat on phones.
        let physicalBatchSize = reuseContext ? 128 : 64
        if !reuseContext {
            invalidateTokenCache()
        }
        let c: OpaquePointer
        var decodeFrom = 0
        if reuseContext, let existing = ctx {
            let shared = GGUFPrefixCache.reuseOffset(
                cached: cachedSequence,
                next: tokens,
                reuseContext: true
            )
            let mem = llama_get_memory(existing)
            if shared > 0, llama_memory_seq_rm(mem, 0, llama_pos(shared), -1) {
                c = existing
                decodeFrom = shared
                Diagnostics.shared.breadcrumb(
                    "GGUF prefix reuse · shared=\(shared) · next=\(tokens.count)",
                    category: "assistant"
                )
            } else {
                llama_memory_clear(mem, false)
                c = existing
                decodeFrom = 0
            }
        } else {
            if let oldContext = ctx {
                llama_free(oldContext)
                ctx = nil
            }
            let requestParams = Self.contextParams(
                nCtx: configuredContextSize, batch: UInt32(physicalBatchSize),
                threads: configuredThreads, quantizedKV: usesQuantizedKV)
            guard let fresh = llama_init_from_model(m, requestParams) else {
                throw LlamaCppError.contextInitFailed
            }
            ctx = fresh
            c = fresh
        }

        var generatedIDs: [llama_token] = []
        if decodeFrom < tokens.count {
            var promptBatch = llama_batch_init(Int32(physicalBatchSize), 0, 1)
            defer { llama_batch_free(promptBatch) }
            let remaining = tokens.count - decodeFrom
            let chunkCount = (remaining + physicalBatchSize - 1) / physicalBatchSize
            Diagnostics.shared.breadcrumb(
                "GGUF prefill start · tokens=\(tokens.count) · from=\(decodeFrom) · batch=\(physicalBatchSize) · chunks=\(chunkCount)",
                category: "assistant"
            )
            var promptOffset = decodeFrom
            var chunkIndex = 0
            while promptOffset < tokens.count {
                if Task.isCancelled || cancelFlag.withLock({ $0 }) {
                    invalidateTokenCache()
                    throw LlamaCppError.cancelled
                }
                let count = min(physicalBatchSize, tokens.count - promptOffset)
                promptBatch.n_tokens = Int32(count)
                for localIndex in 0..<count {
                    let globalIndex = promptOffset + localIndex
                    promptBatch.token[localIndex] = tokens[globalIndex]
                    promptBatch.pos[localIndex] = llama_pos(globalIndex)
                    promptBatch.n_seq_id[localIndex] = 1
                    promptBatch.seq_id[localIndex]?.pointee = 0
                    promptBatch.logits[localIndex] = globalIndex == tokens.count - 1 ? 1 : 0
                }
                chunkIndex += 1
                Diagnostics.shared.breadcrumb(
                    "GGUF prefill chunk · index=\(chunkIndex)/\(chunkCount) · tokens=\(count) · offset=\(promptOffset)",
                    category: "assistant"
                )
                let promptStatus = llama_decode(c, promptBatch)
                guard promptStatus == 0 else {
                    invalidateTokenCache()
                    throw LlamaCppError.decodeFailed(promptStatus)
                }
                promptOffset += count
            }
            Diagnostics.shared.breadcrumb(
                "GGUF prefill complete · tokens=\(tokens.count) · reused=\(decodeFrom) · chunks=\(chunkCount)",
                category: "assistant"
            )
        } else {
            Diagnostics.shared.breadcrumb(
                "GGUF prefill skipped · prefix already resident · tokens=\(tokens.count)",
                category: "assistant"
            )
        }

        let startTime = Date()
        var tokensGenerated = 0
        var pendingUTF8: [UInt8] = []
        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }

        var hitTokenLimit = true
        for _ in 0..<generationLimit {
            if Task.isCancelled || cancelFlag.withLock({ $0 }) {
                invalidateTokenCache()
                throw LlamaCppError.cancelled
            }
            let tokenID = llama_sampler_sample(samp, c, -1)
            llama_sampler_accept(samp, tokenID)
            if llama_vocab_is_eog(vocab, tokenID) {
                hitTokenLimit = false
                break
            }

            var pieceBuffer = [Int8](repeating: 0, count: 256)
            let pieceCount = pieceBuffer.withUnsafeMutableBufferPointer { buffer in
                llama_token_to_piece(vocab, tokenID, buffer.baseAddress, Int32(buffer.count), 0, true)
            }
            if pieceCount > 0 {
                pendingUTF8.append(
                    contentsOf: pieceBuffer.prefix(Int(pieceCount)).map { UInt8(bitPattern: $0) }
                )
                let (piece, tail) = Self.splitCompleteUTF8Prefix(pendingUTF8)
                pendingUTF8 = tail
                if !piece.isEmpty { onToken(piece) }
            }
            tokensGenerated += 1
            generatedIDs.append(tokenID)

            batch.n_tokens = 1
            batch.token[0] = tokenID
            batch.pos[0] = llama_pos(tokens.count + tokensGenerated - 1)
            batch.n_seq_id[0] = 1
            batch.seq_id[0]?.pointee = 0
            batch.logits[0] = 1
            let status = llama_decode(c, batch)
            guard status == 0 else {
                invalidateTokenCache()
                throw LlamaCppError.decodeFailed(status)
            }
        }

        if !pendingUTF8.isEmpty {
            onToken(String(decoding: pendingUTF8, as: UTF8.self))
        }
        cachedSequence = tokens + generatedIDs
        cacheUsableForContinue = reuseContext && hitTokenLimit
        return GGUFTextResult(
            tokensPerSecond: Self.tokensPerSec(tokens: tokensGenerated, start: startTime),
            hitTokenLimit: hitTokenLimit,
            promptTokens: tokens.count,
            outputTokens: tokensGenerated
        )
    }

    /// Resume decoding from the KV left by the last `generateText` that hit
    /// the output budget. Compact / recreate runtimes never expose this.
    func continueText(
        maxTokens: Int,
        sampler spec: GGUFSamplerSpec = .init(),
        onToken: @escaping (String) -> Void
    ) throws -> GGUFTextResult {
        guard mtmdCtx == nil, let m = model, let c = ctx, hasContinuableCache else {
            throw LlamaCppError.contextInitFailed
        }
        let acquired = textGenerationActive.withLock { active -> Bool in
            guard !active else { return false }
            active = true
            return true
        }
        guard acquired else { throw LlamaCppError.generationInProgress }
        defer { textGenerationActive.withLock { $0 = false } }
        cancelFlag.withLock { $0 = false }
        // Swift task cancellation stays sticky even if a queued request starts
        // after Stop has set (and this entry point has reset) the native flag.
        if Task.isCancelled { throw LlamaCppError.cancelled }
        cacheUsableForContinue = false

        guard let samp = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw LlamaCppError.samplerInitFailed
        }
        defer { llama_sampler_free(samp) }
        if spec.repetitionPenalty != 1.0 {
            llama_sampler_chain_add(samp, llama_sampler_init_penalties(
                llama_vocab_n_tokens(llama_model_get_vocab(m)),
                -1, spec.repetitionPenalty, 0.0, 0.0
            ))
        }
        if spec.topK > 0 {
            llama_sampler_chain_add(samp, llama_sampler_init_top_k(spec.topK))
        }
        llama_sampler_chain_add(samp, llama_sampler_init_top_p(spec.topP, 1))
        llama_sampler_chain_add(samp, llama_sampler_init_temp(spec.temperature))
        llama_sampler_chain_add(samp, llama_sampler_init_dist(spec.seed ?? LLAMA_DEFAULT_SEED))

        let vocab = llama_model_get_vocab(m)
        let promptTokenCount = cachedSequence.count
        let generationLimit = GGUFPrefixCache.continuationLimit(
            contextSize: Int(configuredContextSize),
            cachedTokenCount: promptTokenCount,
            requested: maxTokens
        )
        guard generationLimit > 0 else { throw LlamaCppError.promptTooLong(promptTokenCount) }

        Diagnostics.shared.breadcrumb(
            "GGUF continue · n_past=\(promptTokenCount) · limit=\(generationLimit)",
            category: "assistant"
        )

        let startTime = Date()
        var tokensGenerated = 0
        var pendingUTF8: [UInt8] = []
        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }
        var generatedIDs: [llama_token] = []
        var hitTokenLimit = true
        for _ in 0..<generationLimit {
            if Task.isCancelled || cancelFlag.withLock({ $0 }) {
                invalidateTokenCache()
                throw LlamaCppError.cancelled
            }
            let tokenID = llama_sampler_sample(samp, c, -1)
            llama_sampler_accept(samp, tokenID)
            if llama_vocab_is_eog(vocab, tokenID) {
                hitTokenLimit = false
                break
            }
            var pieceBuffer = [Int8](repeating: 0, count: 256)
            let pieceCount = pieceBuffer.withUnsafeMutableBufferPointer { buffer in
                llama_token_to_piece(vocab, tokenID, buffer.baseAddress, Int32(buffer.count), 0, true)
            }
            if pieceCount > 0 {
                pendingUTF8.append(
                    contentsOf: pieceBuffer.prefix(Int(pieceCount)).map { UInt8(bitPattern: $0) }
                )
                let (piece, tail) = Self.splitCompleteUTF8Prefix(pendingUTF8)
                pendingUTF8 = tail
                if !piece.isEmpty { onToken(piece) }
            }
            tokensGenerated += 1
            generatedIDs.append(tokenID)
            batch.n_tokens = 1
            batch.token[0] = tokenID
            batch.pos[0] = llama_pos(
                GGUFPrefixCache.continuationDecodePosition(
                    cachedTokenCount: promptTokenCount,
                    generatedSinceResume: tokensGenerated - 1
                )
            )
            batch.n_seq_id[0] = 1
            batch.seq_id[0]?.pointee = 0
            batch.logits[0] = 1
            let status = llama_decode(c, batch)
            guard status == 0 else {
                invalidateTokenCache()
                throw LlamaCppError.decodeFailed(status)
            }
        }
        if !pendingUTF8.isEmpty {
            onToken(String(decoding: pendingUTF8, as: UTF8.self))
        }
        cachedSequence.append(contentsOf: generatedIDs)
        cacheUsableForContinue = hitTokenLimit
        return GGUFTextResult(
            tokensPerSecond: Self.tokensPerSec(tokens: tokensGenerated, start: startTime),
            hitTokenLimit: hitTokenLimit,
            promptTokens: promptTokenCount,
            outputTokens: tokensGenerated
        )
    }

    // MARK: - Describe

    /// Splits a rendered LFM3 prompt into the prefix to evaluate and the raw
    /// text the audio helper continues: everything from the final assistant
    /// header on (the generation cue, or an open turn being continued after a
    /// token limit). Media markers go into the last user turn, never into a
    /// later tool response.
    static func splitLFM3Prompt(
        _ prompt: String, template: ChatTemplate, mediaMarkers: String
    ) -> (body: String, cue: String)? {
        guard let open = prompt.range(of: template.assistantPrefix, options: .backwards) else { return nil }
        var body = String(prompt[..<open.lowerBound])
        if !mediaMarkers.isEmpty {
            let userStart = body.range(of: template.userPrefix, options: .backwards)?.upperBound ?? body.startIndex
            guard let end = body.range(of: "<|im_end|>", range: userStart..<body.endIndex) else { return nil }
            body.insert(contentsOf: mediaMarkers, at: end.lowerBound)
        }
        return (body, String(prompt[open.lowerBound...]))
    }

    /// Shared Audio/Omni path. All loads still belong to the assistant's
    /// residency owner; this method only runs its already-admitted context.
    func generateLFM3(
        prompt: String, audio: [Float]? = nil, image: UIImage? = nil,
        generateSpeech: Bool = false, letModelChooseAudio: Bool = false,
        template: ChatTemplate = .lfm3Audio,
        maxTokens: Int,
        sampler spec: GGUFSamplerSpec = .init(), onToken: @escaping (String) -> Void,
        onAudioChunk: (([Float], Double) -> Void)? = nil
    ) throws -> GGUFTextResult {
        guard let mc = mtmdCtx, let c = ctx, let m = model,
              mtmd_gen_audio_get_info(mc).type == MTMD_GEN_AUDIO_TYPE_LFM3A else { throw LlamaCppError.contextInitFailed }
        let acquired = textGenerationActive.withLock { active -> Bool in
            guard !active else { return false }; active = true; return true
        }
        guard acquired else { throw LlamaCppError.generationInProgress }
        defer { textGenerationActive.withLock { $0 = false } }
        cancelFlag.withLock { $0 = false }
        func checkCancellation() throws {
            if Task.isCancelled || cancelFlag.withLock({ $0 }) { throw LlamaCppError.cancelled }
        }
        try checkCancellation()
        guard (audio?.count ?? 0) <= 480_000,
              (audio?.allSatisfy({ $0.isFinite }) ?? true) else { throw LlamaCppError.promptTooLong(audio?.count ?? 0) }
        llama_memory_clear(llama_get_memory(c), false)
        invalidateTokenCache()
        var bitmaps: [OpaquePointer?] = []
        defer { bitmaps.compactMap { $0 }.forEach(mtmd_bitmap_free) }
        if let image {
            guard mtmd_support_vision(mc) else { throw LlamaCppError.visionUnsupported }
            let rgb = try Self.makeRGBBitmap(from: image)
            let bitmap = rgb.rgb.withUnsafeBufferPointer { mtmd_bitmap_init(UInt32(rgb.width), UInt32(rgb.height), $0.baseAddress) }
            guard let bitmap else { throw LlamaCppError.bitmapInitFailed }
            bitmaps.append(bitmap)
        }
        if let audio, !audio.isEmpty {
            guard mtmd_support_audio(mc), mtmd_get_audio_sample_rate(mc) == 16_000 else { throw LlamaCppError.contextInitFailed }
            let bitmap = audio.withUnsafeBufferPointer { mtmd_bitmap_init_from_audio($0.count, $0.baseAddress) }
            guard let bitmap else { throw LlamaCppError.bitmapInitFailed }
            bitmaps.append(bitmap)
        }
        let markers = String(repeating: "\n" + String(cString: mtmd_get_marker(mc)), count: bitmaps.count)
        guard let split = Self.splitLFM3Prompt(prompt, template: template, mediaMarkers: markers) else {
            throw LlamaCppError.tokenizeFailed(-1)
        }
        let body = split.body, cue = split.cue
        guard let chunks = mtmd_input_chunks_init() else { throw LlamaCppError.bitmapInitFailed }
        defer { mtmd_input_chunks_free(chunks) }
        let tokenized = body.withCString { ptr -> Int32 in
            var text = mtmd_input_text(text: ptr, text_len: body.utf8.count, add_special: false, parse_special: true)
            return bitmaps.withUnsafeMutableBufferPointer { mtmd_tokenize(mc, chunks, &text, $0.baseAddress, $0.count) }
        }
        guard tokenized == 0 else { throw LlamaCppError.tokenizeFailed(tokenized) }
        var positions = 0
        for index in 0..<mtmd_input_chunks_size(chunks) {
            if let chunk = mtmd_input_chunks_get(chunks, index) { positions += Int(mtmd_input_chunk_get_n_pos(chunk)) }
        }
        guard positions > 0, positions + 32 < Int(configuredContextSize) else { throw LlamaCppError.promptTooLong(positions) }
        var past: llama_pos = 0
        try checkCancellation()
        let evaluated = mtmd_helper_eval_chunks(mc, c, chunks, 0, 0, 128, true, &past)
        guard evaluated == 0 else { throw LlamaCppError.decodeFailed(evaluated) }
        try checkCancellation()
        guard let generator = mtmd_helper_gen_audio_init(c, mc) else { throw LlamaCppError.contextInitFailed }
        defer { mtmd_helper_gen_audio_free(generator) }
        var input = mtmd_helper_gen_audio_inp_default()
        input.n_past = past
        // AUTO lets the model choose between a tool call, text, and speech.
        // That is the documented mode for spoken tool requests; MIXED is the
        // documented prefill when a voice answer must contain speech.
        input.out_mode = generateSpeech
            ? (letModelChooseAudio ? MTMD_HELPER_GEN_AUDIO_OUT_AUTO : MTMD_HELPER_GEN_AUDIO_OUT_MIXED)
            : MTMD_HELPER_GEN_AUDIO_OUT_TEXT
        input.stream = true
        input.out_type = MTMD_HELPER_GEN_AUDIO_OUTTYPE_PCM
        input.seed = spec.seed ?? UInt32.max
        let setStatus = cue.withCString { ptr -> Int32 in
            input.prompt = ptr; input.prompt_len = cue.utf8.count
            return mtmd_helper_gen_audio_set_input(generator, &input)
        }
        guard setStatus == 0 else { throw LlamaCppError.decodeFailed(setStatus) }
        while true {
            try checkCancellation()
            let remaining = mtmd_helper_gen_audio_step_prompt(generator, 128)
            guard remaining >= 0 else { throw LlamaCppError.decodeFailed(remaining) }
            if remaining == 0 { break }
        }
        guard let sampling = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { throw LlamaCppError.samplerInitFailed }
        defer { llama_sampler_free(sampling) }
        let vocab = llama_model_get_vocab(m)
        if spec.repetitionPenalty != 1.0 {
            llama_sampler_chain_add(sampling, llama_sampler_init_penalties(
                llama_vocab_n_tokens(vocab),
                -1, spec.repetitionPenalty, 0.0, 0.0
            ))
        }
        var biasCount = 0
        if let biases = mtmd_helper_gen_audio_get_logit_bias(generator, &biasCount), biasCount > 0 {
            llama_sampler_chain_add(sampling, llama_sampler_init_logit_bias(llama_vocab_n_tokens(vocab), Int32(clamping: biasCount), biases))
        }
        llama_sampler_chain_add(sampling, llama_sampler_init_top_k(spec.topK))
        llama_sampler_chain_add(sampling, llama_sampler_init_top_p(spec.topP, 1))
        llama_sampler_chain_add(sampling, llama_sampler_init_temp(spec.temperature))
        llama_sampler_chain_add(sampling, llama_sampler_init_dist(spec.seed ?? UInt32.max))
        var hidden = llama_get_embeddings_ith(c, -1).map { UnsafePointer<Float>($0) }
        guard hidden != nil else { throw LlamaCppError.contextInitFailed }
        var samples: [Float] = []
        var sampleRate: Int32 = 24_000
        var pending: [UInt8] = []
        var stopped = false
        var count = 0
        let budget = min(max(1, maxTokens), Int(configuredContextSize) - Int(past) - 32)
        let started = Date()
        // ponytail: 60 s of 24 kHz speech per reply; a longer answer stops
        // like a token-limited one instead of discarding text and audio.
        let maxSamples = 1_440_000
        func collectAudio() throws {
            var bytes: UnsafePointer<CChar>?
            var size = 0
            let status = mtmd_helper_gen_audio_get_output(generator, &sampleRate, &bytes, &size, nil)
            guard status == 0 else { throw LlamaCppError.decodeFailed(status) }
            if let bytes, size > 0 {
                guard size % MemoryLayout<Float>.size == 0 else { throw LlamaCppError.decodeFailed(-1) }
                let floats = UnsafeRawPointer(bytes).assumingMemoryBound(to: Float.self)
                let kept = min(size / MemoryLayout<Float>.size, maxSamples - samples.count)
                let chunk = UnsafeBufferPointer(start: floats, count: kept)
                samples.append(contentsOf: chunk)
                if kept > 0 { onAudioChunk?(Array(chunk), Double(sampleRate)) }
            }
        }
        for _ in 0..<budget {
            try checkCancellation()
            let isText = mtmd_helper_gen_audio_next_is_text(generator)
            let token = isText ? llama_sampler_sample(sampling, c, -1) : LLAMA_TOKEN_NULL
            if isText { llama_sampler_accept(sampling, token) }
            var next: UnsafePointer<Float>?
            let status = mtmd_helper_gen_audio_step_gen(generator, token, hidden, &next, &stopped)
            guard status == 0 else { throw LlamaCppError.decodeFailed(status) }
            if stopped { break }
            guard let next else { throw LlamaCppError.decodeFailed(-1) }
            hidden = next
            count += 1
            if isText {
                var bytes = [CChar](repeating: 0, count: 512)
                let length = bytes.withUnsafeMutableBufferPointer { llama_token_to_piece(vocab, token, $0.baseAddress, Int32($0.count), 0, true) }
                guard length >= 0 else { throw LlamaCppError.tokenizeFailed(length) }
                let piece = bytes.prefix(Int(length)).map { UInt8(bitPattern: $0) }
                let text = String(decoding: piece, as: UTF8.self)
                if !["<|mixed_start|>", "<|audio_start|>", "<|audio_end|>", "<|text_end|>", "<|text_start|>"].contains(text) {
                    pending.append(contentsOf: piece)
                    let (complete, tail) = Self.splitCompleteUTF8Prefix(pending)
                    pending = tail
                    if !complete.isEmpty { onToken(complete) }
                }
            }
            if generateSpeech {
                try collectAudio()
                if samples.count >= maxSamples { break }
            }
        }
        try checkCancellation()
        if generateSpeech {
            let status = mtmd_helper_gen_audio_flush(generator)
            guard status == 0 else { throw LlamaCppError.decodeFailed(status) }
            try collectAudio()
        }
        if !pending.isEmpty { onToken(String(decoding: pending, as: UTF8.self)) }
        return GGUFTextResult(tokensPerSecond: Double(count) / max(0.001, Date().timeIntervalSince(started)),
            hitTokenLimit: !stopped, promptTokens: Int(past), outputTokens: count,
            audioSamples: samples, audioSampleRate: Double(sampleRate))
    }

    /// Encode the image, prepend the prompt, stream tokens via
    /// `onToken`, finish via `onComplete(tokensPerSec)`. Cancellable
    /// via `cancelCurrent()`. On error, throws and `onComplete`
    /// is NOT called.
    func describe(
        image: UIImage,
        prompt: String,
        maxTokens: Int = 256,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (Double) -> Void
    ) throws {
        guard let mc = mtmdCtx, let c = ctx, let samp = sampler, let m = model else {
            throw LlamaCppError.contextInitFailed
        }
        if mtmd_gen_audio_get_info(mc).type == MTMD_GEN_AUDIO_TYPE_LFM3A {
            let template: ChatTemplate = mtmd_support_vision(mc) ? .lfm3Omni : .lfm3Audio
            try waitForGenerationSlot(claim: false)   // generateLFM3 claims it
            let result = try generateLFM3(
                prompt: template.format(messages: [
                    ChatMessage(role: .system, content: "Respond in text."),
                    ChatMessage(role: .user, content: prompt),
                ]), image: image, template: template, maxTokens: maxTokens, onToken: onToken)
            onComplete(result.tokensPerSecond)
            return
        }
        try waitForGenerationSlot(claim: true)
        defer { textGenerationActive.withLock { $0 = false } }
        cancelFlag.withLock { $0 = false }
        // Swift task cancellation stays sticky even if a queued request starts
        // after Stop has set (and this entry point has reset) the native flag.
        if Task.isCancelled { throw LlamaCppError.cancelled }

        // Reset the KV cache from the previous describe() call. mtmd_helper_
        // eval_chunks below feeds tokens starting at n_past = 0, but llama_
        // decode tracks the highest position it saw for each sequence and
        // refuses to accept a batch whose starting position isn't
        // (last_pos + 1). Without this clear, the second call fails with:
        //   "init: the tokens of sequence 0 in the input batch have
        //    inconsistent sequence positions … X = N, Y = 0"
        // and the caller is forced to tear down and reload the whole 780+ MB
        // model just to get a working context — observed in the crash log
        // before this fix. data: false drops only the position-tracking
        // metadata; the underlying KV tensor storage is reused.
        llama_memory_clear(llama_get_memory(c), false)
        invalidateTokenCache()

        // 1. Convert UIImage → RGB-packed bytes for mtmd_bitmap.
        let bitmap = try Self.makeRGBBitmap(from: image)
        let mtmdBitmap: OpaquePointer? = bitmap.rgb.withUnsafeBufferPointer { buf -> OpaquePointer? in
            guard let base = buf.baseAddress else { return nil }
            return mtmd_bitmap_init(UInt32(bitmap.width), UInt32(bitmap.height), base)
        }
        guard let mb = mtmdBitmap else { throw LlamaCppError.bitmapInitFailed }
        defer { mtmd_bitmap_free(mb) }

        // 2. Build a chat-template-shaped prompt with the media marker
        //    mtmd will replace with image-token placeholders during
        //    tokenize. SmolVLM2's GGUF weights carry a chat template
        //    (`<|im_start|>User: ...<end_of_utterance>\nAssistant:`).
        //    Feeding only "<__media__>\n<prompt>" used to limp along, but
        //    newer mtmd/template handling expects the real role wrapper.
        let marker = String(cString: mtmd_get_marker(mc))
        let fullPrompt = Self.formatPrompt(
            prompt,
            marker: marker,
            model: m
        )

        // 3. Tokenize text + bitmap into a chunks list.
        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }

        let tokenizeStatus: Int32 = fullPrompt.withCString { cstr -> Int32 in
            var inputText = mtmd_input_text()
            inputText.text = cstr
            inputText.text_len = strlen(cstr)
            inputText.add_special = true
            inputText.parse_special = true
            var bitmaps: [OpaquePointer?] = [mb]
            return bitmaps.withUnsafeMutableBufferPointer { bp -> Int32 in
                mtmd_tokenize(mc, chunks, &inputText, bp.baseAddress, 1)
            }
        }
        guard tokenizeStatus == 0 else {
            throw LlamaCppError.tokenizeFailed(tokenizeStatus)
        }

        // 4. Eval the chunks. mtmd-helper handles the text+image
        //    interleave + non-causal attention setup for image
        //    chunks. n_past starts at 0 (fresh KV cache).
        var nPast: llama_pos = 0
        let evalStatus = mtmd_helper_eval_chunks(
            mc,
            c,
            chunks,
            /* n_past */ 0,
            /* seq_id */ 0,
            /* n_batch */ 512,
            /* logits_last */ true,
            &nPast
        )
        guard evalStatus == 0 else {
            throw LlamaCppError.decodeFailed(evalStatus)
        }

        // 5. Generate. One sample → decode → advance n_past per
        //    iteration. EOS or maxTokens or cancel ends the loop.
        let startTime = Date()
        var tokensGenerated = 0
        let vocab = llama_model_get_vocab(m)
        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }

        // Raw UTF-8 bytes carried across tokens. A multi-byte character
        // (emoji, CJK) is routinely split across two pieces; decoding each
        // piece in isolation corrupts it. We accumulate bytes here, emit
        // the longest complete-UTF-8 prefix per token, and retain the
        // partial tail for the next piece.
        var pendingUTF8: [UInt8] = []

        for _ in 0..<maxTokens {
            if Task.isCancelled || cancelFlag.withLock({ $0 }) {
                // Contract (see doc-comment above): on throw, onComplete
                // is NOT called — the caller's catch handler owns the
                // finalisation in that case. Calling onComplete here
                // AND throwing caused a double-fire that crashed the
                // AnalysisService continuation ("SWIFT TASK CONTINUATION
                // MISUSE: tried to resume its continuation more than once").
                throw LlamaCppError.cancelled
            }

            let tokenID = llama_sampler_sample(samp, c, -1)
            llama_sampler_accept(samp, tokenID)

            if llama_vocab_is_eog(vocab, tokenID) {
                break
            }

            // Token → UTF-8 piece. 128-byte buffer covers any
            // single-token piece (most are <16).
            var pieceBuf = [Int8](repeating: 0, count: 128)
            let n = pieceBuf.withUnsafeMutableBufferPointer { buf -> Int32 in
                llama_token_to_piece(vocab, tokenID, buf.baseAddress, Int32(buf.count), 0, true)
            }
            if n > 0 {
                // Take exactly `n` bytes. String(cString:) is wrong here on
                // both counts: it needs a NUL terminator (absent when the
                // piece fills the buffer — OOB read) and it mangles a
                // multi-byte sequence split across tokens.
                pendingUTF8.append(
                    contentsOf: pieceBuf.prefix(Int(n)).map { UInt8(bitPattern: $0) })
                let (piece, tail) = Self.splitCompleteUTF8Prefix(pendingUTF8)
                pendingUTF8 = tail
                if !piece.isEmpty { onToken(piece) }
            }
            tokensGenerated += 1

            // Next batch: single token at position nPast, logits
            // requested on this position so the next iteration
            // can sample from them.
            batch.n_tokens = 1
            batch.token[0] = tokenID
            batch.pos[0] = nPast
            batch.n_seq_id[0] = 1
            batch.seq_id[0]?.pointee = 0
            batch.logits[0] = 1

            let decRet = llama_decode(c, batch)
            if decRet != 0 {
                throw LlamaCppError.decodeFailed(decRet)
            }
            nPast += 1
        }

        // Flush whatever bytes are still held back (a trailing split
        // sequence that never completed) — decode lossily so nothing is
        // silently dropped.
        if !pendingUTF8.isEmpty {
            let tail = String(decoding: pendingUTF8, as: UTF8.self)
            pendingUTF8.removeAll()
            if !tail.isEmpty { onToken(tail) }
        }

        onComplete(Self.tokensPerSec(tokens: tokensGenerated, start: startTime))
    }

    // MARK: - Helpers

    /// Splits `bytes` into the longest prefix that ends on a complete
    /// UTF-8 character and the trailing bytes of an incomplete multi-byte
    /// sequence (0–3 bytes). llama.cpp tokens routinely split a character
    /// across pieces, so the tail is carried over to the next piece.
    private static func splitCompleteUTF8Prefix(_ bytes: [UInt8]) -> (String, [UInt8]) {
        guard !bytes.isEmpty else { return ("", []) }
        // Walk back over at most 3 trailing continuation bytes to find the
        // lead byte of the final character, then check whether the sequence
        // it starts is complete.
        var cut = bytes.count
        var i = bytes.count - 1
        var continuations = 0
        while i >= 0, continuations < 3, bytes[i] & 0b1100_0000 == 0b1000_0000 {
            continuations += 1
            i -= 1
        }
        if i >= 0 {
            let lead = bytes[i]
            let expected: Int
            if lead & 0b1000_0000 == 0 { expected = 1 }
            else if lead & 0b1110_0000 == 0b1100_0000 { expected = 2 }
            else if lead & 0b1111_0000 == 0b1110_0000 { expected = 3 }
            else if lead & 0b1111_1000 == 0b1111_0000 { expected = 4 }
            else { expected = 1 }   // invalid lead — let lossy decoding handle it
            if continuations + 1 < expected {
                cut = i   // final character incomplete — hold it back
            }
        }
        let prefix = String(decoding: bytes[..<cut], as: UTF8.self)
        return (prefix, Array(bytes[cut...]))
    }

    private static func tokensPerSec(tokens: Int, start: Date) -> Double {
        let elapsed = Date().timeIntervalSince(start)
        return elapsed > 0 ? Double(tokens) / elapsed : 0
    }

    /// Apply the GGUF's own chat template around the user turn, keeping the
    /// mtmd media marker inside the user content. This mirrors
    /// llama-mtmd-cli's single-turn path and is especially important for
    /// SmolVLM/SmolVLM2, whose `<|im_start|>` token is BOS rather than ChatML.
    private static func formatPrompt(
        _ prompt: String,
        marker: String,
        model: OpaquePointer
    ) -> String {
        let userContent: String = {
            if prompt.contains(marker) { return prompt }
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return marker
            }
            return "\(marker)\n\(prompt)"
        }()

        // The lightweight C template renderer treats LFM3 as generic ChatML,
        // omitting its BOS and reasoning cue. Its GGUF disables automatic BOS.
        // Read architecture metadata so renamed/imported files work as well.
        var architecture = [CChar](repeating: 0, count: 32)
        let length = architecture.withUnsafeMutableBufferPointer { buffer in
            llama_model_meta_val_str(model, "general.architecture", buffer.baseAddress, buffer.count)
        }
        if length == 4,
           String(decoding: architecture.prefix(4).map { UInt8(bitPattern: $0) }, as: UTF8.self) == "lfm3" {
            return ChatTemplate.lfm3.format(
                messages: [ChatMessage(role: .user, content: userContent)],
                enableThinking: false
            )
        }

        guard let template = llama_model_chat_template(model, nil),
              let rendered = applyChatTemplate(template, userContent: userContent) else {
            return userContent
        }
        return rendered
    }

    private static func applyChatTemplate(
        _ template: UnsafePointer<CChar>,
        userContent: String
    ) -> String? {
        "user".withCString { rolePtr in
            userContent.withCString { contentPtr in
                var message = llama_chat_message(role: rolePtr, content: contentPtr)
                let required = llama_chat_apply_template(
                    template,
                    &message,
                    1,
                    true,
                    nil,
                    0
                )
                guard required >= 0 else { return nil }

                var buffer = [CChar](repeating: 0, count: Int(required) + 1)
                let written = buffer.withUnsafeMutableBufferPointer { buf in
                    llama_chat_apply_template(
                        template,
                        &message,
                        1,
                        true,
                        buf.baseAddress,
                        Int32(buf.count)
                    )
                }
                guard written >= 0 else { return nil }
                let byteCount = min(Int(written), buffer.count - 1)
                let bytes = buffer.prefix(byteCount).map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            }
        }
    }

    /// UIImage → row-major RGB bytes (3 bytes per pixel) at the
    /// image's native pixel dimensions. mtmd resizes internally
    /// per the mmproj's metadata, so we don't pre-resize. We
    /// rasterize through a CGContext to flatten orientation and
    /// drop any alpha channel — mtmd_bitmap_init expects exactly
    /// `width * height * 3` bytes with no padding.
    ///
    /// Path: render into a 32bpp BGRA bitmap, then repack down to
    /// 24bpp RGB. We CANNOT render directly into 24bpp RGB —
    /// CGBitmapContext on iOS rejects packed 8-bit-per-component
    /// formats without an alpha channel and logs
    ///   "CGBitmapContextCreate: unsupported parameter combination:
    ///    RGB | 8 bits/component, integer | <N> bytes/row.
    ///    kCGImageAlphaNone | kCGImageByteOrderDefault | kCGImagePixelFormatPacked"
    /// before returning nil. The repack step is one O(w*h) pass over
    /// already-resident bytes, cheaper than even a single Metal upload.
    private struct RGBBitmap {
        let rgb: [UInt8]
        let width: Int
        let height: Int
    }

    private static func makeRGBBitmap(from image: UIImage) throws -> RGBBitmap {
        let cg: CGImage
        if let cgImage = image.cgImage {
            cg = cgImage
        } else if let ciImage = image.ciImage {
            let renderCtx = CIContext()
            guard let made = renderCtx.createCGImage(ciImage, from: ciImage.extent) else {
                throw LlamaCppError.bitmapInitFailed
            }
            cg = made
        } else {
            throw LlamaCppError.bitmapInitFailed
        }

        let width = cg.width
        let height = cg.height
        let bgraBytesPerRow = width * 4
        var bgra = [UInt8](repeating: 0, count: bgraBytesPerRow * height)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ok: Bool = bgra.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8,
                bytesPerRow: bgraBytesPerRow,
                space: cs,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                            CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { throw LlamaCppError.bitmapInitFailed }

        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        rgb.withUnsafeMutableBufferPointer { rgbBuf in
            bgra.withUnsafeBufferPointer { bgraBuf in
                guard let rgbBase = rgbBuf.baseAddress,
                      let bgraBase = bgraBuf.baseAddress else { return }
                for i in 0..<(width * height) {
                    let s = bgraBase + i * 4
                    let d = rgbBase + i * 3
                    d[0] = s[2]   // R (from B-position in little-endian BGRA)
                    d[1] = s[1]   // G
                    d[2] = s[0]   // B
                }
            }
        }
        return RGBBitmap(rgb: rgb, width: width, height: height)
    }
}
