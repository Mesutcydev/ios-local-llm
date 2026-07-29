import UIKit

// MARK: - HapticManager
// Thin wrapper around UIImpactFeedbackGenerator.
// All calls are no-ops when hapticsEnabled = false.

enum HapticManager {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        guard AppSettings.shared.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard AppSettings.shared.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }

    static func selection() {
        guard AppSettings.shared.hapticsEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // Convenience presets
    static func capture()          { impact(.heavy) }
    static func analysisComplete() { notification(.success) }
    static func error()            { notification(.error) }
    static func messageSent()      { impact(.light) }
    static func tabSwitch()        { selection() }
}
