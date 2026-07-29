import Foundation
import CoreGraphics
import UIKit

// MARK: - VLMCapabilities
//
// Model-aware preprocessing parameters resolved at VLM load time. The
// Lens pipeline (LensFramePreparer / LensInferenceLoop) reads this to
// decide how to scale, align, and color-correct a camera frame before
// handing it to the model.
//
// Two sources of truth, in priority order:
//   1. The model's HuggingFace JSON: `preprocessor_config.json`,
//      `processor_config.json`, and `config.json` in the local cache
//      after VLMModelFactory finishes downloading.
//   2. Per-architecture defaults (the table at the bottom of this file),
//      used when JSON fields are absent or unparseable.
//
// Whatever the source, the result is then clamped by the current device
// class so a 12 GB iPhone Pro can stream at 512² while a 6 GB iPhone 14
// drops to 384² — same model, same correctness, different latency cap.
//
// IMPORTANT for future me: when a field appears in the JSON, the JSON
// wins. Don't second-guess the model's own processor config. The
// defaults table is a safety net, not a preference.

struct VLMCapabilities: Equatable {

    // MARK: - Input sizing strategy
    //
    // Each strategy maps to a family of processors in mlx-vlm /
    // transformers and dictates how LensFramePreparer must reshape the
    // input before the processor itself runs. Getting this wrong shows
    // up as one of: stretched aspect ratio, illegible text, hallucinated
    // content, or — for Qwen2-VL specifically — a fallback path inside
    // the model that mangles spatial reasoning silently.

    enum InputSizingStrategy: Equatable {
        /// Single fixed input size. The processor's resize-to-square is
        /// the only sizing step that matters; the preparer just bestFit-
        /// scales the source to roughly `2 × side` so the processor's
        /// bicubic step has clean intermediates.
        ///
        /// Used by: LLaVA 1.5, Moondream2, PaliGemma (224 / 448 / 896).
        case fixed(CGSize)

        /// Dynamic resolution aligned to the model's patch × merge grid.
        /// Pixel budget bounded by `[minPixels, maxPixels]`; the
        /// preparer scales total pixels under that cap, then rounds each
        /// dimension to a multiple of `patch * merge`. Non-aligned
        /// inputs hit a fallback path in Qwen2-VL that mangles spatial
        /// reasoning without raising an error.
        ///
        /// Used by: Qwen2-VL, Qwen2.5-VL.
        case dynamicPatchAligned(patch: Int, merge: Int, minPixels: Int, maxPixels: Int)

        /// Any-resolution tiling. The processor picks a grid from a
        /// fixed list of allowed shapes based on input aspect; the
        /// preparer should bestFit-scale to `2 × baseSize` and let the
        /// processor select the grid. Tile size is `baseSize × baseSize`.
        ///
        /// Used by: LLaVA 1.6 / LLaVA-Next.
        case anyresTiling(baseSize: Int, gridOptions: [CGSize])

        /// Fixed-size tiles, capped number of tiles. The preparer scales
        /// so `ceil(w/tileSize) * ceil(h/tileSize) ≤ maxTiles`; the
        /// processor splits and encodes each tile, with one global
        /// thumbnail tile prepended.
        ///
        /// Used by: Llama 3.2 Vision (mllama), Idefics3, SmolVLM,
        /// SmolVLM2.
        case fixedTiling(tileSize: Int, maxTiles: Int)
    }

    // MARK: - Stored properties

    /// Architecture key used for default lookup. Normalised (snake_case)
    /// — see `NormalizedArchitecture` below.
    let architecture: String

    /// Human-readable model name for the debug overlay. Resolved from
    /// the repo ID's tail when no friendlier name is available.
    let modelDisplayName: String

    let inputSizingStrategy: InputSizingStrategy

    /// Per-channel image normalisation, applied AFTER the processor's
    /// rescale step. Three floats: [R, G, B].
    let imageMean: [Float]
    let imageStd:  [Float]

    /// Multiplier applied to raw 0…255 pixel values before normalisation.
    /// Almost always 1/255; surfaced because a handful of community
    /// configs override it.
    let rescaleFactor: Float

    /// Total-pixel budget for live-streaming inputs (camera frames).
    /// Much smaller than the model's documented `maxPixels` — the live
    /// loop trades fidelity for latency. The preparer scales inputs
    /// under this cap before patch/tile alignment.
    let recommendedStreamingPixels: Int

    /// Total-pixel budget for one-shot stills (captureHighResFrame()).
    /// Can be significantly larger; users tolerate a few seconds of
    /// latency for a single high-fidelity describe.
    let recommendedStillPixels: Int

