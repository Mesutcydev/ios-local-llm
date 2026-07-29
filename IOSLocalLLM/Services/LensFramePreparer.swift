import Foundation
import CoreImage
import CoreVideo
import UIKit
import os         // OSAllocatedUnfairLock

// MARK: - LensFramePreparer
//
// CVPixelBuffer (from CameraService delegate) → CIImage (ready for
// UserInput.Image.ciImage(_:) and the VLM processor).
//
// Three things this layer guarantees that the raw camera buffer
// does NOT:
//
//   1. YpCbCr biplanar input is handled via CIImage(cvPixelBuffer:)
//      ONLY. Never reach for raw bytes — that path assumes BGRA and
//      will produce green/magenta-shifted tensors on this camera
//      session's pixel format (kCVPixelFormatType_420YpCbCr8Bi-
//      PlanarFullRange).
//
//   2. World-up matches buffer-up regardless of physical device
//      orientation. The connection rotation (videoRotationAngle = 90)
//      locks buffers to portrait — but when the user is holding the
//      phone landscape to scan a wide document, the world is sideways
//      *inside* that portrait-locked buffer. We re-derive the right
//      CGImagePropertyOrientation from UIDevice.orientation and
//      apply it via CIImage.oriented(_:).
//
//   3. Color space is forced to sRGB. Newer iPhones deliver Display
//      P3; without this step CLIP/ImageNet normalization sees
//      over-saturated pixels and degrades silently.
//
// Then per-strategy resize. CILanczosScaleTransform — sharper text
// edges than CIAffineTransform when downsampling.
//
// Single entry point: `prepare(pixelBuffer:capabilities:usage:frameIndex:)`.
// Stateless apart from the DEBUG diagnostic snapshot (which the lens
// debug overlay reads to render its live readout).
//
// Threading: called on `CameraService.processingQueue` (serial,
// .userInteractive). Returns a CIImage ready to wrap in
// UserInput.Image.ciImage(_:). The CIImage's pixel data is realized
// (one concrete render through an sRGB CIContext per frame); all
// upstream operations — orientation, resize — are lazy and folded
// into that single render.

enum LensFramePreparer {

    // MARK: - Usage

    /// Pixel-budget selector. Streaming = live camera loop, latency-
    /// sensitive. Still = captureHighResFrame() path, fidelity-
    /// sensitive. Maps to `recommendedStreamingPixels` /
    /// `recommendedStillPixels` on VLMCapabilities.
    enum Usage { case streaming, still }

    // MARK: - Static state
    //
    // sRGB context is built once, reused for every render. Constructing
    // a CIContext per-frame would push Metal device/queue allocation
    // into the hot path. Single context = single Metal queue, no
    // per-frame allocation, no Metal-state contention with the VLM
    // since they're on different command queues.

    private static let sRGB: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private static let sRGBContext: CIContext = {
        // workingColorSpace forces all CI filter graphs feeding into a
        // render through this context to evaluate in sRGB. outputColor-
        // Space tags the resulting CGImage as sRGB so the round-trip
        // back into CIImage carries that information forward.
        CIContext(options: [
            .workingColorSpace: sRGB,
            .outputColorSpace:  sRGB,
        ])
    }()

    // MARK: - Debug diagnostic snapshot
    //
    // The lens debug overlay (LensDebugOverlay.swift, step 5) reads
    // this to render a live readout of what the preparer did to the
    // last frame. Written from the camera queue, read from the main
    // queue — guarded by OSAllocatedUnfairLock so the cross-queue
    // read is well-defined.

    struct DebugInfo: Equatable, Sendable {
        let sourceWidth: Int
        let sourceHeight: Int
        let deviceOrientation: UIDeviceOrientation
        let appliedOrientation: CGImagePropertyOrientation
        let outputWidth: Int
        let outputHeight: Int
        let colorSpace: String        // always "sRGB" by construction
        let strategySummary: String   // VLMCapabilities.description
        let frameIndex: Int
        let preparedAt: Date
    }

    private static let _lastDebugInfo = OSAllocatedUnfairLock<DebugInfo?>(initialState: nil)

