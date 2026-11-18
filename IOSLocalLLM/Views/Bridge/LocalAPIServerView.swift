import SwiftUI

/// The API workspace uses the same Studio typography, glass sections, and
/// semantic colors as Settings and Models. It never starts a listener on entry.
struct LocalAPIServerView: View {
    @ObservedObject private var manager = LocalAPIManager.shared
    @ObservedObject private var assistant = CodingAssistantService.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.koduTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedHost = ""
    @State private var format: LocalAPIClientSetup.Format = .openAI
    @State private var revealsKey = false
    @State private var confirmsRotation = false
    @State private var changingServer = false
    @State private var stoppingServer = false
    @State private var setupError: String?

    private var port: UInt16 {
        if case .running(let activePort) = manager.state { return activePort }
        return LocalAPIValidation.validPort(settings.localAPIPort) ?? 11434
    }

    private var setup: LocalAPIClientSetup {
        LocalAPIClientSetup(
            host: manager.addresses.contains(selectedHost)
                ? selectedHost : manager.addresses.first ?? "IPHONE_IP",
            port: port, modelID: assistant.activeModel.id, publicKeyPin: manager.publicKeyPin
        )
    }

    private var activity: LocalAPIWorkspaceActivity {
        let listener: LocalAPIWorkspaceActivity.Listener
        switch manager.state {
        case .stopped: listener = .stopped
        case .starting: listener = .starting
        case .running: listener = .running
        case .failed: listener = .failed
        }
        let model: LocalAPIWorkspaceActivity.Model
        switch assistant.state {
        case .unloaded: model = .unloaded
        case .loading: model = .loading
        case .ready: model = .ready
        case .generating: model = .generating
        case .failed: model = .failed
        }
        return .resolve(listener: listener, model: model,
                        isLocal: assistant.activeExecutionLocation == .localDownloaded,
                        isResident: assistant.isSelectedLocalModelResident, isStopping: stoppingServer)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("DEVELOPER TOOLS")
                        .font(theme.mono(10, .semibold)).tracking(1)
                        .foregroundStyle(theme.accent)
                    Text("Local API Server")
                        .font(theme.display(30, .bold)).foregroundStyle(theme.ink)
                    Text("Connect your tools to a model running on this device.")
                        .font(theme.sans(14)).foregroundStyle(theme.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 8)

                KSection(title: "server") {
                    LocalAPIServerControls(
                        activity: activity, listenerState: manager.state, port: port,
                        changing: changingServer,
                        onStart: { changeServer(.start) },
                        onStop: { changeServer(.stop) },
                        onRestart: { changeServer(.restart) }
                    )
                }
                LocalAPIModelSection()
                KSection(title: "connection") {
                    LocalAPIConnectionSection(
                        setup: setup, addresses: manager.addresses, host: $selectedHost,
                        format: $format, setupError: setupError,
                        onRefresh: prepareSetup
                    )
                }
                KSection(title: "authentication") {
                    LocalAPIKeySection(
                        key: manager.apiKey, revealsKey: $revealsKey,
                        onRotate: { revealsKey = false; confirmsRotation = true }
                    )
                }
                KSection(title: "quick start") {
                    LocalAPIQuickStartSection(setup: setup, format: format,
                                              apiKey: manager.apiKey, revealsKey: revealsKey)
                }
                KSection(title: "server settings") {
                    LocalAPISettingsSection(changingServer: $changingServer)
                }
                KSection(title: "supported endpoints") {
                    LocalAPIEndpointsSection()
                }
                Label("HTTPS encrypts traffic. Verify this device’s public-key pin before connecting. SDKs must trust the certificate or support pinning. The server stops when the app backgrounds.",
                      systemImage: "lock.shield")
                    .font(theme.sans(12)).foregroundStyle(theme.ink2)
                    .padding(20)
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 24)
        }
        .background(LiquidPinkBackdrop())
        .navigationTitle("Local API")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { prepareSetup() }
        .onDisappear { revealsKey = false }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { revealsKey = false }
        }
        .alert("Rotate the API key?", isPresented: $confirmsRotation) {
            Button("Rotate API key", role: .destructive) {
                manager.rotateKey()
                revealsKey = false
                ToastCenter.shared.info("API key rotated", detail: "Update your clients with the new key.")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing clients will need the new key for their next request.")
        }
    }

    private enum ServerAction { case start, stop, restart }

    private func changeServer(_ action: ServerAction) {
        guard !changingServer else { return }
        changingServer = true
        stoppingServer = action == .stop
        settings.localAPIEnabled = action != .stop
        Task {
            defer { changingServer = false; stoppingServer = false }
            switch action {
            case .start: await manager.start()
            case .stop: await manager.stop()
            case .restart: await manager.restart()
            }
        }
    }

    private func prepareSetup() {
        manager.refreshAddresses()
        do {
            try manager.prepareClientSetup()
            setupError = nil
        } catch {
            setupError = error.localizedDescription
        }
    }
}

