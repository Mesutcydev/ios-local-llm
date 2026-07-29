// Copyright © 2024 Apple Inc.

import Foundation
import Hub
import MLX
import MLXNN

// port of https://github.com/ml-explore/mlx-examples/blob/main/stable_diffusion/stable_diffusion/model_io.py

/// Configuration for loading stable diffusion weights.
///
/// These options can be tuned to conserve memory.
public struct LoadConfiguration: Sendable {

    /// convert weights to float16
    public var float16 = true

    /// quantize weights
    public var quantize = false

    public var dType: DType {
        float16 ? .float16 : .float32
    }

    public init(float16: Bool = true, quantize: Bool = false) {
        self.float16 = float16
        self.quantize = quantize
    }
}

/// Parameters for evaluating a stable diffusion prompt and generating latents
public struct EvaluateParameters: Sendable {

    /// `cfg` value from the preset
    public var cfgWeight: Float

    /// number of steps -- default is from the preset
    public var steps: Int

    /// number of images to generate at a time
    public var imageCount = 1
    public var decodingBatchSize = 1

    /// size of the latent tensor -- the result image is a factor of 8 larger than this
    public var latentSize = [64, 64]

    public var seed: UInt64
    public var prompt = ""
    public var negativePrompt = ""

    public init(
        cfgWeight: Float, steps: Int, imageCount: Int = 1, decodingBatchSize: Int = 1,
        latentSize: [Int] = [64, 64], seed: UInt64? = nil, prompt: String = "",
        negativePrompt: String = ""
    ) {
        self.cfgWeight = cfgWeight
        self.steps = steps
        self.imageCount = imageCount
        self.decodingBatchSize = decodingBatchSize
        self.latentSize = latentSize
        self.seed = seed ?? UInt64(Date.timeIntervalSinceReferenceDate * 1000)
        self.prompt = prompt
        self.negativePrompt = negativePrompt
    }
}

/// File types for ``StableDiffusionConfiguration/files``. Used by the presets to provide
/// relative file paths for different types of files.
enum FileKey {
    case unetConfig
    case unetWeights
    case textEncoderConfig
    case textEncoderWeights
    case textEncoderConfig2
    case textEncoderWeights2
    case vaeConfig
    case vaeWeights
    case diffusionConfig
    case tokenizerVocabulary
    case tokenizerMerges
    case tokenizerVocabulary2
    case tokenizerMerges2
}

/// Stable diffusion configuration -- this selects the model to load.
///
/// Use the preset values:
/// - ``presetSDXLTurbo``
/// - ``presetStableDiffusion21Base``
///
/// or use the enum (convenient for command line tools):
///
/// - ``Preset/sdxlTurbo``
/// - ``Preset/sdxlTurbo``
///
/// Call ``download(hub:progressHandler:)`` to download the weights, then
/// ``textToImageGenerator(hub:configuration:)`` or
/// ``imageToImageGenerator(hub:configuration:)`` to produce the ``ImageGenerator``.
///
/// The ``ImageGenerator`` has a method to generate the latents:
/// - ``TextToImageGenerator/generateLatents(parameters:)``
/// - ``ImageToImageGenerator/generateLatents(image:parameters:strength:)``
///
/// Evaluate each of the latents from that iterator and use the decoder to turn the last latent
/// into an image:
///
/// - ``ImageGenerator/decode(xt:)``
///
/// Finally use ``SDImage`` to save it to a file or convert to a CGImage for display.
public struct StableDiffusionConfiguration: Sendable {
    public let id: String
    let files: [FileKey: String]
    public let defaultParameters: @Sendable () -> EvaluateParameters
    let factory:
        @Sendable (HubApi, StableDiffusionConfiguration, LoadConfiguration) throws ->
            StableDiffusion

    public func download(
        hub: HubApi = HubApi(), progressHandler: @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let repo = Hub.Repo(id: self.id)
        try await hub.snapshot(
            from: repo, matching: Array(files.values), progressHandler: progressHandler)
    }

