import SwiftUI

// MARK: - WebSettingsView
// Complete settings UI for the Web Tool. Reads from / writes to
// `WebToolService.shared.settings`. API keys go through `KeychainStore`.

struct WebSettingsView: View {

    @ObservedObject private var webTool = WebToolService.shared
    @ObservedObject private var log = WebActivityLogger.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    @State private var apiKeyInput: String = ""
    @State private var endpointInput: String = ""
    @State private var showActivity = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    modeSection
                    providerSection
                    limitsSection
                    networkSection
                    cacheSection
                    activitySection
                    privacyCard
                }
                .padding(.bottom, 32)
            }
            .background(LiquidPinkBackdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundColor(T.ink)
                }
            }
            .sheet(isPresented: $showActivity) { WebActivityLogView() }
            .onAppear {
                apiKeyInput = ""   // never pre-fill keys from Keychain
                endpointInput = currentEndpoint?.absoluteString ?? ""
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            KCaption(text: "WEB TOOL")
            KPageTitle(title: "Web Access", size: 28)
            KMono(text: "optional · off by default · on-device LLM stays on-device",
                  size: 11, color: T.ink3)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // MARK: - Mode

    private var modeSection: some View {
        KSection(title: "mode") {
            VStack(spacing: 0) {
                ForEach(Array(WebAccessMode.allCases.enumerated()), id: \.element.id) { i, mode in
                    if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                    Button {
                        webTool.settings.mode = mode
                        HapticManager.impact(.light)
                    } label: {
                        HStack {
                            radio(selected: webTool.settings.mode == mode)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label(for: mode))
                                    .font(T.mono(12, .semibold))
                                    .foregroundColor(T.ink)
                                KMono(text: subtitle(for: mode), size: 10, color: T.ink3)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func label(for mode: WebAccessMode) -> String {
        switch mode {
        case .off: return "Off"
        case .askEveryTime: return "Ask Every Time"
        case .alwaysAllow: return "Always Allow"
        }
    }
    private func subtitle(for mode: WebAccessMode) -> String {
        switch mode {
        case .off: return "no network requests, ever"
        case .askEveryTime: return "approval prompt per request"
        case .alwaysAllow: return "fetch automatically when triggered"
        }
    }

    // MARK: - Provider

    private var providerSection: some View {
        KSection(title: "search_provider") {
            VStack(spacing: 0) {
                Menu {
                    ForEach(WebSearchProvider.allCases) { p in
                        Button(p.displayName) {
                            webTool.settings.provider = p
                        }
                    }
                } label: {
                    HStack {
                        KMono(text: webTool.settings.provider.displayName,
                              size: 12, color: T.ink)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(T.ink3)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }

                if webTool.settings.provider.requiresApiKey {
                    Rectangle().fill(T.rule).frame(height: 1)
                    keyField
                }
                if webTool.settings.provider == .searxng || webTool.settings.provider == .custom {
                    Rectangle().fill(T.rule).frame(height: 1)
                    endpointField
                }
            }
        }
    }

    @ViewBuilder
    private var keyField: some View {
        let account = "\(webTool.settings.provider.rawValue).apiKey"
        let hasKey = KeychainStore.has(account: account)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                KMono(text: hasKey ? "api key saved in keychain" : "api key required",
                      size: 10, color: hasKey ? T.good : T.warn)
                Spacer()
                if hasKey {
                    Button {
                        KeychainStore.delete(account: account)
                        HapticManager.impact(.light)
                    } label: {
                        Text("clear")
                            .font(T.mono(10, .semibold))
                            .foregroundColor(T.bad)
                    }
                    .buttonStyle(.plain)
                }
            }
            SecureField("paste API key", text: $apiKeyInput)
                .font(T.mono(11))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.rule, lineWidth: 1))
            Button {
                let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                KeychainStore.set(trimmed, account: account)
                apiKeyInput = ""
                HapticManager.impact(.medium)
                ToastCenter.shared.success("API key saved to Keychain")
            } label: {
                Text("save key")
                    .font(T.mono(11, .semibold))
                    .foregroundColor(T.bg)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(T.ink))
            }
            .buttonStyle(.plain)
            .disabled(apiKeyInput.isEmpty)
        }
        .padding(14)
    }

    @ViewBuilder
    private var endpointField: some View {
        VStack(alignment: .leading, spacing: 6) {
            KMono(text: "instance url (https only)", size: 10, color: T.ink3)
            TextField("https://search.example.com", text: $endpointInput)
                .font(T.mono(11))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.surface))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.rule, lineWidth: 1))
            Button {
                Task { await saveEndpoint() }
            } label: {
                Text("save endpoint")
                    .font(T.mono(11, .semibold))
                    .foregroundColor(T.bg)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(T.ink))
            }
            .buttonStyle(.plain)
            .disabled(endpointInput.isEmpty)
        }
        .padding(14)
    }

    private var currentEndpoint: URL? {
        switch webTool.settings.provider {
        case .searxng: return webTool.settings.searxngEndpoint
        case .custom:  return webTool.settings.customSearchEndpoint
        default:       return nil
        }
    }

    private func saveEndpoint() async {
        guard let url = URL(string: endpointInput.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https" else {
            ToastCenter.shared.error("Endpoint must be https://")
            return
        }
        // Validate it's not a private host.
        let validator = URLSafetyValidator()
        let verdict = await validator.validate(url)
        if !verdict.isSafe {
            ToastCenter.shared.error("Blocked", detail: verdict.reason)
            return
        }
        switch webTool.settings.provider {
        case .searxng: webTool.settings.searxngEndpoint = url
        case .custom:  webTool.settings.customSearchEndpoint = url
        default: break
        }
        HapticManager.impact(.medium)
        ToastCenter.shared.success("Endpoint saved")
    }

    // MARK: - Limits

    private var limitsSection: some View {
        KSection(title: "limits") {
            VStack(spacing: 0) {
                stepper(label: "max search results", value: Binding(
                    get: { webTool.settings.maxSearchResults },
                    set: { webTool.settings.maxSearchResults = $0 }
                ), range: 1...10)
                Rectangle().fill(T.rule).frame(height: 1)
                stepper(label: "max pages to fetch", value: Binding(
                    get: { webTool.settings.maxPagesToFetch },
                    set: { webTool.settings.maxPagesToFetch = $0 }
                ), range: 1...5)
                Rectangle().fill(T.rule).frame(height: 1)
                stepper(label: "total context tokens", value: Binding(
                    get: { webTool.settings.totalWebContextTokens },
                    set: { webTool.settings.totalWebContextTokens = $0 }
                ), range: 500...4000, step: 100)
                Rectangle().fill(T.rule).frame(height: 1)
                stepper(label: "max tokens per source", value: Binding(
                    get: { webTool.settings.maxTokensPerSource },
                    set: { webTool.settings.maxTokensPerSource = $0 }
                ), range: 200...1500, step: 50)
            }
        }
    }

    @ViewBuilder
    private func stepper(label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                KMono(text: label, size: 11.5, color: T.ink)
                Spacer()
                KMono(text: "\(value.wrappedValue)", size: 11.5, color: T.accent)
            }
        }
        .tint(T.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Network

    private var networkSection: some View {
        KSection(title: "network") {
            VStack(spacing: 0) {
                Toggle(isOn: $webTool.settings.allowOnCellular) {
                    VStack(alignment: .leading, spacing: 2) {
                        KMono(text: "allow on cellular", size: 11.5, color: T.ink)
                        KMono(text: "off: web tool only runs on wi-fi", size: 10, color: T.ink3)
                    }
                }
                .tint(T.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Rectangle().fill(T.rule).frame(height: 1)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        KMono(text: "block private ips", size: 11.5, color: T.ink)
                        KMono(text: "always on · prevents ssrf to your local network",
                              size: 10, color: T.ink3)
                    }
                    Spacer()
                    Image(systemName: "lock.fill").foregroundColor(T.good)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        KSection(title: "cache") {
            VStack(spacing: 0) {
                Toggle(isOn: $webTool.settings.cacheEnabled) {
                    KMono(text: "enable cache", size: 11.5, color: T.ink)
                }
                .tint(T.accent)
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    // MARK: - Activity log

    private var activitySection: some View {
        KSection(title: "activity") {
            VStack(spacing: 0) {
                Button {
                    showActivity = true
                } label: {
                    HStack {
                        KMono(text: "view activity log", size: 11.5, color: T.ink)
                        Spacer()
                        Text("\(log.entries.count)")
                            .font(T.mono(10))
                            .foregroundColor(T.ink3)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(T.ink3)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                if !log.entries.isEmpty {
                    Rectangle().fill(T.rule).frame(height: 1)
                    Button(role: .destructive) {
                        log.clear()
                    } label: {
                        HStack {
                            KMono(text: "clear log", size: 11.5, color: T.bad)
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Privacy

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            KCaption(text: "privacy")
            Text("Model inference runs locally on this device. Web Access is optional. When enabled, the app may send a short search query or a URL you provide to the search provider you chose. Your chat history, attachments, and personal content are not sent. Fetched pages are processed on this device and given to the local model as reference material. You can turn Web Access off at any time.")
                .font(T.sans(12))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder
    private func radio(selected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(selected ? T.accent : T.rule2, lineWidth: 1.5)
                .frame(width: 16, height: 16)
            if selected {
                Circle().fill(T.accent).frame(width: 9, height: 9)
            }
        }
    }
}