private struct LocalAPIServerControls: View {
    let activity: LocalAPIWorkspaceActivity
    let listenerState: LocalAPIManager.State
    let port: UInt16
    let changing: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void
    @Environment(\.koduTheme) private var theme

    private var listening: Bool {
        switch listenerState {
        case .running, .starting: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                LocalAPIActivityIndicator(activity: activity)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(theme.sans(19, .semibold)).foregroundStyle(theme.ink)
                        .accessibilityIdentifier("api.server.status")
                    Text(detail).font(theme.sans(13)).foregroundStyle(theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                VStack(spacing: 10) { actions }
            }
        }
        .padding(16)
    }

    @ViewBuilder private var actions: some View {
        LocalAPIActionButton(title: listening ? "Stop server" : "Start server",
                             symbol: listening ? "stop.fill" : "play.fill",
                             primary: true, disabled: changing,
                             action: listening ? onStop : onStart)
            .accessibilityIdentifier(listening ? "api.server.stop" : "api.server.start")
        if listening {
            LocalAPIActionButton(title: "Restart", symbol: "arrow.clockwise",
                                 disabled: changing || listenerState == .starting, action: onRestart)
                .accessibilityIdentifier("api.server.restart")
        }
    }

    private var title: LocalizedStringKey {
        switch activity {
        case .offline: "Server stopped"
        case .starting: "Starting server…"
        case .stopping: "Stopping server…"
        case .listening: "Listening · model unloaded"
        case .loading: "Preparing local model…"
        case .ready: "Ready for requests"
        case .generating: "Generating response…"
        case .localModelRequired: "Choose a local model"
        case .listenerFailed: "Server couldn’t start"
        case .modelFailed: "Model needs attention"
        }
    }

    private var detail: String {
        if case .failed(let message) = listenerState { return message }
        switch activity {
        case .offline: return LocalizationService.shared.t("Start when you’re ready to connect a client.")
        case .starting: return LocalizationService.shared.t("Opening the HTTPS listener on port \(port).")
        case .stopping: return LocalizationService.shared.t("Closing connections and stopping API work.")
        case .listening: return LocalizationService.shared.t("HTTPS is listening on port \(port). Load an installed model below.")
        case .loading: return LocalizationService.shared.t("The listener is open. Wait for the model to finish loading.")
        case .ready: return LocalizationService.shared.t("HTTPS is listening on port \(port). Keep this app in the foreground.")
        case .generating: return LocalizationService.shared.t("The shared model is busy. New requests may need to wait.")
        case .localModelRequired: return LocalizationService.shared.t("The local API serves downloaded models. Apple Private Cloud is available in chat.")
        case .listenerFailed: return LocalizationService.shared.t("Check the port and try again.")
        case .modelFailed: return LocalizationService.shared.t("The listener is open. Review the model error below.")
        }
    }
}

