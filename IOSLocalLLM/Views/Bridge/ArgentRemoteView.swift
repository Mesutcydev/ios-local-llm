import SwiftUI
import UIKit

// MARK: - ArgentRemoteView
//
// iOS-side remote control for the Mac bridge's argent.* tool surface.
// Mirrors the layout of the Mac dashboard's ArgentView so the muscle
// memory transfers in both directions. Each button POSTs to the Mac
// via BridgeAgentClient.callTool() — the same path `/mac …` chat uses.
//
// State machine per button: idle → running(name) → result. Results
// surface in a single output pane at the bottom — screenshots render
// as an inline UIImage when argent.screenshot returns a base64 PNG.
//
// All approval-gated tools (keyboard, flow_execute, run-escape) will
// trigger the Mac's existing approval pipeline; the iOS UI just shows
// "waiting for approval on Mac" via the long URL timeout already in
// BridgeAgentClient (120s for non-safe-read calls).

struct ArgentRemoteView: View {

    @Environment(\.koduTheme) private var T

    // MARK: - State

    @State private var status: StatusState = .checking
    @State private var devices: [DeviceRow] = []
    @State private var selectedUDID: String = ""

    @State private var customBundleID: String = "com.codelens.CodeLens"
    @State private var customURL: String     = ""
    @State private var customFlow: String    = ""
    @State private var customText: String    = ""
    @State private var customToolName: String = "screenshot"
    @State private var customToolArgs: String = ""

    @State private var runningCommand: String?
    @State private var lastOk: Bool = true
    @State private var lastSummary: String = ""
    @State private var lastJSON: String   = ""
    @State private var lastImage: UIImage?

