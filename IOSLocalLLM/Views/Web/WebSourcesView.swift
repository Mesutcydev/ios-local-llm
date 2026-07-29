import SwiftUI

// MARK: - WebSourcesView
// Renders the citation list under an assistant answer whenever a
// `WebContextPackage` was used.

struct WebSourcesView: View {
    @Environment(\.koduTheme) private var T

    let citations: [WebSourceCitation]
    let citedIndices: Set<Int>
    let onRetryWithWeb: (() -> Void)?
    let onAnswerOffline: (() -> Void)?

    var body: some View {
        let visible = citations.filter { citedIndices.contains($0.index) }
        if visible.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.system(size: 10))
                    Text("Used \(visible.count) web source\(visible.count == 1 ? "" : "s")")
                        .font(T.mono(10, .semibold))
                        .tracking(0.3)
                }
                .foregroundColor(T.ink3)
                .padding(.bottom, 6)

                ForEach(visible) { c in
                    WebSourceRowView(citation: c)
                    if c.index != visible.last?.index {
                        Rectangle().fill(T.rule).frame(height: 1)
                    }
                }

                if onRetryWithWeb != nil || onAnswerOffline != nil {
                    HStack(spacing: 10) {
                        if let retry = onRetryWithWeb {
                            Button {
                                retry()
                                HapticManager.impact(.light)
                            } label: {
                                Text("retry with web")
                                    .font(T.mono(10, .semibold))
                                    .foregroundColor(T.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        if let off = onAnswerOffline {
                            Button {
                                off()
                                HapticManager.impact(.light)
                            } label: {
                                Text("answer offline instead")
                                    .font(T.mono(10, .semibold))
                                    .foregroundColor(T.ink3)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(.top, 8)
                }
            }
            .padding(10)
            .kGlass(cornerRadius: 8, fallbackFill: T.surface)
        }
    }
}

struct WebSourceRowView: View {
    @Environment(\.koduTheme) private var T
    let citation: WebSourceCitation

    var body: some View {
        Link(destination: citation.url) {
            HStack(alignment: .top, spacing: 8) {
                Text("[\(citation.index)]")
                    .font(T.mono(11, .semibold))
                    .foregroundColor(T.accent)
                    .frame(width: 22, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(citation.title)
                        .font(T.mono(12, .semibold))
                        .foregroundColor(T.ink)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(citation.siteName)
                            .font(T.mono(10))
                            .foregroundColor(T.ink3)
                            .lineLimit(1)
                        Text("·")
                            .foregroundColor(T.ink3)
                        Text(relativeFetched)
                            .font(T.mono(10))
                            .foregroundColor(T.ink3)
                    }
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundColor(T.ink3)
            }
            .padding(.vertical, 6)
        }
        .accessibilityLabel("Source \(citation.index): \(citation.title), from \(citation.siteName)")
    }

    private var relativeFetched: String {
        let secs = Int(Date().timeIntervalSince(citation.fetchedAt))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
}
