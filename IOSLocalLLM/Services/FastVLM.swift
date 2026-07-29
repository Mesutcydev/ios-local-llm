//
// FastVLM.swift
// IOSLocalLLM
//
// Adapted from apple/ml-fastvlm — app/FastVLM/FastVLM.swift
// © 2025 Apple Inc. All Rights Reserved. (original)
// Adaptations for IOSLocalLLM:
//   - MediaProcessingExtensions → MediaProcessing (MLXVLM 2.29.1 public API)
//   - LMInput.ProcessedImage(imageGridThw:) → (frames:)  (API change in 2.29.1)
//   - Added Prompt.asMessages() extension (not in 2.29.1 public API)
//

import CoreImage
import CoreML
import Foundation
import MLX
import MLXFast
import MLXLMCommon
import MLXNN
import MLXVLM
// NOTE: `Tokenizer` now comes from MLXLMCommon — mlx-swift-lm 3.x defines its
// own `Tokenizer` protocol, so also importing swift-transformers' `Tokenizers`
// made the type ambiguous. The processor registry hands us an
// `MLXLMCommon.Tokenizer`; `.encode(text:)` is provided there.

// MARK: - UserInput.Prompt → messages helper (not in MLXVLM 2.29.1 public API)

private extension UserInput.Prompt {
    /// Converts any Prompt variant to a flat [role: content] array for the FastVLM chat template.
    func asMessages() -> [[String: String]] {
        switch self {
        case .text(let text):
            return [["role": "user", "content": text]]
        case .messages(let msgs):
            return msgs.compactMap { msg in
                guard let role = msg["role"] as? String else { return nil }
                let content = (msg["content"] as? String) ?? ""
                return ["role": role, "content": content]
            }
        case .chat(let chatMessages):
            return chatMessages.map { ["role": $0.role.rawValue, "content": $0.content] }
        }
    }
}

// MARK: - rotateHalf (RoPE helper)

private func rotateHalf(_ x: MLXArray) -> MLXArray {
    let index = x.dim(-1) / 2
    let x1 = x[.ellipsis, 0 ..< index]
    let x2 = x[.ellipsis, index...]
    return concatenated([-x2, x1], axis: -1)
}

// MARK: - Language (Qwen2 decoder in MLX)

private enum Language {

    static private func applyMultimodalRotaryPositionEmbedding(
        q: MLXArray, k: MLXArray, cos: MLXArray, sin: MLXArray,
        positionIds: MLXArray, mropeSection: [Int]
    ) -> (MLXArray, MLXArray) {
        var cos = cos[positionIds]
        var sin = sin[positionIds]

        cos = concatenated(
            split(cos, indices: mropeSection, axis: -1).enumerated().map { i, m in m[i % 3] },
            axis: -1
        )[0..., .newAxis, 0..., 0...]

        sin = concatenated(
            split(sin, indices: mropeSection, axis: -1).enumerated().map { i, m in m[i % 3] },
            axis: -1
        )[0..., .newAxis, 0..., 0...]

        let qEmbed = (q * cos) + (rotateHalf(q) * sin)
        let kEmbed = (k * cos) + (rotateHalf(k) * sin)
        return (qEmbed, kEmbed)
    }

    fileprivate class Attention: Module {

        let heads: Int
        let kvHeads: Int
        let headDim: Int
        let scale: Float
        let mropeSection: [Int]

        @ModuleInfo(key: "q_proj") var wq: Linear
        @ModuleInfo(key: "k_proj") var wk: Linear
        @ModuleInfo(key: "v_proj") var wv: Linear
        @ModuleInfo(key: "o_proj") var wo: Linear

        @ModuleInfo(key: "rotary_emb") var rotaryEmbedding: RoPE

        init(_ args: FastVLMConfiguration.TextConfiguration) {
            let dim = args.hiddenSize
            self.heads = args.attentionHeads
            self.kvHeads = args.kvHeads
            self.headDim = dim / heads
            self.scale = pow(Float(headDim), -0.5)

            self._wq.wrappedValue = Linear(dim, heads * headDim, bias: true)
            self._wk.wrappedValue = Linear(dim, kvHeads * headDim, bias: true)
            self._wv.wrappedValue = Linear(dim, kvHeads * headDim, bias: true)
            self._wo.wrappedValue = Linear(heads * headDim, dim, bias: false)

            if let v = args.ropeScaling?["mrope_section"], let array = v.asInts() {
                self.mropeSection = sequence(state: (0, array.makeIterator())) { state in
                    if let v = state.1.next() {
                        state.0 += v * 2
                        return state.0
                    } else {
                        return nil
                    }
                }.dropLast()
            } else {
                // Fallback: default mrope_section for Qwen2-0.5B [2,1,1] → cumsum*2 = [4,6]
                self.mropeSection = [4, 6]
            }

            self._rotaryEmbedding.wrappedValue = RoPE(
                dimensions: headDim, traditional: args.ropeTraditional, base: args.ropeTheta)
        }

        func callAsFunction(_ x: MLXArray, mask: MLXArray? = nil, cache: (any KVCache)?) -> MLXArray {
            let (B, L) = (x.dim(0), x.dim(1))

            var queries = wq(x)
            var keys = wk(x)
            var values = wv(x)

            queries = queries.reshaped(B, L, heads, headDim).transposed(0, 2, 1, 3)
            keys = keys.reshaped(B, L, kvHeads, headDim).transposed(0, 2, 1, 3)
            values = values.reshaped(B, L, kvHeads, headDim).transposed(0, 2, 1, 3)

            let offset = cache?.offset ?? 0
            let mask = mask?[0..., 0 ..< keys.dim(-2)]

            queries = rotaryEmbedding(queries, offset: offset)
            keys = rotaryEmbedding(keys, offset: offset)

            if let cache {
                (keys, values) = cache.update(keys: keys, values: values)
            }

            let attnOut = MLXFast.scaledDotProductAttention(
                queries: queries, keys: keys, values: values, scale: scale, mask: mask
            )
            .transposed(0, 2, 1, 3)
            .reshaped(B, L, -1)
            return wo(attnOut)
        }
    }

