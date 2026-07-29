# Lens Pipeline

How a camera frame becomes a VLM response.

This document is the on-call reference for "model X is doing something weird on the Lens tab." Read the troubleshooting table first (it's keyed to symptoms, not architecture); fall back to the rest of the doc for context.

---

## Data flow

```
AVCaptureSession
    │
    │ kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    │ portrait-locked (connection.videoRotationAngle = 90)
    │ 60 fps @ 4K (or 1080p fallback)
    ▼
CameraService.captureOutput
    │ acquire-or-bail (OSAllocatedUnfairLock<Bool>)
    │ defer { release }
    │
    ├──► delegate?.cameraService(...)          ← legacy path / OneShotCapture
    │
    └──► streamingFrameHandler?(...)           ← if delegate is NOT OneShotCapture
            │
            ▼
        LensInferenceLoop.handleFrame   (nonisolated, on camera queue)
            │ acquire-or-bail at the streaming gate
            ▼
        Task @MainActor
            │
            ▼
        LensInferenceLoop.dispatchStreamingInference
            │
            │ #if DEBUG && debugSendRaw → CIImage(cvPixelBuffer:)  ← bypass
            │ else                       → LensFramePreparer.prepare(...)
            ▼
        LensFramePreparer
            │
            │  1. CIImage(cvPixelBuffer:)         ← YpCbCr biplanar
            │  2. .oriented(_:)                    ← world-up correction
            │  3. CILanczosScaleTransform          ← strategy-aware resize
            │  4. render through sRGB CIContext    ← single concrete pass
            ▼
        MLXGenerationGate.run { container.perform { ... } }
            │ context.processor.prepare(input:)
            │ MLXLMCommon.generate(...)
            ▼
        onStreamToken / onStreamComplete
```

Three keys to make sense of this:

1. **The buffer is portrait-locked by the connection, not the device.** Even when the phone is physically landscape, the bytes you receive are oriented as if the phone were portrait — but the world inside them is rotated. The preparer un-rotates via `CGImagePropertyOrientation`.
2. **`OneShotCapture` and `streamingFrameHandler` coexist.** `captureHighResFrame()` installs `OneShotCapture` as the delegate; the streaming hook type-checks `delegate is OneShotCapture` and suppresses itself during that window. They never both consume the same frame.
3. **One concrete render per frame.** All the preparer's steps (orient + resize + sRGB) are lazy CIImage operations folded into a single GPU pass at the sRGB-context render. Not four passes, one.

---

## Files

| File | Role |
|---|---|
| `IOSLocalLLM/Services/CameraService.swift` | Owns `AVCaptureSession`. Adds `streamingFrameHandler` and `OSAllocatedUnfairLock<Bool>` gate as additive changes. `OneShotCapture` lifted to file scope for the type-check. |
| `IOSLocalLLM/Services/VLMCapabilities.swift` | Model-aware preprocessing parameters. Loaded from `preprocessor_config.json` + `processor_config.json` + `config.json`, with a per-architecture defaults table as safety net. Device-tier clamps applied last. |
| `IOSLocalLLM/Services/LensFramePreparer.swift` | `CVPixelBuffer` → `CIImage`. YpCbCr-safe, world-orientation aware, sRGB-forced, strategy-aware resize. |
| `IOSLocalLLM/Services/LensInferenceLoop.swift` | Sole owner of the VLM `ModelContainer`. Streaming hook installation, single-flight gate, one-shot describe, memory-gated load with fallback walk. |
| `IOSLocalLLM/Services/MLXVisionService.swift` | Backward-compat shim re-publishing `LensInferenceLoop`'s state for legacy UI bindings. Slated for removal; this document remains the migration reference. |
| `IOSLocalLLM/Views/LensDebugOverlay.swift` | `#if DEBUG`-only diagnostic readout. Long-press the preview to toggle. |
| `IOSLocalLLM/Views/CameraPreviewView.swift` | `UIViewRepresentable` over `AVCaptureVideoPreviewLayer`. **Do not touch.** `updateUIView` is a deliberate no-op; `layoutSubviews` uses `CATransaction.setDisableActions(true)`. Both prevent a 250 ms half-sized-layer flicker during MLX download progress. |

---

## The four sizing strategies

Each VLM family expects its input shaped differently. The preparer picks one of four strategies based on the model's architecture (detected from `config.json`'s `model_type` or `architectures[0]`). Mismatched strategies produce one of: stretched aspect ratios, illegible text, hallucinated content, or silent spatial-reasoning degradation.