    // MARK: - Debug-overlay description
    //
    // Format chosen so the overlay can show the resolved capabilities
    // at-a-glance, which is exactly when you want to know whether the
    // JSON loaded what you expected or fell back to a default. Reads:
    //
    //   "Qwen2.5-VL · dynamicPatchAligned(patch:14, merge:2, stream≤512²) · CLIP-norm · sRGB · tier:.pro"
    //
    // The trailing "sRGB" is the working color space the preparer
    // applies — included so the overlay doubles as confirmation that
    // the color-space step ran.
    //
    // The "tier:.X" suffix reveals which constraint won the streaming-
    // pixel clamp. If the strategy summary's `stream≤N²` matches the
    // tier's natural cap, the device clamp is the binding constraint;
    // if it's smaller, the model's own JSON / defaults are binding.
    // That distinction is the first thing you check when a model
    // streams at an unexpected resolution.

    var description: String {
        "\(modelDisplayName) · \(strategySummary) · \(normSummary) · sRGB · tier:.\(DeviceTierAdvisor.current.rawValue)"
    }

    private var strategySummary: String {
        switch inputSizingStrategy {
        case .fixed(let size):
            return "fixed(\(Int(size.width))×\(Int(size.height)))"
        case .dynamicPatchAligned(let patch, let merge, _, _):
            let side = Int(Double(recommendedStreamingPixels).squareRoot().rounded())
            return "dynamicPatchAligned(patch:\(patch), merge:\(merge), stream≤\(side)²)"
        case .anyresTiling(let base, let grids):
            return "anyresTiling(base:\(base), grids:\(grids.count))"
        case .fixedTiling(let tile, let maxTiles):
            return "fixedTiling(tile:\(tile), max:\(maxTiles))"
        }
    }

    private var normSummary: String {
        // Match the common families by approximate mean. Exact equality
        // on Float is unreliable here — JSON-supplied values can differ
        // by ulps from the canonical constants.
        let m = imageMean
        guard m.count == 3 else { return "custom-norm" }
        let isClip     = approx(m[0], 0.481) && approx(m[1], 0.458) && approx(m[2], 0.408)
        let isImageNet = approx(m[0], 0.485) && approx(m[1], 0.456) && approx(m[2], 0.406)
        let isHalf     = approx(m[0], 0.5)   && approx(m[1], 0.5)   && approx(m[2], 0.5)
        if isClip     { return "CLIP-norm" }
        if isImageNet { return "ImageNet" }
        if isHalf     { return "0.5-norm" }
        return "custom-norm"
    }

    private func approx(_ a: Float, _ b: Float, tol: Float = 0.01) -> Bool {
        abs(a - b) < tol
    }

    // MARK: - Known-broken architectures
    //
    // Some VLM families in `mlx-swift-examples` have upstream bugs that
    // make them unusable through the lens pipeline. When we detect
    // one, the lens inference path refuses to dispatch — surfacing a
    // clear error or auto-routing to a working alternative (e.g. the
    // bundled SmolVLM2 GGUF via `recoverFromSmolVLMSelection`)
    // instead of letting the broken code path crash the process.
    // Swift precondition failures in `ContiguousArrayBuffer.swift`
    // are NOT catchable from outside, so the only safe option is to
    // never call into the broken function in the first place.
    //
    // Currently broken:
    //   • idefics3 / smolvlm / smolvlm2 — share `prepareInputsForMulti-
    //     modal`. Uses `Qwen2VLMessageGenerator` as a placeholder
    //     (literal `TODO: Create SmolVLM2MessageGenerator` in the
    //     upstream source, still present at HEAD as of 2026-05).
    //     The image-token count in the prompt doesn't agree with the
    //     encoder's tile count, producing an Index out of range in
    //     the language model. The lens dispatcher reacts by
    //     auto-swapping the active VLM to the bundled SmolVLM2-500M
    //     GGUF (handled by `recoverFromSmolVLMSelection` in
    //     LensInferenceLoop.swift), which routes through llama.cpp +
    //     mtmd and avoids the bug entirely. An in-tree
    //     SmolVLM2RescueProcessor exists as a best-effort MLX rewrite
    //     but is not yet device-verified; the auto-route to the GGUF
    //     is the production path.
    //
    // Working:
    //   • qwen2_vl / qwen2_5_vl / qwen3_vl — own dedicated message
    //     generators and forward paths.
    //   • llava / llava_next / mllama / moondream / paligemma —
    //     separate model classes, no shared bug surface.
    //
    // To add a new known-broken family: extend the static set below
    // AND update LENS_PIPELINE.md's troubleshooting table so future
    // readers know why their model was refused.
    var isLensPipelineCompatible: Bool {
        // Match by the architecture key written into VLMCapabilities
        // at load time (the NormalizedArchitecture rawValue). Anything
        // not on the broken list is allowed by default — opt-out, not
        // opt-in, so newly-supported architectures work without
        // touching this code.
        let broken: Set<String> = ["idefics3", "smolvlm", "smolvlm2"]
        return !broken.contains(architecture)
    }

