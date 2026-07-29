import Foundation

// MARK: - OnDeviceCompatibility
// Classifies a Hugging Face model summary as runnable or not on this iPhone,
// and explains why. Used by the Download Manager and HF Search to badge
// results so users don't waste time downloading a 70B PyTorch model that
// can't load.
//
// Three-axis verdict:
//   1. Format            (mlx / coreml / gguf / unknown)
//   2. Pipeline kind     (text generation / VLM / TTS / ASR / unknown)
//   3. Recognized family (Qwen 2.5, Llama 3, SmolVLM, KittenTTS, etc.)
//
// We map (format × pipeline × family) → runnable/marginal/blocked verdicts.

enum OnDeviceCompatibility {

    // MARK: - Format

    enum Format: String {
        case mlx       // first-class on Apple silicon
        case coreml    // also good
        case gguf      // supported for VLMs via llama.cpp + mtmd
        case ggml      // legacy gguf
        case onnx      // not supported
        case pytorch   // raw weights — too big and slow
        case unknown
    }

    static func format(from tags: [String]) -> Format {
        let lower = tags.map { $0.lowercased() }
        if lower.contains("mlx") { return .mlx }
        if lower.contains("coreml") || lower.contains("core-ml") { return .coreml }
        if lower.contains("gguf") { return .gguf }
        if lower.contains("ggml") { return .ggml }
        if lower.contains("onnx") { return .onnx }
        if lower.contains("pytorch") || lower.contains("safetensors") { return .pytorch }
        return .unknown
    }

    // MARK: - Pipeline kind

    enum Kind: String {
        case text                  // chat/code LLM
        case vlm                   // image-text-to-text
        case tts                   // text-to-speech
        case asr                   // automatic-speech-recognition
        case imageGen              // text-to-image diffusion (SD / SDXL / FLUX …)
        case unknown
    }

    static func kind(pipelineTag: String?, tags: [String]) -> Kind {
        let lower = (pipelineTag ?? "").lowercased()
        switch lower {
        case "text-generation",
             "text2text-generation",
             "conversational":
            return .text
        case "image-text-to-text",
             "image-to-text",
             "visual-question-answering":
            return .vlm
        case "text-to-speech":
            return .tts
        case "automatic-speech-recognition":
            return .asr
        case "text-to-image",
             "image-to-image",
             "unconditional-image-generation":
            return .imageGen
        default:
            // Fallback: scan tags for hints
            let t = tags.map { $0.lowercased() }
            if t.contains("text-to-speech") { return .tts }
            if t.contains("automatic-speech-recognition") { return .asr }
            if t.contains("vlm") || t.contains("image-text-to-text") { return .vlm }
            if t.contains("text-generation") { return .text }
            if t.contains("text-to-image") || t.contains("diffusers")
                || t.contains("stable-diffusion") || t.contains("flux") {
                return .imageGen
            }
            return .unknown
        }
    }

    /// Repo-name heuristic for diffusion / image-generation models, used when
    /// the HF pipeline tag is missing. Deliberately specific so we don't
    /// misclassify VLMs that merely mention "image".
    static func looksLikeImageGenRepo(_ repoID: String) -> Bool {
        contains(repoID, anyOf: [
            "flux", "stable-diffusion", "sdxl", "sd-turbo", "sd-1.5",
            "sd-2", "sd-3", "diffusion", "pixart", "kandinsky",
            "kolors", "playground-v2", "lcm-",
        ])
    }

    // MARK: - Architecture family

    /// MLX VLM families that mlx-swift-examples' VLMModelFactory knows how to load.
    /// Keep in sync with that library's MLXVLM/Models/ folder.
    private static let supportedVLMFamilies: [String] = [
        "qwen2-vl", "qwen2.5-vl", "qwen2_5-vl", "qwen3-vl",
        "smolvlm", "smolvlm2",
        "paligemma",
        "gemma-3", "gemma3",
        "idefics3",
    ]

    /// MLX LLM families known to load via LLMModelFactory.
    private static let supportedLLMFamilies: [String] = [
        "qwen2", "qwen2.5", "qwen3",
        "llama-3", "llama-3.1", "llama-3.2", "llama-3.3",
        "phi-3", "phi-3.5",
        "gemma-2", "gemma-3",
        "mistral", "mixtral",
        "smollm", "smollm2",
        "deepseek",
    ]