    public func textToImageGenerator(hub: HubApi = HubApi(), configuration: LoadConfiguration)
        throws -> TextToImageGenerator?
    {
        try factory(hub, self, configuration) as? TextToImageGenerator
    }

    public func imageToImageGenerator(hub: HubApi = HubApi(), configuration: LoadConfiguration)
        throws -> ImageToImageGenerator?
    {
        try factory(hub, self, configuration) as? ImageToImageGenerator
    }

    public enum Preset: String, Codable, CaseIterable, Sendable {
        case base
        case sdxlTurbo = "sdxl-turbo"
        // Added in IOSLocalLLM (vendored): extra SD/SDXL-architecture models that
        // ship the same diffusers layout the loaders expect.
        case sdTurbo = "sd-turbo"
        case ssd1b = "ssd-1b"
        case vega = "segmind-vega"
        case sd15 = "sd-1.5"
        case dreamShaper8 = "dreamshaper-8"

        public var configuration: StableDiffusionConfiguration {
            switch self {
            case .base: presetStableDiffusion21Base
            case .sdxlTurbo: presetSDXLTurbo
            case .sdTurbo: presetSDTurbo
            case .ssd1b: presetSSD1B
            case .vega: presetVega
            case .sd15: presetSD15
            case .dreamShaper8: presetDreamShaper8
            }
        }
    }

    /// See https://huggingface.co/stabilityai/sdxl-turbo for the model details and license
    public static let presetSDXLTurbo = StableDiffusionConfiguration(
        id: "stabilityai/sdxl-turbo",
        files: [
            .unetConfig: "unet/config.json",
            .unetWeights: "unet/diffusion_pytorch_model.fp16.safetensors",
            .textEncoderConfig: "text_encoder/config.json",
            .textEncoderWeights: "text_encoder/model.fp16.safetensors",
            .textEncoderConfig2: "text_encoder_2/config.json",
            .textEncoderWeights2: "text_encoder_2/model.fp16.safetensors",
            .vaeConfig: "vae/config.json",
            .vaeWeights: "vae/diffusion_pytorch_model.fp16.safetensors",
            .diffusionConfig: "scheduler/scheduler_config.json",
            .tokenizerVocabulary: "tokenizer/vocab.json",
            .tokenizerMerges: "tokenizer/merges.txt",
            .tokenizerVocabulary2: "tokenizer_2/vocab.json",
            .tokenizerMerges2: "tokenizer_2/merges.txt",
        ],
        defaultParameters: { EvaluateParameters(cfgWeight: 0, steps: 2) },
        factory: { hub, sdConfiguration, loadConfiguration in
            try StableDiffusionXL(
                hub: hub, configuration: sdConfiguration, dType: loadConfiguration.dType,
                quantizeOnLoad: loadConfiguration.quantize)
        }
    )

    /// See https://huggingface.co/stabilityai/stable-diffusion-2-1-base for the model details and license
    public static let presetStableDiffusion21Base = StableDiffusionConfiguration(
        id: "stabilityai/stable-diffusion-2-1-base",
        files: [
            .unetConfig: "unet/config.json",
            .unetWeights: "unet/diffusion_pytorch_model.safetensors",
            .textEncoderConfig: "text_encoder/config.json",
            .textEncoderWeights: "text_encoder/model.safetensors",
            .vaeConfig: "vae/config.json",
            .vaeWeights: "vae/diffusion_pytorch_model.safetensors",
            .diffusionConfig: "scheduler/scheduler_config.json",
            .tokenizerVocabulary: "tokenizer/vocab.json",
            .tokenizerMerges: "tokenizer/merges.txt",
        ],
        defaultParameters: { EvaluateParameters(cfgWeight: 7.5, steps: 50) },
        factory: { hub, sdConfiguration, loadConfiguration in
            try StableDiffusionBase(
                hub: hub, configuration: sdConfiguration, dType: loadConfiguration.dType,
                quantizeOnLoad: loadConfiguration.quantize)
        }
    )