    /// User-facing description of WHY a known-broken model can't run.
    /// Empty string for compatible architectures. Used as the final
    /// fallback message — in practice the lens dispatcher tries to
    /// auto-swap to the bundled SmolVLM2 GGUF first, and only shows
    /// this reason if no recovery path is available.
    var incompatibilityReason: String {
        guard !isLensPipelineCompatible else { return "" }
        return "The \(modelDisplayName) family (\(architecture)) has a known issue in the underlying mlx-swift-examples library — its prompt template doesn't agree with the encoder's tile count, which crashes on inference. SmolVLM2-500M (Q8 GGUF) ships bundled with the app and works through llama.cpp instead; Qwen3-VL-2B/4B/8B work too on Pro/Max devices."
    }

    /// True when this architecture is the SmolVLM family (smolvlm /
    /// smolvlm2 / idefics3). Used by the lens dispatcher to decide
    /// whether the bundled SmolVLM2 GGUF is a safe drop-in fallback —
    /// it is, since the GGUF + llama.cpp path bypasses the broken
    /// mlx-swift-examples message generator entirely.
    var isSmolVLMFamily: Bool {
        let fam: Set<String> = ["smolvlm", "smolvlm2", "idefics3"]
        return fam.contains(architecture)
    }
}

// MARK: - Normalised architecture keys
//
// HuggingFace `config.json` uses two related fields — `model_type`
// (snake_case family) and `architectures[0]` (CamelCase class name).
// Map both into a single enum so the rest of this file doesn't have
// to special-case the same family twice.

private enum NormalizedArchitecture: String {
    case qwen2VL      = "qwen2_vl"
    case qwen25VL     = "qwen2_5_vl"
    case qwen3VL      = "qwen3_vl"
    case qwen35       = "qwen3_5"
    case gemma4       = "gemma4"             // Google Gemma 4 unified multimodal (12B/E2B/E4B)
    case gemma3       = "gemma3"             // Google Gemma 3 multimodal (4B+)
    case llava        = "llava"
    case llavaNext    = "llava_next"
    case mllama       = "mllama"             // Llama 3.2 Vision
    case idefics3     = "idefics3"
    case smolvlm      = "smolvlm"
    case smolvlm2     = "smolvlm2"
    case moondream    = "moondream"
    case paligemma    = "paligemma"
    case unknown      = "unknown"

    /// Detect from any combination of `model_type`, `architectures[0]`,
    /// or — last resort — the repo id. Order matters: more specific
    /// (qwen2_5_vl) before less specific (qwen2_vl).
    static func detect(modelType: String, architecture: String, repoID: String) -> NormalizedArchitecture {
        let hay = (modelType + " " + architecture + " " + repoID).lowercased()
        // Qwen3-VL checked first — its repo IDs contain "qwen3-vl" which
        // would NOT match the older qwen2/qwen2.5 patterns, but ordering
        // explicit-newest-first keeps the family fan-out obvious.
        if hay.contains("qwen3_5")    || hay.contains("qwen3.5")     { return .qwen35   }
        if hay.contains("qwen3_vl")   || hay.contains("qwen3-vl")    { return .qwen3VL  }
        if hay.contains("qwen2_5_vl") || hay.contains("qwen2.5-vl") { return .qwen25VL }
        if hay.contains("qwen2_vl")   || hay.contains("qwen2-vl")    { return .qwen2VL  }
        // Gemma 4 unified multimodal — checked before Gemma 3 so the
        // newer family wins. model_type is "gemma4"; repo IDs use a
        // dash ("gemma-4-12B-it-…"). The 12B/E2B/E4B carry a vision
        // tower; audio is parsed by the config but not yet handled by
        // the Swift processor, so this stays image+text only.
        if hay.contains("gemma4")     || hay.contains("gemma-4") ||
           hay.contains("gemma_4")                                   { return .gemma4   }
        // Gemma 3 multimodal — the 4B / 12B / 27B IT variants have a
        // vision tower (SigLIP). The 1B is text-only. The "gemma3"
        // model_type captures the multimodal class; we ALSO match
        // "gemma-3" / "gemma_3" because mlx-community repo IDs use
        // a dash, not underscore.
        if hay.contains("gemma3")     || hay.contains("gemma-3") ||
           hay.contains("gemma_3")                                   { return .gemma3   }
        if hay.contains("llava_next") || hay.contains("llava-1.6")   { return .llavaNext }
        if hay.contains("llava")                                     { return .llava }
        if hay.contains("mllama")     || hay.contains("llama-3.2-vision") { return .mllama }
        if hay.contains("smolvlm2")                                  { return .smolvlm2 }
        if hay.contains("smolvlm")                                   { return .smolvlm }
        if hay.contains("idefics3")                                  { return .idefics3 }
        if hay.contains("moondream")                                 { return .moondream }
        if hay.contains("paligemma")                                 { return .paligemma }
        // NOTE: fastvlm intentionally NOT handled here. FastVLM has
        // its own dedicated service and must never route through this
        // pipeline. If a "fastvlm" model_type reaches us, returning
        // .unknown surfaces it in the debug overlay as a routing bug
        // rather than silently absorbing it with defensive defaults.
        return .unknown
    }
}

