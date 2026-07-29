@preconcurrency import AVFoundation
import Foundation

// MARK: - AudioPlaybackService
// One AVAudioEngine + one AVAudioPlayerNode. Streaming TTS schedules
// consecutive PCM buffers on a continuous sample timeline. The audio
// sample clock (playerTime) is the source of truth for karaoke/orb.

@MainActor
final class AudioPlaybackService: ObservableObject {

    static let shared = AudioPlaybackService()

    @Published private(set) var isPlaying = false
    @Published private(set) var currentBufferDuration: TimeInterval = 0
    @Published private(set) var outputVolume: Float = 1

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let snapshotStore = AudioPlaybackSnapshotStore.shared
    private let meterAtomics = AudioMeterAtomics.shared

    private var generation: UInt64 = 0
    private var scheduledSampleCount: Int64 = 0
    private var sampleRate: Double = 24_000
    private var pendingCompletions = 0
    private var tapInstalled = false
    private var idleStopTask: Task<Void, Never>?
    private var regions: [ScheduledPCMRegion] = []
    /// Format of the established player→mixer connection. Reconnecting
    /// mid-play re-rates already-queued buffers (audible speed shift) and
    /// glitches the render graph, so once connected we only reconnect while
    /// the queue is idle — live format mismatches are converted instead.
    private var connectedFormat: AVAudioFormat?

    struct ScheduledPCMRegion: Sendable {
        let generation: UInt64
        let startSample: Int64
        let frameCount: Int64
    }

    private init() {
        engine.attach(playerNode)
    }

    // MARK: - Clock

    /// Live position within the continuous utterance timeline (seconds).
    var currentTime: TimeInterval {
        let snap = refreshSnapshotFromPlayer(targetHostTime: 0)
        let sr = max(1, snap.sampleRate)
        return Double(snap.currentPlayerSample) / sr
    }

    var playbackGeneration: UInt64 { generation }

    var continuousScheduledSamples: Int64 { scheduledSampleCount }

    /// Sample rate of the live player→mixer connection — the render domain
    /// the player clock (and therefore karaoke cue lookups) runs in.
    var renderSampleRate: Double { connectedFormat?.sampleRate ?? sampleRate }

    /// Number of scheduled buffers not yet consumed.
    var queuedBufferCount: Int { pendingCompletions }

    /// Begin a new utterance timeline. Increments generation; flushes node.
    func beginUtteranceTimeline(sampleRate: Double? = nil) {
        generation &+= 1
        scheduledSampleCount = 0
        regions.removeAll(keepingCapacity: true)
        pendingCompletions = 0
        if let sampleRate { self.sampleRate = sampleRate }
        meterAtomics.reset()
        stopPlayerOnly(preserveEngine: true)
        publishIdleSnapshot(isPlaying: false)
    }

    func noteRouteChanged() {
        snapshotStore.update { snap in
            snap.outputPresentationLatency = AudioVisualClock.currentOutputPresentationLatency()
        }
    }

    // MARK: - Volume

    func setVolume(_ volume: Float) {
        let v = max(0, min(1, volume))
        outputVolume = v
        playerNode.volume = v
    }

    // MARK: - Play (continuous schedule)

    /// Schedules PCM and waits until that buffer is consumed. The player node
    /// is never stopped between chunks of the same utterance — sampleTime
    /// stays continuous across buffer boundaries.
    /// Returns the sample position (render domain) the buffer was placed at.
    @discardableResult
    func play(buffer: AVAudioPCMBuffer, volume: Float = 1.0) async -> Int64 {
        guard buffer.frameLength > 0 else { return scheduledSampleCount }
        return await enqueue(buffer: buffer, volume: volume, waitForConsumption: true)
    }

    /// Schedule without awaiting consumption — used to keep 1 buffer ahead.
    /// Returns the sample position (render domain) the buffer was placed at.
    @discardableResult
    func schedule(buffer: AVAudioPCMBuffer, volume: Float = 1.0) async -> Int64 {
        guard buffer.frameLength > 0 else { return scheduledSampleCount }
        return await enqueue(buffer: buffer, volume: volume, waitForConsumption: false)
    }

