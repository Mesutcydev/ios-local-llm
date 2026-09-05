import Foundation

/// A ready-to-download Core AI pack.
///
/// Every entry below was verified against the Hugging Face tree API on
/// 2026-08-21 (see `scripts/audit_coreai_repos.py`): the recorded subtree
/// exists, contains at least one `.aimodel`, and ships the `metadata.json`
/// the Core AI runtime contract requires. `approxDownloadBytes` is the summed
/// LFS size of that subtree, not an estimate.
struct CoreAIZooModel: Identifiable, Hashable, Sendable {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        /// Apple's own export recipes, unmodified, running on the stock runtime.
        case officialRecipe
        /// Community text-generation ports.
        case chat
        /// Image + text in, text out.
        case vision
        /// Embedding / rerank / speech utilities.
        case utility

        var id: String { rawValue }

        var title: String {
            switch self {
            case .officialRecipe: return "OFFICIAL RECIPE"
            case .chat:           return "CHAT MODELS"
            case .vision:         return "VISION-LANGUAGE"
            case .utility:        return "SPEECH & EMBEDDING"
            }
        }

        var detail: String {
            switch self {
            case .officialRecipe:
                return "Apple's coreai-models recipes, pre-converted. Stock runtime."
            case .chat:
                return "Community ports. Text generation through the local API."
            case .vision:
                return "Image understanding. Needs the vision + decoder pair."
            case .utility:
                return "Not chat models — embedding, rerank, and transcription."
            }
        }
    }

    let id: String
    let displayName: String
    let subtitle: String
    let hfRepo: String
    let revision: String
    /// When non-nil, only files under this repo subtree are downloaded.
    /// Every one of these repos ships several platform trees side by side, so
    /// omitting the prefix would pull tens of gigabytes.
    let pathPrefix: String?
    /// Measured size of `pathPrefix` (summed LFS bytes), not an estimate.
    let approxDownloadBytes: Int64
    let contextWindow: Int
    let supportsThinking: Bool
    let supportsTools: Bool
    let category: Category
    let licenseNotice: String

    /// Some reasoning-tuned checkpoints have no instruct/no-think mode in
    /// their published chat template. Keep reasoning enabled for those packs
    /// instead of sending a contradictory template flag and system prompt.
    var requiresThinking: Bool {
        id == "zoo-lfm25-2.6b"
    }

    /// Persisted Assistant selection identity. Prefixing keeps it outside the
    /// preset/downloaded/imported namespaces used by the MLX/GGUF registry.
    var assistantSelectionID: String { "coreai:\(id)" }

    /// Adapter into the existing Assistant picker/runtime axis. Core AI stays
    /// a normal local model from the conversation's point of view — same
    /// history, system prompt, tool envelopes and stop button — while runtime
    /// dispatch branches on `.coreAI` instead of forcing `.aimodel` resources
    /// through the MLX/GGUF storage machinery.
    var assistantModel: AssistantModel {
        var typed: Set<ModelCapability> = []
        if supportsThinking { typed.insert(.thinking) }
        if supportsTools { typed.insert(.tools) }
        if category == .vision { typed.insert(.vision) }
        return AssistantModel(
            id: assistantSelectionID,
            repoID: hfRepo,
            displayName: displayName,
            subtitle: "Core AI · \(subtitle)",
            // Download bytes are a better first-order residency proxy than 0.
            // Core AI specialization/runtime buffers add headroom at load time.
            approxRAMBytes: approxDownloadBytes + 500_000_000,
            tags: ["core-ai", category.rawValue],
            contextWindowTokens: contextWindow,
            downloadSizeBytes: approxDownloadBytes,
            capabilities: typed,
            supportsTools: supportsTools,
            runtime: .coreAI
        )
    }

    var hubURL: URL {
        URL(string: "https://huggingface.co/\(hfRepo)")
            ?? URL(string: "https://huggingface.co")!
    }

    /// Direct link to the exact subtree this entry downloads, so the license
    /// and file list can be checked before spending the bandwidth.
    var treeURL: URL {
        let base = "https://huggingface.co/\(hfRepo)/tree/\(revision)"
        if let pathPrefix, !pathPrefix.isEmpty {
            return URL(string: "\(base)/\(pathPrefix)") ?? hubURL
        }
        return URL(string: base) ?? hubURL
    }
}

