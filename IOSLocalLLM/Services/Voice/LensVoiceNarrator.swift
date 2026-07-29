import Foundation

// MARK: - LensVoiceNarrator
//
// TTS for the Lens describing path. When `AppSettings.voiceSpeakInLens == true`
// and `activate()` has been called, `CameraRootView` calls `narrate(_:)` with
// each newly COMPLETED one-shot describe caption (from
// `AnalysisService.activeResult`), and the narrator pipes it through the
// standard pipeline (ReasoningStripper → SemanticChunker → LanguageDetector →
// AudioQueue) using the visual model's `VoiceProfile`.
//
// History: the narrator used to consume a continuous per-frame streaming loop
// (`LensInferenceLoop.onStreamToken`/`onStreamComplete`), but that pipeline was
// never wired up and was a crash-sensitive Metal path, so it was removed. The
// Lens has always been tap-to-capture / interval describe; narrating the
// resulting completed captions is the supported source now and makes
// `voiceSpeakInLens` actually produce speech.
//
// ## Scene-change guard
//
// Capturing the same static scene repeatedly (the interval loop, or repeated
// taps) would re-narrate an unchanged caption. The narrator computes a
// word-level Jaccard similarity between each new completed caption and the last
// one it considered:
//
//   • overlap < 0.30  → substantial scene change. Stop the current narration,
//                       swap in a fresh `AudioQueue`, and narrate the new
//                       caption.
//   • overlap >= 0.30 → same scene. Skip TTS for this capture; the on-screen
//                       caption text still updates from the inference loop.
//
// Explicit interrupts (user dismisses the caption, toggles voiceSpeakInLens
// off, leaves the Lens tab) bypass the heuristic and tear the queue down.

@MainActor
final class LensVoiceNarrator: ObservableObject {

    // MARK: - Singleton

    static let shared = LensVoiceNarrator()

    private init() {}

    // MARK: - Observable state

    /// Current audio queue. Replaced (not reset) on scene change — a stopped
    /// `AudioQueue` can't accept new utterances by design (the cancellation
    /// contract requires it), so we swap the instance. SwiftUI observers
    /// re-subscribe automatically when this `@Published` flips.
    @Published private(set) var audioQueue: AudioQueue = AudioQueue()

    /// True while the narrator is enabled for the Lens tab.
    @Published private(set) var isActive: Bool = false

    // MARK: - Pipeline state

    private var chunker: SemanticChunker?
    private var stripper: ReasoningStripper?
    private var profile: VoiceProfile?

    /// The last completed caption we considered — baseline for the overlap
    /// check on the next capture (updated even when we skip narration, since
    /// the user's current scene IS that caption regardless).
    private var lastCompletedCaption: String = ""

    private let voice = VoiceService.shared

    // MARK: - Public API

    /// Enable narration for the Lens tab. Idempotent.
    func activate() {
        guard !isActive else { return }
        isActive = true
        resetState()
    }

    /// Disable narration and halt any in-flight playback. Idempotent.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        audioQueue.stop()
        audioQueue = AudioQueue()
        resetState()
    }

    /// User-triggered immediate halt. The next caption is evaluated afresh by
    /// the scene-change guard.
    func stop() {
        audioQueue.stop()
        audioQueue = AudioQueue()
    }

    // MARK: - Overlap heuristic (testable in isolation)
    //
    // `nonisolated` so unit tests (and any non-MainActor caller in the future)
    // can use the pure-function math without an actor hop.

    /// Word-level Jaccard similarity. Lower bound 0.0 (no shared words), upper
    /// bound 1.0 (identical word sets). Punctuation and digits are stripped;
    /// tokens are case-folded.
    nonisolated static func overlap(_ a: String, _ b: String) -> Double {
        let tokenize: (String) -> Set<String> = { s in
            Set(s.lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
                .filter { !$0.isEmpty })
        }
        let aT = tokenize(a)
        let bT = tokenize(b)
        let union = aT.union(bT)
        guard !union.isEmpty else { return 0.0 }
        return Double(aT.intersection(bT).count) / Double(union.count)
    }

    /// Overlap at or above this threshold → same scene → skip TTS. Tuned so
    /// "a person at a desk" and "the person at the desk with a laptop" both
    /// score > 0.30 (no re-narration of a static scene) while real scene
    /// changes get through.
    nonisolated static let sceneChangeOverlapThreshold: Double = 0.30

    // MARK: - Narration

    /// Narrate a completed describe caption. Called by CameraRootView when a
    /// one-shot describe finishes and `voiceSpeakInLens` is on. No-op when
    /// inactive, the caption is empty, or it overlaps the previous scene.
    func narrate(_ rawCaption: String) {
        guard isActive else { return }
        let caption = rawCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !caption.isEmpty else { return }

        // Scene-change guard: skip narration when this caption substantially
        // overlaps the last one (same static scene), but still update the
        // baseline so the NEXT comparison is against the latest caption.
        if !lastCompletedCaption.isEmpty,
           Self.overlap(lastCompletedCaption, caption) >= Self.sceneChangeOverlapThreshold {
            lastCompletedCaption = caption
            return
        }
        lastCompletedCaption = caption

        startFreshNarration()
        feedThroughPipeline(caption)
        // Flush stripper + chunker tails, then signal end-of-input so the
        // consumer drains and exits cleanly. finish() (not stop()) — we WANT
        // the queued chunks to play out.
        if let stripper {
            let trailing = stripper.flush()
            if !trailing.isEmpty, let chunker {
                for ch in chunker.append(trailing) { enqueueChunk(ch.text) }
            }
        }
        if let tail = chunker?.finish() { enqueueChunk(tail.text) }
        audioQueue.finish()
    }

    // MARK: - Pipeline

    private func startFreshNarration() {
        // Kill any in-flight playback and swap in a new queue. AudioQueue.stop()
        // is sync + idempotent; the old voice.speakStream consumer sees next()
        // return nil and exits naturally.
        audioQueue.stop()
        audioQueue = AudioQueue()

        // Look up the active Lens model's voice profile. Empty
        // `cameraVisualModelID` means the built-in FastVLM path — resolves via
        // `_fallback` (tuned for English descriptive narration).
        let lensSelection = LocalModelRegistry.storedVisionSelectionID(
            AppSettings.shared.cameraVisualModelID
        )
        let key = LocalModelRegistry.isDefaultVisionSelection(lensSelection)
            ? "_fallback"
            : LocalModelRegistry.persistedVisionRepoID(for: lensSelection)
        let p = VoiceProfileRegistry.profile(for: key)
        profile = p
        stripper = p.usesReasoningTokens
            ? ReasoningStripper(
                openTag:  p.reasoningTokenPattern?.open  ?? "<think>",
                closeTag: p.reasoningTokenPattern?.close ?? "</think>"
              )
            : nil
        chunker = SemanticChunker(strategy: p.chunkingStrategy)

        voice.speakStream(audioQueue)
    }

    private func feedThroughPipeline(_ text: String) {
        guard let chunker else { return }
        let filtered = stripper?.feed(text) ?? text
        guard !filtered.isEmpty else { return }
        for ch in chunker.append(filtered) {
            enqueueChunk(ch.text)
        }
    }

    private func enqueueChunk(_ text: String) {
        let lang = LanguageDetector.shared.detect(
            text, hints: profile?.dominantLanguages ?? ["en"]
        )
        audioQueue.enqueue(AudioQueue.Utterance(text: text, language: lang))
    }

    private func resetState() {
        chunker = nil
        stripper = nil
        profile = nil
        lastCompletedCaption = ""
    }
}
