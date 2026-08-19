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
            .padding(12)
            .frame(maxWidth: 520, alignment: .leading)
            .glassSurface(.card, cornerRadius: 16)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(T.rule.opacity(0.7), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(T.isDark ? 0.14 : 0.05), radius: 10, y: 4)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
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
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(T.accent)
                .frame(width: 28, height: 28)
                .background(T.accent.opacity(0.10), in: Circle())
                .symbolEffect(.pulse, isActive: pulsing)
            VStack(alignment: .leading, spacing: 2) {
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

// MARK: - Streaming status

struct AssistantStreamingStatusCard: View {
    let content: String
    let detectedToolName: String?

    @Environment(\.koduTheme) private var T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: AssistantActivity.Status {
        AssistantActivity.streamingStatus(content: content, detectedToolName: detectedToolName)
    }

    var body: some View {
        ActivityCardChrome {
            ActivityCardHeader(
                symbol: symbol,
                title: AssistantActivity.statusTitle(status),
                subtitle: subtitle,
                pulsing: !reduceMotion
            )
        }
        .accessibilityLabel(AssistantActivity.statusTitle(status))
    }

    private var symbol: String {
        switch status {
        case .generating: return "text.cursor"
        case .reasoning: return "brain.head.profile"
        case .preparingTool(let name): return AssistantActivity.symbol(forTool: name)
        case .runningTool(let name): return AssistantActivity.symbol(forTool: name)
        case .awaitingApproval(let name): return AssistantActivity.symbol(forTool: name)
        }
    }

    private var subtitle: String {
        switch status {
        case .generating: return "On device · live tokens"
        case .reasoning: return "Reasoning before the answer"
        case .preparingTool: return "Stopping decode to run the tool"
        case .runningTool: return "Waiting for the tool result"
        case .awaitingApproval: return "Nothing left the device yet"
        }
    }
}

// MARK: - Running tool

struct AssistantRunningToolCard: View {
    let name: String

    var body: some View {
        ActivityCardChrome {
            ActivityCardHeader(
                symbol: AssistantActivity.symbol(forTool: name),
                title: AssistantActivity.statusTitle(.runningTool(name)),
                subtitle: "On device · not a cloud call unless you approved web",
                pulsing: true
            )
        }
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
            VStack(alignment: .leading, spacing: 12) {
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
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(T.rule, lineWidth: 0.5)
                    )
                VStack(spacing: 8) {
                    Button(action: {
                        HapticManager.impact(.medium)
                        onAllowOnce()
                    }) {
                        Text("Allow once")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .foregroundStyle(T.bg)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.ink))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Allow this \(AssistantActivity.displayName(forTool: toolName)) once")

                    if let onAlwaysAllow {
                        Button(action: {
                            HapticManager.impact(.light)
                            onAlwaysAllow()
                        }) {
                            Text("Always allow")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .foregroundStyle(T.ink)
                                .kGlass(cornerRadius: 8, fallbackFill: T.surface)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Always allow \(AssistantActivity.displayName(forTool: toolName))")
                    }

                    Button(action: {
                        HapticManager.impact(.light)
                        onDecline()
                    }) {
                        Text("Not now")
                            .font(.system(size: 13, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
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
            VStack(alignment: .leading, spacing: 12) {
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
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .foregroundStyle(T.bg)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.ink))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose a file for the assistant")

                Button(action: {
                    HapticManager.impact(.light)
                    onDecline()
                }) {
                    Text("Not now")
                        .font(.system(size: 13, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(T.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Decline file access")
            }
        }
    }
}
