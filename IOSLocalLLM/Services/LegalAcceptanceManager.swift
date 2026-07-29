import Foundation
import SwiftUI

// MARK: - LegalAcceptanceManager
// Tracks whether the user has accepted the current version of the legal
// documents. When `LegalDocuments.currentVersion` is bumped, existing users
// are re-prompted on next launch.

@MainActor
final class LegalAcceptanceManager: ObservableObject {

    static let shared = LegalAcceptanceManager()

    // Persisted version of legal docs the user accepted; 0 = never accepted.
    @AppStorage("legalAcceptedVersion")   var acceptedVersion: Int = 0
    @AppStorage("aiDisclaimerAccepted")   var aiDisclaimerAccepted: Bool = false
    /// Recorded timestamp (epoch seconds) the user accepted the current legal
    /// version. Useful evidence in disputes that the user did consent.
    @AppStorage("legalAcceptedAt")        var acceptedAtEpoch: Double = 0
    /// Device-safety notice acceptance (separate so we can re-prompt if we
    /// materially change the wording without re-prompting for the whole EULA).
    @AppStorage("deviceSafetyAccepted")   var deviceSafetyAccepted: Bool = false
    /// One-time "AI-generated code" reminder shown the first time the user
    /// copies code from an assistant reply. Auto-flipped to true after shown.
    @AppStorage("codeWarningShown")       var codeWarningShown: Bool = false

    // MARK: - Computed

    var needsAcceptance: Bool {
        acceptedVersion < LegalDocuments.currentVersion
    }

    var needsDisclaimerAcceptance: Bool {
        !aiDisclaimerAccepted
    }

    var needsDeviceSafetyAcceptance: Bool {
        !deviceSafetyAccepted
    }

    /// True when ANY required acceptance is outstanding — the legal/EULA
    /// version, the AI disclaimer, or the device-safety notice. The root
    /// gate binds to this so flipping `deviceSafetyAccepted`/`aiDisclaimerAccepted`
    /// back to false (or changing only their wording) actually re-prompts,
    /// instead of the version-only `needsAcceptance` silently swallowing it.
    var needsAnyAcceptance: Bool {
        needsAcceptance || needsDisclaimerAcceptance || needsDeviceSafetyAcceptance
    }

    /// Human-readable acceptance date, or nil if never accepted.
    var acceptedAtDescription: String? {
        guard acceptedAtEpoch > 0 else { return nil }
        let date = Date(timeIntervalSince1970: acceptedAtEpoch)
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - Actions

    func acceptLegal() {
        acceptedVersion = LegalDocuments.currentVersion
        acceptedAtEpoch = Date().timeIntervalSince1970
    }

    func acceptDisclaimer() {
        aiDisclaimerAccepted = true
    }

    func acceptDeviceSafety() {
        deviceSafetyAccepted = true
    }

    /// Call when the user copies code from an assistant reply. Shows a
    /// one-time toast reminder; subsequent copies are silent.
    func markCodeCopiedAndWarnIfNeeded() {
        guard !codeWarningShown else { return }
        codeWarningShown = true
        ToastCenter.shared.info(
            "Heads up: AI-generated code",
            detail: "Always review and test before running. The model can produce convincing-looking bugs."
        )
    }

    /// For Settings → reset (e.g. before testing).
    func reset() {
        acceptedVersion = 0
        acceptedAtEpoch = 0
        aiDisclaimerAccepted = false
        deviceSafetyAccepted = false
        codeWarningShown = false
    }
}
