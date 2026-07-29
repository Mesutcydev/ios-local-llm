import Foundation
import CoreGraphics

// MARK: - FastVLMConfig
// Centralized configuration for all FastVLM model I/O names, shapes, and special tokens.
//
// Architecture: LlavaQwen2 — FastViT-HD vision encoder + multimodal projector + Qwen2-0.5B LLM
//
// Model sources:
//   • fastvithd.mlpackage — from HuggingFace apple/FastVLM-0.5B-fp16 (already in bundle)
//   • Multimodal projector + Qwen2 LLM — downloaded as MLX weights via get_pretrained_mlx_model.sh
//     The ml-fastvlm project uses MLX Swift for the decoder, NOT a separate Core ML export.
//     See: https://github.com/apple/ml-fastvlm/tree/main/app
//
// NOTE on decoder export:
//   ml-fastvlm does NOT export the decoder to a Core ML mlpackage.
//   The official Apple app loads Qwen2 weights in MLX format and runs autoregressive
//   generation via mlx-swift-examples MLXLLM. There is no export_decoder.py script.
//   Only the vision encoder (fastvithd.mlpackage) is a Core ML asset.

enum FastVLMConfig {
    // MARK: - Model filenames
    static let encoderModelName  = "fastvithd"
    // MLX model directory (downloaded via get_pretrained_mlx_model.sh or
    // the in-app Download Center → "FastVLM MLX Weights" entry).
    static let mlxModelDirectory = "llava-fastvithd_0.5b_stage3_llm.fp16"

    // MARK: - Encoder I/O
    static let encoderInputName  = "images"
    static let encoderOutputName = "image_features"
    static let encoderInputSize  = CGSize(width: 1024, height: 1024)
    // Encoder output shape: [1, 256, 3072]  (256 patches, 3072-dim features)
    static let encoderNumPatches = 256
    static let encoderFeatureDim = 3072

    // MARK: - Qwen2-0.5B architecture constants
    static let numHiddenLayers   = 24
    static let hiddenSize        = 896
    static let numAttentionHeads = 14
    static let numKVHeads        = 2
    static let headDim           = 64       // hiddenSize / numAttentionHeads
    static let intermediateSize  = 4864
    static let vocabSize         = 151936

    // MARK: - Multimodal projector
    // Projects encoder output (3072) → Qwen2 hidden size (896) via linear + GELU
    static let projectorInputDim  = encoderFeatureDim   // 3072
    static let projectorOutputDim = hiddenSize          // 896

    // MARK: - Qwen2 special tokens (Qwen2/Qwen2.5 tokenizer)
    static let bosTokenId    = 151643   // <|endoftext|>
    static let eosTokenId    = 151645   // <|im_end|>
    static let padTokenId    = 151643
    static let imageTokenId  = 151646   // <image> placeholder

    // MARK: - Generation defaults
    static let defaultMaxTokens         = 512
    static let defaultTemperature: Float = 0.2
    static let defaultTopP: Float        = 0.9
    static let defaultRepetitionPenalty: Float = 1.05

    // MARK: - Qwen2 chat template tokens
    static let imStartToken = "<|im_start|>"
    static let imEndToken   = "<|im_end|>"
    static let imageToken   = "<image>"
}
