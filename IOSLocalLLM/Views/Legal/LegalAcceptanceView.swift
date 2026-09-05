import SwiftUI

// MARK: - LegalAcceptanceView
// Full-screen gate shown on first launch and whenever the legal version is
// bumped. The user must accept Privacy + EULA + AI Disclaimer before the
// main app UI is reachable.

struct LegalAcceptanceView: View {

    @StateObject private var legal = LegalAcceptanceManager.shared
    @State private var didReadPrivacy = false
    @State private var didReadEULA    = false
    @State private var didReadDisclaimer = false
    @State private var didReadDeviceSafety = false

    @State private var showPrivacy = false
    @State private var showEULA    = false
    @State private var showDisclaimer = false
    @State private var showDeviceSafety = false
    @Environment(\.koduTheme) private var T

    let onAccepted: () -> Void

    private var canContinue: Bool {
        didReadPrivacy && didReadEULA && didReadDisclaimer && didReadDeviceSafety
    }

    var body: some View {
        ZStack {
            LiquidPinkBackdrop()

            ScrollView {
                VStack(spacing: 16) {
                    headerView
                    Spacer().frame(height: 4)
                    rowFor(title: "privacy policy",
                           subtitle: "how your data is (not) handled",
                           icon: "lock.shield",
                           tint: T.good,
                           accepted: $didReadPrivacy,
                           openAction: { showPrivacy = true })
                    rowFor(title: "open-source license & safety",
                           subtitle: "MIT license and important notices",
                           icon: "doc.text",
                           tint: T.accent,
                           accepted: $didReadEULA,
                           openAction: { showEULA = true })
                    rowFor(title: "ai output disclaimer",
                           subtitle: "ai can be wrong — always verify",
                           icon: "exclamationmark.triangle",
                           tint: T.warn,
                           accepted: $didReadDisclaimer,
                           openAction: { showDisclaimer = true })
                    rowFor(title: "device safety notice",
                           subtitle: "on-device ai heats the device — what to know",
                           icon: "thermometer.medium",
                           tint: T.bad,
                           accepted: $didReadDeviceSafety,
                           openAction: { showDeviceSafety = true })

                    Spacer().frame(height: 16)

                    Button {
                        legal.acceptLegal()
                        legal.acceptDisclaimer()
                        legal.acceptDeviceSafety()
                        HapticManager.impact(.medium)
                        onAccepted()
                    } label: {
                        HStack {
                            Text("agree and continue")
                                .font(T.mono(14, .semibold))
                                .tracking(0.3)
                            Spacer()
                            Text("↵")
                                .font(T.mono(11))
                                .foregroundColor(T.ink4)
                        }
                        .foregroundColor(canContinue ? T.bg : T.ink3)
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(canContinue ? T.ink : T.surface2))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canContinue)

                    Text("By tapping Agree, you confirm that you have read and accepted all four documents above. You can review them any time in Settings → Legal.")
                        .font(T.sans(11))
                        .foregroundColor(T.ink3)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 6)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 30)
            }
        }
        // Each doc counts as "read" ONLY after the user scrolls to the end and
        // taps "I have read this" (onReadConfirmed) — not merely on dismiss.
        .sheet(isPresented: $showPrivacy) {
            LegalDocumentView(
                title: "Privacy Policy",
                markdown: LegalDocuments.privacyPolicy,
                externalURL: LegalDocuments.privacyPolicyURL,
                onReadConfirmed: { didReadPrivacy = true }
            )
        }
        .sheet(isPresented: $showEULA) {
            LegalDocumentView(
                title: "License & Safety",
                markdown: LegalDocuments.eula,
                externalURL: LegalDocuments.eulaURL,
                onReadConfirmed: { didReadEULA = true }
            )
        }
        .sheet(isPresented: $showDisclaimer) {
            LegalDocumentView(
                title: "AI Disclaimer",
                markdown: LegalDocuments.aiDisclaimer,
                onReadConfirmed: { didReadDisclaimer = true }
            )
        }
        .sheet(isPresented: $showDeviceSafety) {
            LegalDocumentView(
                title: "Device Safety",
                markdown: LegalDocuments.deviceSafetyNotice,
                onReadConfirmed: { didReadDeviceSafety = true }
            )
        }
    }

    // MARK: - Sub-views

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            KWordmark(name: "OnDevice Core", logoAsset: "app_logo_small")
            VStack(alignment: .leading, spacing: 4) {
                KCaption(text: "first launch")
                Text("Before\nyou start.")
                    .font(T.display(34, .semibold))
                    .tracking(-1.2)
                    .foregroundColor(T.ink)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
            Text("Review the four documents below. Tap each to read.")
                .font(T.sans(13))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rowFor(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        accepted: Binding<Bool>,
        openAction: @escaping () -> Void
    ) -> some View {
        Button(action: openAction) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(tint)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    KMono(text: title, size: 13, weight: .semibold, color: T.ink)
                    KMono(text: subtitle, size: 10, color: T.ink3)
                }

                Spacer()

                if accepted.wrappedValue {
                    Text("●")
                        .font(T.mono(13))
                        .foregroundColor(T.good)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundColor(T.ink3)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .kGlass(cornerRadius: 8, fallbackFill: T.surface)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(accepted.wrappedValue ? T.good.opacity(0.5) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