    // MARK: - Additional models (added in IOSLocalLLM)
    //
    // These reuse the SAME loaders/factories as the two upstream presets — the
    // only differences are the repo `id` and default parameters. They ship the
    // identical diffusers file layout the loaders read (verified on the Hub),
    // so they load through the existing StableDiffusionBase / StableDiffusionXL
    // paths. SD-Turbo is SD-2.1 architecture; SSD-1B and Segmind-Vega are SDXL.

    /// stabilityai/sd-turbo — SD 2.1 architecture, distilled for 1-step
    /// generation. Ungated, fast, and the lightest text-to-image option.
    public static let presetSDTurbo = StableDiffusionConfiguration(
        id: "stabilityai/sd-turbo",
        files: [
            .unetConfig: "unet/config.json",
            .unetWeights: "unet/diffusion_pytorch_model.safetensors",
            .textEncoderConfig: "text_encoder/config.json",
            .textEncoderWeights: "text_encoder/model.safetensors",
            .vaeConfig: "vae/config.json",
            .vaeWeights: "vae/diffusion_pytorch_model.safetensors",
            .diffusionConfig: "scheduler/scheduler_config.json",
            .tokenizerVocabulary: "tokenizer/vocab.json",
            .tokenizerMerges: "tokenizer/merges.txt",
        ],
        defaultParameters: { EvaluateParameters(cfgWeight: 0, steps: 1) },
        factory: { hub, sdConfiguration, loadConfiguration in
            try StableDiffusionBase(
                hub: hub, configuration: sdConfiguration, dType: loadConfiguration.dType,
                quantizeOnLoad: loadConfiguration.quantize)
        }
    )

    /// stable-diffusion-v1-5/stable-diffusion-v1-5 — the canonical SD 1.5 model
    /// (ungated community mirror of the original RunwayML release). Standard SD
    /// architecture: cross-attention mid block, symmetric `transformer_layers_
    /// per_block`, CLIP-L (768) text encoder — i.e. the same family this
    /// `StableDiffusionBase` loader already drives for SD-2.1/SD-Turbo. Ships
    /// the full diffusers safetensors layout (verified on the Hub).
    public static let presetSD15 = StableDiffusionConfiguration(
        id: "stable-diffusion-v1-5/stable-diffusion-v1-5",
        files: [
            .unetConfig: "unet/config.json",
            .unetWeights: "unet/diffusion_pytorch_model.safetensors",
            .textEncoderConfig: "text_encoder/config.json",
            .textEncoderWeights: "text_encoder/model.safetensors",
            .vaeConfig: "vae/config.json",
            .vaeWeights: "vae/diffusion_pytorch_model.safetensors",
            .diffusionConfig: "scheduler/scheduler_config.json",
            .tokenizerVocabulary: "tokenizer/vocab.json",
            .tokenizerMerges: "tokenizer/merges.txt",
        ],
        defaultParameters: { EvaluateParameters(cfgWeight: 7.5, steps: 20) },
        factory: { hub, sdConfiguration, loadConfiguration in
            try StableDiffusionBase(
                hub: hub, configuration: sdConfiguration, dType: loadConfiguration.dType,
                quantizeOnLoad: loadConfiguration.quantize)
        }
    )

    /// Lykon/dreamshaper-8 — a popular, ungated SD 1.5 fine-tune tuned for
    /// crisp, artistic results. Identical architecture/layout to SD 1.5 (it is
    /// a fine-tune), so it loads through the same `StableDiffusionBase` path.
    public static let presetDreamShaper8 = StableDiffusionConfiguration(
        id: "Lykon/dreamshaper-8",
        files: [
            .unetConfig: "unet/config.json",
            .unetWeights: "unet/diffusion_pytorch_model.safetensors",
            .textEncoderConfig: "text_encoder/config.json",
            .textEncoderWeights: "text_encoder/model.safetensors",
            .vaeConfig: "vae/config.json",
            .vaeWeights: "vae/diffusion_pytorch_model.safetensors",
            .diffusionConfig: "scheduler/scheduler_config.json",
            .tokenizerVocabulary: "tokenizer/vocab.json",
            .tokenizerMerges: "tokenizer/merges.txt",
        ],
        defaultParameters: { EvaluateParameters(cfgWeight: 7, steps: 25) },
        factory: { hub, sdConfiguration, loadConfiguration in
            try StableDiffusionBase(
                hub: hub, configuration: sdConfiguration, dType: loadConfiguration.dType,
                quantizeOnLoad: loadConfiguration.quantize)
        }
    )

