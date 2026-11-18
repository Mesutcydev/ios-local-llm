import SwiftUI
import Combine

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
                    .font(.system(.body, weight: .semibold))
                    .foregroundColor(tint)
                    .frame(width: 42, height: 30)
                    .accessibilityLabel(readyLabel)

            case .enumerating:
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
                    .frame(width: 42, height: 30)

            case .downloading:
                HStack(spacing: Space.xs) {
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
        GlassGetButton(label: label, tint: tint, action: start)
    }
}

/// App Store-style Get pill: Apple's glass capsule at its natural width, so a
/// neighbour with layout priority can't squeeze it.
struct GlassGetButton: View {
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button {
            action()
            HapticManager.impact(.medium)
        } label: {
            Text(label).font(.subheadline.weight(.semibold))
        }
        .glassButton()
        .controlSize(.small)
        .tint(tint)
        .fixedSize()
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
        HStack(spacing: Space.s) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(.body, weight: .semibold))
                .foregroundColor(T.good)
                .frame(width: Size.control, height: Size.control)
                .background(Circle().fill(T.good.opacity(0.12)))
            VStack(alignment: .leading, spacing: Space.xxs) {
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
        .padding(Space.m)
        .kGlass(cornerRadius: Radius.card, fallbackFill: T.surface, fallbackStroke: T.rule)
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
    /// Cancelling deletes the downloaded files, so it is confirmed first.
    @State private var confirmingCancel = false

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
        VStack(alignment: .leading, spacing: Space.s) {
            header
            progressBlock
            footer
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kClearGlass(
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous),
            tint: accent.opacity(0.13),
            fallbackFill: T.surface,
            fallbackStroke: accent.opacity(0.26)
        )
        .alert(loc.t("Are you sure?"), isPresented: $confirmingCancel) {
            Button(loc.t("Cancel"), role: .cancel) {}
            Button(loc.t("Delete"), role: .destructive) {
                ModelDownloadCenter.shared.handleDeletion(of: model)
            }
        } message: {
            Text(loc.t("This frees up disk space. The model can be downloaded again later."))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Space.s) {
            // Match the unified pink-soft glyph tile used across every
            // other model card. Accent flips to warn/bad while a
            // download is in flight (see `accent`) so the row signals
            // its state without losing the design language.
            Image(systemName: categoryGlyph)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundColor(accent)
                .frame(width: Size.control, height: Size.control)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
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

            VStack(alignment: .leading, spacing: Space.xxs) {
                KCaption(text: categoryEyebrow, color: T.ink3)
                Text(model.displayName)
                    .font(T.display(17, .semibold))
                    .foregroundColor(T.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(LocalizedStringKey(model.subtitle))
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
        VStack(alignment: .leading, spacing: Space.s) {
            // Bytes + file count line. Hidden during .enumerating since
            // those numbers are 0 / 0 and the rendering would mislead.
            if !isIndeterminate {
                HStack(spacing: Space.xs) {
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
            //   downloading / enumerating → Pause + Cancel download
            //   paused                     → Resume + Cancel download
            //   failed                     → Retry + Cancel download
            HStack(spacing: Space.xs) {
                if downloader.state.isActive {
                    actionButton("Pause") { downloader.pause(); HapticManager.impact(.light) }
                    actionButton("Cancel download") { confirmingCancel = true }
                } else {
                    Button(action: { downloader.start(); HapticManager.impact(.medium) }) {
                        Text(loc.t(downloader.isPaused ? "Resume" : "Retry"))
                            .font(T.mono(11, .semibold))
                            .foregroundColor(T.bg)
                            .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                            .background(RoundedRectangle(cornerRadius: Radius.inner).fill(T.ink))
                    }
                    .buttonStyle(.plain)
                    // Paused or failed: let the row be dismissed and its
                    // partial files removed.
                    actionButton("Cancel download") { confirmingCancel = true }
                }
                if let docURL = model.docURL, let url = URL(string: docURL) {
                    Button(action: { UIApplication.shared.open(url) }) {
                        Text(loc.t("Open on HuggingFace"))
                            .font(T.mono(11, .semibold))
                            .foregroundColor(T.ink2)
                            .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                            .background(RoundedRectangle(cornerRadius: Radius.inner).fill(T.surface2))
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Helpers

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(loc.t(title))
                .font(T.mono(11, .semibold))
                .foregroundColor(T.ink2)
                .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
                .background(RoundedRectangle(cornerRadius: Radius.inner).fill(T.surface2))
        }
        .buttonStyle(.plain)
    }

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

// MARK: - DownloadObserver
// A small ObservableObject that bridges the DownloadableModel's underlying
// downloader(s) to the card view, updating on every published change.

@MainActor
final class DownloadObserver: ObservableObject {
    @Published var state: HFModelDownloadManager.DownloadState = .idle
    @Published var progress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var currentFile: String = ""
    @Published var filesDone: Int = 0
    @Published var filesTotal: Int = 0
    /// Smoothed download throughput in bytes/sec. Drives the speed + ETA
    /// readout so a multi-GB download tells the user how long it'll take
    /// instead of just creeping a progress bar.
    @Published var bytesPerSec: Double = 0

    var isActive: Bool { state == .downloading || state == .enumerating }

    /// Estimated seconds remaining, or nil when we can't make a trustworthy
    /// estimate (not downloading, no rate yet, unknown total).
    var etaSeconds: Double? {
        guard state == .downloading, bytesPerSec > 1024, totalBytes > 0 else { return nil }
        let remaining = Double(totalBytes - downloadedBytes)
        guard remaining > 0 else { return nil }
        return remaining / bytesPerSec
    }

    private var cancellables = Set<AnyCancellable>()
    private let model: DownloadableModel

    // Rolling-rate state. We sample at most ~2×/sec and smooth with an EMA so
    // the readout doesn't jitter on every chunk callback.
    private var lastSampleBytes: Int64 = 0
    private var lastSampleTime: Date?

    init(model: DownloadableModel) {
        self.model = model
        sync()
        subscribe()
    }

    private func sync() {
        let previousState = state
        state          = model.state
        progress       = model.progress
        downloadedBytes = model.downloadedBytes
        totalBytes     = model.totalBytes
        currentFile    = model.currentFile
        filesDone      = model.downloader?.filesDone ?? 0
        filesTotal     = model.downloader?.filesTotal ?? 0
        updateRate(enteredDownloading: previousState != .downloading && state == .downloading)
    }

    private func updateRate(enteredDownloading: Bool) {
        guard state == .downloading else {
            bytesPerSec = 0
            lastSampleTime = nil
            return
        }
        if enteredDownloading || lastSampleTime == nil {
            lastSampleBytes = downloadedBytes
            lastSampleTime = Date()
            return
        }
        let now = Date()
        let dt = now.timeIntervalSince(lastSampleTime!)
        guard dt >= 0.4 else { return }   // throttle: don't sample on every chunk
        let delta = Double(downloadedBytes - lastSampleBytes)
        if delta >= 0 {                   // ignore the dip when a resume rewinds bytes
            let instantaneous = delta / dt
            bytesPerSec = bytesPerSec == 0 ? instantaneous
                                           : bytesPerSec * 0.7 + instantaneous * 0.3
        }
        lastSampleBytes = downloadedBytes
        lastSampleTime = now
    }

    private func subscribe() {
        // Observe HFModelDownloadManager if present
        if let d = model.downloader {
            d.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.sync() }
                .store(in: &cancellables)
        }
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
            VStack(spacing: Space.xxs) {
                Image(systemName: "trash.fill")
                    .font(.system(.callout, weight: .semibold))
                Text("Delete")
                    .scaledFont(size: 11, weight: .semibold)
            }
            .foregroundColor(.white)
            .frame(width: revealWidth)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(T.bad)
            )
            .padding(.vertical, Space.hair)
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
