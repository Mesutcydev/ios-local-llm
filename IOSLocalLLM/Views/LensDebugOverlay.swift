import SwiftUI
import Foundation
import Combine

#if DEBUG

// MARK: - LensDebugOverlay
//
// Diagnostic readout for the Lens pipeline. Entire file is gated
// behind `#if DEBUG` — the View type, the long-press gesture, the
// "send raw" toggle, all of it. Release builds compile this file
// to nothing.
//
// Activation: long-press the camera preview. The overlay floats
// above the preview at the top of the screen, semi-transparent so
// the camera feed remains visible behind it. Long-press again to
// dismiss.
//
// What it surfaces, top to bottom:
//
//   1. **Loaded model + resolved strategy.** From
//      `VLMCapabilities.description` — the one-liner that includes
//      model name, sizing strategy, normalization, color space,
//      and device tier. The tier suffix is the first thing to
//      check when a model streams at an unexpected resolution.
//
//   2. **Last prepared frame.** From `LensFramePreparer.lastDebugInfo`:
//      source dimensions, device orientation, applied
//      CGImagePropertyOrientation, output dimensions, color space.
//      Source and output dimensions side-by-side so the ratio
//      between them is the aggressiveness of the downsample.
//
//   3. **Inference metrics.** From `LensInferenceLoop`: last
//      inference latency in ms, tokens/sec, current available
//      memory via `os_proc_available_memory()`. Refreshed every
//      0.25s — fast enough to be useful, slow enough to not
//      flicker.
//
//   4. **"Send raw" diagnostic toggle.** When on, the streaming
//      loop bypasses LensFramePreparer entirely and feeds the
//      model an unprocessed CIImage. Useful for isolating
//      preparation bugs from model bugs: if captions are sensible
//      with the toggle on, the bug is in prep; if they're still
//      garbage, the bug is in the model. Default off and warned
//      about — accidentally leaving it on while running real
//      validations would silently corrupt every output.
//
// Attaching to a view: use the `.lensDebugOverlay()` modifier on
// the camera preview's container. The modifier installs the
// long-press gesture and conditionally shows the overlay. In
// release builds the modifier is a no-op pass-through (defined
// outside this `#if DEBUG`).

struct LensDebugOverlay: View {

    @ObservedObject private var loop = LensInferenceLoop.shared

    /// Polled snapshot of `LensFramePreparer.lastDebugInfo`. The
    /// preparer's lock-guarded property is poll-friendly; a 0.25s
    /// timer copies into local state for SwiftUI to observe.
    @State private var lastPrep: LensFramePreparer.DebugInfo?

    /// Current available memory before Jetsam. Polled alongside
    /// `lastPrep`.
    @State private var availableMemoryMB: Int = 0

    /// 4 Hz refresh. Anything faster flickers the numeric readout
    /// without giving the user time to actually read it; anything
    /// slower makes "watch the latency change as I move the camera"
    /// feel laggy.
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            section(title: "MODEL") {
                Text(loop.capabilities?.description ?? "no model loaded")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            section(title: "LAST FRAME") {
                if let p = lastPrep {
                    Text(framePrepLine(p))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(.white)
                } else {
                    Text("no frame prepared yet")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            section(title: "INFERENCE") {
                Text(String(format: "latency: %.0f ms  ·  tok/s: %.1f  ·  free: %d MB",
                            loop.lastInferenceMillis,
                            loop.lastTokensPerSecond,
                            availableMemoryMB))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white)
                    // Cross-fade numbers between updates instead of cutting.
                    // The latency/TPS pair changes per inference; without this
                    // they snap and read like a glitch on slow updates.
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.18), value: loop.lastInferenceMillis)
                    .animation(.easeInOut(duration: 0.18), value: loop.lastTokensPerSecond)
            }