    fileprivate class MLP: Module, UnaryLayer {

        @ModuleInfo(key: "gate_proj") var gate: Linear
        @ModuleInfo(key: "down_proj") var down: Linear
        @ModuleInfo(key: "up_proj") var up: Linear

        init(dimensions: Int, hiddenDimensions: Int) {
            self._gate.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
            self._down.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
            self._up.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray {
            down(silu(gate(x)) * up(x))
        }
    }

    fileprivate class DecoderLayer: Module {

        @ModuleInfo(key: "self_attn") var attention: Attention
        let mlp: MLP

        @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
        @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

        init(_ args: FastVLMConfiguration.TextConfiguration) {
            self._attention.wrappedValue = Attention(args)
            self.mlp = MLP(dimensions: args.hiddenSize, hiddenDimensions: args.intermediateSize)
            self._inputLayerNorm.wrappedValue = RMSNorm(
                dimensions: args.hiddenSize, eps: args.rmsNormEps)
            self._postAttentionLayerNorm.wrappedValue = RMSNorm(
                dimensions: args.hiddenSize, eps: args.rmsNormEps)
        }

        func callAsFunction(_ x: MLXArray, mask: MLXArray? = nil, cache: (any KVCache)?) -> MLXArray {
            let r = attention(inputLayerNorm(x), mask: mask, cache: cache)
            let h = x + r
            return h + mlp(postAttentionLayerNorm(h))
        }
    }

    fileprivate class Qwen2Model: Module {

        @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
        fileprivate let layers: [DecoderLayer]
        fileprivate let norm: RMSNorm

        init(_ args: FastVLMConfiguration.TextConfiguration) {
            precondition(args.vocabularySize > 0)
            self._embedTokens.wrappedValue = Embedding(
                embeddingCount: args.vocabularySize, dimensions: args.hiddenSize)
            self.layers = (0 ..< args.hiddenLayers).map { _ in DecoderLayer(args) }
            self.norm = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
        }

        func callAsFunction(
            _ inputs: MLXArray?, cache: [any KVCache]? = nil, inputEmbedding: MLXArray? = nil
        ) -> MLXArray {
            var h: MLXArray
            if let inputEmbedding {
                h = inputEmbedding
            } else if let inputs {
                h = embedTokens(inputs)
            } else {
                fatalError("one of inputs or inputEmbedding must be non-nil")
            }

            // Explicitly request MLXArray? form (there's a ScaledDotProductAttentionMaskMode
            // overload in MLXLMCommon that would otherwise be ambiguous).
            let mask: MLXArray? = createAttentionMask(h: h, cache: cache)
            for (i, layer) in layers.enumerated() {
                h = layer(h, mask: mask, cache: cache?[i])
            }
            return norm(h)
        }
    }

    fileprivate class LanguageModel: Module, KVCacheDimensionProvider {

        @ModuleInfo var model: Qwen2Model
        @ModuleInfo(key: "lm_head") var lmHead: Linear
        var kvHeads: [Int]

        init(_ args: FastVLMConfiguration.TextConfiguration) {
            self.model = Qwen2Model(args)
            // Always allocate lm_head. Different FastVLM repos disagree about
            // `tie_word_embeddings` — Apple's checkpoints ship lm_head.weight
            // explicitly while some MLX repacks declare tied embeddings yet
            // still emit the tensor anyway. Keeping the module present means
            // sanitize can either load the shipped weight or alias
            // embed_tokens into it, instead of crashing the load with
            // "language_model.lm_head: none not compatible with [weight: …]".
            _lmHead.wrappedValue = Linear(args.hiddenSize, args.vocabularySize, bias: false)
            self.kvHeads = (0 ..< args.hiddenLayers).map { _ in args.kvHeads }
        }

        func callAsFunction(
            _ inputs: MLXArray?, cache: [any KVCache]? = nil, inputEmbedding: MLXArray? = nil
        ) -> LMOutput {
            let h = model(inputs, cache: cache, inputEmbedding: inputEmbedding)
            return LMOutput(logits: lmHead(h))
        }
    }
}

// MARK: - Vision (Core ML encoder bridge)

private enum Vision {