enum CoreAIZooCatalog {
    /// Catalog identities intentionally withdrawn from Assistant because the
    /// published artifact requires model-specific runtime plumbing that this
    /// app does not ship. Keep the identity here so older installations do
    /// not fall through to the permissive custom-model path.
    private static let unsupportedTextGenerationPackIDs: Set<String> = [
        "zoo-gemma4-e2b",
    ]

    /// Curated iPhone-capable packs, ordered smallest-first within each
    /// category so the cheapest working download is the first thing offered.
    ///
    /// Deliberately excluded: Mac-only trees (`macos/`, dense 27B+/MoE ports),
    /// `ios-frontend` trees that carry no `.aimodel`, and any subtree missing
    /// `metadata.json`. Those install but cannot load here.
    static let iphoneLanguageModels: [CoreAIZooModel] = [

        // MARK: Official recipes (Apple's export scripts, unmodified)

        CoreAIZooModel(
            id: "zoo-qwen3-0.6b-official-ios",
            displayName: "Qwen3 0.6B · Official iOS",
            subtitle: "Apple recipe · smallest complete pack",
            hfRepo: "mlboydaisuke/qwen3-0.6b-CoreAI-official",
            revision: "main",
            pathPrefix: "ios",
            approxDownloadBytes: 456_296_751,
            contextWindow: 4_096,
            supportsThinking: true,
            supportsTools: false,
            category: .officialRecipe,
            licenseNotice: "Apache-2.0 (Qwen). Verify the Hub card before redistribution."
        ),
        CoreAIZooModel(
            id: "zoo-qwen3-4b-official-ios",
            displayName: "Qwen3 4B · Official iOS",
            subtitle: "Apple recipe · strongest official iOS tree",
            hfRepo: "mlboydaisuke/qwen3-4b-CoreAI-official",
            revision: "main",
            pathPrefix: "ios",
            approxDownloadBytes: 2_502_148_395,
            contextWindow: 4_096,
            supportsThinking: true,
            supportsTools: false,
            category: .officialRecipe,
            licenseNotice: "Apache-2.0 (Qwen). Check free disk and RAM before loading."
        ),

        // MARK: Community chat ports

        CoreAIZooModel(
            id: "zoo-minicpm5-1b",
            displayName: "MiniCPM5 1B",
            subtitle: "OpenBMB · hybrid think / no-think · 128K",
            hfRepo: "mlboydaisuke/MiniCPM5-1B-CoreAI",
            revision: "main",
            pathPrefix: "int8",
            approxDownloadBytes: 1_092_313_209,
            contextWindow: 8_192,
            supportsThinking: true,
            supportsTools: false,
            category: .chat,
            licenseNotice: "Apache-2.0 (OpenBMB)."
        ),
        CoreAIZooModel(
            id: "zoo-qwen35-0.8b",
            displayName: "Qwen3.5 0.8B",
            subtitle: "Compact b2 pipeline · best size / quality trade",
            hfRepo: "mlboydaisuke/qwen3.5-0.8B-CoreAI",
            revision: "main",
            pathPrefix: "gpu-pipelined-b2/qwen3_5_0_8b_decode_int8hu_block32_sym",
            approxDownloadBytes: 1_337_858_025,
            contextWindow: 8_192,
            supportsThinking: true,
            supportsTools: true,
            category: .chat,
            licenseNotice: "Apache-2.0 (Qwen)."
        ),
        CoreAIZooModel(
            id: "zoo-qwen25-coder-1.5b",
            displayName: "Qwen2.5 Coder 1.5B",
            subtitle: "Coding-focused · int8 pack",
            hfRepo: "kevinqz/Qwen2.5-Coder-1.5B-Instruct-CoreAI",
            revision: "main",
            pathPrefix: "int8",
            approxDownloadBytes: 1_656_659_323,
            contextWindow: 8_192,
            supportsThinking: false,
            supportsTools: true,
            category: .chat,
            licenseNotice: "Apache-2.0 (Qwen)."
        ),
        CoreAIZooModel(
            id: "zoo-lfm25-1.2b",
            displayName: "LFM2.5 1.2B Instruct",
            subtitle: "LiquidAI · conv+attention hybrid · fast decode",
            hfRepo: "mlboydaisuke/LFM2.5-1.2B-CoreAI",
            revision: "main",
            pathPrefix: "gpu-pipelined-b2/lfm2_5_1_2b_instruct_decode_int8hu_block32_sym",
            approxDownloadBytes: 1_701_927_366,
            contextWindow: 8_192,
            supportsThinking: false,
            supportsTools: false,
            category: .chat,
            licenseNotice: "LFM Open License v1.0. Review terms on the Hub card."
        ),
        CoreAIZooModel(
            id: "zoo-granite-4.0-h-1b",
            displayName: "Granite 4.0-H 1B",
            subtitle: "IBM · Mamba2 + attention hybrid",
            hfRepo: "mlboydaisuke/granite-4.0-h-CoreAI",
            revision: "main",
            pathPrefix: "gpu-pipelined-b2/granite_4_0_h_1b_decode_int8hu_block32_sym",
            approxDownloadBytes: 1_872_605_842,
            contextWindow: 8_192,
            supportsThinking: false,
            supportsTools: true,
            category: .chat,
            licenseNotice: "Apache-2.0 (IBM Granite)."
        ),
        // Gemma 4 E2B's published `*_tbl_*` bundle is intentionally not
        // offered here. It requires a model-specific ~2.35 GB static-input
        // provider in addition to the generic CoreAILanguageModel runtime;
        // advertising it as a drop-in chat pack would make a successful
        // download fail when selected.
        CoreAIZooModel(
            id: "zoo-youtu-llm-2b",
            displayName: "Youtu LLM 2B",
            subtitle: "Tencent · dense MLA · reasoning + agentic",
            hfRepo: "mlboydaisuke/Youtu-LLM-2B-CoreAI",
            revision: "main",
            pathPrefix: "gpu-pipelined-b2/youtu_llm_2b_decode_absorbed_int8_msdpa_g32",
            approxDownloadBytes: 2_157_473_558,
            contextWindow: 8_192,
            supportsThinking: true,
            supportsTools: true,
            category: .chat,
            licenseNotice: "Other (youtu-llm). Read the Hub license before shipping."
        ),
        CoreAIZooModel(
            id: "zoo-fastcontext-4b",
            displayName: "FastContext 1.0 4B",
            subtitle: "Long-context port · gpu tree",
            hfRepo: "mlboydaisuke/FastContext-1.0-4B-CoreAI",
            revision: "main",
            pathPrefix: "gpu",
            approxDownloadBytes: 2_279_562_468,
            contextWindow: 8_192,
            supportsThinking: false,
            supportsTools: false,
            category: .chat,
            licenseNotice: "Check the Hub card for the source model's license."
        ),
        CoreAIZooModel(
            id: "zoo-qwen35-2b",
            displayName: "Qwen3.5 2B",
            subtitle: "Compact b2 pipeline · stronger chat",
            hfRepo: "mlboydaisuke/qwen3.5-2B-CoreAI",
            revision: "main",
            pathPrefix: "gpu-pipelined-b2/qwen3_5_2b_decode_int8hu_block32_sym",
            approxDownloadBytes: 3_046_585_891,
            contextWindow: 8_192,
            supportsThinking: true,
            supportsTools: true,
            category: .chat,
            licenseNotice: "Apache-2.0 (Qwen)."
        ),
        CoreAIZooModel(
            id: "zoo-bitcpm-8b",
            displayName: "BitCPM 8B · ternary",
            subtitle: "1.58-bit weights · 8B in ~3.2 GB",
            hfRepo: "mlboydaisuke/BitCPM-8B-CoreAI",
            revision: "main",
            pathPrefix: "gpu-pipelined/bitcpm_8b_decode_ternary_s1",
            approxDownloadBytes: 3_184_455_525,
            contextWindow: 8_192,
            supportsThinking: false,
            supportsTools: false,
            category: .chat,
            licenseNotice: "Apache-2.0 (OpenBMB). Custom Metal kernel — expect variance."
        ),
        CoreAIZooModel(
            id: "zoo-lfm25-2.6b",
            displayName: "LFM2.5 2.6B",
            subtitle: "LiquidAI reasoning · largest LFM iPhone tree",
            hfRepo: "mlboydaisuke/LFM2.5-2.6B-CoreAI",
            revision: "main",
            pathPrefix: "gpu-pipelined/lfm2_5_2_6b_decode_int8hu_block32_sym",
            approxDownloadBytes: 3_655_085_252,
            contextWindow: 8_192,
            supportsThinking: true,
            supportsTools: false,
            category: .chat,
            licenseNotice: "LFM Open License v1.0. Large — check free storage first."
        ),
        CoreAIZooModel(
            id: "zoo-nanbeige41-3b",
            displayName: "Nanbeige4.1 3B",
            subtitle: "Dense reasoning / agentic · CN + EN",
            hfRepo: "mlboydaisuke/Nanbeige4.1-3B-CoreAI",
            revision: "main",
            pathPrefix: "gpu-pipelined-b2/nanbeige4_1_3b_decode_int8hu_block32_sym",
            approxDownloadBytes: 4_600_132_783,
            contextWindow: 8_192,
            supportsThinking: true,
            supportsTools: true,
            category: .chat,
            licenseNotice: "Apache-2.0 (Nanbeige)."
        ),
        CoreAIZooModel(
            id: "zoo-nemotron-3-nano-4b",
            displayName: "Nemotron 3 Nano 4B",
            subtitle: "NVIDIA · iOS h18p tree (A18 Pro and newer)",
            hfRepo: "mlboydaisuke/Nemotron-3-Nano-4B-CoreAI",
            revision: "main",
            pathPrefix: "ios-h18p/nemotron_3_nano_4b_decode_int8hu",
            approxDownloadBytes: 4_628_965_401,
            contextWindow: 8_192,
            supportsThinking: true,
            supportsTools: true,
            category: .chat,
            licenseNotice: "NVIDIA Open Model License. Read the Hub card."
        ),
        CoreAIZooModel(
            id: "zoo-nanbeige42-3b",
            displayName: "Nanbeige4.2 3B",
            subtitle: "Looped Llama · community port (ukint-vs)",
            hfRepo: "ukint-vs/Nanbeige4.2-3B-CoreAI",
            revision: "main",
            pathPrefix: "gpu-pipelined/nanbeige4_2_3b_decode_int8hu_block32_sym_s1",
            approxDownloadBytes: 4_930_824_809,
            contextWindow: 8_192,
            supportsThinking: true,
            supportsTools: true,
            category: .chat,
            licenseNotice: "Apache-2.0 (Nanbeige)."
        ),
        // MARK: Vision-language

        CoreAIZooModel(
            id: "zoo-lfm25-vl-450m",
            displayName: "LFM2.5 VL 450M",
            subtitle: "Smallest VLM · iOS h18p tree",
            hfRepo: "mlboydaisuke/LFM2.5-VL-450M-CoreAI",
            revision: "main",
            pathPrefix: "ios-h18p",
            approxDownloadBytes: 1_190_071_987,
            contextWindow: 8_192,
            supportsThinking: false,
            supportsTools: false,
            category: .vision,
            licenseNotice: "LFM Open License v1.0. Square-grid vision preprocessing."
        ),
        CoreAIZooModel(
            id: "zoo-lfm25-vl-3b",
            displayName: "LFM2.5 VL 3B",
            subtitle: "int4 decoder + fp16 vision tower · iOS h18p",
            hfRepo: "mlboydaisuke/LFM2.5-VL-3B-CoreAI",
            revision: "main",
            pathPrefix: "ios-h18p",
            approxDownloadBytes: 3_055_824_901,
            contextWindow: 8_192,
            supportsThinking: false,
            supportsTools: false,
            category: .vision,
            licenseNotice: "LFM Open License v1.0."
        ),
        CoreAIZooModel(
            id: "zoo-qwen3-vl-2b",
            displayName: "Qwen3-VL 2B",
            subtitle: "Vision + decoder pair · gpu-pipelined",
            hfRepo: "mlboydaisuke/Qwen3-VL-2B-CoreAI",
            revision: "main",
            pathPrefix: "gpu-pipelined",
            approxDownloadBytes: 5_414_782_294,
            contextWindow: 8_192,
            supportsThinking: false,
            supportsTools: false,
            category: .vision,
            licenseNotice: "Apache-2.0 (Qwen). Ships both int8hu and int8lin decoders."
        ),

        // MARK: Utility (not chat models)

        CoreAIZooModel(
            id: "zoo-embeddinggemma-300m",
            displayName: "EmbeddingGemma 300M",
            subtitle: "Text embeddings · not a chat model",
            hfRepo: "mlboydaisuke/embeddinggemma-300m-CoreAI",
            revision: "main",
            pathPrefix: "model",
            approxDownloadBytes: 1_277_545_469,
            contextWindow: 2_048,
            supportsThinking: false,
            supportsTools: false,
            category: .utility,
            licenseNotice: "Gemma license. Embedding output only."
        ),
        CoreAIZooModel(
            id: "zoo-qwen3-asr-1.7b",
            displayName: "Qwen3-ASR 1.7B",
            subtitle: "Speech recognition · not a chat model",
            hfRepo: "mlboydaisuke/Qwen3-ASR-1.7B-CoreAI",
            revision: "main",
            pathPrefix: "gpu-pipelined",
            approxDownloadBytes: 3_102_222_264,
            contextWindow: 8_192,
            supportsThinking: false,
            supportsTools: false,
            category: .utility,
            licenseNotice: "Apache-2.0 (Qwen). Transcription output only."
        ),
        CoreAIZooModel(
            id: "zoo-whisper-large-v3-turbo",
            displayName: "Whisper large-v3-turbo",
            subtitle: "Official recipe · iOS tree · transcription",
            hfRepo: "mlboydaisuke/whisper-large-v3-turbo-CoreAI-official",
            revision: "main",
            pathPrefix: "ios",
            approxDownloadBytes: 3_234_997_726,
            contextWindow: 448,
            supportsThinking: false,
            supportsTools: false,
            category: .utility,
            licenseNotice: "MIT (OpenAI Whisper). Transcription output only."
        ),
    ]

