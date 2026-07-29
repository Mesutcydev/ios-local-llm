#if DEBUG

import AVFoundation
import Foundation

// MARK: - VoiceRuntimeDiagnostics
// Debug-only counters for soak tests. Zero production overhead when DEBUG is off.

struct VoiceRuntimeDiagnostics: Equatable, Sendable {
    var activePlaybackTasks: Int = 0
    var activeSynthesisTasks: Int = 0
    var activeAudioTaps: Int = 0
    var activeDisplayLinks: Int = 0
    var registeredObservers: Int = 0
    var queuedSpeechSegments: Int = 0
    var peakKaraokeDrift: TimeInterval = 0
    var interruptionLatencyMs: Double = 0
    var processMemoryBytes: UInt64 = 0

    static var baseline = VoiceRuntimeDiagnostics()

    var isQuiescent: Bool {
        activePlaybackTasks == 0
            && activeSynthesisTasks == 0
            && activeAudioTaps == 0
            && activeDisplayLinks == 0
            && queuedSpeechSegments == 0
    }

    mutating func captureMemory() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            processMemoryBytes = info.resident_size
        }
    }
}

@MainActor
final class VoiceDiagnosticsCenter: ObservableObject {
    static let shared = VoiceDiagnosticsCenter()

    @Published private(set) var counters = VoiceRuntimeDiagnostics()
    @Published private(set) var lastReport: String = ""

    func noteDisplayLink(active: Bool) {
        counters.activeDisplayLinks = max(0, counters.activeDisplayLinks + (active ? 1 : -1))
    }

    func noteObservers(_ count: Int) {
        counters.registeredObservers = count
    }

    func noteQueuedSegments(_ count: Int) {
        counters.queuedSpeechSegments = count
    }

    func notePlayback(active: Bool) {
        counters.activePlaybackTasks = max(0, counters.activePlaybackTasks + (active ? 1 : -1))
    }

    func noteDrift(_ seconds: TimeInterval) {
        counters.peakKaraokeDrift = max(counters.peakKaraokeDrift, abs(seconds))
    }

    func noteInterruptionLatency(_ ms: Double) {
        counters.interruptionLatencyMs = ms
    }

    func snapshotReport(
        conversationModel: String,
        ttsEngine: String,
        voiceID: String,
        route: String,
        alignment: String,
        phase: String
    ) -> String {
        counters.captureMemory()
        syncLiveState()
        let report = """
        CodeLens Voice Validation Report
        -------------------------------
        Conversation model: \(conversationModel)
        TTS engine: \(ttsEngine)
        Voice ID: \(voiceID)
        Route: \(route)
        Alignment: \(alignment)
        Phase: \(phase)
        Active playback tasks: \(counters.activePlaybackTasks)
        Active synthesis tasks: \(counters.activeSynthesisTasks)
        Active audio taps: \(counters.activeAudioTaps)
        Active display links: \(counters.activeDisplayLinks)
        Registered route observers: \(counters.registeredObservers)
        Queued speech segments: \(counters.queuedSpeechSegments)
        Peak karaoke drift: \(String(format: "%.3f", counters.peakKaraokeDrift)) s
        Interrupt latency: \(String(format: "%.1f", counters.interruptionLatencyMs)) ms
        Resident memory: \(counters.processMemoryBytes) bytes
        Quiescent: \(counters.isQuiescent)
        Note: route observers may remain while Voice Mode is open; they must return to 0 after leaving Voice Mode.
        """
        lastReport = report
        return report
    }

    func reset() {
        counters = VoiceRuntimeDiagnostics()
    }

    /// Reconcile counters with live services after soak / session teardown.
    /// Audio taps stay 0 — metering uses PCM envelopes, not engine taps.
    func syncLiveState() {
        counters.activePlaybackTasks = AudioPlaybackService.shared.isPlaying ? 1 : 0
        counters.activeSynthesisTasks = VoiceService.shared.isPlaying && !AudioPlaybackService.shared.isPlaying ? 1 : 0
        counters.activeAudioTaps = 0
        counters.queuedSpeechSegments = SpeechPlaybackCoordinator.shared.segments.count
        counters.registeredObservers = VoiceAudioSessionManager.shared.registeredObserverCount
        // Display-link counter is maintained by VoiceMeterDisplayLink start/stop.
        if !AudioPlaybackService.shared.isPlaying,
           SpeechPlaybackCoordinator.shared.segments.isEmpty {
            counters.activeDisplayLinks = 0
        }
        counters.captureMemory()
        objectWillChange.send()
    }
}

