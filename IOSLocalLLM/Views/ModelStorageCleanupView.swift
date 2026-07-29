import SwiftUI

// MARK: - Guided model storage cleanup

/// Lets people decide what remains on-device in one pass. Required models are
/// locked on; active models start selected but may be removed because the
/// download center safely resets their role before deleting the files.
struct ModelStorageCleanupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    @ObservedObject private var center = ModelDownloadCenter.shared
    @State private var items: [ModelStorageCleanupItem] = []
    @State private var keepIDs: Set<String> = []
    @State private var removePartialDownloads = true
    @State private var showRemovalConfirmation = false
    @State private var didLoad = false

    private var removableItems: [ModelStorageCleanupItem] {
        items.filter { !$0.isRequired && !keepIDs.contains($0.id) }
    }

    private var reclaimableBytes: Int64 {
        removableItems.reduce(0) { $0 + $1.estimatedBytes }
            + (removePartialDownloads ? center.orphanedDownloadBytes : 0)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidPinkBackdrop()
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ModelStorageCleanupHeader(
                            installedCount: items.count,
                            selectedCount: keepIDs.count,
                            storageUsed: center.totalStorageUsed
                        )

                        if items.isEmpty {
                            ModelStorageCleanupEmptyState()
                        } else {
                            ModelStorageCleanupSelectionBar(
                                allSelected: items.allSatisfy { keepIDs.contains($0.id) },
                                onSelectAll: selectAll,
                                onKeepActiveOnly: keepActiveAndRequiredOnly
                            )

                            ForEach(items) { item in
                                ModelStorageCleanupRow(
                                    item: item,
                                    isKept: keepIDs.contains(item.id),
                                    onToggle: { toggleKeep(item) }
                                )
                            }
                        }

                        if center.orphanedDownloadBytes > 0 {
                            ModelPartialDownloadCleanupRow(
                                bytes: center.orphanedDownloadBytes,
                                isSelected: removePartialDownloads,
                                onToggle: { removePartialDownloads.toggle() }
                            )
                        }

                        Color.clear.frame(height: 96)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Storage Cleanup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ModelStorageCleanupActionBar(
                    removalCount: removableItems.count,
                    reclaimableBytes: reclaimableBytes,
                    enabled: !removableItems.isEmpty
                        || (removePartialDownloads && center.orphanedDownloadBytes > 0),
                    onRemove: { showRemovalConfirmation = true }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
            .confirmationDialog(
                "Remove unselected models?",
                isPresented: $showRemovalConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove and free \(reclaimableBytes.formattedBytes)", role: .destructive) {
                    performCleanup()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Models marked Keep stay on this device. Removed models can be downloaded again later.")
            }
            .onAppear(perform: loadItemsIfNeeded)
        }
    }

    private func loadItemsIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        center.refreshAllStates()
        items = center.models
            .filter(\.isReady)
            .map(ModelStorageCleanupItem.init)
            .sorted {
                if $0.isRequired != $1.isRequired { return $0.isRequired }
                if $0.isActive != $1.isActive { return $0.isActive }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        keepActiveAndRequiredOnly()
    }

    private func selectAll() {
        keepIDs = Set(items.map(\.id))
        HapticManager.selection()
    }

    private func keepActiveAndRequiredOnly() {
        keepIDs = Set(items.filter { $0.isActive || $0.isRequired }.map(\.id))
        HapticManager.selection()
    }

    private func toggleKeep(_ item: ModelStorageCleanupItem) {
        guard !item.isRequired else { return }
        if keepIDs.contains(item.id) {
            keepIDs.remove(item.id)
        } else {
            keepIDs.insert(item.id)
        }
        HapticManager.selection()
    }

    private func performCleanup() {
        let removed = removableItems
        for item in removed {
            guard let model = center.models.first(where: { $0.id == item.id }) else { continue }
            center.handleDeletion(of: model)
        }
        var freed = removed.reduce(Int64(0)) { $0 + $1.estimatedBytes }
        if removePartialDownloads {
            freed += center.cleanupOrphanedDownloads()
        }
        center.refreshAllStates()
        HapticManager.impact(.medium)
        ToastCenter.shared.success("Storage cleaned", detail: "Freed about \(freed.formattedBytes)")
        dismiss()
    }
}

private struct ModelStorageCleanupItem: Identifiable {
    let id: String
    let displayName: String
    let detail: String
    let category: DownloadableModel.Category
    let estimatedBytes: Int64
    let isRequired: Bool
    let isActive: Bool

    @MainActor
    init(model: DownloadableModel) {
        id = model.id
        displayName = model.displayName
        detail = "\(model.sizeLabel) · \(model.sourceRepoID)"
        category = model.category
        estimatedBytes = Self.parseBytes(model.sizeLabel)
        isRequired = model.isRequired
        isActive = Self.isActive(model)
    }

