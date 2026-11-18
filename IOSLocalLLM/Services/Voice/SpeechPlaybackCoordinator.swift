import AVFoundation
import Combine
import Foundation
import QuartzCore

// MARK: - SpeechPlaybackCoordinator
// Architecture: AVAudioPlayerNode sample clock → lock-free snapshot →
// CADisplayLink pull → karaoke cue + orb levels. Wall-clock Date is never
// the primary sync source.

@MainActor
final class SpeechPlaybackCoordinator: ObservableObject {

    static let shared = SpeechPlaybackCoordinator()

    let orb = OrbPresentationModel()
    let karaoke = KaraokePresentationModel()
    let controls = ControlsPresentationModel()

    /// Compatibility snapshot for debug overlays — updated on phrase/phase
    /// changes, not every display frame.
    @Published private(set) var snapshot: VoicePlaybackSnapshot = .idle
    @Published private(set) var segments: [SpeechSegment] = []
    @Published private(set) var karaokeText: String = ""
    @Published private(set) var timingSource: SpeechAlignmentAccuracy = .estimated
    @Published private(set) var alignmentDetail: String?

    private let playback = AudioPlaybackService.shared
    private let smoother = VoiceLevelSmoother(attack: 0.42, release: 0.88, noiseFloor: 0.04)
    private let timingProvider = EstimatedSpeechTimingProvider.shared
    private let acousticAligner = AcousticSpeechAlignmentProvider.shared
    private var displayLink = VoiceDisplayLink()
    private var playbackGeneration = UUID()
    private var timelineCursor: TimeInterval = 0
    private var completedDuration: TimeInterval = 0
    private var chunkEnvelope: [Float] = []
    private var chunkDuration: TimeInterval = 0
    private var utteranceSampleRate: Double = 24_000
    private var isOutputMuted = false
    private var preferredEngineIsNeural = false
    private var sessionPhase: VoiceSessionPhase = .idle
    private var cancellables = Set<AnyCancellable>()
    private var karaokeTimeline: KaraokeTimeline = .empty
    private var cueTrack: KaraokeCueTrack = .empty
    /// Backward-jump guard + change detection. Compared by text position and
    /// phrase identity — cue indexes shift on every timeline rebuild.
    private var activeCue: KaraokeCue?
    private var refinementTasks: [UUID: Task<Void, Never>] = [:]
    private var lastPublishedLevel: Float = -1
    private var highWaterSpokenEnd = 0
    private var didPublishFirstHighlight = false
    private var routeObserver: NSObjectProtocol?
    /// Stream cursor for chunk→transcript mapping. Chunks resolve against
    /// karaokeText from here forward — searching from 0 matched the FIRST
    /// occurrence of repeated text and highlighted the wrong span.
    private var utf16SearchCursor = 0
    /// Chunk start (render samples) → UTF-16 end of its text. `karaoke.text`
    /// shows the transcript only up to the chunk being spoken, so the text
    /// streams in with the voice and its bottom stays next to the lit phrase.
    // ponytail: reveals per chunk (≤250 chars ≈ 7 lines, fits the collapsed
    // box); reveal per sentence if chunks ever grow past that.
    private var revealMarks: [(startSample: Int64, utf16End: Int)] = []
    private var revealedUTF16End = 0
    /// utf16Range → stable phrase identity. KaraokePhraseBuilder mints fresh
    /// UUIDs on every rebuild, which churned activePhraseID (and therefore
    /// highlight/auto-scroll invalidation) on each chunk + refinement.
    private var phraseIDCache: [String: UUID] = [:]
    /// Wall-clock fallback when `AVAudioPlayerNode.playerTime` is invalid
    /// (common right after a playAndRecord → playback route flip). Without
    /// this, karaoke sample stays at 0 and highlighting never advances.
    private var karaokeWallStartMediaTime: CFTimeInterval?
    /// Last known good player sample — anchors wall-clock fallback so we
    /// don't restart karaoke from 0 mid-utterance.
    private var lastGoodSample: Int64 = 0
    /// Frozen sample at the moment wall-clock fallback armed (avoids
    /// double-counting elapsed into an advancing lastGoodSample).
    private var wallClockSampleOffset: Int64 = 0
    /// Hysteresis for silent-meter synthetic energy — flipping every frame
    /// at the 0.02 threshold made the orb flutter.
    private var meterFallbackArmed = false