### `.fixed(CGSize)`

**Models:** LLaVA 1.5, Moondream2, PaliGemma.

The processor resizes to one fixed square (336², 378², 448²). The preparer scales the input's long edge to `2 × target.width` so the processor's bicubic step has a clean intermediate — going to exactly the target side would mean the processor downscales twice and throws away sub-pixel information.

### `.dynamicPatchAligned(patch, merge, minPixels, maxPixels)`

**Models:** Qwen2-VL, Qwen2.5-VL.

The model accepts a range of resolutions but each dimension must be a multiple of `patch × merge` (typically `14 × 2 = 28`). The preparer caps total pixels under `min(streamingBudget, maxPixels)`, then **crops** (not resizes) each dimension to a multiple of `patch × merge`.

The crop is from the image origin, not centered. The lost pixels are at most `patch × merge - 1 = 27` per dimension — a single-digit percentage of frame at any streaming resolution. Origin vs center is a wash for model accuracy; origin won on simpler arithmetic.

If alignment would push the pixel count below `minPixels`, the preparer scales the image UP first (the only upscale path in this layer).

**This is the load-bearing strategy.** Qwen2-VL silently falls back to a path that mangles spatial reasoning when given non-aligned inputs — no error, just bad outputs.

### `.anyresTiling(baseSize, gridOptions: [CGSize])`

**Models:** LLaVA 1.6 / LLaVA-Next.

The processor picks a grid shape from a list of allowed pinpoints based on input aspect ratio. The preparer best-fit scales the long edge to `2 × baseSize` and lets the processor pick the grid. Going larger just gets downscaled by the processor; going smaller loses information before the processor can use it.

### `.fixedTiling(tileSize, maxTiles)`

**Models:** Llama 3.2 Vision (`mllama`), Idefics3, SmolVLM, SmolVLM2.

The processor splits the input into fixed-size square tiles. The preparer scales so the total pixel count is under `min(streamingBudget, maxTiles × tileSize²)`. The exact constraint is `ceil(w/tile) × ceil(h/tile) ≤ maxTiles`, which requires aspect-aware bin-packing; the pixel-budget approach is at most one tile over-conservative, which is the right trade at 60 fps.