    /// Voice (TTS) families we know about.
    private static let supportedTTSFamilies: [String] = ["kittentts", "kokoro", "parakeet-tts"]

    /// ASR families known to work on-device via MLX or Core ML.
    private static let supportedASRFamilies: [String] = ["whisper-mlx", "parakeet"]

    /// Lowercased haystack match — case- and separator-insensitive.
    private static func contains(_ haystack: String, anyOf needles: [String]) -> Bool {
        let h = haystack.lowercased()
            .replacingOccurrences(of: "_", with: "-")
        for needle in needles {
            let n = needle.lowercased()
                .replacingOccurrences(of: "_", with: "-")
            if h.contains(n) { return true }
        }
        return false
    }

    /// Best-effort recognized family for `repoID`.
    static func recognizedFamily(repoID: String, kind: Kind) -> String? {
        let candidates: [String]
        switch kind {
        case .vlm: candidates = supportedVLMFamilies
        case .text: candidates = supportedLLMFamilies
        case .tts: candidates = supportedTTSFamilies
        case .asr: candidates = supportedASRFamilies
        case .imageGen: return nil
        case .unknown: return nil
        }
        for fam in candidates {
            if contains(repoID, anyOf: [fam]) { return fam }
        }
        return nil
    }

    // MARK: - Size

    /// Parameter count parsed from repo id ("Qwen2.5-7B-Instruct" → 7_000_000_000).
    /// Returns nil when we can't find a "<n>B" or "<n>M" suffix.
    static func paramCount(repoID: String) -> Int64? {
        let s = repoID.lowercased()
        // Match patterns like "1.5b", "3b", "7b", "500m" right after a dash/underscore/digit boundary.
        let pattern = #"(\d+(?:\.\d+)?)([bm])(?![a-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        let matches = regex.matches(in: s, range: range)
        // Prefer the LARGEST match — repo names sometimes include both a base
        // size and an aux number (e.g. quant level). The biggest one usually
        // wins for parameter count.
        var best: Int64? = nil
        for m in matches {
            guard m.numberOfRanges >= 3,
                  let valR = Range(m.range(at: 1), in: s),
                  let unitR = Range(m.range(at: 2), in: s),
                  let n = Double(s[valR]) else { continue }
            let unit = String(s[unitR])
            let count = Int64(n * (unit == "b" ? 1_000_000_000 : 1_000_000))
            if best == nil || count > best! { best = count }
        }
        return best
    }

    /// Estimated working-set in bytes for a model of `params` weights. 4-bit
    /// quantization gives ~0.5 bytes/param + ~50% KV cache overhead.
    ///
    /// Checks both HF tags AND the repo name because many MLX community repos
    /// encode quantization in the name (e.g. "Qwen2.5-VL-3B-Instruct-4bit")
    /// without adding a corresponding HF tag — causing fp16 rates to be used
    /// and the model to be falsely blocked.
    static func estimatedFootprint(params: Int64, tags: [String], repoID: String = "") -> Int64 {
        let r = repoID.lowercased()
        let isQuantized = tags.contains { t in
            let l = t.lowercased()
            return l.contains("4bit") || l.contains("4-bit")
                || l.contains("8bit") || l.contains("8-bit")
                || l.contains("q4") || l.contains("q8")
        }
        || r.contains("4bit") || r.contains("4-bit")
        || r.contains("8bit") || r.contains("8-bit")
        || r.contains("-q4") || r.contains("_q4")
        || r.contains("-q8") || r.contains("_q8")

        let bytesPerParam: Double = isQuantized ? 0.55 : 2.0   // fp16 = 2 bytes
        let weights = Double(params) * bytesPerParam
        let working = weights * 1.5                            // KV cache + glue
        return Int64(working)
    }

    // MARK: - Verdict

    enum Verdict {
        /// Runs fine — green pill in UI.
        case runnable(notes: String)
        /// Loads but tight — orange pill.
        case marginal(notes: String)
        /// Can't run on this device — red pill, disable download.
        case blocked(reason: String)
    }