// MARK: - Loader

extension VLMCapabilities {

    /// Resolve capabilities for a model whose weights live in
    /// `modelDirectory`. Reads the JSONs that ship with HuggingFace
    /// model repos and overlays any fields it finds onto the per-
    /// architecture defaults table. The result is then clamped by the
    /// current device class.
    ///
    /// Failure mode is "always return something usable" — if every JSON
    /// is missing or malformed, falls back to `.unknown` defaults
    /// (fixed 384×384, ImageNet norm) which is safe-but-slow for any
    /// VLM. The model will still load and run; spatial reasoning may
    /// suffer until proper defaults are added to the table.
    static func load(modelDirectory: URL, repoID: String) -> VLMCapabilities {
        let preprocessor = loadJSON(modelDirectory.appendingPathComponent("preprocessor_config.json"))
        let processor    = loadJSON(modelDirectory.appendingPathComponent("processor_config.json"))
        let config       = loadJSON(modelDirectory.appendingPathComponent("config.json"))

        let modelType    = (config["model_type"] as? String) ?? ""
        let architectures = (config["architectures"] as? [String]) ?? []
        let primaryArch  = architectures.first ?? ""
        let arch = NormalizedArchitecture.detect(
            modelType: modelType,
            architecture: primaryArch,
            repoID: repoID
        )

        let displayName = friendlyDisplayName(repoID: repoID, modelType: modelType)
        var caps = defaults(for: arch, modelDisplayName: displayName)

        // JSON overrides — only override when the field is present AND
        // parses cleanly. Missing fields keep the defaults; malformed
        // fields are ignored rather than silently corrupting the config.

        if let mean: [Float] = floatArray(preprocessor["image_mean"]) ?? floatArray(processor["image_mean"]),
           mean.count == 3 {
            caps = caps.replacing(imageMean: mean)
        }
        if let std: [Float] = floatArray(preprocessor["image_std"]) ?? floatArray(processor["image_std"]),
           std.count == 3 {
            caps = caps.replacing(imageStd: std)
        }
        if let rescale: Float = floatValue(preprocessor["rescale_factor"]) ?? floatValue(processor["rescale_factor"]) {
            caps = caps.replacing(rescaleFactor: rescale)
        }

        // Strategy-specific overrides. We DON'T let JSON change the
        // strategy enum case — that would require re-validating
        // adjacent fields. We only update the numeric parameters
        // *within* a case.
        switch caps.inputSizingStrategy {
        case .dynamicPatchAligned(let patch, let merge, let minP, let maxP):
            let p = intValue(preprocessor["patch_size"]) ?? patch
            let m = intValue(preprocessor["merge_size"]) ?? merge
            let lo = intValue(preprocessor["min_pixels"]) ?? minP
            let hi = intValue(preprocessor["max_pixels"]) ?? maxP
            caps = caps.replacing(strategy: .dynamicPatchAligned(
                patch: p, merge: m, minPixels: lo, maxPixels: hi
            ))
        case .fixed(let size):
            // `size` can be `{height, width}` or `{shortest_edge}` or a
            // bare int. Honor whatever the JSON gives.
            if let dict = preprocessor["size"] as? [String: Any] {
                let h = intValue(dict["height"]) ?? Int(size.height)
                let w = intValue(dict["width"])  ?? Int(size.width)
                caps = caps.replacing(strategy: .fixed(CGSize(width: w, height: h)))
            } else if let edge = intValue(preprocessor["size"]) {
                caps = caps.replacing(strategy: .fixed(CGSize(width: edge, height: edge)))
            }
        case .anyresTiling(let base, _):
            if let grids = preprocessor["image_grid_pinpoints"] as? [[Int]], !grids.isEmpty {
                let sizes = grids.compactMap { pair -> CGSize? in
                    guard pair.count == 2 else { return nil }
                    return CGSize(width: pair[0], height: pair[1])
                }
                caps = caps.replacing(strategy: .anyresTiling(baseSize: base, gridOptions: sizes))
            }
        case .fixedTiling(let tile, let maxTiles):
            // DELIBERATELY do NOT override `tile` from JSON. Earlier
            // versions pulled `max_image_size.longest_edge` and used
            // it as the tile size — that's wrong:
            //
            //   • `max_image_size.longest_edge` (512 for SmolVLM2) is
            //     the threshold ABOVE WHICH the processor splits an
            //     input into multiple tiles. It is NOT the vision
            //     encoder's input size.
            //   • The vision encoder's native input is a fixed
            //     property of the architecture — SigLIP at 384² for
            //     SmolVLM2-500M, baked into the model weights. That
            //     size doesn't appear in the JSON at all.
            //
            // The per-architecture default table holds the encoder
            // size (384 for SmolVLM2, 560 for mllama, etc.). That's
            // the right value for `resizeHintSide` and the upscale-
            // if-tiny floor. JSON-overriding `tile` from
            // max_image_size produced a 512 floor, which forced
            // tiny inputs above the split threshold and crashed
            // (broadcast_shapes: 576 encoder tokens vs 1024 prompt-
            // template slots).
            //
            // `maxTiles` IS a JSON concept (`max_n_images` /
            // `max_image_tiles`) and we keep that override.
            let mx = intValue(preprocessor["max_n_images"])
                  ?? intValue(preprocessor["max_image_tiles"])
                  ?? maxTiles
            caps = caps.replacing(strategy: .fixedTiling(tileSize: tile, maxTiles: mx))
        }

        // Device-class clamps applied last so JSON or defaults can't
        // override a tier-appropriate cap. The model can decode up to
        // `maxPixels`, but the device can only handle so much before
        // thermal throttling and Jetsam come for it.
        return caps.appliedDeviceClamps()
    }