/// Only this small view ticks while work is active. Idle, background, and
/// Reduce Motion states have no animation timeline.
private struct LocalAPIActivityIndicator: View {
    let activity: LocalAPIWorkspaceActivity
    @Environment(\.koduTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        switch activity {
        case .ready: theme.good
        case .listenerFailed, .modelFailed: theme.bad
        case .starting, .stopping, .loading, .generating, .localModelRequired: theme.warn
        case .offline, .listening: theme.ink2
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24,
                                paused: !activity.isWorking || reduceMotion || scenePhase != .active)) { context in
            ZStack {
                Circle().stroke(theme.rule, lineWidth: 1)
                Image(systemName: activity == .ready ? "checkmark" : "network")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(color)
                if activity.isWorking {
                    Circle().trim(from: 0, to: 0.24)
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(reduceMotion ? -90 : context.date.timeIntervalSinceReferenceDate * 90))
                }
            }
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }
}

private struct LocalAPIModelSection: View {
    @ObservedObject private var assistant = CodingAssistantService.shared
    @Environment(\.koduTheme) private var theme
    @State private var choosesModel = false
    @State private var managesModels = false
    @State private var loadTask: Task<Void, Never>?
    @State private var cleaningUp = false

    private var isLocal: Bool { assistant.activeExecutionLocation == .localDownloaded }
    private var busy: Bool {
        switch assistant.state {
        case .loading, .generating: true
        default: cleaningUp || loadTask != nil
        }
    }

    var body: some View {
        KSection(title: "local model") {
            VStack(alignment: .leading, spacing: 12) {
                Text(assistant.activeDisplayName).font(theme.sans(16, .semibold)).foregroundStyle(theme.ink)
                if isLocal {
                    LocalAPICopyValue(label: "Model ID", value: assistant.activeModel.id,
                                      identifier: "api.model.id")
                }
                Label(detail, systemImage: "cpu")
                    .font(theme.sans(13)).foregroundStyle(theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("api.model.status")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { modelActions }
                    VStack(spacing: 10) { modelActions }
                }
                LocalAPIActionButton(title: "Choose installed model", symbol: "square.stack.3d.up",
                                     disabled: busy, action: { choosesModel = true })
                    .accessibilityIdentifier("api.model.choose")
                Text("Uses the shared chat runtime. Memory and thermal limits still apply.")
                    .font(theme.sans(12)).foregroundStyle(theme.ink3)
            }.padding(16)
        }
        .sheet(isPresented: $choosesModel) {
            AssistantModelPickerView(downloadedOnly: true, allowsApplePrivateCloud: false)
        }
        .sheet(isPresented: $managesModels) {
            ModelsManagerView()
                .koduTheme(theme)
                .preferredColorScheme(theme.isDark ? .dark : .light)
        }
    }

    @ViewBuilder private var modelActions: some View {
        if isLocal {
            switch assistant.state {
            case .loading:
                LocalAPIActionButton(title: cleaningUp ? "Cancelling…" : "Cancel load", symbol: "xmark",
                                     disabled: cleaningUp || loadTask == nil, action: cancelLoad)
                    .accessibilityIdentifier("api.model.cancel")
            case .ready where assistant.isSelectedLocalModelResident:
                LocalAPIActionButton(title: "Unload model", symbol: "eject", disabled: cleaningUp) {
                    cleaningUp = true
                    Task { await assistant.unloadAndWaitForCleanup(); cleaningUp = false }
                }
                .accessibilityIdentifier("api.model.unload")
            case .unloaded, .failed, .ready:
                if assistant.selectedModelIsInstalled {
                    LocalAPIActionButton(title: "Load model", symbol: "arrow.up.circle", disabled: cleaningUp || loadTask != nil) {
                        loadTask = Task {
                            await assistant.load(allowStorageFallback: false, reselectFromSettings: false,
                                                 allowDownload: false)
                            loadTask = nil
                        }
                    }.accessibilityIdentifier("api.model.load")
                } else {
                    LocalAPIActionButton(title: "Open Models", symbol: "square.stack", action: { managesModels = true })
                        .accessibilityIdentifier("api.model.manage")
                }
            case .generating:
                Label("Model in use", systemImage: "waveform")
                    .font(theme.sans(13)).foregroundStyle(theme.warn)
            }
        } else {
            Text("Select an installed model to serve requests on this device.")
                .font(theme.sans(13)).foregroundStyle(theme.warn)
        }
    }