    /// Most recent prep snapshot, or nil if `prepare(...)` hasn't run
    /// yet. Safe to read from any thread.
    static var lastDebugInfo: DebugInfo? {
        _lastDebugInfo.withLock { $0 }
    }

    // MARK: - Entry point

    /// Prepare a camera frame for VLM ingest. Steps run in order:
    ///
    ///   1. CIImage(cvPixelBuffer:)      — handles YpCbCr biplanar
    ///   2. .oriented(_:)                 — world-up correction
    ///   3. resize via CILanczosScale     — strategy-dependent
    ///   4. render through sRGB context   — single concrete render,
    ///                                       folds steps 1-3
    ///
    /// Returns a CIImage backed by realized sRGB pixels at the model-
    /// appropriate resolution. The caller wraps it in
    /// `UserInput.Image.ciImage(prepared)` and hands to the model
    /// container's `processor.prepare(input:)`.
    ///
    /// On any failure the function returns a best-effort CIImage
    /// rather than throwing — frame-drop is fine, but propagating
    /// errors up a 30-fps loop would just produce a stream of caught
    /// exceptions for the same root cause.
    static func prepare(
        pixelBuffer: CVPixelBuffer,
        capabilities: VLMCapabilities,
        usage: Usage = .streaming,
        frameIndex: Int = 0
    ) -> CIImage {

        // Step 1 — wrap the YpCbCr biplanar buffer. CIImage handles
        // the color-component conversion lazily during render; no
        // CVPixelBufferLockBaseAddress, no manual byte access, no
        // BGRA assumption.
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceWidth  = Int(source.extent.width)
        let sourceHeight = Int(source.extent.height)

        // Step 2 — world-orientation correction. The buffer is
        // connection-locked to portrait; if the device is physically
        // landscape, the world content inside the buffer is rotated
        // and must be un-rotated here.
        let deviceOrient = currentDeviceOrientation()
        let cgOrient = correctedOrientation(for: deviceOrient)
        let oriented = source.oriented(cgOrient)

        // Step 2.5 — fit the long edge to the model's tile size.
        // Aspect-preserved, scales UP or DOWN as needed. Same
        // rationale as `LensInferenceLoop.describe()`: tile-split
        // mode is triggered by either dimension exceeding the
        // model's max_image_size, and mlx-swift-examples'
        // downstream Swift code doesn't always handle multi-tile
        // counts consistently (broadcast_shapes / Index out of
        // range). Pinning the long edge at tile_size keeps the
        // input in single-tile mode for every aspect ratio.
        //
        // Trade-off: for very large camera frames we lose detail
        // by scaling down to 384 long-edge. For streaming at 30+
        // fps the latency win is worth it; if quality regresses
        // noticeably we revisit by properly supporting multi-tile,
        // which requires upstream changes.
        //
        // (`.dynamicPatchAligned` doesn't take this path — Qwen-VL
        // family handles dynamic inputs natively via the patch-
        // align logic in `alignedToPatchGrid`, no tile split.)
        let modelTileSize = Self.modelMinimumSide(for: capabilities)
        let sized = Self.fitToTileLongEdge(oriented, tileSize: modelTileSize)

        // Step 3 — strategy-aware resize. Lazy filter graph; not
        // realized until the sRGB context renders it below.
        let budget = (usage == .streaming)
            ? capabilities.recommendedStreamingPixels
            : capabilities.recommendedStillPixels
        let resized = resized(sized, capabilities: capabilities, pixelBudget: budget)

        // Step 4 — concrete render through the sRGB context. This is
        // the ONLY render in the pipeline; everything upstream is a
        // lazy CIImage graph that gets folded into this single GPU
        // pass. Result is small (post-resize) and carries explicit
        // sRGB tagging that downstream consumers respect.
        let final = renderThroughSRGB(resized) ?? resized
        let outputWidth  = Int(final.extent.width)
        let outputHeight = Int(final.extent.height)

        // Diagnostic snapshot. Written under lock so the debug overlay
        // can safely read from main without a torn struct.
        let info = DebugInfo(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight,
            deviceOrientation: deviceOrient,
            appliedOrientation: cgOrient,
            outputWidth: outputWidth, outputHeight: outputHeight,
            colorSpace: "sRGB",
            strategySummary: capabilities.description,
            frameIndex: frameIndex,
            preparedAt: Date()
        )
        _lastDebugInfo.withLock { $0 = info }

        #if DEBUG
        debugLogIfNeeded(info)
        #endif

        return final
    }