    // MARK: - JSON helpers
    //
    // JSONSerialization gives back NSNumber/Double — bridge to the
    // Float / Int the rest of this file uses. Keep the helpers
    // forgiving: a wrong-type field returns nil, never throws.

    private static func loadJSON(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let obj  = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private static func floatValue(_ any: Any?) -> Float? {
        if let n = any as? NSNumber { return n.floatValue }
        if let d = any as? Double   { return Float(d) }
        if let i = any as? Int      { return Float(i) }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let i = any as? Int      { return i }
        if let d = any as? Double   { return Int(d) }
        return nil
    }

    private static func floatArray(_ any: Any?) -> [Float]? {
        if let arr = any as? [NSNumber] { return arr.map { $0.floatValue } }
        if let arr = any as? [Double]   { return arr.map { Float($0) } }
        if let arr = any as? [Float]    { return arr }
        return nil
    }

    private static func friendlyDisplayName(repoID: String, modelType: String) -> String {
        // "HuggingFaceTB/SmolVLM2-500M-Video-Instruct-mlx" → "SmolVLM2-500M"
        let tail = repoID.split(separator: "/").last.map(String.init) ?? repoID
        return tail.isEmpty ? (modelType.isEmpty ? "VLM" : modelType) : tail
    }
}

// MARK: - Per-architecture defaults table
//
// These are the "safety net" values used when a model's JSON is
// missing a field. Sourced from upstream transformers / mlx-vlm
// processor implementations as of writing — when a new model family
// is added to the codebase, extend the enum + this switch together,
// and validate by loading the model with debug logging on so any
// JSON-supplied field that differs from the default is visible.
//
// Streaming/still pixel caps here are pre-clamp; the actual cap a
// device sees comes from `appliedDeviceClamps()` below.

extension VLMCapabilities {

