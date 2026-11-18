import SwiftUI

// MARK: - FileAttachmentChip
// Inline composer chip showing one attached file. Tap to remove.

struct FileAttachmentChip: View {
    @Environment(\.koduTheme) private var T
    let attachment: FileAttachmentService.Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: attachment.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundColor(T.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text("\(Int64(attachment.byteSize).formattedBytes)")
                        .font(.caption2)
                        .foregroundColor(T.ink3)
                    if let w = attachment.warning {
                        Text("· \(w)")
                            .font(.caption2)
                            .foregroundColor(T.warn)
                            .lineLimit(1)
                    }
                }
            }
            Button {
                onRemove()
                HapticManager.impact(.light)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(T.ink3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.displayName)")
        }
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.20), lineWidth: 0.5))
    }

    private var icon: String {
        switch attachment.kind {
        case .pdf: return "doc.richtext"
        case .markdown: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .json: return "curlybraces"
        case .text: return "doc"
        }
    }

    private var tint: Color {
        switch attachment.kind {
        case .pdf: return T.bad
        case .markdown: return T.accent
        case .code: return T.good
        case .json: return T.warn
        case .text: return T.ink2
        }
    }
}