    // MARK: - Orientation correction

    /// Read the current device orientation. When `UIDevice.current.orientation`
    /// is `.unknown`/`.faceUp`/`.faceDown` — common at launch and lying flat —
    /// default to `.portrait`.
    ///
    /// This runs on the camera queue (CameraService.processingQueue), so it
    /// must NOT touch `UIApplication`/`UIWindowScene.interfaceOrientation`,
    /// which are main-actor isolated (the old interface-orientation fallback
    /// read them off-main — a concurrency violation that could return stale
    /// values). The app is portrait-locked and the capture connection rotation
    /// already pins the buffer to portrait, so `.portrait` is the correct
    /// indeterminate-case default with no behavior change.
    private static func currentDeviceOrientation() -> UIDeviceOrientation {
        let raw = UIDevice.current.orientation
        if raw.isValidInterfaceOrientation { return raw }
        return .portrait
    }

    /// Map device orientation to the CGImagePropertyOrientation that
    /// makes the camera buffer's world-content upright in the bitmap.
    ///
    /// Full reasoning (so this can be audited without re-deriving):
    /// The connection's 90° rotation maps the sensor's native
    /// landscape-right frame to portrait-up. When the device is in
    /// `.portrait`, the buffer's "up" already matches the world's
    /// "up" — `.up` is right. When the device rotates to
    /// `.portraitUpsideDown`, the buffer stays portrait-locked
    /// (connection rotation is fixed), but the world content inside
    /// it is now upside-down relative to buffer-up — `.down`
    /// recovers it. The landscape cases work the same way: device
    /// in `.landscapeLeft` means the user holds the phone with the
    /// home indicator on the right, putting world-up to the left of
    /// buffer-up — `.left` rotates the bitmap so world-up becomes
    /// image-up.
    ///
    ///   device portrait              → .up
    ///   device portraitUpsideDown    → .down
    ///   device landscapeLeft         → .left
    ///   device landscapeRight        → .right
    ///
    /// Validation method: point the camera at a sheet of paper with
    /// "↑" drawn on it, hold the phone in each of the four
    /// orientations, confirm the model reads the arrow as up. The
    /// arrow is more diagnostic than text — text is readable upside-
    /// down by a tilted head, an arrow forces an unambiguous answer.
    /// If the model reports the arrow as "down" or "right" in any
    /// orientation, swap the two landscape mappings here; the DEBUG
    /// log prints device + applied CG orientation per frame so the
    /// diagnosis is one glance.
    private static func correctedOrientation(for device: UIDeviceOrientation) -> CGImagePropertyOrientation {
        switch device {
        case .portrait:            return .up
        case .portraitUpsideDown:  return .down
        case .landscapeLeft:       return .left
        case .landscapeRight:      return .right
        case .faceUp, .faceDown, .unknown:
            return .up
        @unknown default:          return .up
        }
    }

    // MARK: - sRGB render

    /// Realize the lazy CIImage graph through the sRGB CIContext,
    /// producing a small CGImage tagged sRGB. Wrap that back into a
    /// CIImage so the rest of the pipeline keeps its CI-native type.
    /// Returns nil only under memory pressure (createCGImage fails);
    /// the caller falls back to the un-rendered graph in that case.
    private static func renderThroughSRGB(_ image: CIImage) -> CIImage? {
        // RGBA8 is the smallest format CoreImage will accept that
        // preserves enough precision for VLM normalization; RGBAh
        // would be lossless but doubles memory for no fidelity win
        // at this resolution. sRGB tagging on the output color space
        // is what makes the downstream MLX-VLM processor see correct
        // bytes.
        guard let cg = sRGBContext.createCGImage(
            image,
            from: image.extent,
            format: .RGBA8,
            colorSpace: sRGB
        ) else {
            return nil
        }
        return CIImage(cgImage: cg)
    }

    // MARK: - Resize