    enum StatusState {
        case checking
        case notInstalled(setupHint: String?)
        case ready(version: String?)
        /// argent binary found on disk but `--version` failed. Every
        /// downstream tool call will also fail, so surface that up
        /// front rather than letting the user tap buttons that do
        /// nothing and seeing a generic error in the output pane.
        case installedButUnreachable(hint: String?)
        case bridgeUnreachable(message: String)
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                statusCard
                if case .ready = status {
                    devicesSection
                    captureSection
                    interactionSection
                    deviceStateSection
                    appSection
                    inspectionSection
                    customSection
                    outputSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(LiquidPinkBackdrop())
        .navigationTitle("Argent Remote")
        .navigationBarTitleDisplayMode(.inline)
        .task { await initialLoad() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            KCaption(text: "REMOTE CONTROL")
            KPageTitle(title: "argent")
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusCard: some View {
        switch status {
        case .checking:
            KSection(title: "checking…") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    KMono(text: "asking the Mac if argent is available",
                          size: 11, color: T.ink3)
                    Spacer()
                }
                .padding(14)
            }
        case .notInstalled(let hint):
            KSection(title: "argent not installed") {
                VStack(alignment: .leading, spacing: 8) {
                    KMono(text: hint ?? "Install argent on your Mac to enable this tab.",
                          size: 11, color: T.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    KMono(text: "npm install -g @swmansion/argent",
                          size: 11, color: T.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6,
                                                     style: .continuous)
                                        .fill(T.surface3))
                    KSecondaryButton(label: "re-check",
                                     systemImage: "arrow.clockwise",
                                     trailing: nil) {
                        Task { await refresh() }
                    }
                    .frame(maxWidth: 160)
                }
                .padding(14)
            }
        case .ready(let version):
            KSection(title: "argent · ready") {
                HStack(spacing: 8) {
                    Circle().fill(T.good).frame(width: 7, height: 7)
                    KMono(text: version ?? "version unknown",
                          size: 11, color: T.ink2)
                    Spacer()
                    KSecondaryButton(label: "refresh",
                                     systemImage: "arrow.clockwise",
                                     trailing: nil) {
                        Task { await refresh() }
                    }
                    .fixedSize()
                    .disabled(runningCommand != nil)
                }
                .padding(14)
            }
        case .installedButUnreachable(let hint):
            KSection(title: "argent · not responding") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle().fill(T.warn).frame(width: 7, height: 7)
                        KMono(text: "argent is installed but didn't report a version. Commands won't work until it's reachable.",
                              size: 11, color: T.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let hint {
                        KMono(text: hint, size: 10.5, color: T.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    KSecondaryButton(label: "re-check",
                                     systemImage: "arrow.clockwise",
                                     trailing: nil) {
                        Task { await refresh() }
                    }
                    .frame(maxWidth: 160)
                }
                .padding(14)
            }
        case .bridgeUnreachable(let msg):
            KSection(title: "bridge unreachable") {
                VStack(alignment: .leading, spacing: 8) {
                    KMono(text: msg, size: 11, color: T.bad)
                        .fixedSize(horizontal: false, vertical: true)
                    KMono(text: "Pair (or re-pair) your Mac from the previous screen.",
                          size: 10.5, color: T.ink3)
                    KSecondaryButton(label: "retry",
                                     systemImage: "arrow.clockwise",
                                     trailing: nil) {
                        Task { await refresh() }
                    }
                    .frame(maxWidth: 130)
                }
                .padding(14)
            }
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        KSection(title: "devices") {
            VStack(spacing: 0) {
                if devices.isEmpty {
                    HStack {
                        KMono(text: "no simulators found.",
                              size: 11, color: T.ink3)
                        Spacer()
                    }
                    .padding(14)
                } else {
                    ForEach(Array(devices.enumerated()), id: \.element.udid) { idx, d in
                        if idx > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                        deviceRow(d)
                    }
                }
                Rectangle().fill(T.rule).frame(height: 1)
                HStack {
                    Spacer()
                    KSecondaryButton(label: "refresh devices",
                                     systemImage: "arrow.clockwise",
                                     trailing: nil) {
                        Task { await loadDevices() }
                    }
                    .fixedSize()
                    .disabled(runningCommand != nil)
                }
                .padding(10)
            }
        }
    }

    private func deviceRow(_ d: DeviceRow) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(d.state == "Booted" ? T.good : T.ink4)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                KMono(text: d.name, size: 12,
                      weight: .semibold, color: T.ink)
                KMono(text: d.state, size: 9.5, color: T.ink3)
            }
            Spacer()
            KSecondaryButton(label: d.state == "Booted" ? "selected" : "boot",
                             systemImage: d.state == "Booted" ? "checkmark"
                                                              : "play.fill",
                             trailing: nil) {
                Task { await bootDevice(d) }
            }
            .fixedSize()
            .disabled(runningCommand != nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(selectedUDID == d.udid
                    ? T.accentSoft.opacity(0.35) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedUDID = d.udid }
    }

    // MARK: - Capture

    private var captureSection: some View {
        KSection(title: "capture") {
            HStack(spacing: 10) {
                gridButton(label: "screenshot",
                           systemImage: "camera",
                           commandID: "screenshot") {
                    await callTool("argent.screenshot", risk: .safeRead)
                }
                gridButton(label: "describe",
                           systemImage: "doc.text.magnifyingglass",
                           commandID: "describe") {
                    await callTool("argent.describe", risk: .safeRead)
                }
            }
            .padding(14)
        }
    }

    // MARK: - Interaction

    private var interactionSection: some View {
        KSection(title: "interaction") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    gridButton(label: "tap center",
                               systemImage: "hand.tap",
                               commandID: "tap") {
                        await callTool("argent.tap", risk: .lowRisk,
                                       args: .object([
                                            "x": .number(0.5),
                                            "y": .number(0.5)
                                       ]))
                    }
                    gridButton(label: "home",
                               systemImage: "house",
                               commandID: "home") {
                        await callTool("argent.button", risk: .lowRisk,
                                       args: .object([
                                            "button": .string("home")
                                       ]))
                    }
                }
                HStack(spacing: 10) {
                    gridButton(label: "lock",
                               systemImage: "lock",
                               commandID: "lock") {
                        await callTool("argent.button", risk: .lowRisk,
                                       args: .object([
                                            "button": .string("lock")
                                       ]))
                    }
                    gridButton(label: "return",
                               systemImage: "return",
                               commandID: "return") {
                        await callTool("argent.keyboard", risk: .mediumRisk,
                                       args: .object([
                                            "key": .string("Return")
                                       ]))
                    }
                }
                HStack(spacing: 10) {
                    gridButton(label: "swipe ↑",
                               systemImage: "arrow.up",
                               commandID: "swipe-up") {
                        await callTool("argent.swipe", risk: .lowRisk,
                                       args: .object([
                                            "direction": .string("up")
                                       ]))
                    }
                    gridButton(label: "swipe ↓",
                               systemImage: "arrow.down",
                               commandID: "swipe-down") {
                        await callTool("argent.swipe", risk: .lowRisk,
                                       args: .object([
                                            "direction": .string("down")
                                       ]))
                    }
                }
                HStack(spacing: 10) {
                    gridButton(label: "swipe ←",
                               systemImage: "arrow.left",
                               commandID: "swipe-left") {
                        await callTool("argent.swipe", risk: .lowRisk,
                                       args: .object([
                                            "direction": .string("left")
                                       ]))
                    }
                    gridButton(label: "swipe →",
                               systemImage: "arrow.right",
                               commandID: "swipe-right") {
                        await callTool("argent.swipe", risk: .lowRisk,
                                       args: .object([
                                            "direction": .string("right")
                                       ]))
                    }
                }
                // Type-text composer. MEDIUM risk so the Mac will
                // pop an approval — useful escape hatch for "send a
                // few keys without manually picking up the Mac".
                HStack(spacing: 8) {
                    TextField("text to type", text: $customText)
                        .textFieldStyle(.plain)
                        .font(T.mono(11))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6,
                                                     style: .continuous)
                                        .fill(T.surface3))
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    KSecondaryButton(label: "type",
                                     systemImage: "keyboard",
                                     trailing: nil) {
                        Task {
                            await callTool("argent.keyboard", risk: .mediumRisk,
                                           args: .object([
                                                "text": .string(customText)
                                           ]),
                                           reason: "Type text into Simulator")
                        }
                    }
                    .fixedSize()
                    .disabled(customText.isEmpty || runningCommand != nil)
                }
            }
            .padding(14)
        }
    }

    // MARK: - Device state

    private var deviceStateSection: some View {
        KSection(title: "device state") {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    gridButton(label: "portrait",
                               systemImage: "iphone",
                               commandID: "rot-p") {
                        await callTool("argent.rotate", risk: .lowRisk,
                                       args: .object([
                                            "orientation": .string("Portrait")
                                       ]))
                    }
                    gridButton(label: "upside down",
                               systemImage: "iphone",
                               commandID: "rot-pd") {
                        await callTool("argent.rotate", risk: .lowRisk,
                                       args: .object([
                                            "orientation": .string("PortraitUpsideDown")
                                       ]))
                    }
                }
                HStack(spacing: 10) {
                    gridButton(label: "landscape ←",
                               systemImage: "iphone.landscape",
                               commandID: "rot-l") {
                        await callTool("argent.rotate", risk: .lowRisk,
                                       args: .object([
                                            "orientation": .string("LandscapeLeft")
                                       ]))
                    }
                    gridButton(label: "landscape →",
                               systemImage: "iphone.landscape",
                               commandID: "rot-r") {
                        await callTool("argent.rotate", risk: .lowRisk,
                                       args: .object([
                                            "orientation": .string("LandscapeRight")
                                       ]))
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: - App

    private var appSection: some View {
        KSection(title: "app") {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    TextField("bundle id", text: $customBundleID)
                        .textFieldStyle(.plain)
                        .font(T.mono(11))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6,
                                                     style: .continuous)
                                        .fill(T.surface3))
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    KSecondaryButton(label: "launch",
                                     systemImage: "play",
                                     trailing: nil) {
                        Task {
                            await callTool("argent.launch_app", risk: .lowRisk,
                                           args: .object([
                                                "bundleIdentifier": .string(customBundleID)
                                           ]))
                        }
                    }
                    .fixedSize()
                    .disabled(customBundleID.isEmpty || runningCommand != nil)
                }
                HStack(spacing: 8) {
                    TextField("url / scheme", text: $customURL)
                        .textFieldStyle(.plain)
                        .font(T.mono(11))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6,
                                                     style: .continuous)
                                        .fill(T.surface3))
                        .keyboardType(.URL)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    KSecondaryButton(label: "open",
                                     systemImage: "arrow.up.forward.app",
                                     trailing: nil) {
                        Task {
                            await callTool("argent.open_url", risk: .lowRisk,
                                           args: .object([
                                                "url": .string(customURL)
                                           ]))
                        }
                    }
                    .fixedSize()
                    .disabled(customURL.isEmpty || runningCommand != nil)
                }
                HStack(spacing: 8) {
                    TextField("flow name", text: $customFlow)
                        .textFieldStyle(.plain)
                        .font(T.mono(11))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6,
                                                     style: .continuous)
                                        .fill(T.surface3))
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    KSecondaryButton(label: "run flow",
                                     systemImage: "play.rectangle",
                                     trailing: nil) {
                        Task {
                            await callTool("argent.flow_execute",
                                           risk: .mediumRisk,
                                           args: .object([
                                                "name": .string(customFlow)
                                           ]),
                                           reason: "Replay recorded argent flow")
                        }
                    }
                    .fixedSize()
                    .disabled(customFlow.isEmpty || runningCommand != nil)
                }
            }
            .padding(14)
        }
    }

    // MARK: - Inspection

    private var inspectionSection: some View {
        KSection(title: "inspection") {
            HStack(spacing: 10) {
                gridButton(label: "a11y tree",
                           systemImage: "rectangle.3.group",
                           commandID: "ax") {
                    await callTool("argent.describe", risk: .safeRead)
                }
                gridButton(label: "native tree",
                           systemImage: "rectangle.stack",
                           commandID: "native-tree") {
                    await callTool("argent.run", risk: .safeRead,
                                   args: .object([
                                        "tool": .string("native-full-hierarchy"),
                                        "args": .string("--json")
                                   ]),
                                   reason: "Native UIKit hierarchy via argent.run")
                }
            }
            .padding(14)
        }
    }

    // MARK: - Custom / escape hatch

    private var customSection: some View {
        KSection(title: "any argent tool") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("tool name",
                              text: $customToolName)
                        .textFieldStyle(.plain)
                        .font(T.mono(11))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6,
                                                     style: .continuous)
                                        .fill(T.surface3))
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .frame(maxWidth: 180)
                    Spacer()
                }
                HStack(spacing: 8) {
                    TextField("--flag value …",
                              text: $customToolArgs)
                        .textFieldStyle(.plain)
                        .font(T.mono(11))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6,
                                                     style: .continuous)
                                        .fill(T.surface3))
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    KSecondaryButton(label: "run",
                                     systemImage: "play.fill",
                                     trailing: nil) {
                        Task {
                            await callTool("argent.run", risk: .mediumRisk,
                                           args: .object([
                                                "tool": .string(customToolName),
                                                "args": .string(customToolArgs)
                                           ]),
                                           reason: "Run argent tool \(customToolName)")
                        }
                    }
                    .fixedSize()
                    .disabled(customToolName.isEmpty || runningCommand != nil)
                }
                KMono(text: "Routes through argent.run on the Mac (approval required). Covers the ~49 long-tail tools.",
                      size: 9.5, color: T.ink4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    // MARK: - Output

    @ViewBuilder
    private var outputSection: some View {
        KSection(title: "output") {
            VStack(alignment: .leading, spacing: 0) {
                if let cmd = runningCommand {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        KMono(text: "running \(cmd)…",
                              size: 11, color: T.ink2)
                        Spacer()
                    }
                    .padding(14)
                } else if lastSummary.isEmpty && lastJSON.isEmpty && lastImage == nil {
                    HStack {
                        Image(systemName: "terminal")
                            .foregroundColor(T.ink4)
                        KMono(text: "command output appears here.",
                              size: 10.5, color: T.ink3)
                        Spacer()
                    }
                    .padding(14)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: lastOk ? "checkmark.circle.fill"
                                                 : "xmark.octagon.fill")
                            .foregroundColor(lastOk ? T.good : T.bad)
                        KMono(text: lastOk ? "ok" : "failed",
                              size: 11, weight: .semibold,
                              color: lastOk ? T.good : T.bad)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.top, 10)
                    Rectangle().fill(T.rule).frame(height: 1).padding(.top, 8)
                    VStack(alignment: .leading, spacing: 10) {
                        if let img = lastImage {
                            // Screenshot results — render inline so
                            // the user sees the Simulator state
                            // without leaving the screen. Capped at
                            // the device width via fit.
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 8,
                                                            style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8,
                                                     style: .continuous)
                                        .stroke(T.rule, lineWidth: 0.5)
                                )
                                .frame(maxWidth: .infinity)
                        }
                        if !lastSummary.isEmpty {
                            Text(lastSummary)
                                .font(T.mono(11))
                                .foregroundColor(T.ink)
                                .textSelection(.enabled)
                        }
                        if !lastJSON.isEmpty {
                            ScrollView(.horizontal) {
                                Text(lastJSON)
                                    .font(T.mono(10.5))
                                    .foregroundColor(T.ink2)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 280)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    // MARK: - Reusable button

    @ViewBuilder
    private func gridButton(label: String,
                            systemImage: String,
                            commandID: String,
                            action: @escaping () async -> Void) -> some View {
        KSecondaryButton(label: label, systemImage: systemImage) {
            Task {
                runningCommand = commandID
                await action()
                runningCommand = nil
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(runningCommand != nil)
    }

    // MARK: - Network

    private func callTool(
        _ tool: String,
        risk: RiskLevel,
        args: JSONValue = .object([:]),
        reason: String? = nil
    ) async {
        do {
            let result = try await BridgeAgentClient.shared.callTool(
                tool,
                arguments: args,
                risk:      risk,
                reason:    reason
            )
            handleSuccess(tool: tool, result: result)
        } catch {
            handleFailure(tool: tool, error: error)
        }
    }

    private func handleSuccess(tool: String, result: JSONValue) {
        lastOk    = true
        lastImage = nil

        // Argent screenshot: pull the base64 + render inline. Suppress
        // the JSON dump for image responses — the picture IS the
        // result.
        if tool == "argent.screenshot",
           case .object(let dict) = result,
           case .string(let b64)? = dict["base64"],
           let data = Data(base64Encoded: b64),
           let img  = UIImage(data: data) {
            lastImage   = img
            let bytes   = (dict["bytes"]).flatMap { v -> Int? in
                if case .number(let n) = v { return Int(n) }
                return nil
            } ?? data.count
            lastSummary = "\(Int(img.size.width))×\(Int(img.size.height)) · \(bytes/1024) KB"
            lastJSON    = ""
            return
        }

        // Tool returned an `argent.*` result that wraps argent CLI
        // output as `{ ok, result | stdout }`. Pretty-print whichever
        // key is present.
        if case .object(let dict) = result {
            if case .string(let stdout)? = dict["stdout"] {
                lastSummary = "ok"
                lastJSON    = stdout
                return
            }
            if let inner = dict["result"] {
                lastSummary = "ok"
                lastJSON    = prettyJSON(inner)
                return
            }
        }
        lastSummary = "ok"
        lastJSON    = prettyJSON(result)
    }

    private func handleFailure(tool: String, error: Error) {
        lastOk      = false
        lastImage   = nil
        lastSummary = "\(tool) failed"
        lastJSON    = error.localizedDescription
    }

    private func prettyJSON(_ v: JSONValue) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(v),
           let s = String(data: data, encoding: .utf8) { return s }
        return ""
    }

    // MARK: - Load

    private func initialLoad() async {
        await refresh()
    }

    private func refresh() async {
        status = .checking
        do {
            let r = try await BridgeAgentClient.shared.callTool(
                "argent.status",
                arguments: .object([:]),
                risk:      .safeRead,
                reason:    "Argent Remote tab opened"
            )
            guard case .object(let dict) = r else {
                status = .ready(version: nil)
                await loadDevices()
                return
            }
            let installed: Bool = {
                if case .bool(let b)? = dict["installed"] { return b }
                return false
            }()
            let reachable: Bool = {
                if case .bool(let b)? = dict["reachable"] { return b }
                return false
            }()
            if installed {
                let v: String? = {
                    if case .string(let s)? = dict["version"] { return s }
                    return nil
                }()
                let hint: String? = {
                    if case .string(let s)? = dict["setupHint"] { return s }
                    return nil
                }()
                if reachable || v != nil {
                    status = .ready(version: v)
                    await loadDevices()
                } else {
                    status = .installedButUnreachable(hint: hint)
                }
            } else {
                let hint: String? = {
                    if case .string(let s)? = dict["setupHint"] { return s }
                    return nil
                }()
                status = .notInstalled(setupHint: hint)
            }
        } catch {
            status = .bridgeUnreachable(message: error.localizedDescription)
        }
    }

    private func loadDevices() async {
        runningCommand = "list-devices"
        do {
            let r = try await BridgeAgentClient.shared.callTool(
                "argent.list_devices",
                arguments: .object([:]),
                risk:      .safeRead
            )
            // Mac tool returns { devices: [{ udid, name, runtime, state }] }
            var rows: [DeviceRow] = []
            if case .object(let dict) = r,
               case .array(let arr)? = dict["devices"] {
                for item in arr {
                    guard case .object(let d) = item,
                          case .string(let udid)? = d["udid"],
                          case .string(let name)? = d["name"]
                    else { continue }
                    let state: String = {
                        if case .string(let s)? = d["state"] { return s }
                        return "Unknown"
                    }()
                    rows.append(DeviceRow(udid: udid, name: name, state: state))
                }
            }
            devices = rows
            if selectedUDID.isEmpty,
               let b = rows.first(where: { $0.state == "Booted" }) {
                selectedUDID = b.udid
            }
        } catch {
            // Don't tear down the whole tab — show the error in the
            // output pane and leave devices empty so the user can
            // still hit "refresh devices".
            handleFailure(tool: "argent.list_devices", error: error)
        }
        runningCommand = nil
    }

    private func bootDevice(_ d: DeviceRow) async {
        runningCommand = "boot \(d.name)"
        await callTool("argent.boot_device",
                       risk:   .lowRisk,
                       args:   .object(["udid": .string(d.udid)]),
                       reason: "Boot \(d.name)")
        // Refresh so the state badge flips to Booted.
        await loadDevices()
        runningCommand = nil
    }

    // MARK: - Models

    private struct DeviceRow: Identifiable, Equatable {
        var id: String { udid }
        let udid:  String
        let name:  String
        let state: String
    }
}