    @MainActor
    private static func isActive(_ model: DownloadableModel) -> Bool {
        let settings = AppSettings.shared
        let assistant = LocalModelRegistry.unwrapAssistantSelectionID(settings.assistantModelID)
        let voiceAssistant = LocalModelRegistry.unwrapAssistantSelectionID(settings.voiceConversationModelID)
        let vision = LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        let ids = Set([model.id, model.sourceRepoID])
        if ids.contains(assistant) || ids.contains(voiceAssistant) || ids.contains(vision) { return true }
        if let engine = model.supportedVoiceEngine,
           settings.voiceEngine == engine.rawValue { return true }
        return false
    }

    private static func parseBytes(_ label: String) -> Int64 {
        let normalized = label.lowercased().replacingOccurrences(of: "~", with: "")
        let scanner = Scanner(string: normalized)
        guard let value = scanner.scanDouble() else { return 0 }
        if normalized.contains("gb") { return Int64(value * 1_000_000_000) }
        if normalized.contains("mb") { return Int64(value * 1_000_000) }
        if normalized.contains("kb") { return Int64(value * 1_000) }
        return Int64(value)
    }
}

private struct ModelStorageCleanupHeader: View {
    let installedCount: Int
    let selectedCount: Int
    let storageUsed: Int64

    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            KCaption(text: "KEEP WHAT YOU USE", color: T.accent)
            Text("Models are stored separately from the app")
                .font(T.display(24, .semibold))
                .foregroundColor(T.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Select the models you want to keep. Required and currently active models start selected; everything else can be removed in one step.")
                .font(T.sans(13))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Label("\(selectedCount) kept", systemImage: "checkmark.circle.fill")
                Spacer()
                Text("\(installedCount) installed · \(storageUsed.formattedBytes)")
            }
            .font(T.mono(10, .semibold))
            .foregroundColor(T.ink3)
        }
        .padding(16)
        .kGlass(cornerRadius: 20, fallbackFill: T.surface, fallbackStroke: T.rule)
    }
}

private struct ModelStorageCleanupSelectionBar: View {
    let allSelected: Bool
    let onSelectAll: () -> Void
    let onKeepActiveOnly: () -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        HStack(spacing: 8) {
            Text("Keep")
                .font(T.sans(13, .semibold))
                .foregroundColor(T.ink)
            Spacer()
            Button("Active only", action: onKeepActiveOnly)
            Button(allSelected ? "All selected" : "Select all", action: onSelectAll)
                .disabled(allSelected)
        }
        .font(T.sans(12, .semibold))
        .foregroundColor(T.accent)
        .padding(.horizontal, 4)
    }
}

private struct ModelStorageCleanupRow: View {
    let item: ModelStorageCleanupItem
    let isKept: Bool
    let onToggle: () -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: categoryGlyph)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isKept ? T.accent : T.ink3)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((isKept ? T.accent : T.ink3).opacity(0.10)))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.displayName)
                            .font(T.sans(14, .semibold))
                            .foregroundColor(T.ink)
                            .lineLimit(2)
                        if item.isActive {
                            Text("ACTIVE")
                                .font(T.mono(8, .bold))
                                .foregroundColor(T.good)
                        }
                    }
                    Text(item.detail)
                        .font(T.mono(9.5))
                        .foregroundColor(T.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if item.isRequired {
                    Label("Required", systemImage: "lock.fill")
                        .font(T.mono(9, .semibold))
                        .foregroundColor(T.warn)
                } else {
                    Image(systemName: isKept ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(isKept ? T.accent : T.ink3)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .kGlass(cornerRadius: 18, fallbackFill: T.surface, fallbackStroke: T.rule)
        }
        .buttonStyle(.plain)
        .disabled(item.isRequired)
        .accessibilityLabel("\(item.displayName), \(isKept ? "keep" : "remove")")
    }

    private var categoryGlyph: String {
        switch item.category {
        case .assistant: return "brain"
        case .vlm: return "eye"
        case .voice: return "waveform"
        case .imageGen: return "wand.and.stars"
        }
    }
}

private struct ModelPartialDownloadCleanupRow: View {
    let bytes: Int64
    let isSelected: Bool
    let onToggle: () -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.dotted")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(T.warn)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(T.warn.opacity(0.10)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Partial downloads")
                        .font(T.sans(14, .semibold))
                        .foregroundColor(T.ink)
                    Text("Cancelled files and resumable transfer cache · \(bytes.formattedBytes)")
                        .font(T.mono(9.5))
                        .foregroundColor(T.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(isSelected ? T.warn : T.ink3)
            }
            .padding(14)
            .kGlass(cornerRadius: 18, fallbackFill: T.surface, fallbackStroke: T.rule)
        }
        .buttonStyle(.plain)
    }
}

private struct ModelStorageCleanupActionBar: View {
    let removalCount: Int
    let reclaimableBytes: Int64
    let enabled: Bool
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack {
                Image(systemName: "trash")
                Text(removalCount > 0 ? "Remove \(removalCount) models" : "Clear partial downloads")
                Spacer()
                Text(reclaimableBytes.formattedBytes)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(enabled ? Color.accentColor : Color.secondary, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct ModelStorageCleanupEmptyState: View {
    var body: some View {
        ContentUnavailableView(
            "No downloaded models",
            systemImage: "externaldrive",
            description: Text("Downloaded models will appear here when there is storage to manage.")
        )
        .padding(.vertical, 36)
    }
}
