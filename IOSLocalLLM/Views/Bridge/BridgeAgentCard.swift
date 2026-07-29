import SwiftUI

// MARK: - BridgeAgentCard
//
// Phase-1 manual validation harness. Lives on the Mac tab below the
// paired-Macs card. Surfaces:
//   • Heartbeat probe — fires bridge.heartbeat, shows nonce echo +
//     Mac tool count + round-trip ms.
//   • Read Mac context — fires mac.get_active_context, shows frontmost
//     app + window title + selected text, with a permission hint when
//     Accessibility isn't trusted on the Mac.
//
// Both buttons share the same simple state machine: idle → running
// → result(success) | result(error). Errors render the raw message
// so users (and we) can debug wire/auth/schema issues quickly during
// Phase-1 dogfood. Polished agent chat lands in Phase 3.

struct BridgeAgentCard: View {

    @Environment(\.koduTheme) private var T

    @State private var state: ProbeState = .idle
    @State private var lastResult: ProbeResult? = nil

    enum ProbeState: Equatable {
        case idle
        case running(String)   // "heartbeat" / "active context"
    }

    enum ProbeResult: Equatable {
        case heartbeat(HeartbeatResult)
        case activeContext(ActiveContextResult)
        case approval(focusedApp: String)
        case error(String)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            buttonRow
            if let result = lastResult {
                Divider().background(T.rule)
                resultBlock(result)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .kGlass(cornerRadius: 14, fallbackFill: T.surface)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("AGENT (PREVIEW)")
                .font(T.mono(11, .semibold))
                .foregroundColor(T.ink4)
            Spacer()
            if case .running(let label) = state {
                HStack(spacing: 6) {
                    ProgressView().tint(T.accent).scaleEffect(0.6)
                    Text(label)
                        .font(T.mono(10, .regular))
                        .foregroundColor(T.ink3)
                }
            }
        }
    }

    // MARK: - Buttons

    private var buttonRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                probeButton(
                    label: "Heartbeat",
                    systemImage: "wave.3.right",
                    running: state == .running("heartbeat"),
                    action: runHeartbeat
                )
                probeButton(
                    label: "Mac context",
                    systemImage: "rectangle.on.rectangle",
                    running: state == .running("active context"),
                    action: runActiveContext
                )
            }
            HStack(spacing: 10) {
                probeButton(
                    label: "Focus Xcode (asks approval)",
                    systemImage: "hammer",
                    running: state == .running("focus xcode"),
                    action: runFocusXcode
                )
            }
        }
    }

    @ViewBuilder
    private func probeButton(
        label: String,
        systemImage: String,
        running: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(T.mono(12, .semibold))
            }
            .foregroundColor(running ? T.ink3 : T.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(running ? T.surface2 : T.surface3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(T.rule, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(state != .idle)
    }

    // MARK: - Result rendering

    @ViewBuilder
    private func resultBlock(_ result: ProbeResult) -> some View {
        switch result {
        case .heartbeat(let hb):
            VStack(alignment: .leading, spacing: 6) {
                resultRow("Mac",      hb.macName)
                resultRow("Tools",    "\(hb.toolCount)")
                resultRow("Mac time", hb.macTime)
            }
        case .approval(let focusedApp):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundColor(T.good)
                Text("Approved on Mac → focused \(focusedApp)")
                    .font(T.mono(11, .regular))
                    .foregroundColor(T.ink2)
            }
        case .activeContext(let ctx):
            VStack(alignment: .leading, spacing: 6) {
                resultRow("App",       ctx.frontmostApp ?? "—")
                if let bundle = ctx.bundleIdentifier, !bundle.isEmpty {
                    resultRow("Bundle",  bundle)
                }
                if let title = ctx.windowTitle, !title.isEmpty {
                    resultRow("Window",  title)
                }
                if let selected = ctx.selectedText, !selected.isEmpty {
                    resultRow("Selected", selected.prefix(140).appending(selected.count > 140 ? "…" : ""))
                }
                if !ctx.missingPermissions.isEmpty {
                    permissionHint(missing: ctx.missingPermissions)
                }
            }
        case .error(let msg):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(T.bad)
                Text(msg)
                    .font(T.mono(11, .regular))
                    .foregroundColor(T.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label.uppercased())
                .font(T.mono(9, .semibold))
                .tracking(0.5)
                .foregroundColor(T.ink4)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(T.mono(11, .regular))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func permissionHint(missing: [String]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 10))
                .foregroundColor(T.warn)
            Text(permissionMessage(for: missing))
                .font(T.mono(10, .regular))
                .foregroundColor(T.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(T.warn.opacity(0.10)))
    }

    private func permissionMessage(for codes: [String]) -> String {
        if codes.contains("accessibility_required") {
            return "Mac needs Accessibility. Enable LocalCoderBridge in System Settings → Privacy & Security → Accessibility, then Quit & Relaunch the bridge (macOS caches the grant per-process, the toggle alone isn't enough)."
        }
        return "Mac is missing a permission: \(codes.joined(separator: ", "))"
    }

    // MARK: - Actions

    private func runHeartbeat() {
        state = .running("heartbeat")
        lastResult = nil
        Task {
            let start = Date()
            do {
                var hb = try await BridgeAgentClient.shared.heartbeat()
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                // Patch round-trip ms in after the fact — the client
                // doesn't time itself.
                hb = HeartbeatResult(
                    macName: hb.macName,
                    toolCount: hb.toolCount,
                    macTime: hb.macTime,
                    roundTripMs: ms
                )
                lastResult = .heartbeat(hb)
            } catch {
                lastResult = .error(error.localizedDescription)
            }
            state = .idle
        }
    }

    private func runActiveContext() {
        state = .running("active context")
        lastResult = nil
        Task {
            do {
                let ctx = try await BridgeAgentClient.shared.activeContext()
                lastResult = .activeContext(ctx)
            } catch {
                lastResult = .error(error.localizedDescription)
            }
            state = .idle
        }
    }

    /// Exercises the Phase-5 approval pipeline end-to-end: posts a
    /// MEDIUM_RISK_ACTION (mac.bring_app_to_front targeting Xcode),
    /// which parks on the Mac's Pending Approvals card until the user
    /// clicks Approve. Up to a 2-minute window before the URLSession
    /// times out.
    private func runFocusXcode() {
        state = .running("focus xcode")
        lastResult = nil
        Task {
            do {
                let result = try await BridgeAgentClient.shared.callTool(
                    "mac.bring_app_to_front",
                    arguments: .object([
                        "bundleIdentifier": .string("com.apple.dt.Xcode")
                    ]),
                    risk:      .mediumRisk,
                    reason:    "iPhone wants to focus Xcode on the Mac"
                )
                let name = result.stringField("displayName") ?? "Xcode"
                lastResult = .approval(focusedApp: name)
            } catch {
                lastResult = .error(error.localizedDescription)
            }
            state = .idle
        }
    }
}