    /// segmind/SSD-1B — a 50%-distilled SDXL (~1.3B). SDXL architecture, ungated.
    public static let presetSSD1B = StableDiffusionConfiguration(
        id: "segmind/SSD-1B",
        files: [
            .unetConfig: "unet/config.json",
            .unetWeights: "unet/diffusion_pytorch_model.safetensors",
            .textEncoderConfig: "text_encoder/config.json",
            .textEncoderWeights: "text_encoder/model.safetensors",
            .textEncoderConfig2: "text_encoder_2/config.json",
            .textEncoderWeights2: "text_encoder_2/model.safetensors",
            .vaeConfig: "vae/config.json",
            .vaeWeights: "vae/diffusion_pytorch_model.safetensors",
            .diffusionConfig: "scheduler/scheduler_config.json",
            .tokenizerVocabulary: "tokenizer/vocab.json",
            .tokenizerMerges: "tokenizer/merges.txt",
            .tokenizerVocabulary2: "tokenizer_2/vocab.json",
            .tokenizerMerges2: "tokenizer_2/merges.txt",
        ],
        defaultParameters: { EvaluateParameters(cfgWeight: 7.5, steps: 20) },
        factory: { hub, sdConfiguration, loadConfiguration in
            try StableDiffusionXL(
                hub: hub, configuration: sdConfiguration, dType: loadConfiguration.dType,
                quantizeOnLoad: loadConfiguration.quantize)
        }
    )

    /// segmind/Segmind-Vega — a further-distilled SDXL (~0.74B); the smallest,
    /// fastest SDXL-family model here. SDXL architecture, ungated.
    public static let presetVega = StableDiffusionConfiguration(
        id: "segmind/Segmind-Vega",
        files: [
            .unetConfig: "unet/config.json",
            .unetWeights: "unet/diffusion_pytorch_model.safetensors",
            .textEncoderConfig: "text_encoder/config.json",
            .textEncoderWeights: "text_encoder/model.safetensors",
            .textEncoderConfig2: "text_encoder_2/config.json",
            .textEncoderWeights2: "text_encoder_2/model.safetensors",
            .vaeConfig: "vae/config.json",
            .vaeWeights: "vae/diffusion_pytorch_model.safetensors",
            .diffusionConfig: "scheduler/scheduler_config.json",
            .tokenizerVocabulary: "tokenizer/vocab.json",
            .tokenizerMerges: "tokenizer/merges.txt",
            .tokenizerVocabulary2: "tokenizer_2/vocab.json",
            .tokenizerMerges2: "tokenizer_2/merges.txt",
        ],
        defaultParameters: { EvaluateParameters(cfgWeight: 7, steps: 20) },
        factory: { hub, sdConfiguration, loadConfiguration in
            try StableDiffusionXL(
                hub: hub, configuration: sdConfiguration, dType: loadConfiguration.dType,
                quantizeOnLoad: loadConfiguration.quantize)
        }
    )

}

// MARK: - Key Mapping

func keyReplace(_ replace: String, _ with: String) -> @Sendable (String) -> String? {
    return { [replace, with] key in
        if key.contains(replace) {
            return key.replacingOccurrences(of: replace, with: with)
        }
        return nil
    }
}

func dropPrefix(_ prefix: String) -> @Sendable (String) -> String? {
    return { [prefix] key in
        if key.hasPrefix(prefix) {
            return String(key.dropFirst(prefix.count))
        }
        return nil
    }
}

// see map_unet_weights()