    /// Wraps the auto-generated `fastvithd` Core ML class.
    /// The mlpackage is compiled into the app bundle by Xcode.
    fileprivate class VisionModelCoreML {

        let lock = NSLock()
        var _model: fastvithd?

        func load() throws -> fastvithd {
            try lock.withLock {
                if let model = _model { return model }
                let model = try fastvithd()
                _model = model
                return model
            }
        }

        /// Encodes a [1, 3, H, W] float32 MLXArray through the Core ML vision encoder.
        /// Returns [1, 256, 3072] float32.
        ///
        /// On ANY Core ML failure — the model failed to load/compile, OOM, a
        /// prediction error — this returns a zero-filled feature map instead of
        /// crashing. This path runs on the live Lens loop via the MLX module
        /// graph (a non-throwing `callAsFunction`), so a thrown error here had
        /// nowhere to go but `try!` → SIGABRT, taking the whole app down the
        /// instant the camera saw a frame with a bad/half-loaded encoder. A
        /// poor caption beats a hard crash; the failure is recorded so it's
        /// diagnosable rather than silent.
        func encode(_ image: MLXArray) -> MLXArray {
            func zeroFeatures() -> MLXArray {
                let buf = [Float32](repeating: 0, count: 1 * 256 * 3072)
                return buf.withUnsafeBytes { MLXArray($0, [1, 256, 3072], type: Float32.self) }
            }

            guard let coreMLModel = try? load() else {
                Diagnostics.shared.breadcrumb(
                    "FastVLM vision encoder unavailable — Core ML model failed to load", category: "lens")
                return zeroFeatures()
            }

            precondition(image.ndim == 4)
            precondition(image.dim(0) == 1)
            precondition(image.dim(1) == 3)

            let H = image.dim(2)
            let W = image.dim(3)
            let expectedCount = 1 * 3 * H * W

            // Force a contiguous float32 host copy. Zero-copy into MLX-backed
            // storage + default Core ML `.all` compute units previously routed
            // through MetalPerformanceShadersGraph and SIGSEGV'd mid-prediction
            // on iOS 27. Owning the buffer + ANE/CPU compute units (see
            // `fastvithd.init`) removes both crash vectors.
            let contiguous = image.asType(.float32).asData(access: .copy)
            let shape: [NSNumber] = [1, 3, NSNumber(value: H), NSNumber(value: W)]
            guard let owned = try? MLMultiArray(shape: shape, dataType: .float32) else {
                Diagnostics.shared.breadcrumb(
                    "FastVLM encode failed: could not allocate MLMultiArray", category: "lens")
                return zeroFeatures()
            }
            contiguous.data.withUnsafeBytes { src in
                guard let base = src.baseAddress else { return }
                memcpy(owned.dataPointer, base,
                       min(src.count, expectedCount * MemoryLayout<Float32>.size))
            }

            do {
                let output = try coreMLModel.prediction(images: owned)
                precondition(output.image_features.shape == [1, 256, 3072])
                return output.image_features.withUnsafeBytes { ptr in
                    MLXArray(ptr, [1, 256, 3072], type: Float32.self)
                }
            } catch {
                Diagnostics.shared.breadcrumb(
                    "FastVLM encode failed: \(error.localizedDescription)", category: "lens")
                return zeroFeatures()
            }
        }
    }

    fileprivate class VisionModel: Module {

        let model = VisionModelCoreML()

        override init() {}

        func callAsFunction(_ hiddenStates: MLXArray, gridThw: [THW]) -> MLXArray {
            model.encode(hiddenStates)
        }
    }
}

// MARK: - FastVLMProcessor

/// `UserInputProcessor` for FastVLM / LlavaQwen2.
///
/// Registered as "LlavaProcessor" by ``FastVLM/register(modelFactory:)``.
public final class FastVLMProcessor: UserInputProcessor {

    private let config: FastVLMProcessorConfiguration
    private let imageProcessingConfig: FastVLMPreProcessorConfiguration
    private let tokenizer: any Tokenizer

    public init(_ config: FastVLMPreProcessorConfiguration, tokenizer: any Tokenizer) {
        self.config = FastVLMProcessorConfiguration()
        self.imageProcessingConfig = config
        self.tokenizer = tokenizer
    }

    /// Pre-processes a CIImage: resize to shortest edge, center-crop, normalize.
    /// Returns the [1, C, H, W] pixel array and its THW descriptor.
    public func preprocess(image: CIImage, processing: UserInput.Processing?) throws -> (MLXArray, THW) {
        var img = MediaProcessing.apply(image, processing: processing)

        let targetSize = MediaProcessing.fitIn(
            img.extent.size,
            shortestEdge: imageProcessingConfig.size.shortestEdge)
        img = MediaProcessing.resampleBicubic(img, to: targetSize)

        img = MediaProcessing.centerCrop(img, size: imageProcessingConfig.cropSize.size)

        img = MediaProcessing.normalize(
            img,
            mean: imageProcessingConfig.imageMeanTuple,
            std: imageProcessingConfig.imageStdTuple)

        let array = MediaProcessing.asMLXArray(img)   // [1, C, H, W]
        return (array, THW(0, array.dim(2), array.dim(3)))
    }