    fileprivate static func defaults(
        for arch: NormalizedArchitecture,
        modelDisplayName: String
    ) -> VLMCapabilities {
        let clipMean:    [Float] = [0.48145466, 0.4578275, 0.40821073]
        let clipStd:     [Float] = [0.26862954, 0.26130258, 0.27577711]
        let imagenetM:   [Float] = [0.485, 0.456, 0.406]
        let imagenetS:   [Float] = [0.229, 0.224, 0.225]
        let halfNorm:    [Float] = [0.5, 0.5, 0.5]

        switch arch {

        case .qwen35:
            // Qwen 3.5 uses 16×16 patches merged 2×2 (32-pixel token
            // alignment). Bonsai 27B publishes the same Qwen3VL processor
            // geometry with half normalization.
            return .init(
                architecture: arch.rawValue,
                modelDisplayName: modelDisplayName,
                inputSizingStrategy: .dynamicPatchAligned(
                    patch: 16, merge: 2,
                    minPixels: 256 * 256,
                    maxPixels: 1024 * 1024
                ),
                imageMean: halfNorm, imageStd: halfNorm,
                rescaleFactor: 1.0 / 255.0,
                recommendedStreamingPixels: 512 * 512,
                recommendedStillPixels: 1024 * 1024
            )

        case .qwen3VL, .qwen25VL, .qwen2VL:
            // Qwen2-VL / Qwen2.5-VL / Qwen3-VL all share the dynamic
            // patch-aligned strategy: 14×14 patches grouped by merge=2
            // into 28×28 effective tokens. min_pixels = 4*28² = 3136
            // (upstream default). max_pixels in the upstream processor
            // is 16384*28² ≈ 12.8M; the streaming cap of 512² sits well
            // inside that and is what the spec asks for. Qwen3-VL added
            // long-context vision but the per-tile geometry is the same
            // as Qwen2.5-VL — same defaults work.
            return .init(
                architecture: arch.rawValue,
                modelDisplayName: modelDisplayName,
                inputSizingStrategy: .dynamicPatchAligned(
                    patch: 14, merge: 2,
                    minPixels: 4 * 28 * 28,        // 3136
                    maxPixels: 1280 * 28 * 28      // 1_003_520  (upstream "default" cap)
                ),
                imageMean: clipMean, imageStd: clipStd,
                rescaleFactor: 1.0 / 255.0,
                recommendedStreamingPixels: 512 * 512,
                recommendedStillPixels: 1024 * 1024
            )

        case .llava:
            // LLaVA 1.5 — CLIP-ViT-L/14-336. Single fixed crop.
            return .init(
                architecture: arch.rawValue,
                modelDisplayName: modelDisplayName,
                inputSizingStrategy: .fixed(CGSize(width: 336, height: 336)),
                imageMean: clipMean, imageStd: clipStd,
                rescaleFactor: 1.0 / 255.0,
                recommendedStreamingPixels: 336 * 336,
                recommendedStillPixels: 672 * 672
            )

        case .llavaNext:
            // LLaVA 1.6 — base 336, picks one of five grid pinpoints
            // based on aspect ratio. Pinpoints are the standard ones
            // shipped in the official processor config.
            let pinpoints: [CGSize] = [
                CGSize(width: 336,  height: 672),
                CGSize(width: 672,  height: 336),
                CGSize(width: 672,  height: 672),
                CGSize(width: 1008, height: 336),
                CGSize(width: 336,  height: 1008),
            ]
            return .init(
                architecture: arch.rawValue,
                modelDisplayName: modelDisplayName,
                inputSizingStrategy: .anyresTiling(baseSize: 336, gridOptions: pinpoints),
                imageMean: clipMean, imageStd: clipStd,
                rescaleFactor: 1.0 / 255.0,
                recommendedStreamingPixels: 512 * 512,
                recommendedStillPixels: 1024 * 1024
            )

        case .mllama:
            // Llama 3.2 Vision: 560×560 tiles, up to 4 by default.
            // Some configs use 16; defer to the JSON when present.
            return .init(
                architecture: arch.rawValue,
                modelDisplayName: modelDisplayName,
                inputSizingStrategy: .fixedTiling(tileSize: 560, maxTiles: 4),
                imageMean: halfNorm, imageStd: halfNorm,
                rescaleFactor: 1.0 / 255.0,
                recommendedStreamingPixels: 560 * 560,
                recommendedStillPixels: 1120 * 1120
            )

        case .idefics3, .smolvlm:
            // Idefics3 / original SmolVLM: 384×384 tiles, up to 4 (the
            // global thumbnail counts as one of those). The fixed-
            // tiling shape is exactly the one whose mismatched patch
            // count caused the broadcast_shapes crash earlier — see
            // MLXVisionService.upscaleIfTiny() for the defensive guard.
            return .init(
                architecture: arch.rawValue,
                modelDisplayName: modelDisplayName,
                inputSizingStrategy: .fixedTiling(tileSize: 384, maxTiles: 4),
                imageMean: halfNorm, imageStd: halfNorm,
                rescaleFactor: 1.0 / 255.0,
                recommendedStreamingPixels: 384 * 384,
                recommendedStillPixels: 768 * 768
            )

        case .smolvlm2:
            // SmolVLM2 — same family as Idefics3 but with a 512 tile
            // option in some configs. JSON override expected.
            // NB: the alignment work here is ORTHOGONAL to the
            // defensive upscale-to-512 in MLXVisionService.upscaleIfTiny
            // — the preparer handles "what shape does this model want?"
            // and upscaleIfTiny handles "is this input pathologically
            // small?". Don't consolidate them; they protect against
            // different failure modes.
            return .init(
                architecture: arch.rawValue,
                modelDisplayName: modelDisplayName,
                inputSizingStrategy: .fixedTiling(tileSize: 384, maxTiles: 4),
                imageMean: halfNorm, imageStd: halfNorm,
                rescaleFactor: 1.0 / 255.0,
                recommendedStreamingPixels: 384 * 384,
                recommendedStillPixels: 768 * 768
            )

        case .moondream:
            // Moondream2 — 378×378 square. Uses CLIP-style norm.
            return .init(
                architecture: arch.rawValue,
                modelDisplayName: modelDisplayName,
                inputSizingStrategy: .fixed(CGSize(width: 378, height: 378)),
                imageMean: clipMean, imageStd: clipStd,
                rescaleFactor: 1.0 / 255.0,
                recommendedStreamingPixels: 378 * 378,
                recommendedStillPixels: 756 * 756
            )

        case .gemma4:
            // Gemma 4 unified multimodal (12B IT, plus E2B/E4B).
            // Vision tower uses patch_size 16 and SigLIP-style
            // half-normalisation — the patch embed applies
            // `2 * (x - 0.5)` directly (Gemma4.swift), i.e. mean 0.5
            // / std 0.5. The processor pools every image to a fixed
            // `default_output_length` (280) soft tokens regardless of
            // input resolution, so our size hint is a non-binding
            // bicubic source; we hand it a clean 896² square to match
            // the Gemma 3 sibling. NOTE: audio input is parsed by the
            // config (audio_token_id) but the Swift processor has no
            // audio path yet — image+text only.
            return .init(
                architecture: arch.rawValue,
                modelDisplayName: modelDisplayName,
                inputSizingStrategy: .fixed(CGSize(width: 896, height: 896)),
                imageMean: halfNorm, imageStd: halfNorm,
                rescaleFactor: 1.0 / 255.0,
                recommendedStreamingPixels: 896 * 896,
                recommendedStillPixels: 896 * 896
            )

        case .gemma3:
            // Gemma 3 multimodal (4B IT, 12B IT, 27B IT). Vision
            // tower is SigLIP at 896×896 with patch_size 14 — that's
            // (896/14)² = 4096 raw patches per image, condensed to
            // 256 image-tokens after pixel-shuffle. The processor
            // FORCES inputs to exactly 896×896 via bicubic resample
            // ("Always use the vision configuration's imageSize.
            // Ignore UserInput resize setting." — Gemma3.swift:1083).
            // So our resize hint is ignored; we just give the
            // processor a clean 2× intermediate to bicubic from.
            //
            // SigLIP normalization is 0.5 mean / 0.5 std (the
            // "half-norm" family). Worth double-checking from each
            // model's preprocessor_config.json since some Gemma 3
            // builds may use ImageNet norm.
            return .init(
                architecture: arch.rawValue,
                modelDisplayName: modelDisplayName,
                inputSizingStrategy: .fixed(CGSize(width: 896, height: 896)),
                imageMean: halfNorm, imageStd: halfNorm,
                rescaleFactor: 1.0 / 255.0,
                recommendedStreamingPixels: 896 * 896,
                recommendedStillPixels: 896 * 896    // processor always forces 896², no point asking for more
            )

        case .paligemma:
            // PaliGemma ships in 224/448/896 variants. Default to 448
            // (the most common); JSON override picks up the real value.
            return .init(
                architecture: arch.rawValue,
                modelDisplayName: modelDisplayName,
                inputSizingStrategy: .fixed(CGSize(width: 448, height: 448)),
                imageMean: halfNorm, imageStd: halfNorm,
                rescaleFactor: 1.0 / 255.0,
                recommendedStreamingPixels: 448 * 448,
                recommendedStillPixels: 896 * 896
            )

        case .unknown:
            // Safe fallback. Fixed 384² + ImageNet norm runs *something*
            // for any vision model, even if not optimally. If you see
            // the debug overlay reporting `unknown` for a model you've
            // added, extend NormalizedArchitecture.detect() to recognise
            // its model_type / architectures[0].
            return .init(
                architecture: arch.rawValue,
                modelDisplayName: modelDisplayName,
                inputSizingStrategy: .fixed(CGSize(width: 384, height: 384)),
                imageMean: imagenetM, imageStd: imagenetS,
                rescaleFactor: 1.0 / 255.0,
                recommendedStreamingPixels: 384 * 384,
                recommendedStillPixels: 768 * 768
            )
        }
    }
}

// MARK: - Device-class clamps
//
// Reuses the existing DeviceTier enum (DeviceTierAdvisor.swift) — 5
// tiers from lite (<4 GB) to max (≥12 GB) — rather than inventing a
// parallel 3-tier system. iPad falls into pro/max naturally based on
// physical memory; no special-case needed.
//
// The numbers below are streaming-pixel and still-pixel caps. They
// clamp the model's reported recommendations DOWN — never up. A
// model whose JSON says 512² stays at 512² on a `.max` device; the
// clamp only triggers when defaults exceed what the device can
// comfortably stream at 30+ fps without thermal throttling.

extension VLMCapabilities {