let unetRules: [@Sendable (String) -> String?] = [
    // Map up/downsampling
    keyReplace("downsamplers.0.conv", "downsample"),
    keyReplace("upsamplers.0.conv", "upsample"),

    // Map the mid block. Named (non-numeric) keys are required so these weights
    // unflatten into a `.dictionary` matching the `UNetMidBlock` Module subclass;
    // numeric keys would unflatten into an `.array` and fail to load. Keep these in
    // sync with the @ModuleInfo keys in UNet.swift's UNetMidBlock.
    keyReplace("mid_block.resnets.0", "mid_blocks.resnet0"),
    keyReplace("mid_block.attentions.0", "mid_blocks.attention0"),
    keyReplace("mid_block.resnets.1", "mid_blocks.resnet1"),

    // Map attention layers
    keyReplace("to_k", "key_proj"),
    keyReplace("to_out.0", "out_proj"),
    keyReplace("to_q", "query_proj"),
    keyReplace("to_v", "value_proj"),

    // Map transformer ffn
    keyReplace("ff.net.2", "linear3"),
]

func unetRemap(key: String, value: MLXArray) -> [(String, MLXArray)] {
    var key = key
    var value = value

    for rule in unetRules {
        key = rule(key) ?? key
    }

    // Map transformer ffn
    if key.contains("ff.net.0") {
        let k1 = key.replacingOccurrences(of: "ff.net.0.proj", with: "linear1")
        let k2 = key.replacingOccurrences(of: "ff.net.0.proj", with: "linear2")
        let (v1, v2) = value.split()
        return [(k1, v1), (k2, v2)]
    }

    if key.contains("conv_shortcut.weight") {
        value = value.squeezed()
    }

    // Transform the weights from 1x1 convs to linear
    if value.ndim == 4 && (key.contains("proj_in") || key.contains("proj_out")) {
        value = value.squeezed()
    }

    if value.ndim == 4 {
        value = value.transposed(0, 2, 3, 1)
        value = value.reshaped(-1).reshaped(value.shape)
    }

    return [(key, value)]
}

let clipRules: [@Sendable (String) -> String?] = [
    dropPrefix("text_model."),
    dropPrefix("embeddings."),
    dropPrefix("encoder."),

    // Map attention layers
    keyReplace("self_attn.", "attention."),
    keyReplace("q_proj.", "query_proj."),
    keyReplace("k_proj.", "key_proj."),
    keyReplace("v_proj.", "value_proj."),

    // Map ffn layers
    keyReplace("mlp.fc1", "linear1"),
    keyReplace("mlp.fc2", "linear2"),
]

func clipRemap(key: String, value: MLXArray) -> [(String, MLXArray)] {
    var key = key

    for rule in clipRules {
        key = rule(key) ?? key
    }

    // not used
    if key == "position_ids" {
        return []
    }

    return [(key, value)]
}

let vaeRules: [@Sendable (String) -> String?] = [
    // Map up/downsampling
    keyReplace("downsamplers.0.conv", "downsample"),
    keyReplace("upsamplers.0.conv", "upsample"),

    // Map attention layers
    keyReplace("to_k", "key_proj"),
    keyReplace("to_out.0", "out_proj"),
    keyReplace("to_q", "query_proj"),
    keyReplace("to_v", "value_proj"),

    // Map the mid block
    keyReplace("mid_block.resnets.0", "mid_blocks.0"),
    keyReplace("mid_block.attentions.0", "mid_blocks.1"),
    keyReplace("mid_block.resnets.1", "mid_blocks.2"),

    keyReplace("mid_blocks.1.key.", "mid_blocks.1.key_proj."),
    keyReplace("mid_blocks.1.query.", "mid_blocks.1.query_proj."),
    keyReplace("mid_blocks.1.value.", "mid_blocks.1.value_proj."),
    keyReplace("mid_blocks.1.proj_attn.", "mid_blocks.1.out_proj."),

]

func vaeRemap(key: String, value: MLXArray) -> [(String, MLXArray)] {
    var key = key
    var value = value

    for rule in vaeRules {
        key = rule(key) ?? key
    }

    // Map the quant/post_quant layers
    if key.contains("quant_conv") {
        key = key.replacingOccurrences(of: "quant_conv", with: "quant_proj")
        value = value.squeezed()
    }

    // Map the conv_shortcut to linear
    if key.contains("conv_shortcut.weight") {
        value = value.squeezed()
    }

    if value.ndim == 4 {
        value = value.transposed(0, 2, 3, 1)
        value = value.reshaped(-1).reshaped(value.shape)
    }

    return [(key, value)]
}

