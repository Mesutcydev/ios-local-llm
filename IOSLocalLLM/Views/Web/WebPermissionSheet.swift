import SwiftUI

// MARK: - WebPermissionSheet
// Per-request consent UI. Shows EXACTLY what would be sent (query or URL)
// and to which provider. No network touched until the user picks a button.

struct WebPermissionSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T
    @ObservedObject private var webTool = WebToolService.shared

    let reason: String
    let payload: QueryOrURL
    let onAllowOnce: () -> Void
    let onAlwaysAllow: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                payloadCard
                providerCard
                privacyCard
                buttons
            }
            .padding(20)
        }
        .background(LiquidPinkBackdrop())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(false)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            KCaption(text: "WEB TOOL")
            KPageTitle(title: "Use web sources?", size: 26)
            Text(reason)
                .font(T.sans(13))
                .foregroundColor(T.ink2)
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var payloadCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            KMono(text: "what will be sent", size: 9, color: T.ink3)
            switch payload {
            case .query(let q):
                Text("Query: \"\(q)\"")
                    .font(T.mono(13))
                    .foregroundColor(T.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(T.surface))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.rule, lineWidth: 1))
            case .url(let u):
                Text("URL: \(u.absoluteString)")
                    .font(T.mono(13))
                    .foregroundColor(T.ink)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(T.surface))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.rule, lineWidth: 1))
            }
        }
    }

    private var providerCard: some View {
        let providerName: String = {
            switch payload {
            case .url: return "direct fetch (no search provider)"
            case .query: return webTool.settings.provider.displayName
            }
        }()
        return VStack(alignment: .leading, spacing: 4) {
            KMono(text: "sent to", size: 9, color: T.ink3)
            Text(providerName)
                .font(T.mono(12, .semibold))
                .foregroundColor(T.ink)
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            KMono(text: "what is NOT sent", size: 9, color: T.ink3)
            Text("Your chat history, attachments, OCR, and screenshots are not sent. Inference still runs on this device.")
                .font(T.sans(12))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            Button {
                HapticManager.impact(.medium)
                onAllowOnce()
                dismiss()
            } label: {
                Text("Allow Once")
                    .font(T.mono(13, .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundColor(T.bg)
                    .background(RoundedRectangle(cornerRadius: 8).fill(T.ink))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Allow this web request once")

            Button {
                HapticManager.impact(.light)
                onAlwaysAllow()
                dismiss()
            } label: {
                Text("Always Allow")
                    .font(T.mono(13, .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundColor(T.ink)
                    .kGlass(cornerRadius: 8, fallbackFill: T.surface)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Always allow web requests")

            Button {
                HapticManager.impact(.light)
                onCancel()
                dismiss()
            } label: {
                Text("Not Now")
                    .font(T.mono(13))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundColor(T.ink3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Continue offline")
        }
    }
}
