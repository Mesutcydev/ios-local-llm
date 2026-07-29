import SwiftUI

// MARK: - SetupBannerView
// Small unobtrusive card shown on the camera tab when the vision model (FastVLM)
// isn't ready. Guides the user to set it up without blocking the camera.
//
// States: needs-download, downloading (LIVE progress), or installed-but-load-failed.
// It now reflects DOWNLOAD progress — previously it keyed only off the load
// lifecycle, so while the decoder was downloading it kept saying "download
// fastvlm" with no movement, reading as stuck/doing-nothing.

struct SetupBannerView: View {
    @ObservedObject private var fastVLM = FastVLMService.shared
    // Observe the download center so the banner reflects download start/stop.
    // (The center forwards only downloader STATE changes, not per-byte progress,
    // so this does not re-render on every progress tick — the live bar below
    // observes the downloader directly, scoped to a small child view.)
    @ObservedObject private var center = ModelDownloadCenter.shared
    @Environment(\.koduTheme) private var T

    let onTapDownload: () -> Void

    private var fastVLMDownloader: HFModelDownloadManager? {
        center.fastvlmModel?.downloader
    }
    private var isDownloading: Bool {
        fastVLMDownloader?.state.isActive == true
    }

    var body: some View {
        if shouldShow {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(iconTint.opacity(0.20))
                        .frame(width: 30, height: 30)
                    Image(systemName: iconName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(iconTint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        // Light inks: the card forces a DARK glass surface
                        // (.colorScheme = .dark below), so the light-theme
                        // T.ink / T.ink3 used before were near-invisible.
                        .font(T.mono(11, .semibold))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                    if isDownloading, let dl = fastVLMDownloader {
                        FastVLMSetupProgress(downloader: dl, theme: T)
                    } else {
                        Text(subhead)
                            .font(T.mono(10))
                            .foregroundColor(.white.opacity(0.72))
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 4)

                if !isDownloading {
                    Text(loadFailedWithFilesOnDisk ? "retry →" : "finish setup →")
                        .font(T.mono(10, .semibold))
                        .tracking(0.4)
                        .foregroundColor(T.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .kGlass(cornerRadius: 8)
            .environment(\.colorScheme, .dark)
            .contentShape(Rectangle())
            .onTapGesture {
                // Already working — a tap should not restart the download.
                guard !isDownloading else { return }
                HapticManager.impact(.light)
                if loadFailedWithFilesOnDisk {
                    // Files exist — retry the load instead of opening the
                    // Download Center, which would mislead the user into
                    // re-downloading bytes that are already on disk.
                    Task { await FastVLMService.shared.load() }
                } else {
                    onTapDownload()
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Presentation

    private var iconName: String {
        if isDownloading { return "arrow.down.circle.fill" }
        return loadFailedWithFilesOnDisk ? "exclamationmark.triangle" : "arrow.down.circle"
    }

    private var iconTint: Color {
        if isDownloading { return T.accent }
        return loadFailedWithFilesOnDisk ? T.warn : T.accent
    }

    // MARK: - State derivation

    /// True when at least one component reports a load failure (as opposed to
    /// merely unloaded/loading). Distinguishing this from "not downloaded" is
    /// what lets the banner say "installed but failed" instead of "download".
    private var hasLoadFailure: Bool {
        let s = fastVLM.componentStatus
        let states = [s.encoder, s.projector, s.decoder, s.tokenizer]
        return states.contains { if case .failed = $0 { return true } else { return false } }
    }

    private var firstFailureMessage: String? {
        let s = fastVLM.componentStatus
        for state in [s.encoder, s.projector, s.decoder, s.tokenizer] {
            if case .failed(let msg) = state { return msg }
        }
        return nil
    }

    /// Files are on disk but the model couldn't be loaded.
    private var loadFailedWithFilesOnDisk: Bool {
        guard hasLoadFailure else { return false }
        return ModelDownloadCenter.shared.fastvlmModel?.isReady == true
    }

    // MARK: - Visibility logic

    private var shouldShow: Bool {
        // If the user switched the camera VLM to another downloaded model,
        // the FastVLM banner is irrelevant.
        if !LocalModelRegistry.isDefaultVisionSelection(AppSettings.shared.cameraVisualModelID) {
            return false
        }
        // Show WHILE downloading so the live progress is visible (this is the
        // fix for "tapped set up, banner still says download, looks stuck").
        if isDownloading { return true }
        // Hide while a load is in progress.
        if fastVLM.componentStatus.isLoading { return false }
        // Hide once FastVLM can generate.
        if fastVLM.componentStatus.canGenerate { return false }
        // Files on disk but the load failed — keep the banner up to retry.
        if loadFailedWithFilesOnDisk { return true }
        // Files already on disk and just sleeping — it'll load lazily.
        if ModelDownloadCenter.shared.fastvlmModel?.isReady == true { return false }
        return true
    }

    private var headline: String {
        if isDownloading { return "setting up code lens…" }
        if loadFailedWithFilesOnDisk { return "fastvlm installed — load failed" }
        return "download fastvlm to enable code lens"
    }

    private var subhead: String {
        if loadFailedWithFilesOnDisk {
            if let msg = firstFailureMessage, !msg.isEmpty { return msg }
            return "tap to retry"
        }
        // FastVLM-specific — NOT a whole-catalog "N/25 ready" count, which was
        // meaningless to a user trying to enable the Lens.
        let size = center.fastvlmModel?.sizeLabel ?? "~400 MB"
        return "on-device vision model · \(size)"
    }
}

// MARK: - Live download progress for the FastVLM setup banner

/// Observes the FastVLM downloader directly so the percentage and bar update
/// live as bytes arrive. Kept as a small child so the per-tick re-render is
/// scoped here and doesn't churn the whole camera HUD.
private struct FastVLMSetupProgress: View {
    @ObservedObject var downloader: HFModelDownloadManager
    let theme: KoduTheme
    private var T: KoduTheme { theme }

    /// Fraction once the byte total is known; nil during the brief enumerating
    /// phase (file list still being fetched).
    private var fraction: Double? {
        if downloader.state == .enumerating { return nil }
        return downloader.totalBytes > 0 ? downloader.progress : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(T.mono(10))
                .foregroundColor(.white.opacity(0.82))
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18)).frame(height: 3)
                    if let f = fraction {
                        Capsule().fill(T.accent)
                            .frame(width: max(3, geo.size.width * CGFloat(f)), height: 3)
                    }
                }
            }
            .frame(height: 3)
        }
        .padding(.trailing, 2)
    }

    private var label: String {
        if downloader.state == .enumerating { return "preparing…" }
        if let f = fraction { return "downloading \(Int(f * 100))%" }
        return "downloading…"
    }
}