func loadWeights(
    url: URL, model: Module, mapper: (String, MLXArray) -> [(String, MLXArray)], dType: DType
) throws {
    let weights = try loadArrays(url: url).flatMap { mapper($0.key, $0.value.asType(dType)) }

    // Note: not using verifier because some shapes change upon load
    try model.update(parameters: ModuleParameters.unflattened(weights), verify: .none)
}

// MARK: - Loading

func resolve(hub: HubApi, configuration: StableDiffusionConfiguration, key: FileKey) -> URL {
    precondition(
        configuration.files[key] != nil, "configuration \(configuration.id) missing key: \(key)")
    let repo = Hub.Repo(id: configuration.id)
    let directory = hub.localRepoLocation(repo)
    return directory.appending(component: configuration.files[key]!)
}

func loadConfiguration<T: Decodable>(
    hub: HubApi, configuration: StableDiffusionConfiguration, key: FileKey, type: T.Type
) throws -> T {
    let url = resolve(hub: hub, configuration: configuration, key: key)
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

func loadUnet(hub: HubApi, configuration: StableDiffusionConfiguration, dType: DType) throws
    -> UNetModel
{
    let unetConfiguration = try loadConfiguration(
        hub: hub, configuration: configuration, key: .unetConfig, type: UNetConfiguration.self)
    let model = UNetModel(configuration: unetConfiguration)

    let weightsURL = resolve(hub: hub, configuration: configuration, key: .unetWeights)
    try loadWeights(url: weightsURL, model: model, mapper: unetRemap, dType: dType)

    return model
}

func loadTextEncoder(
    hub: HubApi, configuration: StableDiffusionConfiguration,
    configKey: FileKey = .textEncoderConfig, weightsKey: FileKey = .textEncoderWeights, dType: DType
) throws -> CLIPTextModel {
    let clipConfiguration = try loadConfiguration(
        hub: hub, configuration: configuration, key: configKey,
        type: CLIPTextModelConfiguration.self)
    let model = CLIPTextModel(configuration: clipConfiguration)

    let weightsURL = resolve(hub: hub, configuration: configuration, key: weightsKey)
    try loadWeights(url: weightsURL, model: model, mapper: clipRemap, dType: dType)

    return model
}

func loadAutoEncoder(hub: HubApi, configuration: StableDiffusionConfiguration, dType: DType) throws
    -> Autoencoder
{
    let autoEncoderConfiguration = try loadConfiguration(
        hub: hub, configuration: configuration, key: .vaeConfig, type: AutoencoderConfiguration.self
    )
    let model = Autoencoder(configuration: autoEncoderConfiguration)

    let weightsURL = resolve(hub: hub, configuration: configuration, key: .vaeWeights)
    try loadWeights(url: weightsURL, model: model, mapper: vaeRemap, dType: dType)

    return model
}

func loadDiffusionConfiguration(hub: HubApi, configuration: StableDiffusionConfiguration) throws
    -> DiffusionConfiguration
{
    try loadConfiguration(
        hub: hub, configuration: configuration, key: .diffusionConfig,
        type: DiffusionConfiguration.self)
}

// MARK: - Tokenizer

func loadTokenizer(
    hub: HubApi, configuration: StableDiffusionConfiguration,
    vocabulary: FileKey = .tokenizerVocabulary, merges: FileKey = .tokenizerMerges
) throws -> CLIPTokenizer {
    let vocabularyURL = resolve(hub: hub, configuration: configuration, key: vocabulary)
    let mergesURL = resolve(hub: hub, configuration: configuration, key: merges)

    let vocabulary = try JSONDecoder().decode(
        [String: Int].self, from: Data(contentsOf: vocabularyURL))
    let merges = try String(contentsOf: mergesURL, encoding: .utf8)
        .components(separatedBy: .newlines)
        // first line is a comment
        .dropFirst()
        .filter { !$0.isEmpty }

    return CLIPTokenizer(merges: merges, vocabulary: vocabulary)
}
