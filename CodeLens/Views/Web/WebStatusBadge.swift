import SwiftUI

// MARK: - WebStatusBadge
// Small pill near the model status bar showing what the Web Tool is doing.
// VoiceOver-labeled, Dynamic-Type-safe, localized.

struct WebStatusBadge: View {
    @Environment(\.koduTheme) private var T
    @ObservedObject private var webTool = WebToolService.shared

    var body: some View {
        switch webTool.phase {
        case .idle:
            switch webTool.settings.mode {
            case .off:
                pill(symbol: "globe.slash", text: "web off", color: T.ink3)
                    .accessibilityLabel("Web Access disabled")
            default:
                EmptyView()
            }
        case .awaitingPermission:
            pill(symbol: "questionmark.circle", text: "permission?", color: T.warn)
                .accessibilityLabel("Waiting for permission")
        case .searching:
            pill(symbol: "magnifyingglass", text: "searching", color: T.accent)
                .accessibilityLabel("Searching")
        case .fetching(let done, let total):
            pill(symbol: "globe", text: "\(done)/\(total)", color: T.accent)
                .accessibilityLabel("Fetching \(done) of \(total) sources")
        case .ready(let pkg):
            pill(symbol: "globe.americas.fill",
                 text: "web · \(pkg.citations.count)",
                 color: T.good)
                .accessibilityLabel("Answering with \(pkg.citations.count) sources")
        case .failed(let reason):
            pill(symbol: "exclamationmark.triangle", text: "web failed", color: T.bad)
                .accessibilityLabel("Web failed: \(reason)")
        }
    }

    @ViewBuilder
    private func pill(symbol: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(text).font(T.mono(10, .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.4), lineWidth: 0.5))
    }
}