    private init() {
        orb.renderingMode = VoiceSettingsStore.shared.renderingMode
        VoicePerformanceMonitor.shared.setRenderingMode(orb.renderingMode)
        displayLink.preferredFPSRange = 24...30
        playback.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                guard let self else { return }
                if playing {
                    VoicePerformanceMonitor.shared.noteFirstAudio()
                    self.beginDisplayLink()
                } else {
                    // Soft-release: let the smoother decay instead of hard-zero
                    // so the orb doesn't flatten between streamed TTS chunks.
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        for _ in 0..<8 {
                            if self.playback.isPlaying { return }
                            let decayed = max(0, self.smoother.smooth(0) - 0.04)
                            VoiceVisualLevelStore.shared.playbackLevel = decayed
                            self.publishOrbLevel(decayed, force: true)
                            try? await Task.sleep(nanoseconds: 30_000_000)
                        }
                        guard !self.playback.isPlaying else { return }
                        self.smoother.reset()
                        VoiceVisualLevelStore.shared.playbackLevel = 0
                        self.publishOrbLevel(0, force: true)
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard !self.playback.isPlaying else { return }
                        self.displayLink.stop()
                    }
                }
            }
            .store(in: &cancellables)

        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.playback.noteRouteChanged()
            }
        }
    }

    // MARK: - Session hooks

    func bindSessionPhase(_ phase: VoiceSessionPhase) {
        sessionPhase = phase
        orb.phase = phase
        controls.phase = phase
        controls.canInterrupt = phase == .speaking || phase == .thinking || phase == .preparingSpeech
        orb.canInterrupt = controls.canInterrupt
        VoiceVisualLevelStore.shared.phaseCode = Self.phaseCode(phase)
        publishCompatSnapshot(level: orb.publishedLevel)
    }

    func setMuted(_ muted: Bool) {
        isOutputMuted = muted
        playback.setVolume(muted ? 0 : 1)
        controls.isMuted = muted
        if muted {
            VoiceVisualLevelStore.shared.playbackLevel = 0
            publishOrbLevel(0, force: true)
        }
        publishCompatSnapshot(level: orb.publishedLevel)
    }

    var isMuted: Bool { isOutputMuted }

    func notePreferredEngine(_ kind: VoiceEngineKind, isFallback: Bool) {
        preferredEngineIsNeural = (kind == .kittenTTS || kind == .kokoro)
        controls.isFallbackEngine = isFallback && preferredEngineIsNeural
        var snap = snapshot
        snap.isFallbackEngine = controls.isFallbackEngine
        snapshot = snap
    }

    /// `chunks`: the text to be spoken when it is known up front (replay,
    /// read-aloud), already split the way it will be synthesized. Streamed
    /// replies pass nothing: the transcript is then built from each chunk as
    /// it is registered, so it always matches what is actually spoken. Feeding
    /// it raw model tokens duplicated every sentence the chunker normalized.
    func beginUtterance(chunks: [String] = []) {
        playbackGeneration = UUID()
        playback.beginUtteranceTimeline()
        cancelRefinements()
        segments = []
        karaokeTimeline = .empty
        cueTrack = .empty
        karaokeText = chunks.joined(separator: " ")
        revealMarks = []
        revealedUTF16End = 0
        // First chunk up immediately so a replay never blanks the transcript
        // while it synthesizes.
        reveal(upTo: ((chunks.first ?? "") as NSString).length)
        karaoke.activePhraseID = nil
        karaoke.activePhraseUTF16Range = nil
        karaoke.setSpokenUTF16End(0)
        timelineCursor = 0
        completedDuration = 0
        chunkEnvelope = []
        chunkDuration = 0
        activeCue = nil
        highWaterSpokenEnd = 0
        didPublishFirstHighlight = false
        karaokeWallStartMediaTime = nil
        lastGoodSample = 0
        wallClockSampleOffset = 0
        utf16SearchCursor = 0
        phraseIDCache.removeAll()
        meterFallbackArmed = false
        // Reset playback energy only — keep mic level so speechDetected →
        // thinking doesn't snap the orb to a dead static core mid-transition.
        smoother.reset()
        VoiceVisualLevelStore.shared.playbackLevel = 0
        timingSource = .estimated
        karaoke.timingSource = .estimated
        VoicePerformanceMonitor.shared.resetUtterance()
        // Restore user rendering preference each utterance so a temporary
        // hitch-driven .reduced downgrade can't stick for the whole session.
        let preferred = VoiceSettingsStore.shared.renderingMode
        orb.renderingMode = preferred
        VoicePerformanceMonitor.shared.setRenderingMode(preferred)
        publishOrbLevel(0, force: true)
        publishCompatSnapshot(level: 0)
    }

    /// Natural end of speech: the whole transcript is visible and reads as
    /// spoken, with nothing left lit. `activeCue` stays set so a late display
    /// tick can't re-light the last phrase.
    func finishUtterance() {
        let length = (karaokeText as NSString).length
        reveal(upTo: length)
        highWaterSpokenEnd = length
        karaoke.setSpokenUTF16End(length)
        karaoke.activePhraseID = nil
        karaoke.activePhraseUTF16Range = nil
        publishCompatSnapshot(level: orb.publishedLevel)
    }

    /// Register a chunk that is about to play.
    /// Returns as soon as provisional phrase timings exist — never waits
    /// for acoustic alignment.
    /// `timelineOffsetOverride` anchors the chunk at its REAL playhead
    /// position (the player clock keeps running through synthesis underruns);
    /// `renderSampleRate` is the live connection rate cue lookups run in.
    func registerChunk(
        text: String,
        buffer: AVAudioPCMBuffer,
        engineKind: VoiceEngineKind,
        engineAlignment: SpeechAlignmentResult? = nil,
        synthesisMetadata: SynthesisMetadata? = nil,
        timelineOffsetOverride: TimeInterval? = nil,
        renderSampleRate: Double? = nil
    ) async {
        VoicePerformanceMonitor.shared.noteChunkRegisterStart()
        let generation = playbackGeneration
        utteranceSampleRate = renderSampleRate ?? buffer.format.sampleRate
        let duration = Double(buffer.frameLength) / max(1, buffer.format.sampleRate)
        guard duration > 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let resolvedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseOffset = Self.placeChunk(resolvedText, in: &karaokeText, cursor: &utf16SearchCursor)
        if let timelineOffsetOverride {
            // Never move the timeline backward — the monotonic cue guard has
            // already passed anything earlier.
            timelineCursor = max(timelineCursor, timelineOffsetOverride)
        }
        let offset = timelineCursor
        revealMarks.append((
            startSample: Int64((offset * utteranceSampleRate).rounded()),
            utf16End: baseOffset + (resolvedText as NSString).length
        ))

        // 1) Engine-derived (Kitten pred_dur) — use immediately.
        if let engineAlignment,
           engineAlignment.accuracy == .engineDerived || engineAlignment.accuracy == .exact,
           let rebased = rebase(engineAlignment, timelineOffset: offset, utf16BaseOffset: baseOffset),
           !rebased.segments.isEmpty {
            applyAlignment(rebased, duration: duration, generation: generation)
            prepareMetering(buffer: buffer, duration: duration)
            return
        }

        // 2) Provisional estimated timings — sync, cheap.
        let provisional = await makeProvisional(
            text: resolvedText,
            duration: duration,
            engineKind: engineKind,
            timelineOffset: offset,
            utf16BaseOffset: baseOffset
        )
        guard playbackGeneration == generation else { return }
        applyAlignment(provisional, duration: duration, generation: generation)
        prepareMetering(buffer: buffer, duration: duration)

        // 3) Acoustic refinement off the critical path (utility priority).
        let taskID = UUID()
        let aligner = acousticAligner
        let meta = synthesisMetadata
        refinementTasks[taskID] = Task { @MainActor [weak self] in
            let started = Date()
            let acoustic = await Task.detached(priority: .utility) {
                await aligner.align(
                    text: resolvedText,
                    audio: buffer,
                    synthesisMetadata: meta,
                    timelineOffset: offset,
                    utf16BaseOffset: baseOffset
                )
            }.value
            let ms = Date().timeIntervalSince(started) * 1000
            VoicePerformanceMonitor.shared.noteAcousticAlignment(durationMs: ms)
            guard let self, self.playbackGeneration == generation else { return }
            self.refinementTasks[taskID] = nil
            guard acoustic.accuracy == .engineDerived
                    || acoustic.accuracy == .acousticallyAligned,
                  !acoustic.segments.isEmpty else { return }
            self.adoptRefinedAlignment(acoustic, chunkStart: offset, chunkEnd: offset + duration)
        }
    }

    private func makeProvisional(
        text: String,
        duration: TimeInterval,
        engineKind: VoiceEngineKind,
        timelineOffset: TimeInterval,
        utf16BaseOffset: Int
    ) async -> SpeechAlignmentResult {
        let caps = TTSEngineCapabilities.capabilities(for: engineKind)
        if let estimated = try? await timingProvider.timings(
            for: text,
            audioDuration: duration,
            engineCapabilities: caps,
            timelineOffset: timelineOffset,
            utf16BaseOffset: utf16BaseOffset
        ), let first = estimated.first, !first.words.isEmpty {
            return SpeechAlignmentResult(
                segments: estimated,
                accuracy: .estimated,
                diagnosticDetail: "provisional duration-weighted"
            )
        }
        let seg = SpeechSegment(
            text: text,
            startTime: timelineOffset,
            endTime: timelineOffset + duration,
            words: [
                SpeechWordTiming(
                    word: text,
                    startTime: timelineOffset,
                    endTime: timelineOffset + duration,
                    utf16Range: NSRange(
                        location: utf16BaseOffset,
                        length: (text as NSString).length
                    )
                )
            ],
            timingSource: .phraseLevel
        )
        return SpeechAlignmentResult(
            segments: [seg],
            accuracy: .phraseLevel,
            diagnosticDetail: "provisional phrase"
        )
    }

    private func applyAlignment(
        _ result: SpeechAlignmentResult,
        duration: TimeInterval,
        generation: UUID
    ) {
        guard playbackGeneration == generation else { return }
        // Replace overlapping provisional segments for this chunk window if needed.
        let chunkStart = timelineCursor
        segments.removeAll { $0.startTime >= chunkStart - 0.001 }
        segments.append(contentsOf: result.segments)
        timingSource = result.accuracy
        alignmentDetail = result.diagnosticDetail
        karaoke.timingSource = result.accuracy
        karaoke.alignmentDetail = result.diagnosticDetail
        timelineCursor += duration
        rebuildTimeline()
        #if DEBUG
        VoiceDiagnosticsCenter.shared.noteQueuedSegments(segments.count)
        #endif
    }

    /// Swap a queued chunk's provisional timing for the refined one. A chunk
    /// that is already audible keeps the timing it has: the old segment-level
    /// splice dropped the playing chunk's only segment and adopted nothing,
    /// which froze the highlight for the rest of that chunk.
    private func adoptRefinedAlignment(
        _ result: SpeechAlignmentResult,
        chunkStart: TimeInterval,
        chunkEnd: TimeInterval
    ) {
        // ponytail: no mid-chunk splice — re-timing words under the playhead
        // makes the fill jump. Splice per word if the first sentence of a
        // reply ever needs refined timing.
        guard currentPlaybackTime() < chunkStart else { return }
        segments.removeAll { $0.startTime >= chunkStart - 0.001 && $0.startTime < chunkEnd - 0.001 }
        segments.append(contentsOf: result.segments)
        segments.sort { $0.startTime < $1.startTime }
        if Self.accuracyRank(result.accuracy) >= Self.accuracyRank(timingSource) {
            timingSource = result.accuracy
            alignmentDetail = (result.diagnosticDetail ?? "") + " (refined)"
            karaoke.timingSource = timingSource
            karaoke.alignmentDetail = alignmentDetail
        }
        rebuildTimeline()
    }

    private func prepareMetering(buffer: AVAudioPCMBuffer, duration: TimeInterval) {
        // Envelope kept as fallback only — speaking energy comes from the
        // mixer tap into AudioMeterAtomics, pulled on the display link.
        chunkEnvelope = PCMAmplitudeAnalyzer.envelope(of: buffer, bins: 32)
        chunkDuration = duration
        // `utteranceSampleRate` intentionally NOT overwritten here —
        // registerChunk sets it to the live render rate (cue lookups must
        // match the player clock's sample domain, not the source buffer's).
        completedDuration = max(0, timelineCursor - duration)
        beginDisplayLink()
        // Do NOT stamp wall-clock Date here — that was the primary lag source
        // (clock started at register, before audible play).
        //
        // Publish at the REAL playback position, not the new chunk's start.
        // Force-publishing the fresh chunk's first phrase here pushed the
        // highlight up to a full queued chunk ahead of the audio, and the
        // monotonic cue guard then blocked every correction backward.
        let snap = playback.refreshSnapshotFromPlayer(targetHostTime: 0)
        let nowSample = AudioVisualClock.displayedSample(
            snapshot: snap,
            targetHostTime: snap.renderHostTime
        )
        publishCueIfNeeded(at: nowSample, force: activeCue == nil)
    }

    private func rebuildTimeline() {
        let built = KaraokePhraseBuilder.build(from: segments)
        // Re-key phrases with stable identities: the builder mints fresh UUIDs
        // per build, so every chunk registration / acoustic refinement looked
        // like a brand-new phrase set to the UI (highlight + scroll churn).
        let stabilized = built.phrases.map { phrase -> KaraokePhrase in
            let key = "\(phrase.utf16Range.location):\(phrase.utf16Range.length)"
            let id = phraseIDCache[key] ?? {
                let fresh = UUID()
                phraseIDCache[key] = fresh
                return fresh
            }()
            return KaraokePhrase(
                id: id,
                text: phrase.text,
                startTime: phrase.startTime,
                endTime: phrase.endTime,
                utf16Range: phrase.utf16Range
            )
        }
        karaokeTimeline = KaraokeTimeline(phrases: stabilized)
        cueTrack = KaraokeCueTrack.from(
            phrases: karaokeTimeline.phrases,
            sampleRate: utteranceSampleRate > 0 ? utteranceSampleRate : 24_000,
            timingSource: timingSource,
            words: segments.flatMap(\.words)
        )
    }

    func markChunkFinished() {
        completedDuration = timelineCursor
        chunkEnvelope = []
        chunkDuration = 0
        // Soft release on `isPlaying == false` owns visual decay — hard-zero
        // here flattened the orb between streamed TTS chunks.
    }

    func cancelActivePlayback(markInterrupted: Bool = false) {
        playbackGeneration = UUID()
        playback.beginUtteranceTimeline()
        cancelRefinements()
        // Show everything that was queued; the unspoken tail stays dim.
        reveal(upTo: (karaokeText as NSString).length)
        displayLink.stop()
        chunkEnvelope = []
        chunkDuration = 0
        smoother.reset()
        VoiceVisualLevelStore.shared.playbackLevel = 0
        if markInterrupted {
            sessionPhase = .interrupted
            orb.phase = .interrupted
            controls.phase = .interrupted
            VoiceVisualLevelStore.shared.phaseCode = Self.phaseCode(.interrupted)
        }
        activeCue = nil
        karaoke.activePhraseID = nil
        karaoke.activePhraseUTF16Range = nil
        karaoke.setSpokenUTF16End(highWaterSpokenEnd)
        orb.canInterrupt = false
        controls.canInterrupt = false
        publishOrbLevel(0, force: true)
        publishCompatSnapshot(level: 0)
    }

    /// Immediate interrupt — bump generation, stop metering, clear highlight.
    func interrupt() {
        cancelActivePlayback(markInterrupted: true)
        VoicePerformanceMonitor.shared.noteInterruptAudibleStop()
    }

    func interruptImmediately() {
        interrupt()
    }

    func reset() {
        playbackGeneration = UUID()
        playback.beginUtteranceTimeline()
        cancelRefinements()
        displayLink.stop()
        segments = []
        karaokeTimeline = .empty
        cueTrack = .empty
        karaokeText = ""
        revealMarks = []
        revealedUTF16End = 0
        karaoke.text = ""
        karaoke.activePhraseID = nil
        karaoke.activePhraseUTF16Range = nil
        karaoke.setSpokenUTF16End(0)
        timelineCursor = 0
        completedDuration = 0
        chunkEnvelope = []
        chunkDuration = 0
        activeCue = nil
        highWaterSpokenEnd = 0
        utf16SearchCursor = 0
        phraseIDCache.removeAll()
        karaokeWallStartMediaTime = nil
        lastGoodSample = 0
        wallClockSampleOffset = 0
        meterFallbackArmed = false
        smoother.reset()
        VoiceVisualLevelStore.shared.reset()
        sessionPhase = .idle
        orb.phase = .idle
        controls.phase = .idle
        var snap = VoicePlaybackSnapshot.idle
        snap.isMuted = isOutputMuted
        snapshot = snap
        #if DEBUG
        VoiceDiagnosticsCenter.shared.noteQueuedSegments(0)
        #endif
    }

    // MARK: - Private

    private func cancelRefinements() {
        for (_, task) in refinementTasks { task.cancel() }
        refinementTasks.removeAll()
    }

    /// UTF-16 location of `chunk` in the transcript: its next occurrence at
    /// or after `cursor` when the text was seeded up front, otherwise the
    /// chunk is appended. Never searches backward — a sentence that is said
    /// twice must map to its own occurrence, not the first one.
    nonisolated static func placeChunk(_ chunk: String, in transcript: inout String, cursor: inout Int) -> Int {
        let ns = transcript as NSString
        let from = min(cursor, ns.length)
        let found = ns.range(of: chunk, options: [], range: NSRange(location: from, length: ns.length - from))
        if found.location != NSNotFound {
            cursor = found.location + found.length
            return found.location
        }
        let separator = transcript.isEmpty || transcript.hasSuffix(" ") || transcript.hasSuffix("\n") ? "" : " "
        let base = ns.length + (separator as NSString).length
        transcript += separator + chunk
        cursor = base + (chunk as NSString).length
        return base
    }

    /// Publish the transcript up to `utf16End`. Only ever grows.
    private func reveal(upTo utf16End: Int) {
        let ns = karaokeText as NSString
        revealedUTF16End = min(max(utf16End, revealedUTF16End), ns.length)
        let visible = ns.substring(to: revealedUTF16End)
        if karaoke.text != visible { karaoke.text = visible }
    }

    /// Reveal every chunk the playhead has entered.
    private func updateReveal(at sample: Int64) {
        guard let end = revealMarks.last(where: { $0.startSample <= sample })?.utf16End,
              end > revealedUTF16End else { return }
        reveal(upTo: end)
    }

    private func beginDisplayLink() {
        displayLink.start { [weak self] link in
            self?.displayTick(link)
        }
    }

    /// Authoritative playback time from AVAudioPlayerNode + latency compensation.
    private func currentPlaybackTime() -> TimeInterval {
        let snap = playback.refreshSnapshotFromPlayer(targetHostTime: 0)
        let host = snap.renderHostTime
        return AudioVisualClock.displayedSeconds(snapshot: snap, targetHostTime: host)
    }

    private func displayTick(_ link: CADisplayLink) {
        VoicePerformanceMonitor.shared.noteMeterTick()
        VoicePerformanceSignposts.begin("MeterTick")
        defer { VoicePerformanceSignposts.end("MeterTick") }

        let targetHost = AudioVisualClock.hostTime(forDisplayTimestamp: link.targetTimestamp)
        let snap = playback.refreshSnapshotFromPlayer(targetHostTime: targetHost)
        var sample = AudioVisualClock.displayedSample(snapshot: snap, targetHostTime: targetHost)
        let sr = max(1, snap.sampleRate)

        // After TTS route flips, playerTime is often invalid for a stretch —
        // fall back to wall time so karaoke/orb energy still advance. Keep the
        // estimate continuous so we never jump backward when the real clock
        // reappears (that freeze/jump was a karaoke + orb flutter source).
        if snap.isPlaying {
            // Judge the RAW player clock. The latency-compensated `sample` sits
            // at 0 for the first `outputLatency` of every utterance; treating
            // that as "invalid" ran the wall clock ahead of the audio and then
            // stalled the highlight (visible on Bluetooth).
            let playerValid = snap.currentPlayerSample > 0
            if !playerValid {
                if karaokeWallStartMediaTime == nil {
                    karaokeWallStartMediaTime = CACurrentMediaTime()
                    wallClockSampleOffset = lastGoodSample
                }
                if let start = karaokeWallStartMediaTime {
                    let elapsed = max(0, CACurrentMediaTime() - start)
                    sample = wallClockSampleOffset + Int64((elapsed * sr).rounded())
                    if snap.scheduledSampleCount > 0 {
                        sample = min(sample, snap.scheduledSampleCount)
                    }
                }
            } else {
                // Real clock returned — never retreat past the wall estimate.
                if let start = karaokeWallStartMediaTime {
                    let elapsed = max(0, CACurrentMediaTime() - start)
                    let wallSample = wallClockSampleOffset + Int64((elapsed * sr).rounded())
                    sample = max(sample, wallSample)
                }
                sample = max(sample, lastGoodSample)
                karaokeWallStartMediaTime = nil
                lastGoodSample = sample
            }
        } else {
            karaokeWallStartMediaTime = nil
            meterFallbackArmed = false
        }
        let seconds = Double(sample) / sr

        // Output energy from the audio tap (lock-free), not from Date-progress envelopes.
        let raw: Float = {
            if isOutputMuted { return 0 }
            if snap.isPlaying {
                let metered = max(snap.outputRMS, snap.outputPeak * 0.85)
                // Hysteresis: arm synthetic breath only after sustained silence,
                // disarm only after clear meter — stops 0.02-threshold flutter.
                if metered < 0.015 {
                    meterFallbackArmed = true
                } else if metered > 0.04 {
                    meterFallbackArmed = false
                }
                if meterFallbackArmed, snap.scheduledSampleCount > 0 {
                    let env: Float
                    if !chunkEnvelope.isEmpty, chunkDuration > 0 {
                        let local = max(0, seconds - completedDuration)
                        let progress = min(1, local / chunkDuration)
                        env = PCMAmplitudeAnalyzer.level(at: progress, envelope: chunkEnvelope)
                    } else {
                        let t = Double(sample) / Double(snap.scheduledSampleCount)
                        // Slow breath (~1.2 Hz), not a 3 Hz sine that reads as flutter.
                        env = Float(0.18 + 0.22 * (0.5 + 0.5 * sin(t * .pi * 2.4)))
                    }
                    return max(metered, env)
                }
                return metered
            }
            return 0
        }()
        let visual = max(0, smoother.smooth(raw) - 0.04)
        VoiceVisualLevelStore.shared.playbackLevel = visual
        lastPublishedLevel = visual

        publishCueIfNeeded(at: sample, force: activeCue == nil && snap.isPlaying)

        #if DEBUG
        if ProcessInfo.processInfo.environment["VOICE_TIMING_DEBUG"] == "1" {
            // Keep compat snapshot currentTime in sync for the debug overlay.
            if Int(link.timestamp * 4) != Int((link.timestamp - link.duration) * 4) {
                publishCompatSnapshot(level: visual, current: seconds)
            }
        }
        #endif
    }

    private func publishCueIfNeeded(at sample: Int64, force: Bool = false) {
        // Text first, so the phrase published below is always inside it.
        updateReveal(at: sample)
        guard let cue = cueTrack.cue(at: sample) else {
            if force {
                karaoke.activePhraseID = nil
                karaoke.activePhraseUTF16Range = nil
            }
            return
        }
        // Never step back to earlier text.
        if let prev = activeCue, cue.textRange.location < prev.textRange.location, !force { return }

        let utf16Len = (karaokeText as NSString).length
        let spoken = max(highWaterSpokenEnd, cueTrack.spokenUTF16End(at: sample, transcriptLength: utf16Len))
        let spokenAdvanced = spoken > highWaterSpokenEnd
        highWaterSpokenEnd = spoken

        // The spoken end steps once per word, so both publish as they change —
        // no polling, no throttle.
        let phraseChanged = force || cue.phraseID != activeCue?.phraseID
        guard phraseChanged || spokenAdvanced else { return }

        if phraseChanged {
            activeCue = cue
            karaoke.activePhraseID = cue.phraseID
            karaoke.activePhraseUTF16Range = cue.textRange
        }
        karaoke.setSpokenUTF16End(spoken)
        VoicePerformanceMonitor.shared.noteProgressPublish()
        let seconds = Double(sample) / max(1, cueTrack.sampleRate)
        if !didPublishFirstHighlight {
            didPublishFirstHighlight = true
            VoicePerformanceMonitor.shared.noteFirstHighlight(playbackTime: seconds - completedDuration)
        }
        if phraseChanged {
            publishCompatSnapshot(level: lastPublishedLevel, current: seconds)
        }
    }

    private func publishOrbLevel(_ level: Float, force: Bool) {
        // Kept for compat snapshot / mute resets — not on the meter hot path.
        let clamped = isOutputMuted ? 0 : level
        if !force, abs(clamped - lastPublishedLevel) < 0.02 { return }
        lastPublishedLevel = clamped
        orb.publishedLevel = clamped
    }

    private func publishCompatSnapshot(level: Float, current: TimeInterval? = nil) {
        let duration = max(timelineCursor, completedDuration)
        let t = current ?? currentPlaybackTime()
        let finished = !playback.isPlaying
            && duration > 0
            && t >= duration - 0.05
            && (sessionPhase == .listening || sessionPhase == .idle)

        let phase: VoiceSessionPhase = {
            switch sessionPhase {
            case .interrupted: return .interrupted
            case .failed(let m): return .failed(m)
            case .idle, .listening, .speechDetected, .thinking, .preparingSpeech, .paused:
                if playback.isPlaying { return .speaking }
                return sessionPhase
            case .speaking:
                if playback.isPlaying { return .speaking }
                return sessionPhase
            }
        }()

        snapshot = VoicePlaybackSnapshot(
            phase: phase,
            currentTime: t,
            duration: duration,
            normalizedLevel: isOutputMuted ? 0 : level,
            activeWordIndex: nil,
            activeSegmentIndex: nil,
            spokenUTF16End: finished ? highWaterSpokenEnd : karaoke.spokenUTF16End,
            activeUTF16Range: finished ? nil : karaoke.activePhraseUTF16Range,
            isMuted: isOutputMuted,
            canInterrupt: phase == .speaking || phase == .thinking || phase == .preparingSpeech,
            canPauseResume: false,
            isFallbackEngine: controls.isFallbackEngine,
            timingSource: segments.isEmpty ? nil : timingSource,
            alignmentDetail: alignmentDetail,
            activePhraseUTF16Range: finished ? nil : karaoke.activePhraseUTF16Range
        )
    }

    private func rebase(
        _ result: SpeechAlignmentResult,
        timelineOffset: TimeInterval,
        utf16BaseOffset: Int
    ) -> SpeechAlignmentResult? {
        guard let first = result.segments.first else { return nil }
        let deltaT = timelineOffset - first.startTime
        // Engine alignments are chunk-local (0 = the chunk's first character),
        // so the shift is just the chunk's position. Subtracting the first
        // word's own offset slid every highlight left whenever a chunk opened
        // with a quote or bracket.
        let deltaUTF = utf16BaseOffset
        let segments = result.segments.map { seg in
            SpeechSegment(
                id: seg.id,
                text: seg.text,
                startTime: seg.startTime + deltaT,
                endTime: seg.endTime + deltaT,
                words: seg.words.map { w in
                    SpeechWordTiming(
                        id: w.id,
                        word: w.word,
                        startTime: w.startTime + deltaT,
                        endTime: w.endTime + deltaT,
                        utf16Range: NSRange(
                            location: max(0, w.utf16Range.location + deltaUTF),
                            length: w.utf16Range.length
                        )
                    )
                },
                timingSource: seg.timingSource
            )
        }
        return SpeechAlignmentResult(
            segments: segments,
            accuracy: result.accuracy,
            diagnosticDetail: result.diagnosticDetail
        )
    }

    private static func phaseCode(_ phase: VoiceSessionPhase) -> Int {
        switch phase {
        case .idle: return 0
        case .listening: return 1
        case .thinking: return 2
        case .preparingSpeech: return 3
        case .speaking: return 4
        case .paused: return 5
        case .interrupted: return 6
        case .failed: return 7
        case .speechDetected: return 8
        }
    }

    private static func accuracyRank(_ accuracy: SpeechAlignmentAccuracy) -> Int {
        switch accuracy {
        case .exact: return 5
        case .engineDerived: return 4
        case .acousticallyAligned: return 3
        case .estimated: return 2
        case .phraseLevel: return 1
        }
    }
}

// MARK: - Phrase grouping (compat for tests)

enum KaraokePhraseGrouper {
    static func phraseRange(
        containing active: NSRange,
        time: TimeInterval,
        segments: [SpeechSegment],
        minimumWordDuration: TimeInterval
    ) -> NSRange? {
        let timeline = KaraokePhraseBuilder.build(from: segments)
        if let phrase = timeline.phrase(at: time) {
            return phrase.utf16Range
        }
        return active
    }
}