    /// Wait until the player queue drains for the current generation.
    func waitUntilQueueDrained() async {
        while pendingCompletions > 0, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func enqueue(buffer: AVAudioPCMBuffer, volume: Float, waitForConsumption: Bool) async -> Int64 {
        idleStopTask?.cancel()
        idleStopTask = nil

        let mainMixer = engine.mainMixerNode
        if playerNode.engine == nil {
            engine.attach(playerNode)
        }

        // Keep one render format for the whole utterance. The old code ran
        // disconnectNodeInput + connect before EVERY chunk — mid-play graph
        // reconfig glitched the output, and when a queue mixed rates (neural
        // 24 kHz + system 22.05 kHz via language routing / fallback) the
        // reconnect re-rated already-queued buffers → audible speed shift.
        // Now: reconnect only while the queue is idle; convert live mismatches.
        var renderBuffer = buffer
        if let connected = connectedFormat {
            if connected != buffer.format {
                if playerNode.isPlaying || pendingCompletions > 0,
                   let converted = Self.convert(buffer, to: connected) {
                    renderBuffer = converted
                } else {
                    engine.disconnectNodeInput(mainMixer)
                    engine.connect(playerNode, to: mainMixer, format: buffer.format)
                    connectedFormat = buffer.format
                }
            }
        } else {
            engine.disconnectNodeInput(mainMixer)
            engine.connect(playerNode, to: mainMixer, format: buffer.format)
            connectedFormat = buffer.format
        }

        let format = renderBuffer.format
        sampleRate = format.sampleRate

        let sessionWasManagedElsewhere = isSessionManagedExternally()
        do {
            if !engine.isRunning {
                if !sessionWasManagedElsewhere {
                    try configureAudioSession()
                }
                try engine.start()
                installMeterTapIfNeeded(format: mainMixer.outputFormat(forBus: 0))
            }
        } catch {
            print("[AudioPlaybackService] Engine start failed: \(error)")
            return scheduledSampleCount
        }

        let effectiveVolume = max(0, min(1, volume)) * outputVolume
        playerNode.volume = effectiveVolume

        let frames = Int64(renderBuffer.frameLength)
        let gen = generation
        // Underrun-aware placement: the player clock keeps advancing through
        // synthesis gaps (see the underrun check in refreshSnapshotFromPlayer),
        // so a naive contiguous start lands in the PAST — the cue track then
        // leaps mid-chunk and karaoke appears to jump words/sentences. Anchor
        // each chunk at the real playhead (+10 ms scheduling lead).
        var startSample = scheduledSampleCount
        if let nodeTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
           playerTime.isSampleTimeValid {
            let lead = Int64((0.01 * sampleRate).rounded())
            startSample = max(startSample, playerTime.sampleTime + lead)
        }
        scheduledSampleCount = startSample + frames
        regions.append(ScheduledPCMRegion(generation: gen, startSample: startSample, frameCount: frames))

        let seconds = Double(frames) / max(1, sampleRate)
        currentBufferDuration = seconds
        setPlaying(true)
        pendingCompletions += 1

        snapshotStore.update { snap in
            snap.generation = gen
            snap.isPlaying = true
            snap.sampleRate = sampleRate
            snap.scheduledSampleCount = scheduledSampleCount
            snap.outputPresentationLatency = AudioVisualClock.currentOutputPresentationLatency()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let guardian = ContinuationGuard(continuation)
            playerNode.scheduleBuffer(renderBuffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                // Render-thread callback: only hop for bookkeeping — no SwiftUI.
                Task { @MainActor [weak self] in
                    guard let self else {
                        if waitForConsumption { guardian.resume() }
                        return
                    }
                    self.handleBufferConsumed(
                        generation: gen,
                        waitGuardian: waitForConsumption ? guardian : nil
                    )
                }
            }
            if !playerNode.isPlaying {
                playerNode.play()
            }
            _ = refreshSnapshotFromPlayer(targetHostTime: 0)

            if !waitForConsumption {
                guardian.resume()
            } else {
                let budget = seconds + 2.0
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                    guard let self else { return }
                    if guardian.resume() {
                        self.handleWatchdogTimeout()
                        print("[AudioPlaybackService] playback watchdog fired after \(String(format: "%.1f", budget))s")
                    }
                }
            }
        }

        scheduleEngineIdleStop()
        return startSample
    }

    /// Offline sample-rate/channel conversion so a mismatched chunk can join
    /// the live connection format without touching the render graph.
    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, statusPtr in
            if consumed {
                statusPtr.pointee = .endOfStream
                return nil
            }
            consumed = true
            statusPtr.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    private func handleBufferConsumed(generation gen: UInt64, waitGuardian: ContinuationGuard?) {
        guard gen == generation else {
            waitGuardian?.resume()
            return
        }
        pendingCompletions = max(0, pendingCompletions - 1)
        if pendingCompletions == 0 {
            setPlaying(false)
            meterAtomics.reset()
            snapshotStore.update { snap in
                snap.isPlaying = false
                snap.outputRMS = 0
                snap.outputPeak = 0
            }
            SpeechPlaybackCoordinator.shared.markChunkFinished()
        }
        waitGuardian?.resume()
    }

    private func handleWatchdogTimeout() {
        setPlaying(false)
        pendingCompletions = 0
        scheduledSampleCount = 0
        if playerNode.isPlaying { playerNode.stop() }
        meterAtomics.reset()
        publishIdleSnapshot(isPlaying: false)
    }

    // MARK: - Snapshot from playerTime