            // Diagnostic toggle. Default off — accidentally leaving
            // this on during real captures silently corrupts every
            // output, so the visual treatment is intentionally loud
            // (warn color + "DIAGNOSTIC" caption) when enabled.
            Toggle(isOn: $loop.debugSendRaw) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loop.debugSendRaw ? "send raw (DIAGNOSTIC)" : "send raw")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(loop.debugSendRaw ? .orange : .white)
                    Text("bypasses LensFramePreparer — captions will degrade")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: .orange))
            .padding(.top, 2)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        )
        .frame(maxWidth: 340)
        .onReceive(timer) { _ in
            lastPrep = LensFramePreparer.lastDebugInfo
            availableMemoryMB = Int(os_proc_available_memory()) / 1_048_576
        }
        .onAppear {
            // Prime the snapshot on appear so the overlay isn't empty
            // for the first 250 ms.
            lastPrep = LensFramePreparer.lastDebugInfo
            availableMemoryMB = Int(os_proc_available_memory()) / 1_048_576
            // Tell the loop someone is watching — the lastModelInput /
            // lastModelInputInfo snapshots are only built while this is on.
            loop.debugOverlayVisible = true
        }
        .onDisappear {
            loop.debugOverlayVisible = false
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .tracking(1.0)
            content()
        }
    }

    /// One-line summary of a prepared frame. Source and output
    /// dimensions side-by-side; the ratio between them tells the
    /// user how aggressive the downsample was. Orientation pair
    /// (device → applied CG) is the answer to "did the model see
    /// the world right-side up?"
    private func framePrepLine(_ p: LensFramePreparer.DebugInfo) -> String {
        let src = "\(p.sourceWidth)×\(p.sourceHeight)"
        let out = "\(p.outputWidth)×\(p.outputHeight)"
        let dev = deviceShort(p.deviceOrientation)
        let cgo = cgShort(p.appliedOrientation)
        return "src=\(src) → out=\(out)  ·  \(dev) → \(cgo)  ·  \(p.colorSpace)  ·  f#\(p.frameIndex)"
    }

    private func deviceShort(_ o: UIDeviceOrientation) -> String {
        switch o {
        case .portrait:           return "portrait"
        case .portraitUpsideDown: return "portrait↓"
        case .landscapeLeft:      return "landL"
        case .landscapeRight:     return "landR"
        case .faceUp:             return "faceUp"
        case .faceDown:           return "faceDown"
        case .unknown:            return "unknown"
        @unknown default:         return "?"
        }
    }

    private func cgShort(_ o: CGImagePropertyOrientation) -> String {
        switch o {
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

// MARK: - View modifier
//
// The attach-point for `CameraRootView` (or wherever the preview
// lives). Long-press toggles visibility; the overlay floats over
// the top of the host view. Release-build counterpart below this
// `#if DEBUG` is a no-op pass-through.

struct LensDebugOverlayModifier: ViewModifier {

    @State private var visible: Bool = false

    func body(content: Content) -> some View {
        content
            // `.simultaneousGesture` rather than `.onLongPressGesture`.
            // The Lens preview has a stack of existing gestures on its
            // touch surface (SpatialTapGesture for focus,
            // MagnificationGesture for zoom). A bare `.onLongPress-
            // Gesture` competes with those — SwiftUI's gesture
            // arbitration picks one and drops the others. Simultaneous
            // composition lets all three coexist:
            //   • Quick tap         → focus
            //   • Two-finger pinch  → zoom
            //   • 600 ms hold       → toggle the debug overlay
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                    // Haptic so the user knows the long-press registered
                    // even when the overlay is off-screen for any reason.
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    visible.toggle()
                }
            )
            .overlay(alignment: .top) {
                if visible {
                    LensDebugOverlay()
                        .padding(.horizontal, 12)
                        .padding(.top, 60)        // clear the status bar / notch
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .allowsHitTesting(true)   // so the diagnostic toggle is tappable
                }
            }
            .animation(.easeInOut(duration: 0.18), value: visible)
    }
}

#endif

// MARK: - View extension
//
// Defined outside `#if DEBUG` so call sites compile in release. In
// release the modifier is a no-op pass-through — the long-press
// gesture is not installed and the overlay code does not exist.

extension View {
    func lensDebugOverlay() -> some View {
        #if DEBUG
        return modifier(LensDebugOverlayModifier())
        #else
        return self
        #endif
    }
}
