// MARK: - SmolVLM2Rescue
//
// Upstream `mlx-swift-examples` ships a broken `SmolVLMProcessor`: its
// `prepare(input:)` runs the input through `Qwen2VLMessageGenerator`
// and then through `tokenizer.applyChatTemplate`, then expects the
// rendered prompt to contain a single literal `<image>` token that it
// can substitute with a tile-expanded image prompt. There is a
// literal `// TODO: Create SmolVLM2MessageGenerator` comment at
// `Libraries/MLXVLM/Models/SmolVLM2.swift:224` and that TODO has been
// open since the model was added (March 2025). In practice the
// rendered prompt does not line up with what the
// `prepareInputsForMultimodal` step in `Idefics3.swift` expects, and
// inference crashes with an uncatchable Swift precondition (Index out
// of range inside `ContiguousArrayBuffer`).
//
// This file replaces the broken upstream processor with one that
// builds the prompt directly using SmolVLM2's chat format, skipping
// the chat-template-via-jinja step entirely. All of the surrounding
// machinery (tile splitting, pixel normalisation, the underlying
// `Idefics3` / `SmolVLM2` model class) stays untouched — only the
// processor's `prepare(input:)` is rewritten.
//
// Registration mirrors the FastVLM/LlavaProcessor pattern already in
// this codebase (see `FastVLM.register(modelFactory:)`):
// `ProcessorTypeRegistry.registerProcessorType` is a dictionary
// upsert, so writing "SmolVLMProcessor" with our creator overrides
// the upstream default. We register at app launch from
// `AppDelegate.application(_:didFinishLaunchingWithOptions:)`, before
// any model load can pull the registry.

import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
// `Tokenizer` resolves to MLXLMCommon's protocol (mlx-swift-lm 3.x); importing
// swift-transformers' `Tokenizers` here made the type ambiguous. Only
// `.encode(text:)` is used, which MLXLMCommon.Tokenizer provides.

// Video support is intentionally NOT mirrored here. Upstream
// `SmolVLMProcessor.prepare(input:)` has a video branch, but the
// `VideoFrame` and `ProcessedFrames` types only expose their CIImage /
// MLXArray storage with `internal` access — we cannot reconstruct
// them from outside the MLXVLM module. The CodeLens lens loop never
// feeds video into the processor (it streams CIImage frames as
// `input.images`), so dropping that branch is a correctness no-op
// here; the live-camera and describe paths only exercise the image
// branch.

/// Bridges our rescue processor into `VLMModelFactory.shared`.
enum SmolVLM2Rescue {

    /// Override the upstream "SmolVLMProcessor" creator so any model
    /// whose `processor_config.json` names `SmolVLMProcessor` (every
    /// SmolVLM2 variant on HuggingFace) loads through our processor.
    // mlx-swift-lm 3.x: `ProcessorTypeRegistry` is now an `actor` (async
    // registration) and creators receive the config `Data` directly (was a
    // `URL` in 2.x).
    static func register(modelFactory: VLMModelFactory) async {
        await modelFactory.processorRegistry.registerProcessorType("SmolVLMProcessor") { data, tokenizer in
            let config = try JSONDecoder().decode(
                SmolVLMProcessorConfiguration.self,
                from: data
            )
            return SmolVLM2RescueProcessor(config, tokenizer: tokenizer)
        }
    }
}

/// Drop-in replacement for upstream `SmolVLMProcessor`.
///
/// Layout mirrors the upstream class so any future audit against the
/// HuggingFace transformers reference stays one-to-one. The single
/// behavioural change is in `prepare(input:)` — we hand-render the
/// prompt instead of calling `tokenizer.applyChatTemplate` with the
/// Qwen2VL message generator, which is what produced the crash.
final class SmolVLM2RescueProcessor: UserInputProcessor {

    private let config: SmolVLMProcessorConfiguration
    private let tokenizer: any Tokenizer

    // Hardcoded SmolVLM2 special tokens — same values as upstream.
    // Verified against `added_tokens_decoder` in the tokenizer config
    // for `HuggingFaceTB/SmolVLM2-500M-Video-Instruct-mlx`.
    private let imageToken = "<image>"
    private let fakeImageToken = "<fake_token_around_image>"
    private let globalImageToken = "<global-img>"
    private let endOfUtterance = "<end_of_utterance>"
    private let bosToken = "<|im_start|>"