    /// Builds the Qwen2 chat-template string, inserting image placeholder tokens.
    public func prepare(prompt: UserInput.Prompt, imageTHW: THW?) -> String {
        var messages = prompt.asMessages()

        if messages.first?["role"] != "system" {
            messages.insert(["role": "system", "content": "You are a helpful assistant."], at: 0)
        }

        let lastIdx = messages.count - 1
        var lastContent = messages[lastIdx]["content"] ?? ""

        if imageTHW != nil {
            // FastVLM's Core ML encoder is fixed-output: regardless of input
            // H×W it produces exactly [1, encoderNumPatches, 3072] (the
            // precondition at Vision.VisionModelCoreML.encode pins this at
            // 256). Computing placeholders from (h/patchSize)² was right
            // only when the preprocessor config happens to use 1024×1024 +
            // patchSize=64; any other crop_size produced too few `<image>`
            // tokens and tripped imageTokenCountMismatch downstream. Pin to
            // the encoder's actual feature count so prompt and tensor shape
            // can never drift apart.
            let numImageTokens = FastVLMConfig.encoderNumPatches
            lastContent += Array(repeating: config.imageToken, count: numImageTokens).joined()
        }

        messages[lastIdx]["content"] = lastContent

        return messages
            .map { "<|im_start|>\($0["role"] ?? "user")\n\($0["content"] ?? "")<|im_end|>" }
            .joined(separator: "\n")
            + "\n<|im_start|>assistant\n"
    }

    public func prepare(input: UserInput) async throws -> LMInput {
        // Text-only path
        if input.images.isEmpty {
            let prompt = prepare(prompt: input.prompt, imageTHW: nil)
            let tokens = encodeWithImageTokens(prompt)
            return LMInput(tokens: MLXArray(tokens))
        }

        if input.images.count > 1 {
            throw VLMError.singleImageAllowed
        }

        let (pixels, thw) = try preprocess(
            image: input.images[0].asCIImage(), processing: input.processing)

        // API in mlx-swift-examples 2.29.1 uses `frames:` (not `imageGridThw:`)
        let image = LMInput.ProcessedImage(pixels: pixels, frames: [thw])

        let prompt = prepare(prompt: input.prompt, imageTHW: thw)
        let promptTokens = encodeWithImageTokens(prompt)
        let promptArray = MLXArray(promptTokens).expandedDimensions(axis: 0)
        let mask = ones(like: promptArray).asType(.int8)

        return LMInput(text: .init(tokens: promptArray, mask: mask), image: image)
    }

    /// Encodes `prompt` to token ids, manually inserting the FastVLM
    /// image token id (151646) at every `<image>` placeholder.
    ///
    /// Why bypass the tokenizer here. Even when `tokenizer.json` lists
    /// `<image>` in `added_tokens` with id 151646, swift-transformers'
    /// `Tokenizer.encode(text:)` does not consistently treat it as an
    /// atomic special token across all the FastVLM weight mirrors we
    /// support — depending on the `tokenizer_config.json` flags
    /// (`add_special_tokens`, `is_special`, normalization) the
    /// `<image>` string can get BPE-split into raw bytes. When that
    /// happens `imageIndices` in `mergeInputIdsWithImageFeatures` is
    /// empty, the 256-row image feature tensor has nowhere to scatter
    /// into, and MLX crashes with
    ///   `Shapes (256,896) and (1,0,896) cannot be broadcast`.
    ///
    /// Splitting on the literal token string + injecting the id
    /// ourselves removes that dependency: every `<image>` placeholder
    /// becomes exactly one id 151646, period.
    private func encodeWithImageTokens(_ prompt: String) -> [Int] {
        let imageToken = config.imageToken
        let imageTokenId = FastVLMConfig.imageTokenId   // 151646
        let parts = prompt.components(separatedBy: imageToken)
        guard parts.count > 1 else {
            return tokenizer.encode(text: prompt)
        }
        var tokens: [Int] = []
        tokens.reserveCapacity(parts.count * 16 + parts.count - 1)
        for (idx, part) in parts.enumerated() {
            if !part.isEmpty {
                tokens.append(contentsOf: tokenizer.encode(text: part))
            }
            if idx < parts.count - 1 {
                tokens.append(imageTokenId)
            }
        }
        return tokens
    }
}

// MARK: - FastVLMMultiModalProjector

private class FastVLMMultiModalProjector: Module, UnaryLayer {

    @ModuleInfo(key: "linear_0") var linear0: Linear
    @ModuleInfo(key: "gelu") var gelu: GELU
    @ModuleInfo(key: "linear_2") var linear2: Linear

    init(_ config: FastVLMConfiguration) {
        self._linear0.wrappedValue = Linear(
            config.visionConfiguration.hiddenSize,
            config.textConfiguration.hiddenSize,
            bias: true)
        self._gelu.wrappedValue = GELU()
        self._linear2.wrappedValue = Linear(
            config.textConfiguration.hiddenSize,
            config.textConfiguration.hiddenSize,
            bias: true)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        linear2(gelu(linear0(x)))
    }
}

// MARK: - FastVLM (main model)

/// FastVLM: LlavaQwen2 with Core ML vision tower + MLX language model.
///
/// Bridge between `fastvithd.mlpackage` (Core ML, always in app bundle)
/// and the Qwen2-0.5B MLX weights (downloaded to Documents/FastVLMModels/).
///
/// Registered with `VLMModelFactory` via ``FastVLM/register(modelFactory:)``.
public class FastVLM: Module, VLMModel, KVCacheDimensionProvider {

    // MARK: - Registration

