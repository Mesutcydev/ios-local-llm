import SwiftUI

// MARK: - Shared chrome

private struct ActivityCardChrome<Content: View>: View {
    @Environment(\.koduTheme) private var T
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(Space.s)
            .frame(maxWidth: 520, alignment: .leading)
            .glassSurface(.card, cornerRadius: Radius.card)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(T.rule.opacity(0.7), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(T.isDark ? 0.14 : 0.05), radius: 10, y: 4)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.xs)
            .accessibilityElement(children: .contain)
    }
}

private struct ActivityCardHeader: View {
    @Environment(\.koduTheme) private var T
    let symbol: String
    let title: String
    let subtitle: String
    var pulsing: Bool = false

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(T.accent)
                .frame(width: Size.tile, height: Size.tile)
                .background(T.accent.opacity(0.10), in: Circle())
                .symbolEffect(.pulse, isActive: pulsing)
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(T.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(T.ink3)
            }
            Spacer(minLength: 8)
        }
    }
}

// MARK: - Live status (blends with bubble meta)

struct AssistantLiveStatusRow: View {
    let title: String
    var symbol: String? = nil

    @Environment(\.koduTheme) private var T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.xs) {
            Circle()
                .fill(T.accent)
                .frame(width: 6, height: 6)
                .opacity(reduceMotion ? 0.7 : 0.9)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(.caption2, weight: .semibold))
            }
            Text(title)
                .font(T.sans(11.5, .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(T.ink3)
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.hair)
        .accessibilityLabel(title)
    }
}

// MARK: - Streaming status (kept for call sites that still pass content)

struct AssistantStreamingStatusCard: View {
    let content: String
    let detectedToolName: String?

    private var status: AssistantActivity.Status {
        AssistantActivity.streamingStatus(content: content, detectedToolName: detectedToolName)
    }

    var body: some View {
        AssistantLiveStatusRow(
            title: AssistantActivity.statusTitle(status),
            symbol: {
                switch status {
                case .preparingTool(let name), .runningTool(let name), .awaitingApproval(let name):
                    return AssistantActivity.symbol(forTool: name)
                default:
                    return nil
                }
            }()
        )
    }
}

// MARK: - Running tool

struct AssistantRunningToolCard: View {
    let name: String

    var body: some View {
        AssistantLiveStatusRow(
            title: AssistantActivity.statusTitle(.runningTool(name)),
            symbol: AssistantActivity.symbol(forTool: name)
        )
        .accessibilityLabel(AssistantActivity.statusTitle(.runningTool(name)))
    }
}

// MARK: - Web / generic approval

struct AssistantApprovalCard: View {
    let toolName: String
    let reason: String
    let detail: String
    let onAllowOnce: () -> Void
    let onAlwaysAllow: (() -> Void)?
    let onDecline: () -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        ActivityCardChrome {
            VStack(alignment: .leading, spacing: Space.s) {
                ActivityCardHeader(
                    symbol: AssistantActivity.symbol(forTool: toolName),
                    title: AssistantActivity.statusTitle(.awaitingApproval(toolName)),
                    subtitle: "Nothing is sent until you choose"
                )
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(T.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(T.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.s)
                    .background(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous).fill(T.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                            .stroke(T.rule, lineWidth: 0.5)
                    )
                VStack(spacing: Space.s) {
                    Button(action: {
                        HapticManager.impact(.medium)
                        onAllowOnce()
                    }) {
                        Text("Allow once")
                            .scaledFont(size: 13, weight: .semibold, design: .monospaced)
                            .frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true)
                    .controlSize(.large)
                    .accessibilityLabel("Allow this \(AssistantActivity.displayName(forTool: toolName)) once")

                    if let onAlwaysAllow {
                        Button(action: {
                            HapticManager.impact(.light)
                            onAlwaysAllow()
                        }) {
                            Text("Always allow")
                                .scaledFont(size: 13, weight: .semibold, design: .monospaced)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Space.s)
                                .foregroundStyle(T.ink)
                                .kGlass(cornerRadius: Radius.inner, fallbackFill: T.surface)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Always allow \(AssistantActivity.displayName(forTool: toolName))")
                    }

                    Button(action: {
                        HapticManager.impact(.light)
                        onDecline()
                    }) {
                        Text("Not now")
                            .scaledFont(size: 13, design: .monospaced)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Space.s)
                            .foregroundStyle(T.ink3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Decline and continue offline")
                }
            }
        }
    }
}

// MARK: - File approval

struct AssistantFileApprovalCard: View {
    let prompt: String
    let onChoose: () -> Void
    let onDecline: () -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        ActivityCardChrome {
            VStack(alignment: .leading, spacing: Space.s) {
                ActivityCardHeader(
                    symbol: "doc.text",
                    title: AssistantActivity.statusTitle(.awaitingApproval("file_read")),
                    subtitle: "The file stays on this device"
                )
                Text(prompt)
                    .font(.footnote)
                    .foregroundStyle(T.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: {
                    HapticManager.impact(.medium)
                    onChoose()
                }) {
                    Text("Choose file")
                        .scaledFont(size: 13, weight: .semibold, design: .monospaced)
                        .frame(maxWidth: .infinity)
                }
                .glassButton(prominent: true)
                .controlSize(.large)
                .accessibilityLabel("Choose a file for the assistant")

                Button(action: {
                    HapticManager.impact(.light)
                    onDecline()
                }) {
                    Text("Not now")
                        .scaledFont(size: 13, design: .monospaced)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.s)
                        .foregroundStyle(T.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Decline file access")
            }
        }
    }
}

// MARK: - Image generation

struct AssistantImageGenerationCard: View {
    @Environment(\.koduTheme) private var T
    let status: AssistantActivity.ImageStatus

    var body: some View {
        ActivityCardChrome {
            VStack(alignment: .leading, spacing: Space.s) {
                ActivityCardHeader(
                    symbol: "photo.on.rectangle.angled",
                    title: "Image generation",
                    subtitle: AssistantActivity.imageGenerationSubtitle(status),
                    pulsing: true
                )
                // The Image tab's live progress bar. Loading and checking have
                // no fraction; the pulsing header symbol covers them. The
                // service's statusMessage went stale across phases ("Loading
                // SD-Turbo…" under "Generating · 100%"), so only a failure
                // adds a detail line.
                switch status {
                case .downloading(let fraction), .generating(let fraction):
                    ProgressView(value: fraction).tint(T.accent)
                case .failed(let message) where !message.isEmpty:
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    EmptyView()
                }
            }
        }
        .accessibilityLabel(AssistantActivity.imageGenerationSubtitle(status))
    }
}

// MARK: - Citations

struct AssistantCitationCard: View {
    let citations: [WebSourceCitation]
    let citedIndices: Set<Int>

    var body: some View {
        let visible = citations.filter { citedIndices.contains($0.index) }
        if !visible.isEmpty {
            ActivityCardChrome {
                VStack(alignment: .leading, spacing: Space.s) {
                    ActivityCardHeader(
                        symbol: "quote.opening",
                        title: AssistantActivity.citationTitle(visibleCount: visible.count),
                        subtitle: "Quoted from this turn's web results"
                    )
                    ForEach(visible) { citation in
                        WebSourceRowView(citation: citation)
                    }
                }
            }
            .accessibilityLabel(AssistantActivity.citationTitle(visibleCount: visible.count))
        }
    }
}
