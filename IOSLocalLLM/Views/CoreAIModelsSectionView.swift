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
    @State private var pendingRemoval: CoreAIInstalledModel?

    private var installedPacks: [CoreAIInstalledModel] {
        store.installations.filter {
            $0.assistantModel != nil && (query.isEmpty || $0.manifest.displayName.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        if showsCatalog || !installedPacks.isEmpty {
        VStack(alignment: .leading, spacing: 16) {
            Label("Core AI · Optional local runtime", systemImage: "cpu")
                .font(.headline)
            // On a device that can't run Core AI the reason sits inside the
            // disclosure below, so the card stays two lines tall and the
            // models that do run are not pushed down the page.
            if let reason = CoreAIInferenceService.availabilityReason {
                if !showsCatalog {
                    Text(reason).font(.subheadline).foregroundStyle(.secondary)
                }
            } else if showsCatalog {
                Text("Text chat runs on this device. Download a complete pack before loading. One heavy runtime is kept in memory at a time.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(installedPacks) { installed in
                CoreAIInstalledPackRow(installed: installed) {
                    pendingRemoval = installed
                }
            }
            if showsCatalog {
                DisclosureGroup("Core AI model downloads") {
                    LazyVStack(alignment: .leading, spacing: 16) {
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
                    .padding(.top, 12)
                }
                .accessibilityIdentifier("coreai.catalog")
            }
        }
        .padding(16)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: AppRadius.card))
        .onAppear { store.refresh() }
        .confirmationDialog("Download Core AI pack?", isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } }), presenting: pendingDownload) { pack in
            Button("Download \(pack.approxDownloadBytes.formattedBytes)") {
                downloads.start(model: pack)
            }
        } message: { pack in
            Text("This downloads model files from Hugging Face. Keep the app open while the transfer completes. \(pack.licenseNotice)")
        }
        .confirmationDialog("Remove Core AI pack?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), presenting: pendingRemoval) { installed in
            Button("Remove pack", role: .destructive) {
                Task {
                    if assistant.activeModel.id == installed.assistantSelectionID {
                        await assistant.unloadAndWaitForCleanup()
                    }
                    do { try store.removeModel(id: installed.id) }
                    catch { ToastCenter.shared.error("Could not remove pack", detail: error.localizedDescription) }
                }
            }
        }
        }
    }
}

private struct CoreAIInstalledPackRow: View {
    let installed: CoreAIInstalledModel
    let onRemove: () -> Void
    @ObservedObject private var assistant = CodingAssistantService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(installed.manifest.displayName).font(.headline)
            Label("Installed · Core AI", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Use model") {
                    guard let model = installed.assistantModel else { return }
                    Task { await assistant.switchTo(model, allowDownload: false) }
                }
                .buttonStyle(.kSecondary)
                .disabled(assistant.state == .generating)
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.kSecondary)
            }
        }
    }
}


private struct CoreAICatalogPackRow: View {
    let pack: CoreAIZooModel
    let onReviewDownload: () -> Void
    @ObservedObject private var downloads = CoreAIDownloadCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pack.displayName).font(.headline)
            Text(pack.subtitle).font(.subheadline).foregroundStyle(.secondary)
            Text(pack.approxDownloadBytes.formattedBytes).font(.caption.monospaced())
            Text(pack.licenseNotice).font(.caption).foregroundStyle(.secondary)
            Link("View model files and license", destination: pack.treeURL)
            if let manager = downloads.existing(id: pack.id) {
                CoreAIDownloadControlsView(manager: manager)
            } else {
                Button("Review download", action: onReviewDownload)
                    .buttonStyle(.kSecondary)
                    .disabled(CoreAIInferenceService.availabilityReason != nil)
                    .accessibilityIdentifier("coreai.download.\(pack.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}