    /// Returns a copy of self with streaming/still pixel budgets
    /// clamped to what `DeviceTierAdvisor.current` says is safe.
    func appliedDeviceClamps() -> VLMCapabilities {
        let tier = DeviceTierAdvisor.current
        let streamCap = Self.streamingCap(for: tier)
        let stillCap  = Self.stillCap(for: tier)
        return .init(
            architecture: architecture,
            modelDisplayName: modelDisplayName,
            inputSizingStrategy: inputSizingStrategy,
            imageMean: imageMean, imageStd: imageStd,
            rescaleFactor: rescaleFactor,
            recommendedStreamingPixels: min(recommendedStreamingPixels, streamCap),
            recommendedStillPixels:     min(recommendedStillPixels,     stillCap)
        )
    }

    /// Streaming cap per device tier. Values pre-clamp:
    ///   lite/entry: 320² ≈ 100k px  — battery + thermal headroom
    ///   mid:        384² ≈ 147k px  — iPhone 13–15 standard
    ///   pro:        512² ≈ 262k px  — iPhone 15 Pro / 16 / 17
    ///   max:        640² ≈ 410k px  — Pro Max / iPad Pro M-series
    private static func streamingCap(for tier: DeviceTier) -> Int {
        switch tier {
        case .lite, .entry: return 320 * 320
        case .mid:          return 384 * 384
        case .pro:          return 512 * 512
        case .max:          return 640 * 640
        }
    }