**Watch for:** mllama with `maxTiles = 4` on a 16:9 frame. The aspect wants a 3×2 grid (6 tiles, doesn't fit), falls back to 2×2, and the model sees a letterboxed image. If mllama performs worse on wide landscape than portrait, this is the cause — fix would be to detect "aspect wants more tiles than budget allows" and pre-letterbox to the tile grid's actual aspect.

---

## Orientation correction

The buffer is portrait-locked at the connection (`videoRotationAngle = 90`). The device may be physically landscape. The preparer reads `UIDevice.current.orientation` and applies the matching `CGImagePropertyOrientation`:

```
device .portrait              → .up
device .portraitUpsideDown    → .down
device .landscapeLeft         → .left
device .landscapeRight        → .right
```

Reasoning: when the device is in portrait, the buffer's "up" matches the world's "up." When the device rotates, the buffer stays portrait-shaped but the world content inside it rotates relative to buffer-up, and the inverse rotation recovers it.

**Validation method:** point the camera at a sheet of paper with `↑` drawn on it. Hold the phone in each of the four orientations. The model should read "up" in all four. The arrow forces an unambiguous answer; text is readable upside-down by a tilted head.

### The launch-in-landscape gotcha

`UIDevice.current.orientation` returns `.unknown` until the first motion sample arrives. On a freshly-launched app held perfectly still in landscape, this can take up to a second. During that window the preparer falls back to `UIWindowScene.interfaceOrientation`.

**`UIInterfaceOrientation` uses the opposite landscape convention from `UIDeviceOrientation`:**

| `UIInterfaceOrientation` | actual physical state | equivalent `UIDeviceOrientation` |
|---|---|---|
| `.landscapeLeft` | status bar on the left → device home indicator on the right | `.landscapeRight` |
| `.landscapeRight` | status bar on the right → device home indicator on the left | `.landscapeLeft` |

The fallback code swaps the two landscape cases explicitly. **Validation MUST include "launch the app already in landscape"** as a test case — that's the only path through this swap.

### Known limitation: landscape FOV is portrait-cropped

The connection rotation is fixed at 90° regardless of physical device orientation. When the user holds the phone in landscape to scan a wide document, the buffer is still portrait-shaped — so it contains a portrait-cropped slice of the sensor's landscape field of view. Applying `CGImagePropertyOrientation` rotates the bitmap, but it cannot recover the field of view that the portrait crop discarded.

**This is a product decision, not a bug.** If a user reports "I turned the phone landscape and the model can't see the whole document," the answer is "rotation lock is intentional; use the single high-res capture for that case." If we ever need to support landscape FOV, we'd need to dynamically update `connection.videoRotationAngle` based on `UIDevice.orientation` — which means re-validating every model's orientation correction, and re-validating the preview layer's behavior under rotation. Big change for a niche use case.

---

## Color space (sRGB)

Newer iPhones deliver Display P3 from the camera sensor. The preparer renders every frame through a `CIContext` with `workingColorSpace = sRGB` so the bytes the model sees are in the gamut the model's normalization stats expect.

Without this step, CLIP / ImageNet / 0.5-norm normalization sees over-saturated pixels and degrades silently — captions get vaguer, colors get misnamed, no error is raised.

The render is a single GPU pass that folds in the orientation and resize steps above. Not four passes, one.

---

## Memory gate

Before loading a VLM, `LensInferenceLoop.switchTo` checks:

```
os_proc_available_memory() ≥ estimated × 1.4
```

The `× 1.4` covers the weights themselves plus activations and KV-cache headroom for the first generate. The estimate comes from summing the actual cached weight-file sizes when the model is pre-staged on disk; otherwise it falls back to a conservative 3 GB default (which covers the largest VLM in the catalog).

If the gate fails, the user sees `"Not enough memory to load this model. Need ~X MB, have Y MB available."` — actionable, not generic.

After load, the container is tied to the Lens tab. `handleTabDeactivate()` unloads (and clears GPU + drains the autoreleasepool) so a multi-GB container is never resident while the user is on a different tab. Power users can flip `keepLoadedOnDeactivate: Bool = true` to keep it loaded.

---

## Troubleshooting

Keyed to symptoms, because that's how you'll search this at 2 AM.

### "Model reads text mirrored"

Selfie path is leaking into the back-camera flow. **The Lens pipeline is back-camera-only.** Check that nothing in the camera input chain has been switched to `.front`. The orientation enum mapping is the same for both cameras, but the mirroring flag is different — a misconfigured input would deliver mirrored bytes regardless of how `CGImagePropertyOrientation` is applied.

### "Model outputs garbage on landscape rotation"

Two likely causes:

1. **Launch-in-landscape window.** `UIDevice.orientation` returns `.unknown` until the first motion sample. If the user launched directly into landscape, the preparer is using the `UIInterfaceOrientation` fallback. Verify the `landscapeLeft ↔ landscapeRight` swap is in place in `LensFramePreparer.currentDeviceOrientation`.

2. **Landscape mapping inverted.** If portrait works but both landscapes are wrong, swap `.left ↔ .right` in `LensFramePreparer.correctedOrientation`. The DEBUG log prints device + applied CG orientation per frame; one glance tells you which mapping is active.

Use the arrow card method for diagnosis. Don't use text — text reads upside-down with a tilted head and gives ambiguous answers.

### "Captions are vague or colors are misnamed"

Color space conversion didn't take effect. The model is seeing Display P3 bytes against sRGB-trained normalization. Verify `LensFramePreparer.renderThroughSRGB` is being called (the lazy CIImage graph must end in a `createCGImage(_:from:format:colorSpace:)` through the sRGB context).

If `lastDebugInfo.colorSpace` is `"sRGB"` in the overlay, the step ran. If captions are still vague, suspect normalization stats mismatch — check `VLMCapabilities.description` for `CLIP-norm` vs `ImageNet` vs `0.5-norm` and verify it matches the model's documented normalization.

### "Model OOMs on launch"

Memory gate didn't catch it. Three things to check:

1. Is `os_proc_available_memory()` reporting accurately? On simulators it lies about available memory; the gate is meant for real devices.
2. Is the weight-size estimate way off? If `estimatedWeightBytes` is returning 3 GB but the actual model is 6 GB (quantized variant of a large model), the gate passes when it shouldn't. Verify by checking `cachedWeightBytes` for the staged directory.
3. Is the `× 1.4` multiplier too tight for this model family? Some VLMs (LLaVA 1.6 with high-resolution tiles) want more activation memory. Bump to `× 1.6` and re-validate.

### "FastVLM works but streaming VLMs don't"

The preparer or capabilities is broken for the streaming model. FastVLM uses its own service (`FastVLMService`), not `LensInferenceLoop`, so its happy path doesn't validate the new pipeline.

Check the debug overlay's MODEL line. If it reads `"unknown · fixed(384×384) · ImageNet · sRGB · tier:.X"`, the architecture detection missed your model and you're getting safety-net defaults. Add the model's `model_type` to `NormalizedArchitecture.detect` in `VLMCapabilities.swift`.

If MODEL reads correctly (e.g., `"Qwen2.5-VL · dynamicPatchAligned(patch:14, merge:2, ...)"`), the issue is downstream. Use the "send raw" diagnostic toggle in the overlay: if captions become sensible with raw input, prep is the bug; if they're still garbage, the model itself isn't handling whatever frame it's getting.

### "Model OOMs after several captures"

GPU buffer leak. The deferred `GPU.clearCache()` and `autoreleasepool { }` in `LensInferenceLoop.unload` is the defense against this. Verify the cleanup chain runs by:

1. Tap into and out of the Lens tab repeatedly.
2. Watch `os_proc_available_memory()` in the debug overlay between tab switches.
3. If memory monotonically decreases, the autoreleasepool isn't draining. Most likely cause: a captured MLXArray in a closure that escaped a Task that was supposed to be cancelled.

### "`captureHighResFrame()` returns nil"

The 2-second timeout fallback fired. The delegate-swap dance in that function depends on a frame arriving within 2 seconds. Causes:

- Session is paused (check `captureSession.isRunning`)
- Connection's videoRotationAngle is mis-set (shouldn't change — but if anything has touched the connection, frames may have stopped)
- Camera permission was revoked mid-session

