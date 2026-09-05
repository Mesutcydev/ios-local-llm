import SwiftUI

/// Core AI's own pack lifecycle embedded inside the existing Models → Assistant
/// page. It deliberately does not register `.aimodel` packs with
/// ModelDownloadCenter: that service validates MLX/GGUF layouts and would
/// misclassify Core AI's metadata/tokenizer/resource tree.
struct CoreAIModelsSectionView: View {
    let showsCatalog: Bool
    let query: String

    @ObservedObject private var store = CoreAIModelStore.shared
    @ObservedObject private var downloads = CoreAIDownloadCenter.shared
    @ObservedObject private var assistant = CodingAssistantService.shared
    @Environment(\.koduTheme) private var T

    @State private var expanded = false
    @State private var pendingRemovalID: String?

    init(showsCatalog: Bool = true, query: String = "") {
        self.showsCatalog = showsCatalog
        self.query = query
    }

    private var chatPacks: [CoreAIZooModel] {
        CoreAIZooCatalog.iphoneLanguageModels.filter {
            $0.category == .officialRecipe || $0.category == .chat
        }
    }

    private var filteredInstallations: [CoreAIInstalledModel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.installations }
        return store.installations.filter {
            $0.manifest.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.manifest.id.localizedCaseInsensitiveContains(trimmed)
                || $0.manifest.modelFamily.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(T.accent)
                KCaption(text: "APPLE CORE AI · iOS 27")
                Spacer()
                Text("\(store.installations.count) installed")
                    .font(T.mono(9, .semibold))
                    .foregroundStyle(T.ink3)
            }

            Text("Keep multiple Core AI packs on device and choose which one to run. Only one heavy runtime is specialized in memory at a time.")
                .font(T.sans(12))
                .foregroundStyle(T.ink2)
                .fixedSize(horizontal: false, vertical: true)

            installedCard

            if showsCatalog {
                DisclosureGroup(isExpanded: $expanded) {
                    LazyVStack(spacing: 10) {
                        ForEach(chatPacks) { model in
                            packCard(model)
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    Label(
                        expanded ? "Hide ready-to-run packs" : "Browse ready-to-run packs",
                        systemImage: "shippingbox"
                    )
                    .font(T.sans(14, .semibold))
                    .foregroundStyle(T.ink)
                }
            }
        }
        .padding(16)
        .kGlass(cornerRadius: 22, fallbackFill: T.surface)
        .confirmationDialog(
            "Remove this Core AI pack?",
            isPresented: Binding(
                get: { pendingRemovalID != nil },
                set: { if !$0 { pendingRemovalID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove pack", role: .destructive) {
                if let id = pendingRemovalID { removeInstalledPack(id: id) }
                pendingRemovalID = nil
            }
        } message: {
            Text("MLX and GGUF downloads are not affected.")
        }
        .onAppear {
            store.refresh()
            downloads.removeFinished()
        }
        .onChange(of: store.installations.map(\.id)) { _, _ in
            // A completed manager describes the transfer, not current install
            // state. Drop it after the store publishes the selected pack so a
            // previously-replaced card becomes downloadable again.
            downloads.removeFinished()
        }
    }

    @ViewBuilder
    private var installedCard: some View {
        if !filteredInstallations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(filteredInstallations) { installed in
                    installedRow(installed)
                }
            }
        } else {
            switch store.state {
            case .validating:
                statusRow("Validating Core AI pack…", symbol: "checkmark.shield")
            case .downloading:
                statusRow("Downloading Core AI pack…", symbol: "arrow.down.circle")
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Core AI pack error", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(T.bad)
                    Text(message)
                        .font(T.sans(11))
                        .foregroundStyle(T.ink2)
                }
            case .unavailable(let message):
                statusRow(message, symbol: "nosign")
            case .missing, .ready:
                statusRow(
                    query.isEmpty
                        ? "No Core AI pack installed. Your MLX/GGUF library is unchanged."
                        : "No installed Core AI packs match this search.",
                    symbol: query.isEmpty ? "internaldrive" : "magnifyingglass"
                )
            }
        }
    }

    private func installedRow(_ installed: CoreAIInstalledModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(T.good)
                VStack(alignment: .leading, spacing: 3) {
                    Text(installed.manifest.displayName)
                        .font(T.sans(14, .semibold))
                        .foregroundStyle(T.ink)
                    Text("Installed · \(installed.manifest.totalDownloadBytes.formattedBytes) · Core AI")
                        .font(T.mono(9.5))
                        .foregroundStyle(T.ink3)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                if let model = installed.assistantModel {
                    Button {
                        Task { await assistant.switchTo(model) }
                    } label: {
                        Label(
                            assistant.activeModel.id == model.id
                                ? "Active in Assistant"
                                : "Use in Assistant",
                            systemImage: "brain"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(T.accent)
                    .disabled(
                        assistant.activeModel.id == model.id
                            && assistant.state == .ready
                    )
                }
                Button("Remove", role: .destructive) {
                    pendingRemovalID = installed.id
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(T.good.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func statusRow(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(T.sans(11))
            .foregroundStyle(T.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }

    private func packCard(_ model: CoreAIZooModel) -> some View {
        let manager = downloads.existing(id: model.id)
        let isInstalled = store.installedModel(id: model.id) != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayName)
                        .font(T.sans(13, .semibold))
                        .foregroundStyle(T.ink)
                    Text(model.subtitle)
                        .font(T.sans(10.5))
                        .foregroundStyle(T.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Link(destination: model.treeURL) {
                    Image(systemName: "arrow.up.right.square")
                }
                .accessibilityLabel("Open exact Hugging Face files")
            }

            HStack(spacing: 6) {
                badge(model.approxDownloadBytes.formattedBytes)
                badge(model.pathPrefix ?? "repo")
                if model.supportsThinking { badge("thinking") }
                if model.supportsTools { badge("tools") }
            }

            Text(model.licenseNotice)
                .font(T.sans(9.5))
                .foregroundStyle(T.ink3)
                .fixedSize(horizontal: false, vertical: true)

            if isInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(T.sans(11, .semibold))
                    .foregroundStyle(T.good)
            } else if let manager {
                CoreAIDownloadControlsView(manager: manager)
            } else {
                Button {
                    downloads.start(model: model)
                    ToastCenter.shared.info(
                        "Starting \(model.displayName)",
                        detail: "Listing the verified Hugging Face files…"
                    )
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(T.accent)
            }
        }
        .padding(12)
        .background(T.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(T.mono(8.5, .semibold))
            .foregroundStyle(T.ink2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(T.ink.opacity(0.06), in: Capsule())
    }

    private func removeInstalledPack(id: String) {
        Task {
            let defaults = AppSettings.shared
            let removedSelectionID = id.hasPrefix("coreai:") ? id : "coreai:\(id)"
            if assistant.activeExecutionLocation == .localCoreAI,
               assistant.activeModel.id == removedSelectionID {
                await assistant.adoptSelectionWithoutLoading(
                    AssistantModelCatalog.presets[0]
                )
            }
            if defaults.assistantModelID == removedSelectionID {
                defaults.assistantModelID = AssistantModelCatalog.presets[0].id
                defaults.hasPickedAssistantModel = false
            }
            do {
                try store.removeModel(id: id)
                ToastCenter.shared.success(
                    "Core AI pack removed",
                    detail: "MLX and GGUF models were not changed."
                )
            } catch {
                ToastCenter.shared.error("Couldn’t remove Core AI pack", detail: error.localizedDescription)
            }
        }
    }
}