    /// Still-capture cap per device tier. Larger than streaming since
    /// users tolerate seconds of latency for a one-shot describe.
    private static func stillCap(for tier: DeviceTier) -> Int {
        switch tier {
        case .lite, .entry: return 640 * 640
        case .mid:          return 768 * 768
        case .pro:          return 1024 * 1024
        case .max:          return 1280 * 1280
        }
    }
}

// MARK: - Field-level replacement helpers
//
// `VLMCapabilities` is a struct of `let`s so the JSON-overlay step
// can't mutate it directly. These helpers return a copy with one
// field swapped — verbose but explicit, and the compiler catches
// any field we forget to copy through when the struct grows.

private extension VLMCapabilities {
    func replacing(strategy: InputSizingStrategy) -> VLMCapabilities {
        .init(architecture: architecture, modelDisplayName: modelDisplayName,
              inputSizingStrategy: strategy,
              imageMean: imageMean, imageStd: imageStd,
              rescaleFactor: rescaleFactor,
              recommendedStreamingPixels: recommendedStreamingPixels,
              recommendedStillPixels: recommendedStillPixels)
    }
    func replacing(imageMean: [Float]) -> VLMCapabilities {
        .init(architecture: architecture, modelDisplayName: modelDisplayName,
              inputSizingStrategy: inputSizingStrategy,
              imageMean: imageMean, imageStd: imageStd,
              rescaleFactor: rescaleFactor,
              recommendedStreamingPixels: recommendedStreamingPixels,
              recommendedStillPixels: recommendedStillPixels)
    }
    func replacing(imageStd: [Float]) -> VLMCapabilities {
        .init(architecture: architecture, modelDisplayName: modelDisplayName,
              inputSizingStrategy: inputSizingStrategy,
              imageMean: imageMean, imageStd: imageStd,
              rescaleFactor: rescaleFactor,
              recommendedStreamingPixels: recommendedStreamingPixels,
              recommendedStillPixels: recommendedStillPixels)
    }
    func replacing(rescaleFactor: Float) -> VLMCapabilities {
        .init(architecture: architecture, modelDisplayName: modelDisplayName,
              inputSizingStrategy: inputSizingStrategy,
              imageMean: imageMean, imageStd: imageStd,
              rescaleFactor: rescaleFactor,
              recommendedStreamingPixels: recommendedStreamingPixels,
              recommendedStillPixels: recommendedStillPixels)
    }
}
