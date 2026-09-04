import SwiftUI

// MARK: - Recommended setup download control

/// Observes one catalog downloader directly so a setup row updates through
/// enumeration, progress, failure, and completion without refreshing the
/// surrounding Models screen.
struct ComboModelDownloadControl: View {
    @ObservedObject var downloader: HFModelDownloadManager
    let tint: Color
    let getLabel: String
    let retryLabel: String
    let readyLabel: String
    let start: () -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        Group {
            switch downloader.state {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 42, height: 30)
                    .accessibilityLabel(readyLabel)

            case .enumerating:
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
                    .frame(width: 42, height: 30)

            case .downloading:
                HStack(spacing: 5) {
                    ProgressView(value: downloader.progress)
                        .tint(tint)
                        .frame(width: 26)
                    Text("\(Int(downloader.progress * 100))%")
                        .font(T.mono(9, .semibold))
                        .foregroundColor(tint)
                }
                .frame(width: 58, height: 30)

            case .failed:
                actionButton(retryLabel)

            case .idle:
                actionButton(getLabel)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func actionButton(_ label: String) -> some View {
        Button {
            start()
            HapticManager.impact(.medium)
        } label: {
            Text(label)
                .font(T.sans(12, .semibold))
                .foregroundColor(tint)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(tint.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - InstallingRow
//
// One in-flight download. `@ObservedObject` on the downloader makes the
// row re-render whenever progress / bytes / current-file change — the
// parent view doesn't need to know anything about download state.
//
// Layout, top to bottom:
//   • Model name + category glyph + percentage label
//   • Linear progress bar (determinate when totalBytes > 0,
//     indeterminate during the `.enumerating` phase before file list
//     is fetched)
//   • Bytes done / total + file-count + current file name (truncated)
//   • Cancel / Retry button row
//
// The whole row is bordered with the warn color while downloading and
// flips to the bad color on failure — same accent discipline as the
// load-progress strip in the Active section.

struct CompletedDownloadRow: View {
    let model: DownloadableModel

    @Environment(\.koduTheme) private var T

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(T.good)
                .frame(width: 42, height: 42)
                .background(Circle().fill(T.good.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName)
                    .font(T.sans(14, .semibold))
                    .foregroundColor(T.ink)
                Text("Ready to use · \(model.sizeLabel)")
                    .font(T.mono(9.5))
                    .foregroundColor(T.ink3)
            }
            Spacer()
            Text("100%")
                .font(T.mono(11, .bold))
                .foregroundColor(T.good)
        }
        .padding(14)
        .kGlass(cornerRadius: 18, fallbackFill: T.surface, fallbackStroke: T.rule)
    }
}

struct InstallingRow: View {
    let model: DownloadableModel
    let theme: KoduTheme
    @ObservedObject var loc: LocalizationService

    /// Direct ObservedObject on the model's own downloader. Passed in
    /// (rather than read from `model.downloader`) because that property
    /// is optional on DownloadableModel and Swift can't bind
    /// `@ObservedObject` to an optional — the parent unwraps in the
    /// `ForEach` and hands a guaranteed-non-nil reference here.
    @ObservedObject private var downloader: HFModelDownloadManager

    init(model: DownloadableModel,
         downloader: HFModelDownloadManager,
         theme: KoduTheme,
         loc: LocalizationService) {
        self.model = model
        self.theme = theme
        self.loc = loc
        self.downloader = downloader
    }

    private var T: KoduTheme { theme }

    /// Failed downloads use the bad accent; in-flight use warn.
    private var accent: Color {
        if case .failed = downloader.state { return T.bad }
        return T.warn
    }

    /// Indeterminate progress when:
    ///   • state is `.enumerating` (file list still being fetched), or
    ///   • totalBytes is still 0 (first file not opened yet)
    private var isIndeterminate: Bool {
        if downloader.state == .enumerating { return true }
        return downloader.totalBytes == 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            progressBlock
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kClearGlass(
            in: RoundedRectangle(cornerRadius: 22, style: .continuous),
            tint: accent.opacity(0.13),
            fallbackFill: T.surface,
            fallbackStroke: accent.opacity(0.26)
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            // Match the unified pink-soft glyph tile used across every
            // other model card. Accent flips to warn/bad while a
            // download is in flight (see `accent`) so the row signals
            // its state without losing the design language.
            Image(systemName: categoryGlyph)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(accent)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(accent.opacity(0.12)))
                // Iterative variable-color pulses through the glyph while the
                // download is actively transferring bytes. Doesn't fire on
                // .enumerating (no bytes yet) or .failed (accent already flips
                // to .bad which tells that story).
                .symbolEffect(
                    .variableColor.iterative.dimInactiveLayers,
                    options: .repeating,
                    isActive: downloader.state.isActive && !isIndeterminate
                )

            VStack(alignment: .leading, spacing: 3) {
                KCaption(text: categoryEyebrow, color: T.ink3)
                Text(model.displayName)
                    .font(T.display(17, .semibold))
                    .foregroundColor(T.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.subtitle)
                    .font(T.mono(9.5))
                    .foregroundColor(T.ink3.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            // Percentage label — fades to "…" during indeterminate phase.
            if isIndeterminate {
                Text("…")
                    .font(T.mono(11, .semibold))
                    .foregroundColor(accent)
            } else {
                Text("\(Int(downloader.progress * 100))%")
                    .font(T.mono(11, .semibold))
                    .foregroundColor(accent)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.15), value: downloader.progress)
            }
        }
    }

    // MARK: - Progress bar

    @ViewBuilder
    private var progressBlock: some View {
        if isIndeterminate {
            ProgressView()
                .tint(accent)
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)
        } else {
            ProgressView(value: downloader.progress)
                .tint(accent)
                .progressViewStyle(.linear)
        }
    }

    // MARK: - Footer (bytes + file count + current file + buttons)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Bytes + file count line. Hidden during .enumerating since
            // those numbers are 0 / 0 and the rendering would mislead.
            if !isIndeterminate {
                HStack(spacing: 6) {
                    Text(bytesLine)
                        .font(T.mono(10))
                        .foregroundColor(T.ink2)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.2), value: downloader.downloadedBytes)
                    Spacer(minLength: 0)
                    if downloader.filesTotal > 0 {
                        Text("\(downloader.filesDone)/\(downloader.filesTotal) files")
                            .font(T.mono(10))
                            .foregroundColor(T.ink3)
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.2), value: downloader.filesDone)
                    }
                }
            } else {
                Text(loc.t("Preparing file list…"))
                    .font(T.mono(10))
                    .foregroundColor(T.ink3)
            }

            // Current file name — truncated middle so the repo prefix
            // and the file extension both stay visible. Hidden when
            // there's nothing meaningful to show.
            if !downloader.currentFile.isEmpty {
                Text(downloader.currentFile)
                    .font(T.mono(9))
                    .foregroundColor(T.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Failure detail — only visible on .failed.
            if case .failed(let msg) = downloader.state {
                Text(msg)
                    .font(T.mono(10))
                    .foregroundColor(T.bad)
                    .lineLimit(3)
            }

            // Action buttons. Layout flips based on state:
            //   downloading / enumerating → Cancel
            //   failed                     → Retry + (Open on HuggingFace)
            HStack(spacing: 6) {
                if case .failed = downloader.state {
                    Button(action: { downloader.start(); HapticManager.impact(.medium) }) {
                        Text(loc.t("Retry"))
                            .font(T.mono(11, .semibold))
                            .foregroundColor(T.bg)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(T.ink))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: { downloader.cancel(); HapticManager.impact(.light) }) {
                        Text(loc.t("Cancel"))
                            .font(T.mono(11, .semibold))
                            .foregroundColor(T.ink2)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(T.surface2))
                    }
                    .buttonStyle(.plain)
                }
                if let docURL = model.docURL, let url = URL(string: docURL) {
                    Button(action: { UIApplication.shared.open(url) }) {
                        Text(loc.t("Open on HuggingFace"))
                            .font(T.mono(11, .semibold))
                            .foregroundColor(T.ink2)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(T.surface2))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Helpers

    /// Match the icon set used by installedRow's categoryGlyph so a
    /// model keeps its identity when it moves from Installing →
    /// Installed.
    private var categoryGlyph: String {
        switch model.category {
        case .assistant: return "brain"
        case .vlm:       return "eye"
        case .voice:     return "waveform"
        case .imageGen:  return "wand.and.stars"
        }
    }

    /// Eyebrow label above the model title — mirrors the labels used by
    /// every other card so the visual language is consistent.
    private var categoryEyebrow: String {
        switch model.category {
        case .assistant: return loc.t("Assistant (chat)").uppercased()
        case .vlm:       return loc.t("Vision (camera)").uppercased()
        case .voice:     return loc.t("Voice").uppercased()
        case .imageGen:  return loc.t("Image generation").uppercased()
        }
    }

    /// "12.4 MB / 5.4 GB" style line. Hidden during .enumerating.
    private var bytesLine: String {
        let done = downloader.downloadedBytes.formattedBytes
        let total = downloader.totalBytes.formattedBytes
        return "\(done) / \(total)"
    }
}

// MARK: - SwipeToDeleteContainer
//
// Adds left-swipe-to-reveal-delete behavior to a custom card view.
// The Models tab renders its rows inside a LazyVStack (not a List), so
// SwiftUI's `.swipeActions` isn't available — this wrapper hand-rolls
// the gesture with a DragGesture so the affordance works in the same
// place users expect it. The drag tracks horizontal motion only and
// yields to vertical scrolling, so it doesn't fight the parent
// ScrollView. Full-swipe past `triggerDistance` fires `onDelete`
// immediately; a partial swipe latches the card open with a red
// trash button revealed under the trailing edge that the user can
// tap to confirm or swipe back to dismiss.
struct SwipeToDeleteContainer<Content: View>: View {

    let onDelete: () -> Void
    @ViewBuilder var content: Content

    @Environment(\.koduTheme) private var T
    @State private var offset: CGFloat = 0
    @State private var isOpen: Bool = false

    private let revealWidth: CGFloat = 92
    private let openSnapThreshold: CGFloat = 46
    private let fullSwipeTrigger: CGFloat = 180

    var body: some View {
        ZStack(alignment: .trailing) {
            deleteAffordance
                .opacity(min(1, -offset / revealWidth))

            content
                .offset(x: offset)
                // Tapping the card while the delete button is exposed
                // closes the row instead of activating an inner button.
                // Inner buttons retain their own hit-testing; this is
                // a transparent overlay that only intercepts when open.
                .overlay(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .allowsHitTesting(isOpen)
                )
                .gesture(swipeGesture)
        }
        .clipped()
    }

    private var deleteAffordance: some View {
        Button {
            performDelete()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Delete")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(width: revealWidth)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(T.bad)
            )
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(isOpen)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                // Don't hijack vertical scroll — only respond when the
                // motion is dominantly horizontal.
                guard abs(dx) > abs(dy) else { return }
                let base: CGFloat = isOpen ? -revealWidth : 0
                let candidate = base + dx
                // Clamp: card can move from 0 (closed) past -revealWidth,
                // but light resistance past the reveal width so the user
                // feels the limit without a hard stop (full-swipe still
                // works for delete trigger).
                if candidate >= 0 {
                    offset = 0
                } else if candidate < -revealWidth {
                    let overshoot = candidate + revealWidth
                    offset = -revealWidth + overshoot * 0.45
                } else {
                    offset = candidate
                }
            }
            .onEnded { value in
                let dx = value.translation.width
                let predicted = value.predictedEndTranslation.width
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    if dx < -fullSwipeTrigger || predicted < -fullSwipeTrigger * 1.4 {
                        // Full swipe — treat as confirmed delete intent.
                        // The parent still presents an alert (the same
                        // one the in-card "Delete model" button uses), so
                        // the user gets one last chance to back out.
                        offset = 0
                        isOpen = false
                        performDelete()
                    } else if offset < -openSnapThreshold {
                        offset = -revealWidth
                        isOpen = true
                    } else {
                        offset = 0
                        isOpen = false
                    }
                }
            }
    }

    private func performDelete() {
        HapticManager.impact(.medium)
        onDelete()
        // Reset state so if the user cancels the confirmation alert
        // the row returns to its normal closed appearance.
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            offset = 0
            isOpen = false
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            offset = 0
            isOpen = false
        }
    }
}