    /// Registers `llava_qwen2` and `LlavaProcessor` with any VLMModelFactory instance.
    /// Call once before loading the model, e.g. in `FastVLMService.load()`.
    // mlx-swift-lm 3.x made the type/processor registries `actor`s, so
    // registration is async. Creators now receive the config file's `Data`
    // directly (was a `URL` in 2.x), so decode from it as-is.
    public static func register(modelFactory: VLMModelFactory) async {
        await modelFactory.typeRegistry.registerModelType("llava_qwen2") { data in
            let config = try JSONDecoder().decode(FastVLMConfiguration.self, from: data)
            return FastVLM(config)
        }
        await modelFactory.processorRegistry.registerProcessorType("LlavaProcessor") { data, tokenizer in
            let config = try JSONDecoder().decode(FastVLMPreProcessorConfiguration.self, from: data)
            return FastVLMProcessor(config, tokenizer: tokenizer)
        }
    }

    // MARK: - Components

    @ModuleInfo(key: "vision_tower") private var visionModel: Vision.VisionModel
    @ModuleInfo(key: "language_model") private var languageModel: Language.LanguageModel
    @ModuleInfo(key: "multi_modal_projector") private var multiModalProjector: FastVLMMultiModalProjector

    public let config: FastVLMConfiguration

    public var vocabularySize: Int { config.baseConfiguration.vocabularySize }
    public var kvHeads: [Int] { languageModel.kvHeads }

    // mlx-swift-lm 3.x: `LoRAModel` (required by `VLMModel`) replaced
    // `func loraLinearLayers() -> LoRALinearLayers` with `var loraLayers`.
    // FastVLM is inference-only, so this just satisfies the conformance —
    // the attention modules are the LoRA-eligible layers.
    public var loraLayers: [Module] {
        languageModel.model.layers.map { $0.attention }
    }

    public init(_ config: FastVLMConfiguration) {
        self.config = config
        self._visionModel.wrappedValue = Vision.VisionModel()
        self._languageModel.wrappedValue = Language.LanguageModel(config.textConfiguration)
        self._multiModalProjector.wrappedValue = FastVLMMultiModalProjector(config)
    }

    // MARK: - Input embedding (Core ML → MLX bridge point)

    private func inputEmbeddings(
        inputIds: MLXArray, pixelValues: MLXArray?, gridThw: [THW]?
    ) throws -> MLXArray {
        guard let pixelValues, let gridThw else {
            // Text-only — return embeddings directly (no image)
            return languageModel.model.embedTokens(inputIds)
        }

        let inputEmbeds = languageModel.model.embedTokens(inputIds)

        // Core ML → [1, 256, 3072] → project → [256, 896]
        let imageFeaturesCoreML = visionModel(pixelValues, gridThw: gridThw)
        let imageFeatures = multiModalProjector(imageFeaturesCoreML)

        return try mergeInputIdsWithImageFeatures(
            inputIds: inputIds, inputEmbeds: inputEmbeds, imageFeatures: imageFeatures)
    }

    private func mergeInputIdsWithImageFeatures(
        inputIds: MLXArray, inputEmbeds: MLXArray, imageFeatures: MLXArray
    ) throws -> MLXArray {
        // MUST match the id that `encodeWithImageTokens` injects at every
        // `<image>` placeholder. Reading `config.baseConfiguration.image-
        // TokenId` here was wrong: that field decodes `image_token_index`
        // from the model's config.json which is missing on Apple's
        // FastVLM-0.5B mirror and falls back to the FastVLM Python
        // reference's IGNORE_INDEX sentinel of -200 (see
        // FastVLMConfiguration.BaseConfiguration). -200 is never produced
        // by the tokenizer, so `imageIndices.count` was always 0 and every
        // generate threw `imageTokenCountMismatch(0, 256)` even though the
        // prompt contained the right number of placeholders.
        let imageTokenIndex = FastVLMConfig.imageTokenId
        var imageIndices = [Int]()
        for (i, v) in inputIds.asArray(Int.self).enumerated() {
            if v == imageTokenIndex {
                imageIndices.append(i)
            }
        }
        // Validate shapes BEFORE the subscript assignment. The setter
        // does an internal broadcast that fatal-errors at the MLX C
        // layer when shapes don't match — the call:
        //     inputEmbeds[0..., MLXArray(imageIndices), 0...] = imageFeatures
        // requires imageFeatures' sequence dim to equal
        // imageIndices.count. Mismatch produced TestFlight incident
        // 119136B3-F74F-49EF-9F4C-BC9258EFD2A7 (broadcast_to →
        // _mlx_error → fatalError on iPhone18,2 / iOS 26.3). The
        // FastVLMService.analyze wrap with `withError` now converts
        // the underlying MLX error to a Swift throw, but checking
        // here gives the user (and crash reports) a concrete reason
        // instead of "broadcast failed".
        //
        // imageFeatures shape after multiModalProjector is [N, hidden]
        // for the standard 336×336 input (N=256). For non-standard
        // input sizes the vision encoder may emit a different N — that
        // is the mismatch we surface here.
        let featureSlots = imageFeatures.shape.count >= 2
            ? imageFeatures.shape[imageFeatures.shape.count - 2]
            : 0
        guard imageIndices.count == featureSlots else {
            throw FastVLMError.imageTokenCountMismatch(
                promptImageTokens: imageIndices.count,
                visionFeatureSlots: featureSlots
            )
        }
        // The subscript assignment below is a mutating setter on MLXArray,
        // but Swift can't see that through the type's API surface — silence
        // the false-positive "never mutated" warning by aliasing.
        var merged = inputEmbeds
        let mutator: (inout MLXArray) -> Void = { $0[0..., MLXArray(imageIndices), 0...] = imageFeatures }
        mutator(&merged)
        return merged
    }