    private var detail: String {
        if cleaningUp { return LocalizationService.shared.t("Finishing model cleanup…") }
        guard isLocal else { return LocalizationService.shared.t("Cloud models cannot be served by the local API.") }
        switch assistant.state {
        case .unloaded: return assistant.selectedModelIsInstalled ? "Installed · not loaded" : "Download this model in Models first."
        case .loading(let progress): return progress.isEmpty ? "Loading…" : progress
        case .ready: return assistant.isSelectedLocalModelResident ? "Loaded on this device" : "Runtime unloaded · load the model again"
        case .generating: return LocalizationService.shared.t("Generating · shared runtime is busy")
        case .failed(let error): return error
        }
    }

    private func cancelLoad() {
        guard let pending = loadTask else { return }
        cleaningUp = true
        pending.cancel()
        assistant.unload()
        Task {
            // Package loaders may finish allocating before cancellation is
            // observed. Drain the original task before offering another load.
            await pending.value
            await assistant.unloadAndWaitForCleanup()
            cleaningUp = false
        }
    }
}

private struct LocalAPIConnectionSection: View {
    let setup: LocalAPIClientSetup
    let addresses: [String]
    @Binding var host: String
    @Binding var format: LocalAPIClientSetup.Format
    let setupError: String?
    let onRefresh: () -> Void
    @Environment(\.koduTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Client format", selection: $format) {
                ForEach(LocalAPIClientSetup.Format.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("api.client.format")
            if addresses.count > 1 {
                Picker("Network address", selection: Binding(
                    get: { addresses.contains(host) ? host : addresses[0] },
                    set: { host = $0 }
                )) {
                    ForEach(addresses, id: \.self) { Text($0).tag($0) }
                }.font(theme.mono(12)).tint(theme.accent)
            }
            if addresses.isEmpty {
                Text("Connect both devices to the same network. Replace IPHONE_IP with this device’s address.")
                    .font(theme.sans(12)).foregroundStyle(theme.warn)
            }
            LocalAPICopyValue(label: "Base URL", value: setup.baseURL(for: format), identifier: "api.connection.url")
            LocalAPICopyValue(label: "TLS public-key pin",
                              value: setup.hasValidPin ? setup.publicKeyPin : "Pin unavailable",
                              identifier: "api.connection.pin", copyEnabled: setup.hasValidPin)
            if let setupError {
                Text(setupError).font(theme.sans(12)).foregroundStyle(theme.bad)
            }
            Button("Refresh connection details", action: onRefresh)
                .font(theme.sans(13, .medium)).tint(theme.accent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("api.connection.refresh")
        }.padding(16)
    }
}

private struct LocalAPIKeySection: View {
    let key: String
    @Binding var revealsKey: Bool
    let onRotate: () -> Void
    @Environment(\.koduTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(revealsKey ? key : "•••• •••• •••• ••••")
                .font(theme.mono(13)).foregroundStyle(theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .privacySensitive().accessibilityIdentifier("api.key.value")
                .accessibilityLabel(revealsKey ? "API key revealed" : "API key hidden")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { controls }
                VStack(spacing: 10) { controls }
            }
            Text("Key copies stay on this device’s clipboard. Revealed keys hide when you leave this page.")
                .font(theme.sans(12)).foregroundStyle(theme.ink3)
        }.padding(16)
    }