    private var maxProcessingImageSize: CGFloat { CGFloat(config.size.longestEdge) }
    private var fixedImageSize: CGFloat { CGFloat(config.maxImageSize.longestEdge) }
    private var imageSequenceLength: Int { config.imageSequenceLength }

    init(_ config: SmolVLMProcessorConfiguration, tokenizer: any Tokenizer) {
        self.config = config
        self.tokenizer = tokenizer
    }

    // MARK: - Public entry point

    public func prepare(input: UserInput) async throws -> LMInput {
        if input.images.isEmpty && input.videos.isEmpty {
            // Text-only — render the chat as a flat string, no image
            // expansion needed.
            let prompt = renderChat(from: input, imagePlaceholders: 0)
            return makeTextOnlyLMInput(prompt: prompt)
        }

        if !input.images.isEmpty && input.videos.isEmpty {
            guard input.images.count == 1 else {
                throw VLMError.singleImageAllowed
            }
            return try prepareSingleImage(input)
        }

        // Video path is intentionally unsupported (see the header
        // comment: VideoFrame/ProcessedFrames have internal storage,
        // and the lens pipeline doesn't feed video anyway).
        throw VLMError.singleMediaTypeAllowed
    }

    // MARK: - Image path

    private func prepareSingleImage(_ input: UserInput) throws -> LMInput {
        let raw = try input.images[0].asCIImage().toSRGB()
        let (tiles, rows, cols) = tiles(from: raw)

        // Append the resampled global image. Matches upstream
        // ordering: tiles in row-major then global last so the
        // language model sees the per-tile features before the
        // overview feature.
        let images = tiles + [
            raw.resampled(
                to: CGSize(width: fixedImageSize, height: fixedImageSize),
                method: .lanczos
            )
        ]

        let pixelsForImages = images.map {
            $0.normalized(mean: config.imageMeanTuple, std: config.imageStdTuple).asMLXArray()
        }
        // (N, C, H, W) -> (N, H, W, C). Same transposition upstream
        // performs; the Idefics3 vision encoder expects channels-last.
        let pixels = concatenated(pixelsForImages, axis: 0).transposed(0, 2, 3, 1)

        let imageBlock = expandedImagePrompt(rows: rows, cols: cols)
        let prompt = renderChat(from: input, imagePlaceholders: 1, imageBlock: imageBlock)

        let promptTokens = tokenizer.encode(text: prompt)
        let tokensArray = MLXArray(promptTokens).expandedDimensions(axis: 0)
        let mask = ones(like: tokensArray)

        return LMInput(
            text: .init(tokens: tokensArray, mask: mask),
            image: .init(pixels: pixels)
        )
    }

    // MARK: - Prompt construction
    //
    // We build the prompt string directly using SmolVLM2's chat
    // format (verified against the model's tokenizer_config.json
    // chat_template — see SmolVLM2Rescue.swift header for why we
    // bypass `applyChatTemplate`). The format, per turn:
    //
    //   <|im_start|>{Role}: {content}<end_of_utterance>\n
    //
    // and a final `Assistant:` to prime the generation. The
    // `<|im_start|>` token only appears once, at the very start —
    // it is the BOS marker, not a per-turn separator.

    private func renderChat(
        from input: UserInput,
        imagePlaceholders: Int,
        imageBlock: String = ""
    ) -> String {
        var rendered = bosToken
        let turns: [(role: String, text: String)] = extractTurns(input)

        // The image block (already tile-expanded) is inserted at the
        // start of the LAST user turn — that matches the upstream
        // behaviour of replacing the single `<image>` placeholder
        // that comes from the user's message content.
        let lastUserIdx = turns.lastIndex(where: { $0.role.lowercased() == "user" })

        for (i, turn) in turns.enumerated() {
            let role = turn.role.capitalized
            let isLastUser = (i == lastUserIdx)
            let needsImageBlock = isLastUser && imagePlaceholders > 0
            // SmolVLM2's template uses `:` (no space) when the first
            // content entry is an image, `: ` otherwise. We mirror that.
            let sep = needsImageBlock ? ":" : ": "
            rendered += "\(role)\(sep)"
            if needsImageBlock { rendered += imageBlock }
            rendered += turn.text
            rendered += endOfUtterance
            rendered += "\n"
        }

        rendered += "Assistant:"
        return rendered
    }