    /// Strategy dispatcher. Each branch hands off to the helper that
    /// matches the model family's expectations.
    private static func resized(
        _ image: CIImage,
        capabilities: VLMCapabilities,
        pixelBudget: Int
    ) -> CIImage {
        let w = image.extent.width
        let h = image.extent.height
        guard w > 0 && h > 0 else { return image }

        switch capabilities.inputSizingStrategy {

        case .fixed(let target):
            // Long edge → 2× the model's target side. The processor's
            // own bicubic-to-square step does the final precise resize
            // from a clean intermediate. Doing the precise resize here
            // ourselves would mean the processor downscales again,
            // throwing away sub-pixel information twice.
            let targetLong = 2.0 * Double(max(target.width, target.height))
            let longEdge = max(w, h)
            let scale = min(1.0, targetLong / Double(longEdge))
            return lanczos(image, scale: CGFloat(scale))

        case .dynamicPatchAligned(let patch, let merge, let minPx, let maxPx):
            // Two-step constraint:
            //   (a) Scale total pixels under min(streamingBudget, maxPx).
            //   (b) Round each dimension to a multiple of patch*merge.
            //
            // Step (b) is the load-bearing one for Qwen2-VL —
            // non-aligned inputs hit a fallback path in the model that
            // silently mangles spatial reasoning (no error, just bad
            // outputs). Pre-aligning here keeps the processor on its
            // happy path.
            let cap = min(pixelBudget, maxPx)
            let scale = scaleForPixelBudget(w: w, h: h, budget: cap)
            let scaled = lanczos(image, scale: scale)
            return alignedToPatchGrid(scaled, alignment: patch * merge, minPixels: minPx)

        case .anyresTiling(let base, _):
            // LLaVA 1.6 — bestFit-scale to 2*baseSize, processor picks
            // the grid from its pinpoints. The 2× factor is the same
            // logic as `.fixed`: give the processor a clean intermediate.
            let targetLong = 2.0 * Double(base)
            let longEdge = max(w, h)
            let scale = min(1.0, targetLong / Double(longEdge))
            return lanczos(image, scale: CGFloat(scale))

        case .fixedTiling(let tile, let maxTiles):
            // ceil(w/tile)*ceil(h/tile) <= maxTiles is the actual
            // constraint, but solving for it exactly requires aspect-
            // aware bin-packing. A simpler conservative approach:
            // scale total pixels under maxTiles*tile², which always
            // satisfies the tile-count constraint and is at most one
            // tile's worth of pixels over-conservative. Also clamp by
            // the streaming budget independently.
            let tilePixelBudget = maxTiles * tile * tile
            let cap = min(pixelBudget, tilePixelBudget)
            let scale = scaleForPixelBudget(w: w, h: h, budget: cap)
            return lanczos(image, scale: scale)
        }
    }

    /// Per-tile target side the model's processor expects. Mirrors
    /// `LensInferenceLoop.resizeHintSide(for:)` — the two should
    /// always agree. TODO: hoist to `VLMCapabilities.modelMinimum-
    /// Side` so there's one source of truth instead of two.
    private static func modelMinimumSide(for caps: VLMCapabilities) -> Int {
        switch caps.inputSizingStrategy {
        case .fixed(let s):                 return Int(max(s.width, s.height))
        case .dynamicPatchAligned:          return Int(Double(caps.recommendedStreamingPixels).squareRoot().rounded())
        case .anyresTiling(let base, _):    return base
        case .fixedTiling(let tile, _):     return tile
        }
    }

    /// Aspect-preserved scale so the LONG edge equals `tileSize`.
    /// Scales UP or DOWN. Mirrors
    /// `LensInferenceLoop.fitToTileLongEdge` for the CIImage type;
    /// see that function's comment for the full rationale on why
    /// long-edge-targeting beats short-edge-targeting for
    /// `.fixedTiling` strategy.
    ///
    /// The CIImage graph stays lazy — actual GPU pass is the single
    /// sRGB render at the end of `prepare`.
    private static func fitToTileLongEdge(_ image: CIImage, tileSize: Int) -> CIImage {
        let w = image.extent.width
        let h = image.extent.height
        let longEdge = max(w, h)
        guard longEdge > 0 else { return image }
        let target = CGFloat(tileSize)
        // Exact match: no-op. CGFloat comparison is fine here since
        // longEdge is an integer pixel count.
        if longEdge == target { return image }
        let scale = target / longEdge
        return lanczos(image, scale: scale, allowUpscale: true)
    }

