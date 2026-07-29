import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

// Nanbeige 4.2 is Llama-shaped, but its decoder layers execute repeatedly.
// A plain Llama alias loads the tensors yet skips half the trained depth.

private struct NanbeigeConfiguration: Codable, Sendable {
    let hiddenSize: Int
    let hiddenLayers: Int
    let intermediateSize: Int
    let attentionHeads: Int
    let headDimensions: Int?
    let rmsNormEps: Float
    let vocabularySize: Int
    let kvHeads: Int
    let maxPositionEmbeddings: Int?
    let ropeTheta: Float
    let tieWordEmbeddings: Bool
    let attentionBias: Bool
    let mlpBias: Bool
    let numLoops: Int
    let skipLoopFinalNorm: Bool

    var resolvedHeadDimensions: Int {
        headDimensions ?? (hiddenSize / attentionHeads)
    }

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case hiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case attentionHeads = "num_attention_heads"
        case headDimensions = "head_dim"
        case rmsNormEps = "rms_norm_eps"
        case vocabularySize = "vocab_size"
        case kvHeads = "num_key_value_heads"
        case maxPositionEmbeddings = "max_position_embeddings"
        case ropeTheta = "rope_theta"
        case tieWordEmbeddings = "tie_word_embeddings"
        case attentionBias = "attention_bias"
        case mlpBias = "mlp_bias"
        case numLoops = "num_loops"
        case skipLoopFinalNorm = "skip_loop_final_norm"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hiddenSize = try values.decode(Int.self, forKey: .hiddenSize)
        hiddenLayers = try values.decode(Int.self, forKey: .hiddenLayers)
        intermediateSize = try values.decode(Int.self, forKey: .intermediateSize)
        attentionHeads = try values.decode(Int.self, forKey: .attentionHeads)
        headDimensions = try values.decodeIfPresent(Int.self, forKey: .headDimensions)
        rmsNormEps = try values.decode(Float.self, forKey: .rmsNormEps)
        vocabularySize = try values.decode(Int.self, forKey: .vocabularySize)
        kvHeads = try values.decodeIfPresent(Int.self, forKey: .kvHeads) ?? attentionHeads
        maxPositionEmbeddings = try values.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings)
        ropeTheta = try values.decodeIfPresent(Float.self, forKey: .ropeTheta) ?? 10_000
        tieWordEmbeddings = try values.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? true
        attentionBias = try values.decodeIfPresent(Bool.self, forKey: .attentionBias) ?? false
        mlpBias = try values.decodeIfPresent(Bool.self, forKey: .mlpBias) ?? false
        numLoops = max(1, try values.decodeIfPresent(Int.self, forKey: .numLoops) ?? 1)
        skipLoopFinalNorm = try values.decodeIfPresent(Bool.self, forKey: .skipLoopFinalNorm) ?? false
    }
}

private final class NanbeigeAttention: Module {
    let configuration: NanbeigeConfiguration
    let scale: Float
    @ModuleInfo(key: "q_proj") var query: Linear
    @ModuleInfo(key: "k_proj") var key: Linear
    @ModuleInfo(key: "v_proj") var value: Linear
    @ModuleInfo(key: "o_proj") var output: Linear
    let rope: RoPELayer

    init(_ configuration: NanbeigeConfiguration) {
        self.configuration = configuration
        let hiddenSize = configuration.hiddenSize
        let headSize = configuration.resolvedHeadDimensions
        scale = pow(Float(headSize), -0.5)
        _query.wrappedValue = Linear(hiddenSize, configuration.attentionHeads * headSize, bias: configuration.attentionBias)
        _key.wrappedValue = Linear(hiddenSize, configuration.kvHeads * headSize, bias: configuration.attentionBias)
        _value.wrappedValue = Linear(hiddenSize, configuration.kvHeads * headSize, bias: configuration.attentionBias)
        _output.wrappedValue = Linear(configuration.attentionHeads * headSize, hiddenSize, bias: configuration.attentionBias)
        rope = initializeRope(
            dims: headSize, base: configuration.ropeTheta, traditional: false,
            scalingConfig: nil, maxPositionEmbeddings: configuration.maxPositionEmbeddings)
    }

    func callAsFunction(
        _ input: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cache: KVCache?
    ) -> MLXArray {
        let batch = input.dim(0)
        let length = input.dim(1)
        var queries = query(input).reshaped(batch, length, configuration.attentionHeads, -1).transposed(0, 2, 1, 3)
        var keys = key(input).reshaped(batch, length, configuration.kvHeads, -1).transposed(0, 2, 1, 3)
        let values = value(input).reshaped(batch, length, configuration.kvHeads, -1).transposed(0, 2, 1, 3)
        queries = applyRotaryPosition(rope, to: queries, offset: cache?.ropeOffset)
        keys = applyRotaryPosition(rope, to: keys, offset: cache?.ropeOffset)
        return output(
            attentionWithCacheUpdate(
                queries: queries, keys: keys, values: values,
                cache: cache, scale: scale, mask: mask)
            .transposed(0, 2, 1, 3)
            .reshaped(batch, length, -1)
        )
    }
}