    /// Packs for one category, in catalog (smallest-first) order.
    static func models(in category: CoreAIZooModel.Category) -> [CoreAIZooModel] {
        iphoneLanguageModels.filter { $0.category == category }
    }

    /// Catalog entry for a download-manager id, when the download came from the
    /// catalog rather than a free-text Hub search.
    static func model(id: String) -> CoreAIZooModel? {
        iphoneLanguageModels.first { $0.id == id }
    }

    /// Resolves either a raw catalog id (stored in CoreAIModelStore's manifest)
    /// or the prefixed Assistant selection id.
    static func model(forSelectionID id: String) -> CoreAIZooModel? {
        let raw = id.hasPrefix("coreai:") ? String(id.dropFirst("coreai:".count)) : id
        return model(id: raw)
    }

    static var assistantModels: [AssistantModel] {
        iphoneLanguageModels
            .filter { $0.category == .officialRecipe || $0.category == .chat }
            .map(\.assistantModel)
    }

    static func assistantModel(forSelectionID id: String) -> AssistantModel? {
        guard let model = model(forSelectionID: id),
              model.category == .officialRecipe || model.category == .chat else {
            return nil
        }
        return model.assistantModel
    }

    /// True when a pack is expected to serve `/v1/chat/completions`.
    /// Embedding, rerank, transcription, and vision packs are installable,
    /// but they are not chat models.
    static func isTextGenerationPack(id: String) -> Bool {
        let rawID = id.hasPrefix("coreai:") ? String(id.dropFirst("coreai:".count)) : id
        if unsupportedTextGenerationPackIDs.contains(rawID) { return false }
        guard let model = model(forSelectionID: id) else {
            // Free-text Hub downloads are unclassified; assume chat, which is
            // what a hand-entered repo almost always is.
            return true
        }
        return model.category == .officialRecipe || model.category == .chat
    }

    /// Categories that actually have entries, in display order.
    static var populatedCategories: [CoreAIZooModel.Category] {
        CoreAIZooModel.Category.allCases.filter { !models(in: $0).isEmpty }
    }

    static let zooIndexURL = URL(
        string: "https://raw.githubusercontent.com/john-rocky/coreai-model-zoo/main/models/index.json"
    )!

    static let zooHomeURL = URL(string: "https://github.com/john-rocky/coreai-model-zoo")!

    static let appleRecipesURL = URL(string: "https://github.com/apple/coreai-models")!
}