    // MARK: - LanguageModel protocol

    public func prepare(_ input: LMInput, cache: [any KVCache], windowSize: Int?) throws -> PrepareResult {
        // API in mlx-swift-examples 2.29.1 uses `frames:` property
        let gridThw = input.image?.frames
        let pixels = input.image?.pixels.asType(.float32)

        let inputEmbeddings = try self.inputEmbeddings(
            inputIds: input.text.tokens,
            pixelValues: pixels,
            gridThw: gridThw)

        let result = languageModel(nil, cache: cache, inputEmbedding: inputEmbeddings)
        return .logits(result)
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [any KVCache]?) -> MLXArray {
        languageModel(inputs, cache: cache).logits
    }

    /// Called by VLMModelFactory after loading weights.
    /// Triggers lazy load of the Core ML model and normalises key names
    /// across the FastVLM checkpoint variants found on HF.
    ///
    /// Projector variants:
    ///  • Standard (Apple ml-fastvlm): linear_0 + linear_2  ← our schema
    ///  • Some mlx-community repacks:  linear_0 + linear_1  ← remap _1 → _2
    ///  • Rare flat variant:           multi_modal_projector.0 / .1  ← remap
    ///
    /// Language-model key variants (the cause of the user-reported
    /// "Key language_model.model.embed_tokens.weight not found in
    /// FastVLM.LanguageModel.Qwen2Model.Embedding" load failure):
    ///  • Apple ml-fastvlm:            language_model.model.embed_tokens.weight
    ///  • Flat repack:                 language_model.embed_tokens.weight
    ///  • No-prefix LLaVA:             model.embed_tokens.weight
    ///  • Older HF format:             transformer.wte.weight
    /// Same prefix-stripping happens for layers, norm, and lm_head. When the
    /// weights also lack an explicit `lm_head.weight` but the config says
    /// embeddings are untied, we fall back to the embed_tokens tensor (the
    /// usual tied-embedding pattern Qwen2 uses).
    public func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        _ = try? visionModel.model.load()

        let prefix = "multi_modal_projector."
        var out = weights

        // ── Normalise the projector prefix ────────────────────────────────
        // The same projector ships under at least four different prefixes
        // across HF mirrors and MLX repacks:
        //   • multi_modal_projector.*        ← apple ml-fastvlm / HF transformers
        //   • mm_projector.*                 ← original LLaVA training scripts
        //   • model.mm_projector.*           ← LLaVA wrapped inside a HF "model" namespace
        //   • model.multi_modal_projector.*  ← double-wrapped repacks
        // Without this step, sanitize's linear_1/.0/.2 normalisation never
        // fires for the three non-canonical layouts and load crashes with
        // "Key multi_modal_projector.linear_0.weight not found".
        let aliasPrefixes = [
            "model.multi_modal_projector.",
            "model.mm_projector.",
            "mm_projector.",
        ]
        for alias in aliasPrefixes {
            let aliasKeys = out.keys.filter { $0.hasPrefix(alias) }
            guard !aliasKeys.isEmpty else { continue }
            // Don't clobber: only promote if the canonical prefix is empty.
            let canonicalAlreadyPresent = out.keys.contains { $0.hasPrefix(prefix) }
            guard !canonicalAlreadyPresent else { continue }
            for key in aliasKeys {
                let suffix = key.dropFirst(alias.count)
                out[prefix + suffix] = out.removeValue(forKey: key)
            }
        }

        // Variant: second linear stored as linear_1 instead of linear_2
        let hasLinear2 = out.keys.contains { $0.hasPrefix(prefix + "linear_2") }
        let hasLinear1 = out.keys.contains { $0.hasPrefix(prefix + "linear_1") }
        if !hasLinear2 && hasLinear1 {
            for key in out.keys where key.hasPrefix(prefix + "linear_1") {
                let newKey = prefix + "linear_2" + key.dropFirst((prefix + "linear_1").count)
                out[newKey] = out.removeValue(forKey: key)
            }
        }

        // Variant: positional numeric keys  multi_modal_projector.0 / .2
        let hasNamed = out.keys.contains { $0.hasPrefix(prefix + "linear_") }
        if !hasNamed {
            for key in out.keys where key.hasPrefix(prefix) {
                let rest = String(key.dropFirst(prefix.count))
                let newKey: String
                if rest.hasPrefix("0.") {
                    newKey = prefix + "linear_0." + rest.dropFirst(2)
                } else if rest.hasPrefix("2.") || rest.hasPrefix("1.") {
                    newKey = prefix + "linear_2." + rest.dropFirst(2)
                } else {
                    continue
                }
                out[newKey] = out.removeValue(forKey: key)
            }
        }

        // ── Normalise the language-model prefix ────────────────────────────
        // FastVLM declares its decoder at `language_model.model.*` (plus
        // `language_model.lm_head.*` when embeddings are untied). Repacks
        // often drop one of those segments. Re-add whatever's missing so the
        // strict-verify load pass finds every parameter.
        let expectedTrunk = "language_model.model."
        let expectedHead = "language_model.lm_head."
        let hasExpectedTrunk = out.keys.contains { $0.hasPrefix(expectedTrunk) }
        let hasExpectedHead = out.keys.contains { $0.hasPrefix(expectedHead) }