    /// Scale factor that fits (w*h) under `budget` total pixels.
    /// Returns 1.0 when input is already under budget — never upscale
    /// in the budget path. The dynamicPatchAligned floor (below) is
    /// the one place this preparer ever scales UP.
    private static func scaleForPixelBudget(w: CGFloat, h: CGFloat, budget: Int) -> CGFloat {
        let total = Double(w * h)
        let cap = Double(budget)
        if total <= cap { return 1.0 }
        return CGFloat((cap / total).squareRoot())
    }

    /// Round both dimensions DOWN to a multiple of `alignment`. If
    /// the resulting pixel count would fall below `minPixels`, scale
    /// the image UP first using Lanczos, then re-align. This is the
    /// only path in the preparer that can upscale, and it's only
    /// reachable for dynamicPatchAligned models with very small
    /// inputs (rare in the streaming camera case; possible for
    /// imported thumbnails).
    ///
    /// Crop is from the image origin (lower-left in CIImage coords),
    /// not centered. For a `patch * merge = 28`-aligned model the
    /// crop loses at most 27 px per dimension — a single-digit
    /// percentage of frame at any sensible streaming resolution.
    /// At that magnitude, origin vs center is a wash for model
    /// accuracy; origin won on simpler arithmetic and predictable
    /// origin invariance (so the orientation step we ran earlier
    /// doesn't get spatially shifted by an offset-based center
    /// crop). Don't revisit this expecting a real improvement —
    /// the crop is too small to matter.
    private static func alignedToPatchGrid(
        _ image: CIImage,
        alignment: Int,
        minPixels: Int
    ) -> CIImage {
        let w = Int(image.extent.width)
        let h = Int(image.extent.height)
        let alignedW = max(alignment, (w / alignment) * alignment)
        let alignedH = max(alignment, (h / alignment) * alignment)
        if alignedW * alignedH >= minPixels {
            // Common case: aligned dimensions still satisfy minPixels.
            // Crop from the same origin so the orientation we applied
            // earlier doesn't get effectively undone by an origin shift.
            return image.cropped(to: CGRect(
                x: image.extent.origin.x,
                y: image.extent.origin.y,
                width: CGFloat(alignedW),
                height: CGFloat(alignedH)
            ))
        }
        // Floor case: bump the image up so the aligned crop hits
        // minPixels. The factor is the smallest scale that makes
        // alignedW' * alignedH' >= minPixels, derived analytically.
        let upScale = CGFloat(sqrt(Double(minPixels) / Double(max(alignedW * alignedH, 1))))
        let upscaled = lanczos(image, scale: upScale, allowUpscale: true)
        let uw = Int(upscaled.extent.width)
        let uh = Int(upscaled.extent.height)
        let aw = max(alignment, (uw / alignment) * alignment)
        let ah = max(alignment, (uh / alignment) * alignment)
        return upscaled.cropped(to: CGRect(
            x: upscaled.extent.origin.x,
            y: upscaled.extent.origin.y,
            width: CGFloat(aw),
            height: CGFloat(ah)
        ))
    }