    @ViewBuilder private var controls: some View {
        LocalAPIActionButton(title: revealsKey ? "Hide key" : "Reveal key",
                             symbol: revealsKey ? "eye.slash" : "eye", action: { revealsKey.toggle() })
            .accessibilityIdentifier("api.key.reveal")
        LocalAPIActionButton(title: "Copy key", symbol: "doc.on.doc") {
            LocalAPIClipboard.copy(key, message: "API key copied")
        }.accessibilityIdentifier("api.key.copy")
        Button("Rotate", action: onRotate)
            .font(theme.sans(13, .medium)).tint(theme.bad).frame(minWidth: 60, minHeight: 44)
            .accessibilityIdentifier("api.key.rotate")
    }
}

private struct LocalAPIQuickStartSection: View {
    let setup: LocalAPIClientSetup
    let format: LocalAPIClientSetup.Format
    let apiKey: String
    let revealsKey: Bool
    @Environment(\.koduTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. Start the server and load an installed model.\n2. Verify the TLS pin through a trusted channel.\n3. Run these commands on your client.")
                .font(theme.sans(13)).foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text(setup.example(for: format, apiKey: revealsKey ? apiKey : "YOUR_API_KEY"))
                .font(theme.mono(11)).foregroundStyle(theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface2, in: RoundedRectangle(cornerRadius: 10))
                .privacySensitive().accessibilityIdentifier("api.setup.commands")
                .accessibilityLabel(revealsKey
                    ? "Setup commands include your API key. Use Copy setup commands."
                    : setup.example(for: format, apiKey: "YOUR_API_KEY"))
            LocalAPIActionButton(title: "Copy setup commands", symbol: "terminal", disabled: !setup.hasValidPin) {
                LocalAPIClipboard.copy(setup.example(for: format, apiKey: apiKey), message: "Setup commands copied")
            }.accessibilityIdentifier("api.setup.copy")
            Text("Copied commands include your API key. Keep both --insecure and --pinnedpubkey together; the pin verifies this device’s certificate.")
                .font(theme.sans(12)).foregroundStyle(theme.ink3)
        }.padding(16)
    }
}

private struct LocalAPISettingsSection: View {
    @Binding var changingServer: Bool
    @ObservedObject private var manager = LocalAPIManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.koduTheme) private var theme
    @State private var portText = String(AppSettings.shared.localAPIPort)
    @State private var portError: String?
    @FocusState private var editingPort: Bool

    private var controlsBusy: Bool { changingServer || manager.state == .starting }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { portControls }
                VStack(alignment: .leading, spacing: 8) { portControls }
            }
            if let portError {
                Text(portError).font(theme.sans(12)).foregroundStyle(theme.bad)
                    .accessibilityIdentifier("api.settings.portError")
            }
            Text("Ports 1024–65535. Applying a change restarts an enabled server.")
                .font(theme.sans(12)).foregroundStyle(theme.ink3)
            Divider().overlay(theme.rule)
            Toggle("Keep screen awake while running", isOn: Binding(
                get: { settings.localAPIKeepScreenAwake },
                set: { settings.localAPIKeepScreenAwake = $0; manager.refreshIdleTimerPolicy() }
            )).accessibilityIdentifier("api.settings.keepAwake")
            Toggle("Allow nearby devices", isOn: Binding(
                get: { settings.localAPIIncludePeerToPeer },
                set: { enabled in
                    settings.localAPIIncludePeerToPeer = enabled
                    guard settings.localAPIEnabled else { return }
                    changingServer = true
                    Task { await manager.restart(); changingServer = false }
                }
            ))
            .disabled(controlsBusy).accessibilityIdentifier("api.settings.peerToPeer")
            Text("Off by default. Peer-to-peer / AWDL can accept nearby devices outside your network. Authentication is still required.")
                .font(theme.sans(12)).foregroundStyle(theme.ink3)
        }
        .font(theme.sans(14)).tint(theme.accent).padding(16)
        .onChange(of: settings.localAPIPort) { _, value in
            if !editingPort { portText = String(value) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if editingPort {
                    Spacer()
                    Button("Done", systemImage: "checkmark") { editingPort = false }
                }
            }
        }
    }

    @ViewBuilder private var portControls: some View {
        Text("Port").font(theme.sans(14, .medium)).foregroundStyle(theme.ink)
        TextField("11434", text: $portText)
            .font(theme.mono(14)).keyboardType(.numberPad)
            .padding(10).background(theme.surface2, in: RoundedRectangle(cornerRadius: 8))
            .frame(minWidth: 90).focused($editingPort)
            .disabled(controlsBusy).accessibilityIdentifier("api.settings.port")
        Button("Apply", action: applyPort)
            .font(theme.sans(14, .semibold)).tint(theme.accent)
            .frame(minWidth: 60, minHeight: 44).disabled(controlsBusy)
            .accessibilityIdentifier("api.settings.applyPort")
    }

    private func applyPort() {
        guard let value = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              LocalAPIValidation.validPort(value) != nil else {
            portError = "Use a port from 1024 through 65535."
            return
        }
        // Persist synchronously so lifecycle restarts read the applied value.
        settings.localAPIPort = value
        portText = String(value)
        portError = nil
        editingPort = false
        if settings.localAPIEnabled {
            changingServer = true
            Task {
                await manager.restart()
                changingServer = false
                if case .running(let activePort) = manager.state, Int(activePort) == value {
                    ToastCenter.shared.success("Local API port changed", detail: "Now listening on \(activePort).")
                }
            }
        } else {
            ToastCenter.shared.success("Local API port saved")
        }
    }
}

