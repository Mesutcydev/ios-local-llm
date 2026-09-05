import SwiftUI

/// Observes one download manager directly. CoreAIDownloadCenter publishes only
/// insertion/removal of managers; it intentionally does not forward every
/// child progress tick because doing so would re-render the entire 16-card
/// catalog several times per second.
struct CoreAIDownloadControlsView: View {
    @ObservedObject var manager: CoreAIHFDownloadManager
    @Environment(\.koduTheme) private var T

    var body: some View {
        switch manager.state {
        case .enumerating, .downloading, .installing:
            VStack(alignment: .leading, spacing: 6) {
                if manager.state == .enumerating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(T.accent)
                } else {
                    ProgressView(value: manager.progress)
                        .tint(T.accent)
                }
                Text(manager.statusDetail)
                    .font(T.mono(9))
                    .foregroundStyle(T.ink3)
                    .lineLimit(2)
                if manager.totalBytes > 0 {
                    Text(
                        "\(manager.downloadedBytes.formattedBytes) / \(manager.totalBytes.formattedBytes)"
                        + (manager.speedMBps > 0
                           ? String(format: " · %.1f MB/s", manager.speedMBps)
                           : "")
                    )
                    .font(T.mono(8.5))
                    .foregroundStyle(T.ink3)
                }
                HStack {
                    if manager.state != .installing {
                        Button("Pause") { manager.pause() }
                            .buttonStyle(.bordered)
                    }
                    Button("Cancel", role: .destructive) { manager.cancel() }
                        .buttonStyle(.bordered)
                }
            }

        case .paused:
            HStack {
                Button("Resume") {
                    manager.resume()
                    ToastCenter.shared.info("Resuming Core AI download")
                }
                .buttonStyle(.borderedProminent)
                .tint(T.accent)
                Button("Cancel", role: .destructive) { manager.cancel() }
                    .buttonStyle(.bordered)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(T.sans(10.5))
                    .foregroundStyle(T.bad)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Retry") {
                        manager.resume()
                        ToastCenter.shared.info("Retrying Core AI download")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(T.accent)
                    Button("Clear") { manager.cancel() }
                        .buttonStyle(.bordered)
                }
            }

        case .ready:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(T.sans(11, .semibold))
                .foregroundStyle(T.good)

        case .idle:
            Button {
                manager.start()
                ToastCenter.shared.info("Starting Core AI download")
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(T.accent)
        }
    }
}