    private func extractTurns(_ input: UserInput) -> [(role: String, text: String)] {
        switch input.prompt {
        case .text(let text):
            return [(role: "user", text: text)]

        case .chat(let messages):
            return messages.map { (role: $0.role.rawValue, text: $0.content) }

        case .messages(let messages):
            return messages.map { msg in
                let role = (msg["role"] as? String) ?? "user"
                let text = extractText(fromContent: msg["content"])
                return (role: role, text: text)
            }
        }
    }

    /// Pulls the plain text out of either a `String` content payload
    /// or a `[[String: Any]]` content payload (transformers-style
    /// typed content list). Type-image entries are ignored — they're
    /// represented by `imageBlock` in `renderChat` instead, so we
    /// never want a stray `<image>` literal coming from a caller.
    private func extractText(fromContent content: Any?) -> String {
        if let s = content as? String { return s }
        guard let parts = content as? [[String: Any]] else { return "" }
        var out = ""
        for part in parts {
            guard let type = part["type"] as? String else { continue }
            if type == "text", let txt = part["text"] as? String {
                out += txt
            }
        }
        return out
    }

    private func makeTextOnlyLMInput(prompt: String) -> LMInput {
        let tokens = tokenizer.encode(text: prompt)
        let arr = MLXArray(tokens).expandedDimensions(axis: 0)
        return LMInput(text: .init(tokens: arr, mask: ones(like: arr)), image: nil)
    }

    // MARK: - Tile + image-prompt expansion
    //
    // These mirror the upstream `SmolVLMProcessor` helpers byte-for-
    // byte. They're private over there, so we have to copy.

    private func expandedImagePrompt(rows: Int, cols: Int) -> String {
        let seq = imageSequenceLength
        var out = ""
        for h in 0 ..< rows {
            for w in 0 ..< cols {
                out += fakeImageToken
                out += "<row_\(h + 1)_col_\(w + 1)>"
                out += String(repeating: imageToken, count: seq)
            }
            out += "\n"
        }
        out += "\n"
        out += fakeImageToken
        out += globalImageToken
        out += String(repeating: imageToken, count: seq)
        out += fakeImageToken
        return out
    }

    // MARK: - Tile splitting
    //
    // Same algorithm as upstream — splits an oversized input into a
    // grid of `fixedImageSize × fixedImageSize` tiles, snapping the
    // grid edges to multiples of the tile size first. y=0 is the
    // CIImage bottom, so we iterate rows in reverse to match the
    // Python transformers reference.

    private func tiles(from originalImage: CIImage) -> (tiles: [CIImage], rows: Int, cols: Int) {
        let processingSize = aspectRatioSize(
            for: originalImage.extent.size,
            longestEdge: maxProcessingImageSize,
            multiple: fixedImageSize
        )
        let image = MediaProcessing.resampleLanczos(originalImage, to: processingSize)

        let nRows = Int(ceil(image.extent.size.height / fixedImageSize))
        let nCols = Int(ceil(image.extent.size.width / fixedImageSize))
        let tileEdge = Int(fixedImageSize)

        var tiles: [CIImage] = []
        for row in (0 ..< nRows).reversed() {
            for col in 0 ..< nCols {
                let x0 = col * tileEdge
                let y0 = row * tileEdge
                let x1 = min(x0 + tileEdge, Int(image.extent.size.width))
                let y1 = min(y0 + tileEdge, Int(image.extent.size.height))
                tiles.append(image.cropped(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)))
            }
        }
        return (tiles, nRows, nCols)
    }

    private func aspectRatioSize(for size: CGSize, longestEdge: CGFloat, multiple: CGFloat?) -> CGSize {
        let targetSize = MediaProcessing.bestFit(size, in: CGSize(width: longestEdge, height: longestEdge))
        guard let multiple else { return targetSize }
        let aspect = targetSize.width / targetSize.height
        if size.width >= size.height {
            let width = ceil(targetSize.width / multiple) * multiple
            var height = width / aspect
            height = ceil(height / multiple) * multiple
            return CGSize(width: width, height: height)
        } else {
            let height = ceil(targetSize.height / multiple) * multiple
            var width = height * aspect
            width = ceil(width / multiple) * multiple
            return CGSize(width: width, height: height)
        }
    }
}