        if !hasExpectedTrunk {
            // Try the four most common alternate prefixes in order. The first
            // one that yields any matching key is taken as the source.
            let candidatePrefixes = [
                "language_model.",   // flat (no `.model.` segment)
                "model.",            // no language_model wrapper
                "transformer.",      // older HF naming
                "",                  // completely flat, just `embed_tokens.*`
            ]
            for cand in candidatePrefixes {
                let suffixes = ["embed_tokens.", "layers.", "norm."]
                let hasAny = out.keys.contains { k in
                    k.hasPrefix(cand) &&
                    suffixes.contains { k.dropFirst(cand.count).hasPrefix($0) } &&
                    !k.hasPrefix(expectedTrunk) &&
                    !k.hasPrefix(expectedHead) &&
                    !k.hasPrefix(prefix) &&
                    !k.hasPrefix("vision_tower.")
                }
                guard hasAny else { continue }
                for key in Array(out.keys) {
                    guard key.hasPrefix(cand) else { continue }
                    let rest = String(key.dropFirst(cand.count))
                    // Don't touch keys that already match a different namespace.
                    if rest.hasPrefix("multi_modal_projector.") { continue }
                    if rest.hasPrefix("vision_tower.") { continue }
                    if rest.hasPrefix("lm_head.") { continue }
                    let isDecoderKey = suffixes.contains { rest.hasPrefix($0) } ||
                        rest.hasPrefix("wte.")    // older HF: transformer.wte → embed_tokens
                    guard isDecoderKey else { continue }
                    let mapped: String = {
                        if rest.hasPrefix("wte.") {
                            return expectedTrunk + "embed_tokens." + rest.dropFirst("wte.".count)
                        }
                        return expectedTrunk + rest
                    }()
                    out[mapped] = out.removeValue(forKey: key)
                }
                break
            }
        }

        // Promote a bare `lm_head.*` to the expected `language_model.lm_head.*`
        // when that's where the rest of the LM lives. Same for the
        // `model.lm_head.*` variant — HF transformers exports the Llava head
        // under `model.` on some Qwen2 repacks.
        if !hasExpectedHead {
            for key in Array(out.keys) where key.hasPrefix("lm_head.") {
                out[expectedHead + key.dropFirst("lm_head.".count)] = out.removeValue(forKey: key)
            }
            for key in Array(out.keys) where key.hasPrefix("model.lm_head.") {
                out[expectedHead + key.dropFirst("model.lm_head.".count)] = out.removeValue(forKey: key)
            }
        }

        // LanguageModel now ALWAYS allocates lm_head, so the weight dict must
        // contain lm_head.weight. When a repo legitimately ties embeddings and
        // omits the tensor (Qwen2-0.5B base, some MLX repacks of FastVLM),
        // alias embed_tokens.weight into the lm_head slot — mathematically
        // equivalent to `embed_tokens.asLinear()`.
        if out[expectedHead + "weight"] == nil,
           let embed = out[expectedTrunk + "embed_tokens.weight"] {
            out[expectedHead + "weight"] = embed
        }

        // The Core ML encoder owns the vision tower. Any vision_tower.* keys
        // shipped by an MLX repack belong to a different vision backbone and
        // would fail strict load against our empty Vision.VisionModel.
        for key in Array(out.keys) where key.hasPrefix("vision_tower.") {
            out.removeValue(forKey: key)
        }
        // Same idea for any rotary embedding inv_freq buffers — MLX recomputes
        // them from rope_theta at init; loading the file's copy would error
        // out on the Attention.rotaryEmbedding submodule which exposes no
        // parameter slot for it.
        for key in Array(out.keys) where key.hasSuffix(".rotary_emb.inv_freq") {
            out.removeValue(forKey: key)
        }

        // Final safety net. FastVLM exposes exactly three top-level @ModuleInfo
        // submodules: `vision_tower`, `language_model`, `multi_modal_projector`.
        // Any leftover key outside those namespaces would crash MLX's strict
        // load with "Unhandled keys ['<prefix>'] in FastVLM" — the symptom from
        // LLaVA training artifacts (model.image_newline, model.vision_resampler.*,
        // mm_vision_tower.*) and from non-canonical repacks that nest things
        // under bare `model.` after our promotions ran. Drop them rather than
        // failing the whole load: at inference time they wouldn't be used
        // anyway since the encoder is Core ML and there are no extra slots.
        let validPrefixes = [expectedTrunk, expectedHead, prefix]
        for key in Array(out.keys) {
            let isValid = validPrefixes.contains { key.hasPrefix($0) }
            if !isValid {
                out.removeValue(forKey: key)
            }
        }

        return out
    }
}

// MARK: - FastVLMConfiguration

public struct FastVLMConfiguration: Decodable, Sendable {

    public struct VisionConfiguration: Decodable, Sendable {
        public let hiddenSize: Int

        enum CodingKeys: String, CodingKey {
            case mmHiddenSize = "mm_hidden_size"
            case visionHiddenSize = "vision_hidden_size"
            case mmProjectorDim = "mm_projector_dim"
        }

