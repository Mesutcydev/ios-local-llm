import AVFoundation
import Foundation

// MARK: - VoiceAudioSessionManager
// Central description of Voice Mode session policy. Category/mode changes
// still run through VoiceConversationService.applyConversationSession so we
// do not duplicate activate/deactivate races — this type owns the *policy*
// and route snapshot used by UI.

enum VoiceAudioMode: Sendable, Equatable {
    /// Mic open for listening / VAD. Needs input + Bluetooth HFP mic.
    case listening
    /// TTS playback. Prefer high-quality A2DP; avoid full-duplex zombie path.
    case speaking
    case idle
}

struct AudioRouteSnapshot: Sendable, Equatable {
    let portName: String
    let portTypeRaw: String
    let uid: String
    let isBluetooth: Bool
    let hasMultipleOutputs: Bool

    var displayName: String {
        if portName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return portTypeRaw
        }
        return portName
    }

    var symbolName: String {
        switch portTypeRaw {
        case AVAudioSession.Port.builtInSpeaker.rawValue: return "speaker.wave.2.fill"
        case AVAudioSession.Port.builtInReceiver.rawValue: return "ear"
        case AVAudioSession.Port.headphones.rawValue: return "headphones"
        case AVAudioSession.Port.bluetoothA2DP.rawValue,
             AVAudioSession.Port.bluetoothLE.rawValue,
             AVAudioSession.Port.bluetoothHFP.rawValue: return "airpodspro"
        case AVAudioSession.Port.airPlay.rawValue: return "airplayaudio"
        case AVAudioSession.Port.carAudio.rawValue: return "car.fill"
        default: return "hifispeaker.fill"
        }
    }

    static func current(session: AVAudioSession = .sharedInstance()) -> AudioRouteSnapshot {
        let outputs = session.currentRoute.outputs
        let primary = outputs.first
        let type = primary?.portType ?? .builtInSpeaker
        let name = primary?.portName ?? "iPhone Speaker"
        let uid = primary?.uid ?? type.rawValue
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        return AudioRouteSnapshot(
            portName: name,
            portTypeRaw: type.rawValue,
            uid: uid,
            isBluetooth: bluetooth.contains(type),
            hasMultipleOutputs: outputs.count > 1
        )
    }
}

/// Documents session options and provides route observation for Voice Mode UI.
@MainActor
final class VoiceAudioSessionManager: ObservableObject {
    static let shared = VoiceAudioSessionManager()

    @Published private(set) var route: AudioRouteSnapshot = .current()
    @Published private(set) var lastRouteChangeReason: String = ""

    private var observers: [NSObjectProtocol] = []

    /// Why each option exists (do not add options indiscriminately):
    ///
    /// Listening (`.playAndRecord` + `.spokenAudio`):
    ///   • `.defaultToSpeaker` — audible on device without a headset
    ///   • `.duckOthers` — keep assistant replies intelligible
    ///   • `.allowBluetoothHFP` — headset mic for dictation (HFP)
    ///
    /// Speaking (`.playback` + `.spokenAudio`):
    ///   • `.duckOthers` only — A2DP is automatic on `.playback`;
    ///     `.allowBluetoothA2DP` is for input-capable categories and can
    ///     fail the transition, leaving TTS on HFP ("zombie" voice).
    static func policy(for mode: VoiceAudioMode) -> (
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) {
        switch mode {
        case .listening:
            return (.playAndRecord, .spokenAudio, [.defaultToSpeaker, .duckOthers, .allowBluetoothHFP])
        case .speaking:
            return (.playback, .spokenAudio, [.duckOthers])
        case .idle:
            return (.playback, .spokenAudio, [.duckOthers])
        }
    }

    func startObserving() {
        stopObserving()
        refreshRoute()
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
                Task { @MainActor in
                    self?.handleRouteChange(note)
                }
            }
        )
        observers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshRoute()
                }
            }
        )
        observers.append(
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshRoute()
                    self?.lastRouteChangeReason = "mediaServicesReset"
                }
            }
        )
        #if DEBUG
        VoiceDiagnosticsCenter.shared.noteObservers(observers.count)
        #endif
    }

    func stopObserving() {
        let center = NotificationCenter.default
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        #if DEBUG
        VoiceDiagnosticsCenter.shared.noteObservers(0)
        #endif
    }

    /// DEBUG soak: how many route/interruption observers this manager holds.
    var registeredObserverCount: Int { observers.count }

    func refreshRoute() {
        route = .current()
    }

    private func handleRouteChange(_ note: Notification) {
        let reasonValue = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
            .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        let reason: String = {
            switch reasonValue {
            case .some(.newDeviceAvailable): return "newDeviceAvailable"
            case .some(.oldDeviceUnavailable): return "oldDeviceUnavailable"
            case .some(.categoryChange): return "categoryChange"
            case .some(.override): return "override"
            case .some(.wakeFromSleep): return "wakeFromSleep"
            case .some(.routeConfigurationChange): return "routeConfigurationChange"
            default: return "unknown"
            }
        }()
        lastRouteChangeReason = reason
        let previous = route
        refreshRoute()
        Diagnostics.shared.notice(
            "Audio route \(reason): \(previous.displayName) → \(route.displayName)",
            category: "voice"
        )
    }

    deinit {
        let center = NotificationCenter.default
        for token in observers { center.removeObserver(token) }
    }
}
