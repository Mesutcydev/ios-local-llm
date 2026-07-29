import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Accessibility strings and announcements for ``VoiceAgentOrb``.
///
/// State meaning is never communicated by color alone: the orb carries a
/// label, an optional visible status text, and announcements for major
/// transitions. Microphone/playback levels are never announced.
public enum VoiceOrbAccessibility {

    /// VoiceOver label for the orb element.
    public static func label(for state: VoiceOrbState) -> String {
        switch state.kind {
        case .idle: return "Voice assistant, ready"
        case .preparing: return "Voice assistant, preparing model"
        case .listening: return "Voice assistant, listening"
        case .speechDetected: return "Voice assistant, speech detected"
        case .transcribing: return "Voice assistant, transcribing"
        case .thinking: return "Voice assistant, thinking"
        case .speaking: return "Voice assistant, speaking"
        case .interrupted: return "Voice assistant, interrupted"
        case .error: return "Voice assistant, error"
        case .disabled: return "Voice assistant, unavailable"
        }
    }

    /// Short visible status text for the optional label beneath the orb.
    public static func statusText(for state: VoiceOrbState) -> String {
        switch state.kind {
        case .idle: return "Ready"
        case .preparing:
            if let progress = state.normalizedProgress {
                return "Preparing \(Int((progress * 100).rounded()))%"
            }
            return "Preparing"
        case .listening: return "Listening"
        case .speechDetected: return "Listening"
        case .transcribing: return "Transcribing"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .interrupted: return "Interrupted"
        case .error: return "Something went wrong"
        case .disabled: return "Voice unavailable"
        }
    }

    /// Announcement text for major transitions only. Returns `nil` for states
    /// that should stay quiet (preparing, transcribing, thinking, …) so
    /// VoiceOver is not spammed during a normal conversation flow.
    public static func announcementText(for state: VoiceOrbState) -> String? {
        switch state.kind {
        case .listening: return "Listening"
        case .speaking: return "Assistant is speaking"
        case .interrupted: return "Interrupted"
        case .error: return "Voice assistant error"
        case .disabled: return "Voice assistant unavailable"
        case .idle, .preparing, .speechDetected, .transcribing, .thinking:
            return nil
        }
    }

    /// Posts an announcement to the assistive technology, if any is required.
    @MainActor
    public static func announceIfNeeded(for state: VoiceOrbState) {
        guard let text = announcementText(for: state) else { return }
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: text)
        #elseif canImport(AppKit)
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text]
        )
        #endif
    }
}

// MARK: - Haptics

/// Sparingly-used haptics: light tap when listening begins, soft tap when the
/// assistant starts speaking, warning for a real error. Never fired from
/// animation frames or audio peaks.
@MainActor
final class VoiceOrbHaptics {
    #if canImport(UIKit)
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let warning = UINotificationFeedbackGenerator()

    func prepare() {
        light.prepare()
        soft.prepare()
        warning.prepare()
    }
    #else
    func prepare() {}
    #endif

    func fire(for kind: VoiceOrbStateKind) {
        #if canImport(UIKit)
        switch kind {
        case .listening:
            light.impactOccurred()
        case .speaking:
            soft.impactOccurred()
        case .error:
            warning.notificationOccurred(.warning)
        default:
            break
        }
        #endif
    }
}