### "Captions feel slower than they used to"

Compare `lastInferenceMillis` in the debug overlay before and after. If it's significantly higher than the old `MLXVisionService.describe()` path, the most likely cause is the `resizeHintSide(for: caps)` change — see the comment in `LensInferenceLoop.describe`. Either accept the new strategy-aware behavior (which is more correct) or hardcode the old `448` in `describe()` to preserve the old behavior on the one-shot path.

---

## Known stale comments

Documenting the surprises so future readers don't waste time chasing them.

- **`CameraService.captureHighResFrame()`** has a doc-comment that reads "Reconfigures to 4K for a single high-res capture, then restores 1080p." The body does no reconfiguration — the live output is already 4K (or 1080p fallback) per the session preset, so the function just grabs the next frame. The comment is preserved because the function is in the "do not refactor" lockdown — touching the comment counts as touching the function. Don't fix it; the next person needs the same warning.

---

## Validation checklist

Per-model. Run for: Qwen2.5-VL, LLaVA 1.6, Llama 3.2 Vision, SmolVLM, SmolVLM2, Moondream2, PaliGemma.

- [ ] **Arrow card, four orientations.** Print a card with a clear `↑`. Hold the phone in portrait, landscape-left, landscape-right, upside-down. Verify the model reads "up" / "left" / "right" / "down" correctly.
- [ ] **Text card.** Print a card with three lines of varied text + a known object + an orientation arrow. Verify the model reads the text legibly in each orientation.
- [ ] **Launch-in-landscape.** Quit the app, hold in landscape, launch. Verify the first capture reads correctly (validates the `UIInterfaceOrientation` fallback path).
- [ ] **Memory gate.** Load the largest model in the catalog. If your device has less than 1.4× the model size available, verify the load is refused with a clear message rather than crashing.
- [ ] **Tab switch.** Load the model, switch to Models tab, switch back. Verify the container unloaded (memory recovered) and reloads cleanly.
- [ ] **`captureHighResFrame()` regression.** This is the critical regression check — the delegate-swap dance is fragile. Trigger via the existing capture button. Verify a frame is returned and inference produces the same output as the streaming path on the same scene.
- [ ] **Token-equivalent on shim path.** Run a known image through `AnalysisService.tryMLXVisionPath` (which routes through the shim → `LensInferenceLoop.describe`). Compare output against pre-migration behavior. Significant drift likely traces to the `resizeHintSide` change documented in `LensInferenceLoop.describe`.