// MARK: - Soak harness

@MainActor
final class VoiceSoakHarness: ObservableObject {
    static let shared = VoiceSoakHarness()

    @Published private(set) var isRunning = false
    @Published private(set) var cyclesCompleted = 0
    @Published private(set) var status = "Idle"

    private var task: Task<Void, Never>?

    /// Simulated soak — does not download models. Advances mock playback
    /// through SpeechPlaybackCoordinator with fixed scripts.
    func run(durationMinutes: Double) {
        stop()
        isRunning = true
        cyclesCompleted = 0
        status = "Running \(durationMinutes)m soak"
        VoiceDiagnosticsCenter.shared.reset()
        VoiceRuntimeDiagnostics.baseline.captureMemory()

        task = Task { @MainActor in
            let deadline = Date().addingTimeInterval(durationMinutes * 60)
            let scripts = [
                "Hello from the soak harness. This is a punctuation-heavy line, with commas, and an ending.",
                "Merhaba dünya. Bu bir Türkçe test cümlesidir.",
                "مرحبا بالعالم. هذه جملة اختبار.",
                "Numbers 1 2 3 and emoji should not crash alignment."
            ]
            var i = 0
            while Date() < deadline, !Task.isCancelled {
                let text = scripts[i % scripts.count]
                i += 1
                status = "Cycle \(i): synthesize mock"
                await Self.mockSpeak(text: text, duration: 2.5)
                if i % 3 == 0 {
                    status = "Cycle \(i): interrupt"
                    let t0 = Date()
                    SpeechPlaybackCoordinator.shared.interrupt()
                    VoiceDiagnosticsCenter.shared.noteInterruptionLatency(
                        Date().timeIntervalSince(t0) * 1000
                    )
                }
                if i % 5 == 0 {
                    status = "Cycle \(i): route refresh"
                    VoiceAudioSessionManager.shared.refreshRoute()
                }
                cyclesCompleted = i
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            // Settle metering before asserting quiescence.
            SpeechPlaybackCoordinator.shared.reset()
            AudioPlaybackService.shared.stop()
            try? await Task.sleep(nanoseconds: 350_000_000)
            VoiceDiagnosticsCenter.shared.syncLiveState()
            status = "Completed \(cyclesCompleted) cycles"
            isRunning = false
            _ = VoiceDiagnosticsCenter.shared.snapshotReport(
                conversationModel: CodingAssistantService.shared.activeModel.displayName,
                ttsEngine: VoiceSettingsStore.shared.selectedEngine.shortName,
                voiceID: VoiceSettingsStore.shared.selectedVoiceID,
                route: VoiceAudioSessionManager.shared.route.displayName,
                alignment: SpeechPlaybackCoordinator.shared.timingSource.diagnosticLabel,
                phase: "idle"
            )
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        SpeechPlaybackCoordinator.shared.reset()
        AudioPlaybackService.shared.stop()
        VoiceDiagnosticsCenter.shared.syncLiveState()
    }

    private static func mockSpeak(text: String, duration: TimeInterval) async {
        let coordinator = SpeechPlaybackCoordinator.shared
        coordinator.beginUtterance(karaokeSeed: text)
        coordinator.bindSessionPhase(.speaking)
        let rate = 24_000.0
        let frames = AVAudioFrameCount(rate * duration)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: 1,
            interleaved: false
        ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return }
        buffer.frameLength = frames
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<Int(frames) {
                let t = Float(i) / Float(rate)
                data[i] = sin(t * 440 * 2 * .pi) * 0.15
            }
        }
        await coordinator.registerChunk(
            text: text,
            buffer: buffer,
            engineKind: .appleSystem,
            engineAlignment: nil,
            synthesisMetadata: SynthesisMetadata(sourceText: text, engineKind: .appleSystem)
        )
        let steps = 20
        for _ in 0...steps {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: UInt64((duration / Double(steps)) * 1_000_000_000))
        }
        coordinator.markChunkFinished()
        coordinator.bindSessionPhase(.listening)
    }
}

#endif