private final class NanbeigeMLP: Module {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "down_proj") var down: Linear
    @ModuleInfo(key: "up_proj") var up: Linear

    init(_ configuration: NanbeigeConfiguration) {
        _gate.wrappedValue = Linear(configuration.hiddenSize, configuration.intermediateSize, bias: configuration.mlpBias)
        _down.wrappedValue = Linear(configuration.intermediateSize, configuration.hiddenSize, bias: configuration.mlpBias)
        _up.wrappedValue = Linear(configuration.hiddenSize, configuration.intermediateSize, bias: configuration.mlpBias)
    }

    func callAsFunction(_ input: MLXArray) -> MLXArray {
        down(silu(gate(input)) * up(input))
    }
}

private final class NanbeigeDecoderLayer: Module {
    @ModuleInfo(key: "self_attn") var attention: NanbeigeAttention
    @ModuleInfo(key: "mlp") var mlp: NanbeigeMLP
    @ModuleInfo(key: "input_layernorm") var inputNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionNorm: RMSNorm

    init(_ configuration: NanbeigeConfiguration) {
        _attention.wrappedValue = NanbeigeAttention(configuration)
        _mlp.wrappedValue = NanbeigeMLP(configuration)
        _inputNorm.wrappedValue = RMSNorm(dimensions: configuration.hiddenSize, eps: configuration.rmsNormEps)
        _postAttentionNorm.wrappedValue = RMSNorm(dimensions: configuration.hiddenSize, eps: configuration.rmsNormEps)
    }

    func callAsFunction(
        _ input: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode,
        cache: KVCache?
    ) -> MLXArray {
        let attended = input + attention(inputNorm(input), mask: mask, cache: cache)
        return attended + mlp(postAttentionNorm(attended))
    }
}

private final class NanbeigeModelInner: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    let layers: [NanbeigeDecoderLayer]
    let norm: RMSNorm
    let configuration: NanbeigeConfiguration

    init(_ configuration: NanbeigeConfiguration) {
        self.configuration = configuration
        _embedTokens.wrappedValue = Embedding(
            embeddingCount: configuration.vocabularySize,
            dimensions: configuration.hiddenSize)
        layers = (0 ..< configuration.hiddenLayers).map { _ in NanbeigeDecoderLayer(configuration) }
        norm = RMSNorm(dimensions: configuration.hiddenSize, eps: configuration.rmsNormEps)
    }

    func callAsFunction(_ tokens: MLXArray, cache: [KVCache]?) -> MLXArray {
        var hidden = embedTokens(tokens)
        for loop in 0 ..< configuration.numLoops {
            let firstCacheIndex = loop * configuration.hiddenLayers
            let firstCache = cache.flatMap { firstCacheIndex < $0.count ? $0[firstCacheIndex] : nil }
            let mask = createAttentionMask(h: hidden, cache: firstCache)
            for (layerIndex, layer) in layers.enumerated() {
                let cacheIndex = firstCacheIndex + layerIndex
                let layerCache = cache.flatMap { cacheIndex < $0.count ? $0[cacheIndex] : nil }
                hidden = layer(hidden, mask: mask, cache: layerCache)
            }
            if !configuration.skipLoopFinalNorm {
                hidden = norm(hidden)
            }
        }
        return configuration.skipLoopFinalNorm ? norm(hidden) : hidden
    }
}

private final class NanbeigeMLXModel: Module, LLMModel, KVCacheDimensionProvider {
    let vocabularySize: Int
    let kvHeads: [Int]
    let model: NanbeigeModelInner
    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    init(_ configuration: NanbeigeConfiguration) {
        vocabularySize = configuration.vocabularySize
        kvHeads = Array(
            repeating: configuration.kvHeads,
            count: configuration.hiddenLayers * configuration.numLoops)
        model = NanbeigeModelInner(configuration)
        if !configuration.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(configuration.hiddenSize, configuration.vocabularySize, bias: false)
        }
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        let result = model(inputs, cache: cache)
        return lmHead?(result) ?? model.embedTokens.asLinear(result)
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        weights.filter { !$0.key.contains("self_attn.rotary_emb.inv_freq") }
    }

    var loraLayers: [Module] {
        model.layers
    }
}

enum NanbeigeMLXRegistration {
    static func register() async {
        await LLMTypeRegistry.shared.registerModelType("nanbeige") { data in
            NanbeigeMLXModel(try JSONDecoder().decode(NanbeigeConfiguration.self, from: data))
        }
    }
}
