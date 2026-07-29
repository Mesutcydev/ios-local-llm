import Foundation
import SwiftUI

// MARK: - VoiceSettingsViewModel
// Drives the VoiceSettingsView UI.
// Reads/writes through AppSettings @AppStorage and calls VoiceService as needed.

@MainActor
final class VoiceSettingsViewModel: ObservableObject {

    // MARK: - Services

    private let voiceService = VoiceService.shared
    private let settings = AppSettings.shared
    let voiceSettings = VoiceSettingsStore.shared

    // MARK: - Engine selection

    var selectedEngineKind: VoiceEngineKind {
        get { voiceSettings.selectedEngine }
        set {
            voiceSettings.selectEngine(newValue)
            // Auto-select the first available voice for the new engine
            if let first = voicesForEngine(newValue).first {
                settings.voiceID = first.id
            }
            // Load the engine if it requires it and isn't ready yet
            Task { await voiceService.load() }
        }
    }

    // MARK: - Voice selection

    var voices: [VoiceOption] { voicesForEngine(selectedEngineKind) }

    /// Backed by AppSettings but auto-corrects when the stored value
    /// doesn't belong to the current engine's voice list — this is the
    /// fix for the "Picker: the selection 'kokoro:default' is invalid"
    /// SwiftUI fault. A user can have a Kokoro voice persisted from an
    /// older build; once the Kokoro engine moves out of the user-
    /// selectable list, the picker has nothing matching to highlight.
    /// Returning (and persisting) the first available voice keeps the
    /// UI consistent without forcing the user through a manual reset.
    var selectedVoiceID: String {
        get {
            let stored = settings.voiceID
            if voices.contains(where: { $0.id == stored }) {
                // Auto-upgrade a persisted compact Default Apple voice
                // to Enhanced/Premium so older installs stop sounding
                // zombie without the user hunting through the picker.
                if selectedEngineKind == .appleSystem,
                   let current = voices.first(where: { $0.id == stored }) {
                    let upgraded = voiceService.systemEngine.upgradedVoice(for: current)
                    if upgraded.id != stored {
                        settings.voiceID = upgraded.id
                        return upgraded.id
                    }
                }
                return stored
            }
            if let first = voices.first {
                let chosen: VoiceOption
                if selectedEngineKind == .appleSystem {
                    chosen = voiceService.systemEngine.upgradedVoice(for: first)
                } else {
                    chosen = first
                }
                settings.voiceID = chosen.id
                return chosen.id
            }
            return stored
        }
        set { voiceSettings.selectVoice(newValue) }
    }

    var selectedVoice: VoiceOption? {
        voices.first { $0.id == selectedVoiceID } ?? voices.first
    }

    // MARK: - Sliders

    var speed: Double {
        get { settings.voiceSpeed }
        set { settings.voiceSpeed = newValue }
    }

    var pitch: Double {
        get { settings.voicePitch }
        set { settings.voicePitch = newValue }
    }

    var volume: Double {
        get { settings.voiceVolume }
        set { settings.voiceVolume = newValue }
    }

    // MARK: - Toggles

    var autoRead: Bool {
        get { settings.voiceAutoRead }
        set { settings.voiceAutoRead = newValue }
    }

    var readCodeBlocks: Bool {
        get { settings.voiceReadCodeBlocks }
        set { settings.voiceReadCodeBlocks = newValue }
    }

    // MARK: - Engine state helpers

    func stateForEngine(_ kind: VoiceEngineKind) -> VoiceModelState {
        switch kind {
        case .appleSystem: return voiceService.systemState
        case .kittenTTS:   return voiceService.kittenState
        case .kokoro:      return voiceService.kokoroState
        }
    }

    var selectedEngineState: VoiceModelState { stateForEngine(selectedEngineKind) }

    var isModelAvailable: Bool {
        switch selectedEngineKind {
        case .appleSystem: return true
        case .kittenTTS:   return VoiceModelBundleValidator.isKittenTTSAvailable()
        case .kokoro:      return VoiceModelBundleValidator.isKokoroAvailable()
        }
    }

    var downloadInstructions: String {
        switch selectedEngineKind {
        case .appleSystem: return ""
        case .kittenTTS:
            return "KittenTTS model not installed. Open Models → Download to fetch it (~61 MB)."
        case .kokoro:
            return "Kokoro is no longer available on this device. Voice Mode can use Apple TTS until it is downloaded again."
        }
    }

    // MARK: - Preview / test

    func previewVoice() {
        let text = "Hello! This is a preview of the selected voice."
        voiceService.speak(text)
    }

    func stopPreview() {
        voiceService.stop()
    }

    var isPreviewPlaying: Bool { voiceService.isPlaying }

    // MARK: - Helpers

    private func voicesForEngine(_ kind: VoiceEngineKind) -> [VoiceOption] {
        switch kind {
        case .appleSystem: return voiceService.systemEngine.availableVoices
        case .kittenTTS:   return KittenTTSService.kittenVoices
        case .kokoro:      return KokoroTTSService.kokoroVoices
        }
    }
}
