import SwiftUI

/// Core AI has its own pack format; it never enters the MLX/GGUF downloader.
struct CoreAIModelsSectionView: View {
    var showsCatalog = true
    var query = ""
    @ObservedObject private var store = CoreAIModelStore.shared
    @ObservedObject private var downloads = CoreAIDownloadCenter.shared
    @ObservedObject private var assistant = CodingAssistantService.shared
    @Environment(\.koduTheme) private var theme
    @State private var pendingDownload: CoreAIZooModel?

    private var installedPacks: [CoreAIInstalledModel] {
        store.installations.filter {
            $0.assistantModel != nil && (query.isEmpty || $0.manifest.displayName.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        if showsCatalog {
            catalogCard
        } else {
            // My Models: plain rows, so the enclosing list card divides them
            // like the MLX and GGUF rows around them.
            ForEach(installedPacks) { installed in
                CoreAIInstalledPackRow(installed: installed)
            }
        }
    }

    private var catalogCard: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Label("Core AI · Optional local runtime", systemImage: "cpu")
                .font(.headline)
            // On a device that can't run Core AI the reason sits inside the
            // disclosure below, so the card stays two lines tall.
            if CoreAIInferenceService.availabilityReason == nil {
                Text("Text chat runs on this device. Download a complete pack before loading. One heavy runtime is kept in memory at a time.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !installedPacks.isEmpty {
                ModelsListCard {
                    ForEach(installedPacks) { installed in
                        CoreAIInstalledPackRow(installed: installed)
                    }
                }
            }
            DisclosureGroup("Core AI model downloads") {
                LazyVStack(alignment: .leading, spacing: Space.m) {
                    if let reason = CoreAIInferenceService.availabilityReason {
                        Text(reason).font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(CoreAIZooCatalog.downloadableTextModels.filter {
                        query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)
                    }) { pack in
                        if store.installedModel(id: pack.id) == nil {
                            CoreAICatalogPackRow(pack: pack) { pendingDownload = pack }
                        }
                    }
                }
                .padding(.top, Space.s)
            }
            .accessibilityIdentifier("coreai.catalog")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onAppear { store.refresh() }
        .confirmationDialog("Download Core AI pack?", isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } }), presenting: pendingDownload) { pack in
            Button("Download \(pack.approxDownloadBytes.formattedBytes)") {
                downloads.start(model: pack)
            }
        } message: { pack in
            Text("This downloads model files from Hugging Face. Keep the app open while the transfer completes. \(pack.licenseNotice)")
        }
    }
}

/// Same row as an installed MLX or GGUF model; tap for Use / Remove.
private struct CoreAIInstalledPackRow: View {
    let installed: CoreAIInstalledModel
    @ObservedObject private var store = CoreAIModelStore.shared
    @ObservedObject private var assistant = CodingAssistantService.shared
    @ObservedObject private var loc = LocalizationService.shared
    @State private var showActions = false

    private var isInUse: Bool { assistant.activeModel.id == installed.assistantSelectionID }

    private var status: String {
        if let reason = CoreAIInferenceService.availabilityReason { return reason }
        guard isInUse else { return "" }
        return loc.t(assistant.state == .ready || assistant.state == .generating ? "Loaded" : "In use")
    }

    var body: some View {
        ModelsCompactRow(
            name: installed.manifest.displayName,
            subtitle: loc.t("Assistant") + " · " + installed.manifest.totalDownloadBytes.formattedBytes,
            status: status,
            runtime: .coreAI,
            actionTitle: loc.t("Details"),
            identifier: "models.installed.coreai.\(installed.id)",
            action: { showActions = true }
        )
        .confirmationDialog(installed.manifest.displayName, isPresented: $showActions, titleVisibility: .visible) {
            Button("Use model") {
                guard let model = installed.assistantModel else { return }
                Task { await assistant.switchTo(model, allowDownload: false) }
            }
            .disabled(isInUse || assistant.state == .generating || CoreAIInferenceService.availabilityReason != nil)
            Button("Remove pack", role: .destructive) { remove() }
        } message: {
            Text(installed.manifest.totalDownloadBytes.formattedBytes + " · Core AI")
        }
    }

    private func remove() {
        Task {
            if isInUse { await assistant.unloadAndWaitForCleanup() }
            do { try store.removeModel(id: installed.id) }
            catch { ToastCenter.shared.error("Could not remove pack", detail: error.localizedDescription) }
        }
    }
}


private struct CoreAICatalogPackRow: View {
    let pack: CoreAIZooModel
    let onReviewDownload: () -> Void
    @ObservedObject private var downloads = CoreAIDownloadCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(pack.displayName).font(.headline)
            Text(pack.subtitle).font(.subheadline).foregroundStyle(.secondary)
            Text(pack.approxDownloadBytes.formattedBytes).font(.caption.monospaced())
            Text(pack.licenseNotice).font(.caption).foregroundStyle(.secondary)
            Link("View model files and license", destination: pack.treeURL)
            if let manager = downloads.existing(id: pack.id) {
                CoreAIDownloadControlsView(manager: manager)
            } else {
                Button("Review download", action: onReviewDownload)
                    .glassButton()
                    .disabled(CoreAIInferenceService.availabilityReason != nil)
                    .accessibilityIdentifier("coreai.download.\(pack.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.xs)
    }
}
