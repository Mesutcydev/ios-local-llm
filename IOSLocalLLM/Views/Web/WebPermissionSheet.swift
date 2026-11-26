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
            VStack(alignment: .leading, spacing: Space.m) {
                header
                payloadCard
                providerCard
                privacyCard
                buttons
            }
            .padding(Space.m)
        }
        .background(LiquidPinkBackdrop())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(false)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            KCaption(text: "WEB TOOL")
            KPageTitle(title: "Use web sources?", size: 28)
            Text(reason)
                .font(T.sans(13))
                .foregroundColor(T.ink2)
                .padding(.top, Space.xxs)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var payloadCard: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            KMono(text: "what will be sent", size: 9, color: T.ink3)
            switch payload {
            case .query(let q):
                Text("Query: \"\(q)\"")
                    .font(T.mono(13))
                    .foregroundColor(T.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.s)
                    .background(RoundedRectangle(cornerRadius: Radius.inner).fill(T.surface))
                    .overlay(RoundedRectangle(cornerRadius: Radius.inner).stroke(T.rule, lineWidth: 1))
            case .url(let u):
                Text("URL: \(u.absoluteString)")
                    .font(T.mono(13))
                    .foregroundColor(T.ink)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.s)
                    .background(RoundedRectangle(cornerRadius: Radius.inner).fill(T.surface))
                    .overlay(RoundedRectangle(cornerRadius: Radius.inner).stroke(T.rule, lineWidth: 1))
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
        return VStack(alignment: .leading, spacing: Space.xxs) {
            KMono(text: "sent to", size: 9, color: T.ink3)
            Text(providerName)
                .font(T.mono(12, .semibold))
                .foregroundColor(T.ink)
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            KMono(text: "privacy", size: 9, color: T.ink3)
            Text("Only the query or URL shown above is sent. Chat history and attachments are not sent by the web tool. The recipient receives your IP address and an API credential when configured. Search providers may retain queries and reuse them to improve their services. Do not include private information.")
                .font(T.sans(12))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if case .query = payload, let providerPrivacyURL {
                Link("Read provider privacy policy", destination: providerPrivacyURL)
                    .font(T.sans(12))
            }
        }
    }

    private var providerPrivacyURL: URL? {
        switch webTool.settings.provider {
        case .brave: return URL(string: "https://api-dashboard.search.brave.com/app/documentation/general/privacy-policy")!
        case .tavily: return URL(string: "https://www.tavily.com/privacy")!
        case .exa: return URL(string: "https://exa.ai/privacy-policy")!
        case .duckduckgoHTML: return URL(string: "https://duckduckgo.com/privacy")!
        case .directURLOnly, .searxng, .custom: return nil
        }
    }

    private var buttons: some View {
        VStack(spacing: Space.s) {
            Button {
                HapticManager.impact(.medium)
                webTool.settings.acceptPrivacyDisclosure()
                onAllowOnce()
                dismiss()
            } label: {
                Text("Allow Once")
                    .font(T.mono(13, .semibold))
                    .frame(maxWidth: .infinity)
            }
            .glassButton(prominent: true)
            .controlSize(.large)
            .accessibilityLabel("Allow this web request once")

            Button {
                HapticManager.impact(.light)
                webTool.settings.acceptPrivacyDisclosure()
                onAlwaysAllow()
                dismiss()
            } label: {
                Text("Always Allow")
                    .font(T.mono(13, .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.s)
                    .foregroundColor(T.ink)
                    .kGlass(cornerRadius: Radius.inner, fallbackFill: T.surface)
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
                    .padding(.vertical, Space.s)
                    .foregroundColor(T.ink3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Continue offline")
        }
    }
}