        public init(from decoder: any Swift.Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Different FastVLM repacks key the projector's input dimension
            // differently. Try each variant in turn; default to 3072 (the
            // FastViT-HD output dim used by the 0.5B/1.5B/7B family) so a
            // missing field doesn't kill the whole load.
            self.hiddenSize =
                (try? c.decodeIfPresent(Int.self, forKey: .mmHiddenSize)).flatMap { $0 }
                ?? (try? c.decodeIfPresent(Int.self, forKey: .visionHiddenSize)).flatMap { $0 }
                ?? (try? c.decodeIfPresent(Int.self, forKey: .mmProjectorDim)).flatMap { $0 }
                ?? 3072
        }
    }

    public struct TextConfiguration: Decodable, Sendable {
        public let modelType: String
        public let hiddenSize: Int
        public let hiddenLayers: Int
        public let intermediateSize: Int
        public let attentionHeads: Int
        private let _rmsNormEps: Float?
        public var rmsNormEps: Float { _rmsNormEps ?? 1e-6 }
        public let vocabularySize: Int
        public let kvHeads: Int
        private let _maxPositionEmbeddings: Int?
        public var maxPositionEmbeddings: Int { _maxPositionEmbeddings ?? 32768 }
        private let _ropeTheta: Float?
        public var ropeTheta: Float { _ropeTheta ?? 1_000_000 }
        private let _ropeTraditional: Bool?
        public var ropeTraditional: Bool { _ropeTraditional ?? false }
        public let _ropeScaling: [String: StringOrNumber]?
        public var ropeScaling: [String: StringOrNumber]? {
            _ropeScaling ?? ["mrope_section": .ints([2, 1, 1])]
        }
        private let _tieWordEmbeddings: Bool?
        public var tieWordEmbeddings: Bool { _tieWordEmbeddings ?? true }

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case hiddenSize = "hidden_size"
            case hiddenLayers = "num_hidden_layers"
            case intermediateSize = "intermediate_size"
            case attentionHeads = "num_attention_heads"
            case _rmsNormEps = "rms_norm_eps"
            case vocabularySize = "vocab_size"
            case kvHeads = "num_key_value_heads"
            case _maxPositionEmbeddings = "max_position_embeddings"
            case _ropeTheta = "rope_theta"
            case _ropeTraditional = "rope_traditional"
            case _ropeScaling = "rope_scaling"
            case _tieWordEmbeddings = "tie_word_embeddings"
        }
    }

    public struct BaseConfiguration: Decodable, Sendable {
        public let modelType: String
        public let vocabularySize: Int
        public let imageTokenId: Int
        public let hiddenSize: Int

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
            case vocabularySize = "vocab_size"
            case imageTokenId = "image_token_index"
            case hiddenSize = "hidden_size"
        }

        public init(from decoder: any Swift.Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.modelType = try c.decode(String.self, forKey: .modelType)
            self.vocabularySize = try c.decode(Int.self, forKey: .vocabularySize)
            self.hiddenSize = try c.decode(Int.self, forKey: .hiddenSize)
            // image_token_index isn't always present on upstream FastVLM repo
            // forks. The published llava-fastvithd checkpoints use the value
            // -200 for the image placeholder token id — same as the FastVLM
            // reference implementation. Default to that when missing instead
            // of failing the whole load.
            self.imageTokenId = try c.decodeIfPresent(Int.self, forKey: .imageTokenId)
                ?? -200
        }
    }

    public let visionConfiguration: VisionConfiguration
    public let textConfiguration: TextConfiguration
    public let baseConfiguration: BaseConfiguration

    public init(from decoder: any Swift.Decoder) throws {
        self.visionConfiguration = try VisionConfiguration(from: decoder)
        self.textConfiguration = try TextConfiguration(from: decoder)
        self.baseConfiguration = try BaseConfiguration(from: decoder)
    }
}

// MARK: - FastVLMPreProcessorConfiguration

public struct FastVLMPreProcessorConfiguration: Codable, Sendable {

    public struct CropSize: Codable, Sendable {
        public let width: Int
        public let height: Int
        public var size: CGSize { .init(width: CGFloat(width), height: CGFloat(height)) }
    }

    public struct Size: Codable, Sendable {
        public let shortestEdge: Int
        enum CodingKeys: String, CodingKey {
            case shortestEdge = "shortest_edge"
        }
    }

    public var imageMean: [CGFloat]
    public var imageStd: [CGFloat]
    public var size: Size
    public var cropSize: CropSize

    public var imageMeanTuple: (CGFloat, CGFloat, CGFloat) {
        (imageMean[0], imageMean[1], imageMean[2])
    }
    public var imageStdTuple: (CGFloat, CGFloat, CGFloat) {
        (imageStd[0], imageStd[1], imageStd[2])
    }

    enum CodingKeys: String, CodingKey {
        case imageMean = "image_mean"
        case imageStd = "image_std"
        case size
        case cropSize = "crop_size"
    }
}

// MARK: - FastVLMProcessorConfiguration

public struct FastVLMProcessorConfiguration: Codable, Sendable {

    public enum Strategy: Codable, Sendable {
        case `default`
    }

    public var imageToken = "<image>"
    public var numAdditionalImageTokens = 0
    public var patchSize = 64
    public var visionFeatureSelectStrategy: Strategy?
}
