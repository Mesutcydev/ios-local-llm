import Foundation
import CoreImage
import UIKit
import Combine
import MLX
import MLXVLM
import MLXLMCommon

// MARK: - MLXVisionService
//
// ⚠️  BACKWARD-COMPAT SHIM — DO NOT ADD NEW CALLERS.
//
// This class is a thin shim re-publishing `LensInferenceLoop`'s
// state for legacy UI bindings (ContentView, ModelsManagerView,
// VisualModelPickerView, SettingsView, IOSLocalLLMApp, AnalysisService,
// DeviceTierAdvisor — roughly 14 callsites). Container ownership,
// streaming pipeline, capabilities resolution, and one-shot
// describe ALL live on `LensInferenceLoop.shared` now.
//
// New callers should bind to `LensInferenceLoop.shared` directly.
//
// Slated for removal after migration tracked at:
//   LENS_PIPELINE.md
//
// The migration plan is documented in that issue: 14 callsites to
// migrate, then this file deletes. The shim survives in the
// interim so the streaming-pipeline PR's blast radius stays
// bounded.
//
// Why a shim and not a rename: this class is referenced by Settings
// debug bindings, Models Manager state observers, the visual-model
// picker's progress UI, and AnalysisService's fallback chain.
// Renaming all 14 callsites in the same PR as the streaming
// pipeline change would mean one PR touching three different
// failure surfaces (camera, container ownership, UI bindings), and
// no clean bisect when something breaks two weeks after merge.

@MainActor
final class MLXVisionService: ObservableObject {

    static let shared = MLXVisionService()

    // MARK: - Type re-exports
    //
    // Existing callers reference `MLXVisionService.State` and
    // `MLXVisionService.ModelInputInfo` by full name. Type-alias
    // them so the type system sees one canonical type per concept
    // and the shim doesn't fork the enum cases.

    typealias State = LensInferenceLoop.State
    typealias ModelInputInfo = LensInferenceLoop.ModelInputInfo

    // MARK: - Published mirrors
    //
    // SwiftUI's @ObservedObject watches `objectWillChange`. We don't
    // duplicate the @Published storage — instead we forward
    // LensInferenceLoop's objectWillChange into ours, then expose
    // computed properties that read from the loop. SwiftUI sees
    // the same observation events the loop emits.

    private var cancellable: AnyCancellable?

    private init() {
        // Forward LensInferenceLoop's change notifications to ours.
        //
        // THE DEFERRAL IS LOAD-BEARING. Do not remove it.
        //
        // SwiftUI evaluates a view's body by reading @Published
        // properties. When LensInferenceLoop's @Published fires DURING
        // that body evaluation (which can happen when any other view
        // in the tree reads the property and triggers a downstream
        // update), synchronously firing this shim's objectWillChange
        // on the same runloop turn produces:
        //
        //   1. "Modifying state during view update, this will cause
        //      undefined behavior" runtime warnings every time.
        //   2. Occasional infinite update loops where SwiftUI's
        //      reconciliation re-reads the shim, triggering the same
        //      forward, triggering another reconciliation, and so on
        //      until the watchdog kills the runloop.
        //
        // DispatchQueue.main.async pushes our objectWillChange to the
        // next runloop turn, AFTER the in-flight view body completes.
        // The trade-off is one frame of UI latency on state changes,
        // which is invisible to users and the only correct option.
        //
        // If you benchmark this and find the deferral adds "frame
        // lag" — that lag is the bug protection. Don't remove it
        // hoping to recover the frame; you'll trade a measurable
        // millisecond for unreproducible TestFlight crashes.
        cancellable = LensInferenceLoop.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
            }
        }
    }

    // MARK: - Forwarded state
    //
    // Each property reads through to LensInferenceLoop.shared. The
    // shim doesn't store any of its own state — there's only one
    // source of truth.

    var state: State {
        LensInferenceLoop.shared.state
    }

    var activeRepoID: String? {
        LensInferenceLoop.shared.activeRepoID
    }

    var lastModelInput: UIImage? {
        LensInferenceLoop.shared.lastModelInput
    }

    var lastModelInputInfo: ModelInputInfo? {
        LensInferenceLoop.shared.lastModelInputInfo
    }

    // MARK: - Forwarded methods

    /// Forwards to `LensInferenceLoop.shared.switchTo(repoID:)`.
    func switchTo(repoID: String, preserveMatchingAssistant: Bool = false) async {
        await LensInferenceLoop.shared.switchTo(
            repoID: repoID,
            preserveMatchingAssistant: preserveMatchingAssistant
        )
    }

    /// Forwards to `LensInferenceLoop.shared.cancelCurrentInference()`.
    func cancelCurrentInference() {
        LensInferenceLoop.shared.cancelCurrentInference()
    }

    /// Forwards to `LensInferenceLoop.shared.unload(clearGPUCache:)`.
    func unload(clearGPUCache: Bool = true) {
        LensInferenceLoop.shared.unload(clearGPUCache: clearGPUCache)
    }

    /// Forwards to `LensInferenceLoop.shared.describe(...)`. This is
    /// the only path AnalysisService.tryMLXVisionPath uses — when
    /// the migration in #1 ships, that call will bind directly to
    /// LensInferenceLoop and this method goes away.
    func describe(
        image: UIImage,
        prompt: String = "Describe what's in this image. Be concise.",
        maxTokens: Int = 256,
        onToken: @Sendable @escaping (String) -> Void,
        onComplete: @Sendable @escaping (Double) -> Void
    ) {
        LensInferenceLoop.shared.describe(
            image: image, prompt: prompt, maxTokens: maxTokens,
            onToken: onToken, onComplete: onComplete
        )
    }

    /// Forwards to `LensInferenceLoop.shared.saveLastModelInputToDocuments()`.
    @discardableResult
    func saveLastModelInputToDocuments() -> URL? {
        LensInferenceLoop.shared.saveLastModelInputToDocuments()
    }
}