    /// Pull AVAudioPlayerNode clock into the snapshot store.
    @discardableResult
    func refreshSnapshotFromPlayer(targetHostTime: UInt64) -> AudioPlaybackSnapshot {
        var snap = snapshotStore.load()
        snap.generation = generation
        snap.sampleRate = sampleRate
        snap.scheduledSampleCount = scheduledSampleCount
        snap.outputPresentationLatency = AudioVisualClock.currentOutputPresentationLatency()
        snap.isPlaying = isPlaying || playerNode.isPlaying

        if let nodeTime = playerNode.lastRenderTime,
           nodeTime.isHostTimeValid || nodeTime.isSampleTimeValid,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
           playerTime.isSampleTimeValid {
            snap.currentPlayerSample = playerTime.sampleTime
            if nodeTime.isHostTimeValid {
                snap.renderHostTime = nodeTime.hostTime
            }
            sampleRate = playerTime.sampleRate > 0 ? playerTime.sampleRate : sampleRate
            snap.sampleRate = sampleRate
        }

        let meter = meterAtomics.read()
        snap.outputRMS = meter.rms
        snap.outputPeak = meter.peak

        // Detect underrun: playing but nothing scheduled ahead of playhead.
        if snap.isPlaying,
           snap.scheduledSampleCount > 0,
           snap.currentPlayerSample >= snap.scheduledSampleCount,
           pendingCompletions == 0 {
            snap.underrunCount &+= 1
        }

        _ = targetHostTime // reserved for future extrapolated write
        snapshotStore.store(snap)
        return snap
    }

    // MARK: - Meter tap (audio thread)

    private func installMeterTapIfNeeded(format: AVAudioFormat) {
        guard !tapInstalled else { return }
        // Tap the mixer output — bounded DSP only.
        let bus: AVAudioNodeBus = 0
        let bufferSize: AVAudioFrameCount = 1024
        engine.mainMixerNode.installTap(onBus: bus, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            Self.computeAndStoreMeter(buffer: buffer, atomics: self.meterAtomics)
        }
        tapInstalled = true
    }

    private static func computeAndStoreMeter(buffer: AVAudioPCMBuffer, atomics: AudioMeterAtomics) {
        guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        var peak: Float = 0
        let step = max(1, n / 256)
        var i = 0
        var count = 0
        while i < n {
            let v = data[i]
            let a = v < 0 ? -v : v
            sum += a * a
            if a > peak { peak = a }
            i += step
            count += 1
        }
        let rms = count > 0 ? sqrt(sum / Float(count)) : 0
        // Soft normalize for TTS levels.
        atomics.write(rms: min(1, rms * 2.4), peak: min(1, peak * 1.8))
    }

    private func removeMeterTap() {
        guard tapInstalled else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    private func isSessionManagedExternally() -> Bool {
        AVAudioSession.sharedInstance().category == .playAndRecord
            && VoiceConversationService.shared.isHoldingRecordSession
    }

    // MARK: - Stop

    private func stopPlayerOnly(preserveEngine: Bool) {
        idleStopTask?.cancel()
        idleStopTask = nil
        if playerNode.isPlaying { playerNode.stop() }
        // Reset the player's timeline when clearing the queue.
        playerNode.reset()
        setPlaying(false)
        currentBufferDuration = 0
        if !preserveEngine {
            // no-op
        }
    }

    func stop() {
        generation &+= 1
        scheduledSampleCount = 0
        regions.removeAll()
        pendingCompletions = 0
        idleStopTask?.cancel()
        idleStopTask = nil
        if playerNode.isPlaying { playerNode.stop() }
        playerNode.reset()
        removeMeterTap()
        if engine.isRunning { engine.stop() }
        setPlaying(false)
        currentBufferDuration = 0
        meterAtomics.reset()
        publishIdleSnapshot(isPlaying: false)
    }

    private func setPlaying(_ playing: Bool) {
        // Avoid re-publishing identical `true` on every streamed chunk — that
        // was restarting the meter display-link observer path unnecessarily.
        guard playing != isPlaying else { return }
        isPlaying = playing
        #if DEBUG
        VoiceDiagnosticsCenter.shared.notePlayback(active: playing)
        #endif
    }

    private func publishIdleSnapshot(isPlaying: Bool) {
        var snap = AudioPlaybackSnapshot.idle
        snap.generation = generation
        snap.isPlaying = isPlaying
        snap.sampleRate = sampleRate
        snap.scheduledSampleCount = scheduledSampleCount
        snap.outputPresentationLatency = AudioVisualClock.currentOutputPresentationLatency()
        snapshotStore.store(snap)
    }

    private func scheduleEngineIdleStop() {
        idleStopTask?.cancel()
        guard !isSessionManagedExternally() else { return }
        idleStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            guard !self.isPlaying, self.engine.isRunning else { return }
            self.removeMeterTap()
            self.engine.stop()
        }
    }

    // MARK: - Buffer helper

    static func makeBuffer(
        from samples: [Float],
        sampleRate: Double,
        channels: AVAudioChannelCount = 1
    ) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else { return nil }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            channelData.initialize(from: base, count: samples.count)
        }
        return buffer
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = [.duckOthers]
        let alreadyConfigured = session.category == .playback
            && session.mode == .spokenAudio
            && session.categoryOptions == options
        if !alreadyConfigured {
            if session.category == .playAndRecord || session.category == .record {
                try? session.setActive(false, options: [])
            }
            try session.setCategory(.playback, mode: .spokenAudio, options: options)
        }
        try session.setActive(true)
    }
}

// MARK: - Continuation resume-once guard

private final class ContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume() -> Bool {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
        return c != nil
    }
}
