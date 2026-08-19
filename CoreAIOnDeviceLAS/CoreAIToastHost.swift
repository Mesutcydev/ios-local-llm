import SwiftUI

/// Renders `ToastCenter` notifications for the Core AI target.
///
/// The shared runtime services (downloads, imports, thermal guard, server
/// actions) already report through `ToastCenter`; without a host those
/// signals were published into the void. This overlay gives every one of
/// them a visible, self-dismissing surface.
struct CoreAIToastHost: View {
    @ObservedObject private var toast = ToastCenter.shared

    var body: some View {
        ZStack {
            if let current = toast.current {
                toastView(current)
                    .id(current.id)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilitySummary(for: current))
            }
        }
        .animation(.spring(duration: 0.35), value: toast.current)
        .allowsHitTesting(false)
        .onReceive(toast.$current) { current in
            guard let current else { return }
            scheduleDismiss(for: current)
        }
    }

    @State private var dismissTask: Task<Void, Never>?

    private func scheduleDismiss(for current: Toast) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0.5, current.duration)))
            guard !Task.isCancelled else { return }
            if toast.current?.id == current.id {
                toast.dismiss()
            }
        }
    }

    private func toastView(_ current: Toast) -> some View {
        HStack(spacing: 10) {
            icon(for: current.kind)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color(for: current.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(current.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let detail = current.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 340)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(color(for: current.kind).opacity(0.35), lineWidth: 1)
        )
        .padding(.top, toast.topPadding)
        .padding(.horizontal, 16)
    }

    private func icon(for kind: Toast.Kind) -> some View {
        switch kind {
        case .error:
            Image(systemName: "exclamationmark.octagon.fill")
        case .success:
            Image(systemName: "checkmark.circle.fill")
        case .info:
            Image(systemName: "info.circle.fill")
        }
    }

    private func color(for kind: Toast.Kind) -> Color {
        switch kind {
        case .error: return .red
        case .success: return .green
        case .info: return .blue
        }
    }

    private func accessibilitySummary(for current: Toast) -> String {
        switch current.kind {
        case .error: return "Error: \(current.title)"
        case .success: return "Success: \(current.title)"
        case .info: return current.title
        }
    }
}
