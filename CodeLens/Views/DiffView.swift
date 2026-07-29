import SwiftUI

// MARK: - DiffView
// Renders a unified line-based diff with red (removed) / green (added)
// highlighting. Used by the chat to make refactoring suggestions readable.
//
// Detection: any code block tagged ```diff``` is rendered through this
// view by AssistantMarkdownView instead of the plain CodeBlock.

struct DiffView: View {
    let diffText: String
    @Environment(\.koduTheme) private var T

    private var lines: [(String, LineKind)] {
        diffText.components(separatedBy: "\n").map { line in
            let kind: LineKind
            if line.hasPrefix("+") && !line.hasPrefix("+++") { kind = .added }
            else if line.hasPrefix("-") && !line.hasPrefix("---") { kind = .removed }
            else if line.hasPrefix("@@") { kind = .hunk }
            else { kind = .context }
            return (line, kind)
        }
    }

    enum LineKind { case added, removed, hunk, context }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // header
            HStack {
                Text("diff")
                    .font(T.mono(9, .semibold))
                    .tracking(0.4)
                    .foregroundColor(T.ink2)
                Spacer()
                Button {
                    UIPasteboard.general.string = diffText
                    ToastCenter.shared.info("Copied diff")
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                        Text("copy").font(T.mono(9))
                    }
                    .foregroundColor(T.ink2)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(T.surface2)
            .overlay(alignment: .bottom) {
                Rectangle().fill(T.rule).frame(height: 1)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        diffLine(line.0, kind: line.1)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.rule, lineWidth: 1))
    }

    @ViewBuilder
    private func diffLine(_ text: String, kind: LineKind) -> some View {
        HStack(spacing: 0) {
            // 2px stripe on the left signalling the kind
            Rectangle()
                .fill(stripeColor(kind))
                .frame(width: 3)
            Text(text.isEmpty ? " " : text)
                .font(T.mono(11))
                .foregroundColor(textColor(kind))
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bgColor(kind))
    }

    private func stripeColor(_ kind: LineKind) -> Color {
        switch kind {
        case .added:   return T.good
        case .removed: return T.bad
        case .hunk:    return T.accent
        case .context: return T.surface
        }
    }
    private func textColor(_ kind: LineKind) -> Color {
        switch kind {
        case .added:   return T.good
        case .removed: return T.bad
        case .hunk:    return T.accent
        case .context: return T.ink
        }
    }
    private func bgColor(_ kind: LineKind) -> Color {
        switch kind {
        case .added:   return T.good.opacity(0.06)
        case .removed: return T.bad.opacity(0.06)
        case .hunk:    return T.accentSofter
        case .context: return T.surface
        }
    }
}