    /// Combined verdict for `summary`. Conservative: a model is only marked
    /// runnable when we recognize its format AND family AND it fits in RAM.
    static func verdict(for summary: HFModelSummary) -> Verdict {
        let f = format(from: summary.tags)
        let inferredCategory = LocalModelRegistry.category(for: summary)
        var k = kind(pipelineTag: summary.pipelineTag, tags: summary.tags)
        if k == .unknown {
            switch inferredCategory {
            case .assistant: k = .text
            case .vlm:       k = .vlm
            case .voice:     k = .tts
            case .imageGen:  k = .imageGen
            }
        }

        // 0. Image-generation gate. Diffusion repos route to the dedicated
        //    Images section (MLX StableDiffusion), NOT the LLM/VLM download
        //    flow — otherwise they'd fall through to the "raw PyTorch" block
        //    below with a misleading message. FLUX is called out explicitly:
        //    it can't run on iOS (12B params, not in the MLX SD library).
        if k == .imageGen || looksLikeImageGenRepo(summary.id) {
            if let supported = ImageGenerationService.model(forID: summary.id) {
                return .runnable(notes: "Image model — open Models → Images to download \(supported.displayName).")
            }
            if summary.id.lowercased().contains("flux") {
                return .blocked(reason: "FLUX is too large to run on iOS (12B params). On-device image generation supports SDXL-Turbo and Stable Diffusion 2.1 — see Models → Images.")
            }
            return .blocked(reason: "Image-generation model. On-device image-gen is available in Models → Images (SDXL-Turbo, Stable Diffusion 2.1); arbitrary diffusion repos can't be loaded here.")
        }

        // 1. Format gate
        switch f {
        case .gguf, .ggml:
            if k != .vlm {
                return .blocked(reason: "GGUF / GGML is only supported for vision models in this app right now.")
            }
        case .onnx:
            return .blocked(reason: "ONNX format — no on-device runtime in this app.")
        case .pytorch:
            return .blocked(reason: "Raw PyTorch / safetensors weights — needs a Mac/Linux GPU runtime.")
        case .unknown:
            // Could still work if a recognized family. Mark marginal.
            break
        case .mlx, .coreml:
            break  // continue checks
        }

        // 2. Family gate
        let family = recognizedFamily(repoID: summary.id, kind: k)
        if family == nil, k != .unknown {
            // Recognized pipeline but unknown family. Allow with a warning.
            return .marginal(notes: "Pipeline matches \(k.rawValue) but architecture not in our supported list — may not load.")
        }

        // 3. RAM gate (only for LLM/VLM where we have a footprint estimate)
        if k == .text || k == .vlm {
            if let params = paramCount(repoID: summary.id) {
                let footprint = estimatedFootprint(params: params, tags: summary.tags, repoID: summary.id)
                // Clamp the badge budget to the per-process ceiling: 70% of
                // physical RAM marks models "runnable" that the ~6 GB
                // per-process cap can never actually load.
                let budget = min(MemoryAdvisor.availableRAM, MemoryAdvisor.processMemoryCeiling)
                if footprint > budget {
                    return .blocked(reason: "Needs ~\(footprint.formattedBytes) — this device only has ~\(budget.formattedBytes) available.")
                }
                if Double(footprint) / Double(budget) > 0.75 {
                    return .marginal(notes: "Tight fit (~\(footprint.formattedBytes) vs ~\(budget.formattedBytes) available). Expect throttling on long replies.")
                }
            }
        }

        // Passed all gates.
        let fmt = f == .mlx ? "MLX" : (f == .coreml ? "Core ML" : f.rawValue)
        let fam = family.map { " · \($0)" } ?? ""
        return .runnable(notes: "\(fmt)\(fam)")
    }

    // MARK: - Convenience for UI

    /// "MLX · qwen2.5" / "Core ML · kokoro" / "unknown · pytorch".
    static func shortLabel(for summary: HFModelSummary) -> String {
        let f = format(from: summary.tags)
        var k = kind(pipelineTag: summary.pipelineTag, tags: summary.tags)
        if k == .unknown {
            switch LocalModelRegistry.category(for: summary) {
            case .assistant: k = .text
            case .vlm:       k = .vlm
            case .voice:     k = .tts
            case .imageGen:  k = .imageGen
            }
        }
        let fam = recognizedFamily(repoID: summary.id, kind: k)
        let fmt: String = {
            switch f {
            case .mlx: return "MLX"
            case .coreml: return "Core ML"
            case .gguf, .ggml: return "GGUF"
            case .onnx: return "ONNX"
            case .pytorch: return "raw"
            case .unknown: return "?"
            }
        }()
        return [fmt, fam].compactMap { $0 }.joined(separator: " · ")
    }
}