private struct LocalAPIEndpointsSection: View {
    @Environment(\.koduTheme) private var theme
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(LocalAPIClientSetup.routes) { route in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(route.method + " " + route.path)
                            .font(theme.mono(12, .medium)).foregroundStyle(theme.ink)
                            .textSelection(.enabled)
                        Text(LocalizedStringKey(route.purpose)).font(theme.sans(12)).foregroundStyle(theme.ink2)
                    }.accessibilityIdentifier("api.route.\(route.path)")
                }
                Text("All routes require an API key. Responses supports text only. Compatibility is scoped; unsupported options return an error.")
                    .font(theme.sans(12)).foregroundStyle(theme.ink3)
            }.padding(.top, 14)
        } label: {
            Text("8 endpoints · OpenAI, Anthropic, Ollama")
                .font(theme.sans(14, .medium)).foregroundStyle(theme.ink)
                .accessibilityIdentifier("api.endpoints.toggle")
        }
        .tint(theme.accent).padding(16)
    }
}

private struct LocalAPICopyValue: View {
    let label: String
    let value: String
    let identifier: String
    var copyEnabled = true
    @Environment(\.koduTheme) private var theme

    var body: some View {
        Button {
            LocalAPIClipboard.copy(value, message: "\(label) copied")
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(LocalizedStringKey(label)).font(theme.mono(10, .semibold)).foregroundStyle(theme.ink2)
                    Spacer()
                    Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundStyle(theme.accent)
                }
                Text(value).font(theme.mono(12)).foregroundStyle(theme.ink)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface2, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).disabled(!copyEnabled).accessibilityIdentifier(identifier)
        .accessibilityLabel("Copy \(label)").accessibilityValue(value)
    }
}

private struct LocalAPIActionButton: View {
    let title: String
    let symbol: String
    var primary = false
    var disabled = false
    let action: () -> Void
    @Environment(\.koduTheme) private var theme

    var body: some View {
        Button(action: action) {
            Label(LocalizedStringKey(title), systemImage: symbol)
                .font(theme.sans(14, .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 46)
                // Neutral ink/contrast pairing matches the app's Onyx action
                // language in both appearances, including its OLED theme.
                .foregroundStyle(primary ? theme.bg : theme.ink)
                .background(primary ? theme.ink : theme.surface2,
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(primary ? .clear : theme.rule, lineWidth: 1))
                .opacity(disabled ? 0.45 : 1)
        }.buttonStyle(KTactileButtonStyle()).disabled(disabled)
    }
}

@MainActor
private enum LocalAPIClipboard {
    static func copy(_ value: String, message: String) {
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: value]], options: [.localOnly: true])
        ToastCenter.shared.success(message)
    }
}