    /// CILanczosScaleTransform wrapper. Lanczos beats affine for
    /// downsampling text — sharper edges, less ringing on thin
    /// glyphs. `aspectRatio = 1` preserves the input aspect; the
    /// scale parameter applies uniformly. Skip the filter (returns
    /// the input unchanged) when the resize would lose strictly less
    /// than one pixel from the smaller dimension, or for any upscale
    /// unless explicitly allowed.
    private static func lanczos(
        _ image: CIImage,
        scale: CGFloat,
        allowUpscale: Bool = false
    ) -> CIImage {
        guard scale > 0 else { return image }
        // Skip threshold calibrated to the image's shorter dimension:
        // pixels_lost = shortSide × (1 - scale), so 1 - scale ≤ 1/shortSide
        // guarantees zero pixel loss when we skip. A flat 0.999
        // threshold would let a 4K frame skip Lanczos while quietly
        // dropping ~2 rows of pixels — this formula closes that gap
        // adaptively. For a 2160 short side the threshold is ~0.99954;
        // for 512 it's ~0.99805.
        let shortSide = max(Double(min(image.extent.width, image.extent.height)), 1.0)
        let skipThreshold = 1.0 - 1.0 / shortSide
        if Double(scale) >= skipThreshold && !allowUpscale {
            #if DEBUG
            // Diagnostic line for the validation pass: the streaming
            // path with SmolVLM2 fixedTiling(384,4) against a 4K-
            // downscaled input should NEVER reach this branch — total
            // pixels are always over budget so scale is always well
            // under 1.0. Seeing this fire on streaming = budget math
            // is broken. Rate-limited via the same orientation-log
            // throttle so a one-shot describe on a small input
            // (the legitimate skip case) doesn't flood at 30 fps.
            debugLogLanczosSkipIfNeeded(scale: Double(scale), shortSide: Int(shortSide))
            #endif
            return image
        }
        guard let f = CIFilter(name: "CILanczosScaleTransform") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(NSNumber(value: Double(scale)), forKey: kCIInputScaleKey)
        f.setValue(NSNumber(value: 1.0),           forKey: kCIInputAspectRatioKey)
        return f.outputImage ?? image
    }

    // MARK: - Debug logging
    //
    // The user spec asks for both the input device orientation and
    // the applied CGImagePropertyOrientation in DEBUG. Log on every
    // orientation change AND at most once per second otherwise — at
    // 30+ fps, logging every frame would flood the console.

    #if DEBUG
    private static let _logState = OSAllocatedUnfairLock<(
        lastOrient: UIDeviceOrientation?,
        lastLogged: Date
    )>(initialState: (nil, .distantPast))

    private static let _lanczosSkipLogState = OSAllocatedUnfairLock<Date>(initialState: .distantPast)

    private static func debugLogLanczosSkipIfNeeded(scale: Double, shortSide: Int) {
        let shouldLog: Bool = _lanczosSkipLogState.withLock { last in
            let oldEnough = Date().timeIntervalSince(last) > 1.0
            if oldEnough { last = Date(); return true }
            return false
        }
        guard shouldLog else { return }
        print("[LensFramePreparer] LANCZOS skip scale=\(String(format: "%.4f", scale)) shortSide=\(shortSide)")
    }

    private static func debugLogIfNeeded(_ info: DebugInfo) {
        let shouldLog: Bool = _logState.withLock { state -> Bool in
            let orientChanged = state.lastOrient != info.deviceOrientation
            let oldEnough = Date().timeIntervalSince(state.lastLogged) > 1.0
            if orientChanged || oldEnough {
                state = (info.deviceOrientation, Date())
                return true
            }
            return false
        }
        guard shouldLog else { return }
        print("""
              [LensFramePreparer] frame=\(info.frameIndex) \
              device=\(info.deviceOrientation.shortName) → \
              cgOrient=\(info.appliedOrientation.shortName) \
              src=\(info.sourceWidth)×\(info.sourceHeight) → \
              out=\(info.outputWidth)×\(info.outputHeight) \
              cs=\(info.colorSpace)
              """
            .replacingOccurrences(of: "\n", with: " "))
    }
    #endif
}

// MARK: - Short-name extensions for debug logging

#if DEBUG
extension UIDeviceOrientation {
    fileprivate var shortName: String {
        switch self {
        case .portrait:           return "portrait"
        case .portraitUpsideDown: return "portrait↓"
        case .landscapeLeft:      return "landscapeL"
        case .landscapeRight:     return "landscapeR"
        case .faceUp:             return "faceUp"
        case .faceDown:           return "faceDown"
        case .unknown:            return "unknown"
        @unknown default:         return "?"
        }
    }
}

extension CGImagePropertyOrientation {
    fileprivate var shortName: String {
        switch self {
        case .up:            return "up"
        case .down:          return "down"
        case .left:          return "left"
        case .right:         return "right"
        case .upMirrored:    return "upM"
        case .downMirrored:  return "downM"
        case .leftMirrored:  return "leftM"
        case .rightMirrored: return "rightM"
        }
    }
}
#endif
