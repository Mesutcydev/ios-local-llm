import SwiftUI

// MARK: - ModelsManagerView
//
// My Models contains the local inventory; Discover contains catalogs and online
// search. Compact rows open the existing model actions in a detail sheet.
// Import, downloads, and storage remain available above either destination.

struct ModelsManagerView: View {

    /// TabView keeps inactive tabs mounted, so use this to avoid presenting
    /// Models-only navigation in response to downloads started elsewhere.
    var isActive: Bool = true

    // Shared role filters for local inventory and discovery.
    enum Section: String, CaseIterable, Identifiable {
        case assistant = "Assistant"
        case lens      = "Lens"
        case voice     = "Voice"
        case image     = "Image"
        var id: String { rawValue }

        /// The download-category these models belong to.
        var category: DownloadableModel.Category {
            switch self {
            case .assistant: return .assistant
            case .lens:      return .vlm
            case .voice:     return .voice
            case .image:     return .imageGen
            }
        }

        var glyph: String {
            switch self {
            case .assistant: return "brain"
            case .lens:      return "eye"
            case .voice:     return "waveform"
            case .image:     return "wand.and.stars"
            }
        }
    }

    @ObservedObject private var center    = ModelDownloadCenter.shared
    @ObservedObject private var coreAIStore = CoreAIModelStore.shared
    @ObservedObject private var coreAIDownloads = CoreAIDownloadCenter.shared
    @ObservedObject private var assistant = CodingAssistantService.shared
    @ObservedObject private var vision    = MLXVisionService.shared
    @ObservedObject private var fastVLM   = FastVLMService.shared
    @ObservedObject private var voiceSvc  = VoiceService.shared
    @ObservedObject private var voiceCatalog = VoiceCatalogStore.shared
    @ObservedObject private var settings  = AppSettings.shared
    @ObservedObject private var loc       = LocalizationService.shared
    @ObservedObject private var bridge    = AppBridge.shared
    @StateObject   private var search     = HFSearchService()

    @State private var selectedSection: Section = .assistant
    /// Which recommended-setup combo is expanded to show its per-role picks.
    @State private var expandedComboID: String? = nil
    /// Collapsed-by-default disclosures that keep the page short. The user
    /// opens Recommended Setups / Tools & storage only when they want them.
    @State private var showRecommendedSetups = false
    @State private var showFutureVoiceIntegrations = false
    @State private var searchText: String = ""
    /// Library search stays local; Discover is the explicit online entry point.
    @State private var isLibrary = true
    @State private var filterAllCategories = true
    @State private var showingGuidedSetup = false
    @State private var details: ModelDetails?
    @State private var afterDetailsDismiss: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize

    private enum ModelDetails: Identifiable {
        case model(DownloadableModel, DownloadableModel.Category)
        case image(ImageGenerationService.Model)
        case voice(VoiceCatalogEntry)

        var id: String {
            switch self {
            case let .model(model, role): return "model-\(model.id)-\(role)"
            case let .image(model): return "image-\(model.id)"
            case let .voice(entry): return "voice-\(entry.id)"
            }
        }
    }
    @State private var searchTask: Task<Void, Never>?
    @State private var pendingDelete: DownloadableModel?
    @State private var showImportPicker = false
    @State private var importError: String?
    /// Installed model currently being copied to a user-selected Files
    /// location. The export picker works from the downloader's real directory,
    /// preserving config, tokenizer, and every weight shard together.
    @State private var exportingModel: DownloadableModel?
    /// Confirmation gate for reclaiming space from partial/cancelled
    /// downloads. Captures the byte count at the moment the user taps so the
    /// alert body can quote how much will be freed.
    @State private var pendingCleanupBytes: Int64?
    /// Flips to true the instant the user taps Load on the assistant row,
    /// before CodingAssistantService.load() has had a chance to set its
    /// own `.loading` state. Gives the user immediate visual confirmation
    /// that their tap registered (indeterminate progress bar + "Starting…"
    /// message) so they don't tap again thinking nothing happened. Cleared
    /// once the service moves out of `.unloaded`.
    @State private var assistantLoadStarting = false
    /// Same idea for the vision row — covers both MLXVision and FastVLM
    /// since loadVision() routes to whichever pipeline is active.
    @State private var visionLoadStarting = false

    /// Live handles to in-flight load tasks so the user can stop a load
    /// that's stuck on a slow download or a large model that's taking too
    /// long. Cleared in the load function's await-completion block. Cancel
    /// chains: Task.cancel() interrupts the await, then unload() flushes
    /// any partial state (MLX container, FastVLM components, GPU cache).
    @State private var assistantLoadTask: Task<Void, Never>?
    @State private var visionLoadTask: Task<Void, Never>?

    /// Watchdogs that auto-cancel a load stuck past
    /// `AppSettings.modelLoadTimeoutSeconds`, via the same safe cancel path as
    /// the Stop button. Cleared when the load finishes or is cancelled.
    @State private var assistantWatchdog: Task<Void, Never>?
    @State private var visionWatchdog: Task<Void, Never>?

    /// Presents HFTokenSheet from a catalog row's auth-failure CTA.
    @State private var showingHFTokenSheet = false

    /// Presents the Downloads sheet (every in-flight / failed download across
    /// all categories) from the header pill.
    @State private var showDownloads = false
    /// Presents the guided "choose what to keep" storage flow.
    @State private var showStorageCleanup = false
    /// Completed during this Models session, retained in the unified center so
    /// a finished row does not vanish the instant it reaches 100%.
    @State private var recentlyCompletedRepoIDs: [String] = []

    /// Role-specific picker sheets. Each Active row's Swap button drives
    /// into the matching picker rather than nudging the user toward the
    /// Installed tab — the previous tab-jump was the single most-cited
    /// "feels problematic" interaction. The picker sheets already exist
    /// and own the full activation flow (download, set-as-active,
    /// preview); reusing them here means the manager doesn't reinvent
    /// the wheel and the UX is identical regardless of entry point.
    @State private var showingAssistantPicker = false
    @State private var showingVisualPicker    = false
    @State private var showingVoicePicker     = false
    @State private var assistantSettingsTarget: AssistantModelSettingsTarget?
    /// Presents the text-to-image generation sheet from the Images section.
    @State private var showImageGen = false
    @ObservedObject private var imageGen = ImageGenerationService.shared

    @Environment(\.koduTheme) private var T

    var body: some View {
        ZStack {
            LiquidPinkBackdrop()
                .allowsHitTesting(false)

            ScrollView {
                LazyVStack(spacing: Space.cardGap) {
                    ModelsDestinationPicker(isLibrary: $isLibrary)
                    searchBar
                    ModelsCategoryFilter(selection: Binding(
                        get: { filterAllCategories ? nil : selectedSection },
                        set: { section in
                            filterAllCategories = section == nil
                            if let section { selectedSection = section }
                        }
                    ))
                    activeContent
                }
                .padding(.horizontal, Space.m)
                .padding(.top, Space.s)
                .padding(.bottom, Space.l)
                .frame(maxWidth: AppLayout.readingWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("models.catalog.scroll")
        }
        .transaction { if reduceMotion { $0.animation = nil } }
        .safeAreaInset(edge: .top, spacing: 0) {
            ModelsLibraryToolbar(
                downloadCount: activeDownloadCount,
                needsAttention: hasDownloadFailures,
                onImport: { showImportPicker = true },
                onDownloads: { showDownloads = true },
                onStorage: { showStorageCleanup = true }
            )
            .frame(maxWidth: AppLayout.readingWidth)
            .frame(maxWidth: .infinity)
            .background(T.bg)
            .avoidingDisplayDivision()
        }
        .onChange(of: coreAIStore.installations) { _, _ in
            center.refreshStorageStats()
        }
        .onChange(of: isLibrary) { _, _ in
            searchTask?.cancel()
            searchText = ""
            HapticManager.selection()
        }
        .onDisappear { searchTask?.cancel() }
        .sheet(isPresented: $showingGuidedSetup) {
            NavigationStack {
                OnboardingModelPickerView { showingGuidedSetup = false }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(loc.t("Close"), systemImage: "xmark") { showingGuidedSetup = false }
                        }
                    }
            }
            .preferredColorScheme(settings.resolvedColorScheme)
        }
        .sheet(item: $details, onDismiss: {
            let action = afterDetailsDismiss
            afterDetailsDismiss = nil
            action?()
        }) { destination in
            modelDetails(destination)
                .preferredColorScheme(settings.resolvedColorScheme)
        }
        .onAppear {
            applyRequestedSection(bridge.requestedModelsSection)
        }
        .onChange(of: bridge.requestedModelsSection) { _, section in
            applyRequestedSection(section)
        }
        .alert(loc.t("Are you sure?"),
               isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
               )) {
            Button(loc.t("Cancel"), role: .cancel) { pendingDelete = nil }
            Button(loc.t("Delete"), role: .destructive) {
                // Routed through the center so active selections are reset
                // (and services unloaded) before files vanish, and failures
                // surface as a toast instead of being swallowed.
                if let m = pendingDelete { ModelDownloadCenter.shared.handleDeletion(of: m) }
                pendingDelete = nil
            }
        } message: {
            Text(loc.t("This frees up disk space. The model can be downloaded again later."))
        }
        .sheet(isPresented: $showingHFTokenSheet) {
            HFTokenSheet()
                .preferredColorScheme(settings.resolvedColorScheme)
        }
        .sheet(isPresented: $showDownloads) {
            downloadsSheet
                .preferredColorScheme(settings.resolvedColorScheme)
        }
        .sheet(isPresented: $showStorageCleanup) {
            ModelStorageCleanupView()
                .preferredColorScheme(settings.resolvedColorScheme)
        }
        // Role-specific picker sheets, presented from each Active row's
        // Swap button. Same sheets the user opens from Settings →
        // Models / camera top-bar / Voice settings, so the activation
        // flow is identical across entry points.
        .sheet(isPresented: $showingAssistantPicker) {
            AssistantModelPickerView()
        }
        .sheet(isPresented: $showingVisualPicker) {
            VisualModelPickerView()
        }
        .sheet(isPresented: $showingVoicePicker) {
            VoiceModelPickerView()
        }
        .sheet(item: $assistantSettingsTarget) { target in
            AssistantModelSettingsView(target: target)
                .preferredColorScheme(settings.resolvedColorScheme)
        }
        .sheet(isPresented: $showImageGen) {
            ImageGenerationView()
                .preferredColorScheme(settings.resolvedColorScheme)
        }
        // Import-local picker + its alerts, formerly attached to the Installed
        // section. They now live on the page body so they work from the
        // utilities footer on every category page.
        .sheet(isPresented: $showImportPicker) {
            LocalModelDocumentPicker(
                onPick: { url in
                    showImportPicker = false
                    Task { await importLocalModel(at: url) }
                },
                onCancel: { showImportPicker = false }
            )
        }
        .sheet(item: $exportingModel) { model in
            if let directory = model.downloader?.destination {
                LocalModelExportPicker(
                    modelDirectory: directory,
                    onComplete: {
                        exportingModel = nil
                        ToastCenter.shared.success(
                            "Model exported",
                            detail: "\(model.displayName) is available in Files."
                        )
                    },
                    onCancel: { exportingModel = nil }
                )
            }
        }
        .alert("Import failed",
               isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
               )) {
            Button(loc.t("OK"), role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert(loc.t("Clean up partial downloads?"),
               isPresented: Binding(
                get: { pendingCleanupBytes != nil },
                set: { if !$0 { pendingCleanupBytes = nil } }
               )) {
            Button(loc.t("Cancel"), role: .cancel) { pendingCleanupBytes = nil }
            Button(loc.t("Clean up"), role: .destructive) {
                let freed = center.cleanupOrphanedDownloads()
                center.refreshAllStates()
                HapticManager.impact(.medium)
                if freed > 0 {
                    ToastCenter.shared.success(
                        loc.t("Freed up space"),
                        detail: freed.formattedBytes
                    )
                }
                pendingCleanupBytes = nil
            }
        } message: {
            Text(loc.t("This removes leftover files from downloads that were cancelled or failed partway. Installed and in-progress models are not affected."))
        }
        // Any download entry point in this tab feeds the same center. Opening
        // it immediately is the feedback the old inline rows lacked: the user
        // sees preparation/progress instead of wondering whether the tap took.
        .onReceive(NotificationCenter.default.publisher(for: .hfModelDownloadStarted)) { _ in
            guard isActive, !showDownloads else { return }
            presentAfterDetails { showDownloads = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hfModelDownloadCompleted)) { note in
            guard let repoID = note.userInfo?["repoID"] as? String else { return }
            recentlyCompletedRepoIDs.removeAll { $0 == repoID }
            recentlyCompletedRepoIDs.insert(repoID, at: 0)
            if recentlyCompletedRepoIDs.count > 5 {
                recentlyCompletedRepoIDs.removeLast(recentlyCompletedRepoIDs.count - 5)
            }
        }
        .onChange(of: imageGen.directDownloadProgress) { old, new in
            for repoID in old.keys.sorted() where new[repoID] == nil {
                guard let model = ImageGenerationService.model(forID: repoID), imageGen.isInstalled(model) else { continue }
                recentlyCompletedRepoIDs.removeAll { $0 == repoID }
                recentlyCompletedRepoIDs.insert(repoID, at: 0)
            }
            recentlyCompletedRepoIDs = Array(recentlyCompletedRepoIDs.prefix(5))
        }
    }

    private var detailActionsLayout: AnyLayout {
        textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s))
            : AnyLayout(KFlowLayout(horizontalSpacing: 8, verticalSpacing: 8))
    }

    private var detailHeaderLayout: AnyLayout {
        textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Space.s))
    }

    private func presentAfterDetails(_ action: @escaping () -> Void) {
        guard details != nil else { action(); return }
        afterDetailsDismiss = action
        details = nil
    }

    @ViewBuilder
    private func modelDetails(_ destination: ModelDetails) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    switch destination {
                    case let .model(model, role):
                        if let runtime = LocalModelRegistry.descriptor(for: model).runtime {
                            ModelRuntimeBadge(runtime: runtime)
                        }
                        Text(model.sourceRepoID)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(T.ink2)
                            .textSelection(.enabled)
                        if model.isReady {
                            installedDetailRow(model, activationCategory: role)
                        } else {
                            catalogDetailRow(model, activationCategory: role)
                        }
                        if isActiveModel(model, as: role) {
                            activeRoleHeader(for: sectionFor(role))
                        }
                        if role == .assistant { smartHandlingCard }
                    case let .image(model):
                        imageDetailRow(model)
                        KPrimaryButton(label: loc.t("Open generator"), systemImage: "sparkles") {
                            presentAfterDetails { showImageGen = true }
                        }
                    case let .voice(entry):
                        voiceCatalogDetailRow(entry)
                        if isActiveVoiceEntry(entry) {
                            activeRoleHeader(for: .voice)
                        }
                    }
                }
                .padding(Space.m)
                .frame(maxWidth: AppLayout.readingWidth)
                .frame(maxWidth: .infinity)
            }
            .background(LiquidPinkBackdrop())
            .navigationTitle(loc.t("Model details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc.t("Done"), systemImage: "checkmark") { details = nil }
                        .accessibilityIdentifier("models.details.close")
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func applyRequestedSection(_ requested: AppBridge.ModelsSection?) {
        guard let requested else { return }
        filterAllCategories = false
        isLibrary = false
        searchTask?.cancel()
        searchText = ""
        switch requested {
        case .assistant: selectedSection = .assistant
        case .lens:      selectedSection = .lens
        case .voice:     selectedSection = .voice
        case .image:     selectedSection = .image
        }
        bridge.requestedModelsSection = nil
    }

    // MARK: - Active downloads (header pill + sheet)

    /// Every HF catalog download currently in flight or failed, across all
    /// categories. Drives the Downloads sheet.
    private var allInFlightDownloads: [DownloadableModel] {
        center.models.filter(\.hasUnfinishedDownload)
    }

    /// Count of downloads actively transferring (enumerating/downloading) —
    /// not failures. Shown in the header pill.
    private var activeDownloadCount: Int {
        center.models.filter { $0.downloader?.state.isActive == true }.count
            + imageGen.directDownloadProgress.count
            + coreAIDownloads.activeCount
    }

    private var hasDownloadFailures: Bool {
        coreAIDownloads.hasFailures || !imageGen.directDownloadErrors.isEmpty || center.models.contains { model in
            if case .failed = model.downloader?.state { return true }
            return false
        }
    }

    private var imageDownloads: [ImageGenerationService.Model] {
        ImageGenerationService.catalog.filter {
            imageGen.isDownloading($0) || imageGen.directDownloadErrors[$0.id] != nil
        }
    }

    private var recentlyCompletedDownloads: [DownloadableModel] {
        recentlyCompletedRepoIDs.compactMap { repoID in
            center.models.first {
                ($0.downloader?.repoID == repoID || $0.sourceRepoID == repoID) && $0.isReady
            }
        }
    }

    private var recentlyCompletedImageDownloads: [ImageGenerationService.Model] {
        recentlyCompletedRepoIDs.compactMap { repoID in
            guard let model = ImageGenerationService.model(forID: repoID), imageGen.isInstalled(model) else { return nil }
            return model
        }
    }

    /// Header pill: open active downloads or retry a failed image download.
    private var downloadsPill: some View {
        Button {
            HapticManager.impact(.light)
            showDownloads = true
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(.caption2, weight: .semibold))
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers,
                                  options: .repeating, isActive: activeDownloadCount > 0)
                if activeDownloadCount > 0 {
                    Text("\(activeDownloadCount)")
                        .font(T.mono(13, .bold))
                } else {
                    Text("Retry")
                        .font(T.mono(13, .bold))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
            .background(Capsule().fill(T.accent))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(activeDownloadCount > 0
                            ? "\(activeDownloadCount) " + loc.t("downloading")
                            : loc.t("Retry failed downloads"))
    }

    /// The Downloads "page" — a sheet listing every in-flight / failed
    /// download. Reuses InstallingRow so progress + cancel/retry work exactly
    /// as they do inline in each category.
    private var downloadsSheet: some View {
        let items = allInFlightDownloads
        let images = imageDownloads
        let coreAI = coreAIDownloads.downloads.filter { $0.state != .idle }
        return ZStack {
            LiquidPinkBackdrop()
            ScrollView {
                VStack(spacing: Space.cardGap) {
                    HStack {
                        KPageTitle(title: loc.t("Downloads"), size: 28)
                        Spacer()
                        Button(loc.t("Close"), systemImage: "xmark") { showDownloads = false }
                            .font(T.mono(13, .semibold))
                            .foregroundColor(T.accent)
                            .accessibilityIdentifier("models.downloads.close")
                    }
                    if items.isEmpty && images.isEmpty && coreAI.isEmpty && recentlyCompletedDownloads.isEmpty && recentlyCompletedImageDownloads.isEmpty {
                        emptyState(icon: "arrow.down.circle",
                                   title: loc.t("No active downloads"),
                                   subtitle: loc.t("Downloads you start appear here."))
                    } else {
                        if !coreAI.isEmpty {
                            sectionLabel("Core AI", glyph: "cpu", tint: T.accent)
                            ForEach(coreAI) { manager in
                                VStack(alignment: .leading, spacing: Space.s) {
                                    Text(manager.displayName).font(.headline)
                                    CoreAIDownloadControlsView(manager: manager)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if !items.isEmpty {
                            sectionLabel(loc.t("Active").uppercased(), glyph: "arrow.down.circle", tint: T.warn)
                            ForEach(items) { m in
                                if let dl = m.downloader {
                                    InstallingRow(model: m, downloader: dl, theme: T, loc: loc)
                                }
                            }
                        }
                        if !images.isEmpty {
                            sectionLabel(loc.t("Image models").uppercased(), glyph: "photo.stack", tint: T.imageTint)
                            ForEach(images) { model in
                                ImageGenerationModelRow(model: model)
                            }
                        }
                        if !recentlyCompletedDownloads.isEmpty || !recentlyCompletedImageDownloads.isEmpty {
                            sectionLabel(loc.t("Completed").uppercased(), glyph: "checkmark.circle", tint: T.good)
                            ForEach(recentlyCompletedDownloads) { model in
                                CompletedDownloadRow(model: model)
                            }
                            ForEach(recentlyCompletedImageDownloads) { model in
                                ImageGenerationModelRow(model: model)
                            }
                        }
                    }
                }
                .padding(Space.m)
                .padding(.top, Space.l)
            }
        }
    }

    /// On-device storage card (design 05) — total used + a segmented bar split
    /// by model role (Language / Vision / Voice). Proportions are parsed from
    /// each ready model's size label (ready models have no live downloader, so
    /// byte counters read 0 — the label is the reliable source).
    private var storageCard: some View {
        func bytes(_ cat: DownloadableModel.Category) -> Int64 {
            center.models
                .filter { $0.isReady && $0.category == cat }
                .reduce(0) { $0 + Self.parseSizeToBytes($1.sizeLabel) }
        }
        let lang = bytes(.assistant)
        let vision = bytes(.vlm)
        let voice = bytes(.voice)
        let sum = max(1, lang + vision + voice)
        let visionColor = Color(red: 0.24, green: 0.36, blue: 1.0)
        let voiceColor = Color(red: 0.06, green: 0.64, blue: 0.50)
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text(loc.t("On-device storage"))
                    .font(T.sans(15, .semibold)).foregroundColor(T.ink)
                Spacer()
                Text(center.totalStorageUsed.formattedBytes)
                    .font(T.sans(13)).foregroundColor(T.ink2)
            }
            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 0) {
                    Rectangle().fill(T.accent)
                        .frame(width: w * CGFloat(lang) / CGFloat(sum))
                    Rectangle().fill(visionColor)
                        .frame(width: w * CGFloat(vision) / CGFloat(sum))
                    Rectangle().fill(voiceColor)
                        .frame(width: w * CGFloat(voice) / CGFloat(sum))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 10)
            .background(T.ink4.opacity(0.3))
            .clipShape(Capsule())
            HStack(spacing: Space.m) {
                storageLegend(loc.t("Language"), T.accent)
                storageLegend(loc.t("Vision"), visionColor)
                storageLegend(loc.t("Voice"), voiceColor)
            }

            Rectangle().fill(T.rule).frame(height: 1)

            HStack(alignment: .center, spacing: Space.s) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundColor(T.warn)
                Text(loc.t("Model downloads can grow quickly. Keep the ones you use and remove the rest without resetting the app."))
                    .font(T.sans(11.5))
                    .foregroundColor(T.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    showStorageCleanup = true
                    HapticManager.impact(.light)
                } label: {
                    Text(loc.t("Clean up"))
                        .font(T.sans(12, .semibold))
                        .foregroundColor(T.accent)
                        .padding(.horizontal, Space.s)
                        .frame(height: 32)
                        .background(Capsule().fill(T.accentSoft))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Space.m)
        .kClearGlass(
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous),
            fallbackFill: T.surface,
            fallbackStroke: T.rule
        )
    }

    private func storageLegend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: Space.xs) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).font(T.sans(12)).foregroundColor(T.ink2)
        }
    }

    /// Parses size labels like "1.7 GB", "82 MB", "82M", "~4.4 GB" → bytes.
    static func parseSizeToBytes(_ s: String) -> Int64 {
        let lower = s.lowercased().replacingOccurrences(of: "~", with: "")
        let scan = Scanner(string: lower)
        guard let value = scan.scanDouble() else { return 0 }
        if lower.contains("g") { return Int64(value * 1_000_000_000) }
        if lower.contains("m") { return Int64(value * 1_000_000) }
        if lower.contains("k") { return Int64(value * 1_000) }
        return Int64(value)
    }

    private var inventoryBadge: some View {
        HStack(spacing: Space.s) {
            Image(systemName: activeLoadedCount > 0 ? "bolt.horizontal.circle.fill" : "circle.dashed")
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(activeLoadedCount > 0 ? T.good : T.ink3)
                .frame(width: Size.tile, height: Size.tile)
                .background(
                    Circle()
                        .fill((activeLoadedCount > 0 ? T.good : T.ink3).opacity(T.isDark ? 0.18 : 0.10))
                )
                // Cross-fade the glyph between bolt / dashed-circle when
                // the live count rises off (or falls back to) zero, so
                // unloading the last model gives an explicit visual cue.
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeInOut(duration: 0.22), value: activeLoadedCount > 0)
            Text("\(activeLoadedCount)")
                .font(T.display(17, .semibold))
                .foregroundColor(T.ink)
                // Roll the counter rather than snapping. The numericText
                // transition only fires on the actual number change, not
                // on unrelated re-renders, so it stays performant even
                // inside the LazyVStack hot path.
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: activeLoadedCount)
            VStack(alignment: .leading, spacing: 1) {
                KMono(text: "live", size: 11, weight: .semibold, color: T.ink3)
                KMono(text: activeLoadedCount == 1 ? "model" : "models",
                      size: 11, weight: .semibold, color: T.ink3)
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.s)
        .fixedSize(horizontal: true, vertical: false)
        .kClearGlass(
            in: Capsule(),
            fallbackFill: T.surface,
            fallbackStroke: T.rule
        )
    }

    private var libraryHero: some View {
        modelCardShell(accent: T.accent, prominence: 0.16) {
            HStack(alignment: .center, spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    KCaption(text: "Library Overview", color: T.accent)
                    Text("Chat, vision, and imported MLX models.")
                        .font(T.sans(16, .semibold))
                        .foregroundColor(T.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(.body, weight: .semibold))
                    .foregroundColor(T.accent)
                    .frame(width: Size.control, height: Size.control)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(T.accentSoft)
                    )
            }
        }
    }

    // MARK: - Storage / counts strip
    //
    // README §Models split the four equal-weight stat cards into a two-
    // tile primary row (Storage + Active) and a small inline meta chip
    // row beneath (installed count · family count). Cuts visual noise in
    // half and stops the "0 MB used" + "6 installed" contradiction by
    // sourcing storage from `ModelDownloadCenter.totalStorageUsed`
    // (actual on-disk allocation), not the per-downloader totalBytes
    // expectation which drops to 0 once a download completes.

    /// One-line at-a-glance summary: storage used · models installed ·
    /// families · in-flight downloads (when any). The previous version
    /// stacked two card-sized tiles on top of a metadata row, which
    /// repeated the install count and ate ~140pt of vertical real
    /// estate before the user reached the section picker. Collapsing
    /// to a single horizontal strip cuts the preamble height roughly
    /// in half while preserving every datum.
    private var summaryStats: some View {
        let imageInstalled = ImageGenerationService.catalog.filter { imageGen.isInstalled($0) }
        let installedCount = center.models.filter { $0.isReady }.count + imageInstalled.count + coreAIStore.installations.count
        // totalStorageUsed now covers the HubApi cache (which is where the
        // image-gen models live) — adding imageGen.totalInstalledBytes on
        // top would double-count them.
        let storage = center.totalStorageUsed
        let downloading = center.models.filter {
            switch $0.state {
            case .downloading, .enumerating: return true
            default: return false
            }
        }.count

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s) {
                summaryChips(storage: storage, installed: installedCount, downloading: downloading)
            }
            VStack(alignment: .leading, spacing: Space.s) {
                summaryChips(storage: storage, installed: installedCount, downloading: downloading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func summaryChips(storage: Int64, installed: Int, downloading: Int) -> some View {
        metaChip(text: storage > 0 ? storage.formattedBytes : "0 mb", color: T.accent)
        metaChip(text: "\(installed) installed", color: T.ink3)
        metaChip(text: "\(familyGroups.count) families", color: T.ink3)
        if downloading > 0 {
            metaChip(text: "\(downloading) downloading", color: T.accent)
        }
    }

    @ViewBuilder
    private func metaChip(text: String, color: Color) -> some View {
        HStack(spacing: Space.xs) {
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
            Text(text)
                .font(T.mono(13))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xxs)
        .kClearGlass(
            in: Capsule(style: .continuous),
            fallbackFill: T.surface,
            fallbackStroke: T.rule
        )
    }

    @ViewBuilder
    private func statChip(icon: String, title: String, value: String, detail: String, tint: Color, soft: Color) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: icon)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: Size.tile, height: Size.tile)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(soft)
                )
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(value)
                    .font(T.display(20, .semibold))
                    .foregroundColor(T.ink)
                Text(title)
                    .font(T.mono(13, .semibold))
                    .foregroundColor(T.ink3)
                Text(detail)
                    .font(T.mono(13))
                    .foregroundColor(T.ink3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.m)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(T.surface.opacity(0.96))
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(T.isDark ? 0.12 : 0.09),
                                .clear,
                                T.surface.opacity(0.03)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .stroke(T.glassBorder, lineWidth: 0.5)
        )
    }

    private func totalStorageBytes() -> Int64 {
        center.models.reduce(0) { $0 + $1.totalBytes }
            + coreAIStore.installations.reduce(0) { $0 + $1.manifest.totalDownloadBytes }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        KSearchField(
            placeholder: isLibrary
                ? loc.t("Search downloaded models…")
                : loc.t("Search online · Hugging Face…"),
            text: $searchText,
            onClear: { searchTask?.cancel() },
            onSubmit: runSearch
        )
        .accessibilityIdentifier("models.search")
        .onChange(of: searchText) { _, new in
            debouncedSearch(query: new)
        }
    }

    private func debouncedSearch(query: String) {
        searchTask?.cancel()
        guard !isLibrary else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await search.search(query: q, filter: .all, limit: 30)
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        guard !isLibrary else { return }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searchTask = Task { await search.search(query: q, filter: .all, limit: 30) }
    }

    /// True when the user is actively searching Hugging Face.
    private var isSearching: Bool {
        !isLibrary
            && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Section content router

    @ViewBuilder
    private var activeContent: some View {
        if isLibrary {
            downloadedOnlyContent
        } else {
            VStack(spacing: Space.m) {
                if !isSearching {
                    Button(loc.t("Guided model setup")) { showingGuidedSetup = true }
                        .buttonStyle(.kSecondary)
                        .frame(minHeight: 44)
                    if filterAllCategories || selectedSection == .assistant {
                        recommendedSetupsCard
                    }
                }
                if filterAllCategories || selectedSection == .assistant {
                    CoreAIModelsSectionView(query: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if isSearching && filterAllCategories {
                    scopedSearchResults()
                } else if filterAllCategories {
                    ForEach(Section.allCases) { section in
                        categoryPage(for: section)
                    }
                } else {
                    categoryPage(for: selectedSection)
                }
            }
        }
    }

    /// Complete local inventory across every runtime family. Image-generation
    /// models use their own service/catalog, so they are appended explicitly
    /// rather than silently disappearing from the global count.
    @ViewBuilder
    private var downloadedOnlyContent: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let downloaded = center.models.filter { model in
            guard model.isReady, filterAllCategories || model.supportsCategory(selectedSection.category) else { return false }
            guard !query.isEmpty else { return true }
            return model.displayName.localizedCaseInsensitiveContains(query)
                || model.subtitle.localizedCaseInsensitiveContains(query)
                || model.sourceRepoID.localizedCaseInsensitiveContains(query)
        }
        let downloadedImages = ImageGenerationService.catalog.filter { model in
            guard imageGen.isInstalled(model), filterAllCategories || selectedSection == .image else { return false }
            guard !query.isEmpty else { return true }
            return model.displayName.localizedCaseInsensitiveContains(query)
                || model.subtitle.localizedCaseInsensitiveContains(query)
                || model.id.localizedCaseInsensitiveContains(query)
        }

        LazyVStack(spacing: 0) {
            if filterAllCategories || selectedSection == .assistant { CoreAIModelsSectionView(showsCatalog: false, query: query) }
            if downloaded.isEmpty && downloadedImages.isEmpty && !coreAIStore.installations.contains(where: {
                $0.assistantModel != nil && (filterAllCategories || selectedSection == .assistant)
                    && (query.isEmpty || $0.manifest.displayName.localizedCaseInsensitiveContains(query))
            }) {
                emptyState(
                    icon: query.isEmpty ? "internaldrive" : "magnifyingglass",
                    title: query.isEmpty
                        ? loc.t(filterAllCategories ? "No models downloaded yet" : "No downloaded models in this category")
                        : loc.t("No downloaded models found"),
                    subtitle: query.isEmpty
                        ? loc.t("Import a model from Files or discover a model to download.")
                        : loc.t("Try a broader search.")
                )
                if query.isEmpty {
                    KPrimaryButton(label: loc.t("Discover models"), systemImage: "sparkle.magnifyingglass") {
                        isLibrary = false
                    }
                    .padding(.top, Space.s)
                    .accessibilityIdentifier("models.discover.open")
                    Button { showImportPicker = true } label: {
                        Text(loc.t("Import model"))
                            .font(T.sans(14, .medium))
                            .foregroundStyle(T.ink2)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(KTactileButtonStyle())
                } else {
                    Button(loc.t("Clear search")) { searchText = "" }
                        .frame(minHeight: 44)
                }
            } else {
                sectionLabel(
                    loc.t("Downloaded").uppercased(),
                    glyph: "internaldrive.fill",
                    tint: T.good
                )
                ForEach(downloaded) { model in
                    if model.isRequired {
                        installedRow(model, activationCategory: filterAllCategories ? model.category : selectedSection.category)
                    } else {
                        SwipeToDeleteContainer(onDelete: { pendingDelete = model }) {
                            installedRow(model, activationCategory: filterAllCategories ? model.category : selectedSection.category)
                        }
                    }
                }
                ForEach(downloadedImages) { model in
                    imageModelRow(model)
                }
            }
        }
    }

    // MARK: - Discovery categories

    // Discovery lists suggestions and explicit online search results. Runtime
    // controls live in each model's details; transfers stay in Downloads.
    @ViewBuilder
    private func categoryPage(for section: Section) -> some View {
        let category = section.category
        LazyVStack(spacing: Space.m) {
            sectionLabel(loc.t(section.rawValue), glyph: section.glyph, tint: T.accent)
            // In-flight downloads for this category.
            let inFlight = inFlightModels(category)
            if !inFlight.isEmpty {
                sectionLabel(loc.t("Downloading").uppercased(), glyph: "arrow.down.circle", tint: T.accent)
                ForEach(inFlight) { model in
                    if let downloader = model.downloader {
                        InstallingRow(model: model, downloader: downloader, theme: T, loc: loc)
                    }
                }
            }

            if isSearching {
                if section == .voice {
                    voiceCatalogBlock(query: searchText)
                    scopedSearchResults(category)
                } else {
                    scopedSearchResults(category)
                }
            } else {
                if category == .imageGen {
                    imageSuggestionsBlock
                } else if section == .voice {
                    voiceCatalogBlock(query: "")
                } else {
                    suggestedBlock(category)
                }

            }
        }
    }

    // MARK: - Active role header

    @ViewBuilder
    private func activeRoleHeader(for section: Section) -> some View {
        switch section {
        case .assistant:
            VStack(spacing: Space.s) {
                categorySectionHeader(.assistant)
                activeRow(
                    title: loc.t("assistant"),
                    icon: "brain",
                    modelName: assistant.activeModel.displayName,
                    modelRepoID: assistant.activeModel.repoID,
                    phase: assistantLoadPhase,
                    onLoad:   { loadAssistant() },
                    onUnload: { unloadAssistant() },
                    onCancel: { cancelAssistantLoad() },
                    onSwap:   { presentAfterDetails { showingAssistantPicker = true } },
                    onSettings: {
                        presentAfterDetails {
                            assistantSettingsTarget = AssistantModelSettingsTarget(model: assistant.activeModel)
                        }
                    }
                )
            }
        case .lens:
            VStack(spacing: Space.s) {
                categorySectionHeader(.vlm)
                activeRow(
                    title: loc.t("vision"),
                    icon: "eye",
                    modelName: visionDisplayName,
                    modelRepoID: visionRepoID,
                    phase: visionLoadPhase,
                    onLoad:   { loadVision() },
                    onUnload: { unloadVision() },
                    onCancel: { cancelVisionLoad() },
                    onSwap:   { presentAfterDetails { showingVisualPicker = true } }
                )
            }
        case .voice:
            VStack(spacing: Space.s) {
                categorySectionHeader(.voice)
                activeRow(
                    title: loc.t("voice"),
                    icon: "waveform",
                    modelName: voiceDisplayName,
                    modelRepoID: voiceRepoLabel,
                    phase: voiceLoadPhase,
                    onLoad:   { loadVoice() },
                    onUnload: { unloadVoice() },
                    onCancel: { cancelVoiceLoad() },
                    onSwap:   { presentAfterDetails { showingVoicePicker = true } }
                )
            }
        case .image:
            imageHeroCard
        }
    }

    // MARK: - Per-category model lists

    /// In-flight (downloading / enumerating / failed) downloads for a category.
    private func inFlightModels(_ category: DownloadableModel.Category) -> [DownloadableModel] {
        center.models.filter { $0.supportsCategory(category) && $0.hasUnfinishedDownload }
    }

    /// Installed (.ready) models for a category.
    private func installedModels(_ category: DownloadableModel.Category) -> [DownloadableModel] {
        center.models.filter { $0.supportsCategory(category) && $0.isReady }
    }

    /// All not-installed candidates for a category, ranked so the best models
    /// that FIT this device surface first. Unfiltered — `suggestedModels`
    /// applies the safety/edge filter on top.
    private func rankedCandidates(_ category: DownloadableModel.Category) -> [DownloadableModel] {
        let candidates = center.models.filter { m in
            guard m.supportsCategory(category) else { return false }
            switch m.state {
            case .ready, .downloading, .enumerating: return false  // shown elsewhere
            default: return true                                    // idle / failed
            }
        }
        func rank(_ m: DownloadableModel) -> Int {
            // Lower is better. Compatible + recommended float to the top.
            var score = 0
            switch MemoryAdvisor.fit(forFootprint: modelFootprint(m)) {
            case .fits:  score += 0
            case .tight: score += 100
            case .over:  score += 1000
            }
            if m.capabilities.contains(.recommended) { score -= 40 }
            if m.capabilities.contains(.best)        { score -= 25 }
            if m.capabilities.contains(.newRelease)  { score -= 10 }
            return score
        }
        return candidates.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return modelFootprint(a) < modelFootprint(b)
        }
    }

    /// Best available peak-RAM estimate for a model. Prefers the catalog's own
    /// declared `approxRAMBytes` (set for VLM / voice / image entries that
    /// aren't in the assistant preset table), then the id-based estimate, then
    /// the conservative floor. Used for fit badges and the safety filter.
    private func modelFootprint(_ model: DownloadableModel) -> Int64 {
        if let ram = model.approxRAMBytes, ram > 0 { return ram }
        let est = MemoryAdvisor.estimatedFootprint(for: model.id)
        return est > 0 ? est : MemoryAdvisor.unknownFootprintFloor
    }

    /// True when a candidate may be shown to the user. A normal user only ever
    /// sees models that comfortably fit (`.fits`) — so they can never be tempted
    /// into an OOM crash or an incompatible pick. Edge / developer mode adds the
    /// `.tight` models (run right at the limit; experimental). `.over` models
    /// genuinely can't load and are never suggested.
    private func passesSafetyFilter(_ model: DownloadableModel) -> Bool {
        guard model.platformCompatibility?.supportsCurrentPlatform ?? true else {
            return false
        }
        switch MemoryAdvisor.fit(forFootprint: modelFootprint(model)) {
        case .fits:  return true
        case .tight: return settings.showEdgeModels
        case .over:  return false
        }
    }

    /// Suggestions actually shown, after the safety/edge filter.
    private func suggestedModels(_ category: DownloadableModel.Category) -> [DownloadableModel] {
        rankedCandidates(category).filter { passesSafetyFilter($0) }
    }

    /// How many candidates are hidden by the safety/edge filter — drives the
    /// "N hidden" hint so the user knows Edge mode would reveal more.
    private func hiddenCandidateCount(_ category: DownloadableModel.Category) -> Int {
        rankedCandidates(category).count - suggestedModels(category).count
    }

    // MARK: - Installed block

    @ViewBuilder
    private func installedBlock(_ category: DownloadableModel.Category) -> some View {
        let installed = installedModels(category)
        if !installed.isEmpty {
            sectionLabel(loc.t("Installed").uppercased(), glyph: "internaldrive", tint: T.good)
            ForEach(installed) { model in
                if model.isRequired {
                    installedRow(model, activationCategory: category)
                } else {
                    SwipeToDeleteContainer(onDelete: { pendingDelete = model }) {
                        installedRow(model, activationCategory: category)
                    }
                }
            }
        }
    }

    // MARK: - Suggested block

    @ViewBuilder
    private func suggestedBlock(_ category: DownloadableModel.Category) -> some View {
        let suggested = suggestedModels(category)
        let hidden = hiddenCandidateCount(category)
        if suggested.isEmpty && hidden == 0 {
            if installedModels(category).isEmpty {
                emptyState(
                    icon: selectedSection.glyph,
                    title: loc.t("Nothing to suggest yet"),
                    subtitle: loc.t("Search Hugging Face above to add a model.")
                )
            }
        } else {
            suggestedHeader
            ForEach(suggested) { model in
                catalogRow(model, activationCategory: category)
            }
            edgeHiddenHint(hidden)
        }
    }

    // MARK: - Production voice catalog

    /// The authoritative catalog rendered by the Models tab's Voice section.
    /// Runtime availability affects the action, never whether the card exists.
    @ViewBuilder
    private func voiceCatalogBlock(query: String) -> some View {
        let entries = voiceCatalog.entries(query: query.trimmingCharacters(in: .whitespacesAndNewlines))
        let useful = entries.filter { $0.isDownloadEnabled || $0.id == "tts.apple.system" }
        let future = entries.filter { !$0.isDownloadEnabled && $0.id != "tts.apple.system" }
        sectionLabel(loc.t("All voice models").uppercased(), glyph: "waveform", tint: T.accent)
        if entries.isEmpty {
            emptyState(icon: "magnifyingglass", title: loc.t("No voice models found"), subtitle: loc.t("Try a broader search."))
        } else {
            ForEach(useful) { entry in
                voiceCatalogRow(entry)
            }
            if !future.isEmpty {
                DisclosureGroup(isExpanded: $showFutureVoiceIntegrations) {
                    ForEach(future) { entry in voiceCatalogRow(entry) }
                } label: {
                    Label("Future Runtime Integrations", systemImage: "shippingbox")
                        .font(T.display(16, .semibold))
                        .foregroundStyle(T.ink2)
                }
            }
        }
    }

    private func isActiveVoiceEntry(_ entry: VoiceCatalogEntry) -> Bool {
        if entry.id == "tts.apple.system" { return currentVoiceEngine == .appleSystem }
        guard let id = entry.legacyDownloadID,
              let model = center.models.first(where: { $0.id == id }) else { return false }
        return isActiveModel(model, as: .voice)
    }

    private func voiceCatalogRow(_ entry: VoiceCatalogEntry) -> some View {
        ModelsCompactRow(
            name: entry.name,
            subtitle: loc.t(entry.task == .textToSpeech ? "Text to Speech" : "Speech Recognition") + (entry.sizeLabel.map { " · " + $0 } ?? ""),
            status: loc.t(entry.statusLabel),
            actionTitle: loc.t("Review voice support and download options"),
            action: { details = .voice(entry) }
        )
        .accessibilityIdentifier("modelsVoiceCatalogCard.\(entry.id)")
    }

    private func voiceCatalogDetailRow(_ entry: VoiceCatalogEntry) -> some View {
        let model = entry.legacyDownloadID.flatMap { id in center.models.first { $0.id == id } }
        return modelCardShell(accent: T.accent, prominence: 0.09) {
            VStack(alignment: .leading, spacing: Space.s) {
                detailHeaderLayout {
                    categoryGlyph(.voice)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        KCaption(text: entry.task == .textToSpeech ? "TEXT TO SPEECH" : "SPEECH RECOGNITION", color: T.ink3)
                        Text(entry.name).font(T.display(18, .semibold)).foregroundColor(T.ink)
                        Text(LocalizedStringKey(entry.summary)).font(T.sans(14)).foregroundColor(T.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                        statusPill(text: entry.statusLabel, color: entry.isDownloadEnabled ? T.good : T.warn)
                    }
                        if let size = entry.sizeLabel { metricBadge(size) }
                }

                detailActionsLayout {
                    if entry.id == "tts.apple.system" {
                        cardButton(label: loc.t("Select"), kind: .primary) {
                            VoiceSettingsStore.shared.selectEngine(.appleSystem)
                        }
                    } else if entry.isDownloadEnabled, let model {
                        switch model.state {
                        case .ready:
                            if let variant = KittenVariant(rawValue: entry.id) {
                                let hasPassedRuntimeTest = VoiceSettingsStore.shared.selectedKittenVariant == variant
                                    && voiceSvc.kittenState == .ready
                                statusPill(
                                    text: loc.t(hasPassedRuntimeTest ? "ready" : "installed · test required"),
                                    color: hasPassedRuntimeTest ? T.good : T.warn
                                )
                                cardButton(label: loc.t("Select & Test"), kind: .primary) {
                                    Task { @MainActor in
                                        do {
                                            try await voiceSvc.activateAndTestKittenVariant(variant)
                                            ToastCenter.shared.success("\(entry.name) produced audio")
                                        } catch {
                                            ToastCenter.shared.error("Voice test failed", detail: error.localizedDescription)
                                        }
                                    }
                                }
                            }
                        case .downloading, .enumerating:
                            statusPill(text: loc.t("downloading"), color: T.accent)
                        case .idle, .failed:
                            cardButton(label: loc.t("Download"), kind: .primary) { model.start() }
                        }
                    } else {
                        cardButton(label: loc.t(entry.statusLabel), kind: .secondary) {}
                            .disabled(true)
                    }
                    if let source = entry.sourceURL, let url = URL(string: source) {
                        Link(loc.t("Open Project"), destination: url)
                            .font(T.mono(13, .semibold)).foregroundColor(T.accent)
                    }
                }
            }
        }
        .accessibilityIdentifier("models.voice.details.\(entry.id)")
    }

    /// "SUGGESTED · best fit first" eyebrow + live free-memory hint, then the
    /// edge-mode toggle. The hint gives the fit badges context ("fits" relative
    /// to what?), and the toggle is the single control that gates whether any
    /// risky model is ever shown or loadable.
    private var suggestedHeader: some View {
        let avail = MemoryAdvisor.availableMemoryForModel
        return VStack(spacing: Space.s) {
            // A description of the list, not a second small-caps header: the
            // category header right above already names the section.
            HStack(spacing: Space.xs) {
                Text(loc.t("Suggested · best fit first"))
                Spacer(minLength: 0)
                if avail > 0 {
                    Text("~\(avail.formattedBytes) " + loc.t("free"))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(T.ink3)
            edgeToggle
        }
    }

    /// Edge / developer toggle. OFF (default): a normal user sees only models
    /// that safely fit — zero OOM risk. ON: "tight" edge models are revealed
    /// and the load gate drops its reserve so they can actually run.
    private var edgeToggle: some View {
        let on = settings.showEdgeModels
        return Button {
            withAnimation(.snappy(duration: 0.2)) { settings.showEdgeModels.toggle() }
            HapticManager.impact(.light)
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: on ? "hammer.fill" : "hammer")
                    .font(.system(.caption2, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(loc.t(on ? "Edge / developer mode — ON" : "Edge / developer mode"))
                        .font(T.mono(13, .semibold))
                    Text(on
                         ? loc.t("Tight models shown — experimental, may be unstable")
                         : loc.t("Only models that safely fit this device are shown"))
                        .font(T.mono(13))
                        .foregroundColor((on ? T.warn : T.ink3).opacity(0.9))
                }
                Spacer(minLength: 0)
                Image(systemName: on ? "circle.inset.filled" : "circle")
                    .font(.system(.callout, weight: .semibold))
            }
            .foregroundColor(on ? T.warn : T.ink2)
            .padding(.horizontal, Space.s).padding(.vertical, Space.s)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill((on ? T.warn : T.ink3).opacity(on ? 0.12 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .stroke(on ? T.warn.opacity(0.40) : T.glassBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// Hint shown when the safety filter is hiding models. Only appears when
    /// edge mode is off (when it's on, nothing fitting is hidden).
    @ViewBuilder
    private func edgeHiddenHint(_ count: Int) -> some View {
        if count > 0 && !settings.showEdgeModels {
            HStack(alignment: .top, spacing: Space.xs) {
                Image(systemName: "eye.slash")
                    .font(.system(.caption2))
                    .foregroundColor(T.ink3)
                Text("\(count) " + loc.t("model(s) hidden that won't safely fit this device. Turn on Edge mode to try them."))
                    .font(T.mono(13))
                    .foregroundColor(T.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.xxs)
        }
    }

    @ViewBuilder
    private var imageSuggestionsBlock: some View {
        let visible = ImageGenerationService.catalog.filter { m in
            imageGen.isInstalled(m) || passesImageSafetyFilter(m)
        }
        let hidden = ImageGenerationService.catalog.count - visible.count
        suggestedHeader
        ForEach(visible) { m in
            imageModelRow(m)
        }
        edgeHiddenHint(hidden)
    }

    /// Image models live in their own catalog (not `center.models`), so they
    /// get a parallel safety filter keyed off their declared RAM footprint.
    private func passesImageSafetyFilter(_ m: ImageGenerationService.Model) -> Bool {
        switch MemoryAdvisor.fit(forFootprint: m.approxRAMBytes) {
        case .fits:  return true
        case .tight: return settings.showEdgeModels
        case .over:  return false
        }
    }

    // MARK: - Recommended setups (model combinations)

    /// Light / Medium / Heavy full-stack combos (assistant · vision · voice ·
    /// image). Educational: a coherent set of models that work well together,
    /// each with an honest device-fit badge based on the heaviest single model
    /// — models load one at a time, so the largest pick is the binding limit.
    private var recommendedSetupsCard: some View {
        VStack(spacing: Space.s) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { showRecommendedSetups.toggle() }
                HapticManager.impact(.light)
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(.caption2))
                        .foregroundColor(T.accent)
                    KCaption(text: loc.t("Recommended setups").uppercased(), color: T.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Rectangle().fill(T.rule).frame(height: 1)
                    Image(systemName: showRecommendedSetups ? "chevron.up" : "chevron.down")
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundColor(T.ink3)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showRecommendedSetups {
                Text(loc.t("Coherent Light · Medium · Heavy stacks for your device. Tap a model to open its category."))
                    .font(T.mono(13))
                    .foregroundColor(T.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Self.modelCombos) { combo in
                    comboCard(combo)
                }
            }
        }
    }

    @ViewBuilder
    private func comboCard(_ combo: ModelCombo) -> some View {
        let accent = comboAccent(combo.tier)
        let maxRAM = combo.picks.map(\.approxRAM).max() ?? 0
        let expanded = expandedComboID == combo.id
        modelCardShell(accent: accent, prominence: expanded ? 0.14 : 0.09, padding: Space.cardPadding) {
            VStack(alignment: .leading, spacing: expanded ? Space.s : 0) {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        expandedComboID = expanded ? nil : combo.id
                    }
                    HapticManager.impact(.light)
                } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: combo.glyph)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundColor(accent)
                            .frame(width: Size.control, height: Size.control)
                            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(accent.opacity(0.14)))
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            HStack(spacing: Space.xs) {
                                Text(loc.t(combo.tier))
                                    .font(T.display(17, .semibold))
                                    .foregroundColor(T.ink)
                                fitBadge(forFootprint: maxRAM)
                            }
                            Text(loc.t(combo.tagline))
                                .font(T.mono(13))
                                .foregroundColor(T.ink3)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: Space.xs) {
                            metricBadge("↓ " + combo.totalDownload.formattedBytes)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(.caption2, weight: .semibold))
                                .foregroundColor(T.ink3)
                        }
                    }
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(spacing: Space.s) {
                        ForEach(combo.picks) { pick in
                            comboPickRow(pick)
                        }
                    }

                    // The card's one main action: Apple's prominent glass in the
                    // app accent, like every other primary button.
                    KPrimaryButton(
                        label: loc.t("Download all"),
                        systemImage: "arrow.down.circle.fill",
                        trailing: combo.totalDownload.formattedBytes
                    ) {
                        startDownloads(for: combo)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func comboPickRow(_ pick: ComboPick) -> some View {
        HStack(spacing: Space.s) {
            Button {
                searchText = ""
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    filterAllCategories = false
                    selectedSection = sectionFor(pick.role)
                }
                HapticManager.impact(.light)
            } label: {
                HStack(spacing: Space.s) {
                    categoryGlyph(pick.role)
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(pick.name)
                            .font(T.mono(13, .semibold))
                            .foregroundColor(T.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(loc.t(pick.detail))
                            .font(T.mono(13))
                            .foregroundColor(T.ink3)
                    }
                    Spacer(minLength: 0)
                    fitBadge(forFootprint: pick.approxRAM)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)

            comboDownloadControl(for: pick)
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.s)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(T.surface2.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .stroke(T.glassBorder, lineWidth: 0.5))
    }

    @ViewBuilder
    private func comboDownloadControl(for pick: ComboPick) -> some View {
        let tint = categoryTint(pick.role)
        if pick.role == .imageGen,
           let model = ImageGenerationService.model(forID: pick.catalogID) {
            if imageGen.isInstalled(model) {
                comboReadyBadge(tint: tint)
            } else if imageGen.isDownloading(model) {
                comboProgressBadge(
                    progress: imageGen.downloadProgress(for: model),
                    tint: tint
                )
            } else {
                GlassGetButton(
                    label: imageGen.directDownloadErrors[model.id] == nil
                        ? loc.t("Get")
                        : loc.t("Retry"),
                    tint: tint
                ) {
                    imageGen.startDownload(model)
                }
            }
        } else if let model = comboDownloadableModel(for: pick),
                  let downloader = model.downloader {
            ComboModelDownloadControl(
                downloader: downloader,
                tint: tint,
                getLabel: loc.t("Get"),
                retryLabel: loc.t("Retry"),
                readyLabel: loc.t("Ready")
            ) {
                model.start()
            }
        } else {
            Button {
                filterAllCategories = false
                selectedSection = sectionFor(pick.role)
            } label: {
                Image(systemName: "chevron.forward")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(T.ink3)
                    .frame(width: 34, height: 30)
            }
            .buttonStyle(.plain)
        }
    }

    private func comboDownloadableModel(for pick: ComboPick) -> DownloadableModel? {
        center.models.first { $0.id == pick.catalogID }
    }

    private func startDownloads(for combo: ModelCombo) {
        var started = 0
        for pick in combo.picks {
            if pick.role == .imageGen,
               let model = ImageGenerationService.model(forID: pick.catalogID) {
                guard !imageGen.isInstalled(model), !imageGen.isDownloading(model) else { continue }
                imageGen.startDownload(model)
                started += 1
            } else if let model = comboDownloadableModel(for: pick),
                      !model.isReady,
                      !model.state.isActive {
                model.start()
                started += 1
            }
        }

        HapticManager.impact(.medium)
        if started == 0 {
            ToastCenter.shared.info("Setup already downloaded")
        } else {
            ToastCenter.shared.info(
                "Downloading \(combo.tier) setup",
                detail: "Models started: \(started)"
            )
        }
    }

    @ViewBuilder
    private func comboProgressBadge(progress: Double, tint: Color) -> some View {
        HStack(spacing: Space.xs) {
            ProgressView(value: progress)
                .tint(tint)
                .frame(width: 28)
            Text("\(Int(progress * 100))%")
                .font(T.mono(13, .semibold))
                .foregroundColor(tint)
        }
        .frame(height: 30)
    }

    @ViewBuilder
    private func comboReadyBadge(tint: Color) -> some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(.body, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: 42, height: 30)
    }

    private func comboAccent(_ tier: String) -> Color {
        switch tier {
        case "Light": return T.good
        case "Heavy": return T.warn
        default:      return T.accent
        }
    }

    private func sectionFor(_ role: DownloadableModel.Category) -> Section {
        switch role {
        case .assistant: return .assistant
        case .vlm:       return .lens
        case .voice:     return .voice
        case .imageGen:  return .image
        }
    }

    /// Image hero card + generator launcher (replaces the active-role row for
    /// the Image category, which has no persistent "active" selection).
    private var imageHeroCard: some View {
        VStack(spacing: Space.s) {
            categorySectionHeader(.imageGen)
            modelCardShell(accent: T.accent, prominence: 0.16) {
                HStack(alignment: .center, spacing: Space.m) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(.body, weight: .semibold))
                        .foregroundColor(T.accent)
                        .frame(width: Size.control, height: Size.control)
                        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(T.accentSoft))
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        KCaption(text: loc.t("Text to image"), color: T.accent)
                        Text(loc.t("Generate images on-device"))
                            .font(T.display(18, .semibold))
                            .foregroundColor(T.ink)
                        Text("Download an image model below. No prompt needed. Generate offline when you're ready.")
                            .font(T.mono(13))
                            .foregroundColor(T.ink3)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            Button {
                showImageGen = true
                HapticManager.impact(.medium)
            } label: {
                HStack(spacing: Space.s) {
                    Image(systemName: "sparkles")
                    Text(loc.t("Open generator"))
                }
                .font(T.display(16, .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.m)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(T.roseHi))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("modelsOpenImageGenerator")
        }
    }

    // MARK: - Scoped Hugging Face search results

    @ViewBuilder
    private func scopedSearchResults(_ category: DownloadableModel.Category? = nil) -> some View {
        let results = search.results.filter { model in
            category.map { LocalModelRegistry.category(for: model) == $0 } ?? true
        }
        VStack(spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(.caption2))
                    .foregroundColor(T.accent)
                KCaption(text: loc.t("Hugging Face results").uppercased(), color: T.accent)
                Rectangle().fill(T.rule).frame(height: 1)
            }
            if search.isSearching {
                ProgressView().tint(T.accent).padding(.vertical, Space.m)
            } else if let error = search.lastError {
                VStack(alignment: .leading, spacing: Space.s) {
                    Label(loc.t("Search unavailable"), systemImage: "wifi.exclamationmark")
                        .font(T.sans(15, .semibold))
                        .foregroundStyle(T.ink)
                    Text(error).font(T.sans(13)).foregroundStyle(T.ink2)
                    Button(loc.t("Retry"), action: runSearch).frame(minHeight: 44)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if results.isEmpty {
                emptyState(
                    icon: "magnifyingglass",
                    title: loc.t("No matching models"),
                    subtitle: search.results.isEmpty
                        ? loc.t("Try a different search term.")
                        : loc.t("No results in this category. Choose All to see more models.")
                )
            } else {
                // Same row as the search sheet: compatibility verdict,
                // size/licence preflight, and one shared downloader.
                ForEach(results) { result in
                    HFSearchRow(model: result)
                }
            }
        }
    }

    /// Thin labelled divider used to head a block inside a category page.
    @ViewBuilder
    private func sectionLabel(_ title: String, glyph: String, tint: Color) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: glyph)
                .font(.system(.caption2))
                .foregroundColor(tint)
            KCaption(text: title, color: tint)
            Rectangle().fill(T.rule).frame(height: 1)
        }
    }

    /// Inline, adjustable controls for the app's "smart" model handling —
    /// mirrors the Settings → Models knobs so users can tune crash-safety and
    /// the load watchdog without leaving the Models hub.
    private var smartHandlingCard: some View {
        modelCardShell(accent: T.accent, prominence: 0.08) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Image(systemName: "wand.and.stars.inverse")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundColor(T.accent)
                    KCaption(text: "Smart handling", color: T.accent)
                    Spacer(minLength: 0)
                }
                Toggle(isOn: $settings.strictMemoryGate) {
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(loc.t("Memory safety gate"))
                            .font(T.sans(14, .semibold))
                            .foregroundColor(T.ink)
                        Text(loc.t("Refuse models too large for this device instead of crashing"))
                            .font(T.mono(13))
                            .foregroundColor(T.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(T.accent)

                Rectangle().fill(T.rule).frame(height: 0.5)

                Toggle(isOn: $settings.largeModelLowMemoryEnabled) {
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(loc.t("MLX low-cache / GGUF paging"))
                            .font(T.sans(14, .semibold))
                            .foregroundColor(T.ink)
                        Text(loc.t("Experimental · MLX still loads all weights; GGUF can page weights from storage"))
                            .font(T.mono(13))
                            .foregroundColor(T.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(T.accent)

                Rectangle().fill(T.rule).frame(height: 0.5)

                HStack(alignment: .center, spacing: Space.s) {
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(loc.t("Load timeout"))
                            .font(T.sans(14, .semibold))
                            .foregroundColor(T.ink)
                        Text(settings.modelLoadTimeoutSeconds == 0
                             ? loc.t("Off — a stuck load won't auto-cancel")
                             : loc.t("\(settings.modelLoadTimeoutSeconds / 60) min before a stuck load auto-cancels"))
                            .font(T.mono(13))
                            .foregroundColor(T.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Stepper("", value: $settings.modelLoadTimeoutSeconds, in: 0...1800, step: 60)
                        .labelsHidden()
                }
            }
        }
    }

    // MARK: - Voice row plumbing
    //
    // The voice engine has a simpler state shape than assistant/vision —
    // Apple System Voice is always "ready" and needs no loading; only
    // KittenTTS / Kokoro have load progress and can fail. We collapse
    // both shapes onto the same LoadPhase enum so the row UI stays
    // identical to the other two roles.

    private var currentVoiceEngine: VoiceEngineKind {
        VoiceEngineKind(rawValue: settings.voiceEngine) ?? .appleSystem
    }

    private var voiceDisplayName: String {
        switch currentVoiceEngine {
        case .appleSystem: return LocalizationService.shared.t("Apple System Voice")
        case .kittenTTS:   return LocalizationService.shared.t("KittenTTS (neural)")
        case .kokoro:      return LocalizationService.shared.t("Kokoro (neural)")
        case .paradee:     return LocalizationService.shared.t("Paradee (neural)")
        case .supertonic:  return LocalizationService.shared.t("Supertonic (neural)")
        }
    }

    private var voiceRepoLabel: String {
        switch currentVoiceEngine {
        case .appleSystem: return "AVSpeechSynthesizer · built-in"
        case .kittenTTS:   return "alexwengg/kittentts-coreml"
        case .kokoro:      return "hexgrad/Kokoro-82M"
        case .paradee:     return "sahilmahendrakar/Paradee-8M-v1.2"
        case .supertonic:  return "Supertone/supertonic-3"
        }
    }

    private var voiceLoadPhase: LoadPhase {
        switch currentVoiceEngine {
        case .appleSystem:
            // System voice has no model to load — always ready, no
            // unload affordance is meaningful. The row will hide the
            // unload button by virtue of always reporting .ready.
            return .ready
        case .kittenTTS:
            return loadPhase(for: voiceSvc.kittenState)
        case .kokoro:
            return loadPhase(for: voiceSvc.kokoroState)
        case .paradee:
            return loadPhase(for: voiceSvc.paradeeState)
        case .supertonic:
            return loadPhase(for: voiceSvc.supertonicState)
        }
    }

    /// Map a VoiceModelState onto the unified LoadPhase enum used by
    /// the active-row UI. .loading collapses to indeterminate because
    /// voice engines don't expose a numeric progress fraction during
    /// load (the entire model is a single CoreML compile + voices.npz
    /// parse, both atomic from the caller's perspective).
    private func loadPhase(for state: VoiceModelState) -> LoadPhase {
        switch state {
        case .unloaded:        return .unloaded
        case .loading:         return .loading(nil, loc.t("Loading voice engine…"))
        case .ready:           return .ready
        case .failed(let msg): return .failed(msg)
        }
    }

    private func canSetActive(
        _ model: DownloadableModel,
        as activationCategory: DownloadableModel.Category? = nil
    ) -> Bool {
        guard model.platformCompatibility?.supportsCurrentPlatform ?? true else {
            return false
        }
        switch activationCategory ?? model.category {
        case .voice:
            return supportedVoiceEngine(for: model) != nil
        case .assistant, .vlm:
            return true
        case .imageGen:
            // Image-generation models run through ImageGenerationService's
            // own curated flow, not a "set as active" role — never offer it.
            return false
        }
    }

    private func supportedVoiceEngine(for model: DownloadableModel) -> VoiceEngineKind? {
        LocalModelRegistry.voiceEngine(for: model)
    }

    /// True for speech-to-text models (Whisper). They're voice-category but
    /// drive dictation / voice conversation, not TTS playback — so a missing
    /// TTS engine binding isn't a problem, they're "ready" once downloaded.
    private func isSpeechToText(_ model: DownloadableModel) -> Bool {
        let s = (model.displayName + " " + model.subtitle).lowercased()
        return s.contains("whisper") || s.contains("stt")
            || s.contains("speech-to-text") || s.contains("speech recognition")
    }

    private func loadVoice() {
        HapticManager.impact(.medium)
        // System voice needs no load; opening the picker is the only
        // way to land on Kitten/Kokoro, so a Load tap on the system row
        // is a no-op. Surface a hint via Toast so the user understands.
        if currentVoiceEngine == .appleSystem {
            ToastCenter.shared.info("System Voice is always ready")
            return
        }
        Task { await voiceSvc.load() }
    }
    private func unloadVoice() {
        HapticManager.impact(.light)
        voiceSvc.unloadAll()
    }
    private func cancelVoiceLoad() {
        HapticManager.impact(.medium)
        voiceSvc.unloadAll()
        ToastCenter.shared.info("Stopped loading \(voiceDisplayName)")
    }

    // MARK: - Active row load phase

    /// Normalised lifecycle the activeRow renders against. Folds the two
    /// underlying state enums (CodingAssistantService / MLXVisionService /
    /// FastVLMService.componentStatus) into a single shape so the row UI
    /// doesn't need to know which path it's looking at.
    private enum LoadPhase: Equatable {
        case unloaded              // user hasn't loaded yet → show "Load model"
        case loading(Double?, String)  // 0…1 progress + display message; nil = indeterminate
        case ready                 // model resident → show "Unload"
        case failed(String)        // error → show "Retry"
    }

    private var assistantLoadPhase: LoadPhase {
        switch assistant.state {
        case .unloaded:
            // User just tapped Load — the service hasn't flipped to
            // `.loading` yet (safetyBlocker checks, gate acquisition,
            // etc. all happen first). Show indeterminate progress
            // immediately so the tap doesn't feel like it was missed.
            return assistantLoadStarting
                ? .loading(nil, loc.t("Starting…"))
                : .unloaded
        case .loading(let msg):          return .loading(Self.percentage(in: msg), msg)
        case .ready, .generating:        return .ready
        case .failed(let msg):           return .failed(msg)
        }
    }

    private var visionLoadPhase: LoadPhase {
        // FastVLM uses its own componentStatus rather than the MLXVision
        // state machine — branch on which one the user has selected as
        // active so we display the right pipeline's progress.
        if LocalModelRegistry.isDefaultVisionSelection(
            LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        ) {
            if fastVLM.componentStatus.canGenerate { return .ready }
            if fastVLM.componentStatus.isLoading {
                let msg = fastVLM.loadStatusMessage.isEmpty
                    ? loc.t("Loading FastVLM…")
                    : fastVLM.loadStatusMessage
                // FastVLM.loadProgress is 0 before any callback fires, so
                // treat 0 as "indeterminate" rather than rendering a stuck
                // empty bar.
                let p = fastVLM.loadProgress
                return .loading(p > 0 ? p : nil, msg)
            }
            // Surface the first failed component's message rather than a
            // generic "not loaded" so users see e.g. "weights not
            // downloaded yet" and know what to do.
            for c in [fastVLM.componentStatus.decoder,
                      fastVLM.componentStatus.projector,
                      fastVLM.componentStatus.encoder,
                      fastVLM.componentStatus.tokenizer] {
                if case .failed(let msg) = c { return .failed(msg) }
            }
            // Same immediate-tap feedback as the assistant row — see
            // assistantLoadPhase for the rationale.
            return visionLoadStarting
                ? .loading(nil, loc.t("Starting…"))
                : .unloaded
        }
        switch vision.state {
        case .unloaded:
            return visionLoadStarting
                ? .loading(nil, loc.t("Starting…"))
                : .unloaded
        case .loading(let msg):          return .loading(Self.percentage(in: msg), msg)
        case .ready, .generating:        return .ready
        case .failed(let msg):           return .failed(msg)
        }
    }

    // MARK: - Load / Unload actions

    private func loadAssistant() {
        HapticManager.impact(.medium)
        // load() targets the saved default. When that model is not on the
        // device it downloads through the catalog (progress, pause, delete)
        // rather than invisibly inside load().
        let target = AssistantModelCatalog.currentSelection()
        if assistant.activeExecutionLocation == .localDownloaded,
           !CodingAssistantService.isInstalled(target),
           let entry = center.models.first(where: { $0.id == target.id }) {
            entry.start()
            return
        }
        // Immediate visual ack — flips the row into an indeterminate
        // progress state until the service publishes its own `.loading`
        // (or fails fast). See assistantLoadPhase for how this is read.
        assistantLoadStarting = true
        assistantLoadTask = Task {
            await assistant.load()
            await MainActor.run {
                assistantLoadStarting = false
                assistantLoadTask = nil
                assistantWatchdog?.cancel(); assistantWatchdog = nil
            }
        }
        assistantWatchdog = armLoadWatchdog(stillLoading: { assistantLoadTask != nil }) {
            cancelAssistantLoad()
            ToastCenter.shared.error("Load timed out",
                detail: "\(assistant.activeModel.displayName) took too long. Check your connection or pick a smaller model.")
        }
    }

    /// Returns a watchdog Task that fires `onTimeout` if `stillLoading()` is
    /// true after the configured timeout. nil when the watchdog is disabled.
    private func armLoadWatchdog(stillLoading: @escaping () -> Bool,
                                 onTimeout: @escaping () -> Void) -> Task<Void, Never>? {
        let secs = AppSettings.shared.modelLoadTimeoutSeconds
        guard secs > 0 else { return nil }
        return Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
            if Task.isCancelled { return }
            if stillLoading() { onTimeout() }
        }
    }
    private func unloadAssistant() {
        HapticManager.impact(.light)
        assistant.unload()
    }
    /// Stop an in-flight load. Cancels the launching Task (which interrupts
    /// any `await` inside `assistant.load()`), then calls `unload()` so the
    /// MLX container + GPU cache are flushed cleanly. The downloader is
    /// stopped by the cancelled Task — HubApi watches its parent Task's
    /// cancellation flag and aborts its URLSession download.
    private func cancelAssistantLoad() {
        HapticManager.impact(.medium)
        assistantLoadTask?.cancel()
        assistantLoadTask = nil
        assistantWatchdog?.cancel(); assistantWatchdog = nil
        assistantLoadStarting = false
        assistant.unload()
        ToastCenter.shared.info("Stopped loading \(assistant.activeModel.displayName)")
    }
    private func loadVision() {
        HapticManager.impact(.medium)
        visionLoadStarting = true
        if LocalModelRegistry.isDefaultVisionSelection(
            LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        ) {
            visionLoadTask = Task {
                await fastVLM.load()
                await MainActor.run {
                    visionLoadStarting = false
                    visionLoadTask = nil
                    visionWatchdog?.cancel(); visionWatchdog = nil
                }
            }
        } else {
            let repoID = LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
            visionLoadTask = Task {
                await vision.switchTo(repoID: repoID)
                await MainActor.run {
                    visionLoadStarting = false
                    visionLoadTask = nil
                    visionWatchdog?.cancel(); visionWatchdog = nil
                }
            }
        }
        visionWatchdog = armLoadWatchdog(stillLoading: { visionLoadTask != nil }) {
            cancelVisionLoad()
            ToastCenter.shared.error("Load timed out",
                detail: "\(visionDisplayName) took too long. Check your connection or pick a smaller model.")
        }
    }
    private func unloadVision() {
        HapticManager.impact(.light)
        if LocalModelRegistry.isDefaultVisionSelection(
            LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        ) {
            fastVLM.unload()
        } else {
            vision.unload()
        }
    }
    private func cancelVisionLoad() {
        HapticManager.impact(.medium)
        visionLoadTask?.cancel()
        visionLoadTask = nil
        visionWatchdog?.cancel(); visionWatchdog = nil
        visionLoadStarting = false
        if LocalModelRegistry.isDefaultVisionSelection(
            LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        ) {
            fastVLM.unload()
        } else {
            vision.unload()
        }
        ToastCenter.shared.info("Stopped loading \(visionDisplayName)")
    }

    /// Pulls a 0…1 fraction out of strings like "Downloading 47%" or
    /// "Preparing 12%". Returns nil for messages that haven't yet
    /// reached a numeric tick so the row falls back to an indeterminate
    /// spinner instead of a stuck-at-zero bar.
    private static func percentage(in message: String) -> Double? {
        guard let percentIdx = message.firstIndex(of: "%") else { return nil }
        let prefix = message[..<percentIdx]
        var digits = ""
        for ch in prefix.reversed() {
            if ch.isWholeNumber { digits.append(ch) } else if !digits.isEmpty { break }
        }
        digits = String(digits.reversed())
        guard let n = Int(digits), (0...100).contains(n) else { return nil }
        return Double(n) / 100.0
    }

    private var visionDisplayName: String {
        if LocalModelRegistry.isDefaultVisionSelection(
            LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        ) {
            // FastVLM ships the encoder + config + tokenizer in the bundle
            // but NOT the language-model safetensors — those are fetched
            // from HuggingFace on demand. Call out the "needs download"
            // half explicitly so users don't read "built-in" and wonder why
            // the loader sits at "not loaded" until they tap Load model.
            return LocalizationService.shared.t("FastVLM 0.5B")
        }
        let selectionID = LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        return selectionID.split(separator: "/").last.map(String.init)
            ?? selectionID
    }
    private var visionRepoID: String {
        LocalModelRegistry.isDefaultVisionSelection(
            LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        )
            ? "apple/FastVLM-MLX"
            : LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
    }

    private func activeRow(
        title: String,
        icon: String,
        modelName: String,
        modelRepoID: String,
        phase: LoadPhase,
        onLoad:   @escaping () -> Void,
        onUnload: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onSwap:   @escaping () -> Void,
        onSettings: (() -> Void)? = nil
    ) -> some View {
        let accent: Color = {
            switch icon {
            case "eye":      return T.accent     // vision
            case "waveform": return T.accent   // voice
            default:         return T.accent      // assistant
            }
        }()
        // Long-press a row name to reveal the full repo path + display
        // name in a toast. Repo IDs are middle-truncated to fit two lines,
        // which hides the variant suffix (the "-4bit", "-GGUF", etc. tail
        // that tells the user what they're actually about to run) — the
        // toast surfaces the full string without forcing a layout change.
        let fullName = "\(modelName)\n\(modelRepoID)"
        return modelCardShell(accent: accent, prominence: 0.16) {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .top, spacing: Space.s) {
                    Image(systemName: icon)
                        .font(.system(.callout, weight: .semibold))
                        .foregroundColor(accent)
                        .frame(width: Size.control, height: Size.control)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(accent.opacity(T.isDark ? 0.18 : 0.12))
                        )
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        KCaption(text: title, color: T.ink3)
                        Text(modelName)
                            .font(T.display(19, .semibold))
                            .foregroundColor(T.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(modelRepoID)
                            .font(T.mono(13))
                            .foregroundColor(T.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(title): \(modelName), \(modelRepoID)")
                    Spacer(minLength: 0)
                    if let onSettings {
                        cardIconButton(
                            systemImage: "slider.horizontal.3",
                            accessibilityLabel: loc.t("Model settings"),
                            action: onSettings
                        )
                    }
                }
                activeRowActionStrip(phase: phase,
                                     onLoad: onLoad,
                                     onUnload: onUnload,
                                     onCancel: onCancel,
                                     onSwap: onSwap)
            }
        }
        .contextMenu {
            // Long-press reveals the untruncated repo + a copy action.
            // ContextMenu doesn't render arbitrary Text, so the full name
            // goes through a disabled button — iOS shows it as a header.
            Button {} label: {
                Text(fullName)
                    .font(.system(.body, design: .monospaced))
            }
            .disabled(true)
            Button {
                UIPasteboard.general.string = modelRepoID
                HapticManager.impact(.light)
                ToastCenter.shared.info("Repo ID copied")
            } label: {
                Label("Copy repo ID", systemImage: "doc.on.doc")
            }
        }
    }

    /// Bottom strip of the active row. Switches between:
    ///   • Load model + Swap            (unloaded)
    ///   • Progress bar with % + msg    (loading)
    ///   • Unload + Swap                (ready)
    ///   • Error message + Retry + Swap (failed)
    @ViewBuilder
    private func activeRowActionStrip(
        phase: LoadPhase,
        onLoad:   @escaping () -> Void,
        onUnload: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onSwap:   @escaping () -> Void
    ) -> some View {
        switch phase {
        case .unloaded:
            HStack(spacing: Space.xs) {
                cardButton(label: loc.t("Load"), kind: .primary, action: onLoad)
                cardButton(label: loc.t("Swap"), kind: .ghost, action: onSwap)
                Spacer(minLength: 0)
            }
        case .loading(let progress, let msg):
            VStack(alignment: .leading, spacing: Space.xs) {
                if let p = progress {
                    ProgressView(value: p)
                        .tint(T.accent)
                        .progressViewStyle(.linear)
                } else {
                    // Indeterminate — message hasn't ticked past 0% yet.
                    ProgressView()
                        .tint(T.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: Space.xs) {
                    if let p = progress {
                        Text("\(Int(p * 100))%")
                            .font(T.mono(13, .semibold))
                            .foregroundColor(T.accent)
                    }
                    Text(msg)
                        .font(T.mono(13))
                        .foregroundColor(T.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    // Stop button — interrupts the load. Some models take
                    // several minutes to download or decode; without this
                    // the user's only escape was to background the app
                    // (which doesn't actually cancel the URLSession or
                    // MLX load — it just hides them). Compact pill style
                    // so it tucks beside the % readout without dominating
                    // the row.
                    Button(action: onCancel) {
                        HStack(spacing: Space.xxs) {
                            Image(systemName: "stop.fill")
                                .font(.system(.caption2, weight: .semibold))
                            Text(loc.t("Stop"))
                                .font(T.mono(13, .semibold))
                        }
                        .foregroundColor(T.bad)
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, Space.xxs)
                        .background(
                            Capsule().fill(T.bad.opacity(0.10))
                        )
                        .overlay(
                            Capsule().stroke(T.bad.opacity(0.35), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop loading")
                }
            }
        case .ready:
            HStack(spacing: Space.xs) {
                cardButton(label: loc.t("Unload"), kind: .secondary, action: onUnload)
                cardButton(label: loc.t("Swap"),   kind: .ghost, action: onSwap)
                Spacer(minLength: 0)
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(msg)
                    .font(T.mono(13))
                    .foregroundColor(T.bad)
                    .lineLimit(3)
                HStack(spacing: Space.xs) {
                    cardButton(label: loc.t("Retry"), kind: .primary, action: onLoad)
                    cardButton(label: loc.t("Swap"),  kind: .ghost, action: onSwap)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Installing section
    //
    // MARK: - Installed section

    private var installedSection: some View {
        let installed = center.models.filter { $0.isReady }
        return VStack(spacing: Space.m) {
            if installed.isEmpty {
                emptyState(
                    icon: "tray",
                    title: loc.t("No models installed yet"),
                    subtitle: loc.t("Open Catalog to download one.")
                )
            } else {
                // Grouped under a header per category so each model sits with
                // its own kind (Assistants / Vision / Image generation / Voice)
                // rather than in one undifferentiated list.
                ForEach(Self.categoryOrder, id: \.self) { category in
                    let group = installed.filter { $0.category == category }
                    if !group.isEmpty {
                        VStack(spacing: Space.s) {
                            categorySectionHeader(category)
                            ForEach(group) { model in
                                if model.isRequired {
                                    // Required models (e.g. FastVLM) can't be
                                    // deleted, so swipe would mislead.
                                    installedRow(model)
                                } else {
                                    SwipeToDeleteContainer(
                                        onDelete: { pendingDelete = model }
                                    ) {
                                        installedRow(model)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            importLocalRow
            cleanupRow
        }
        .sheet(isPresented: $showImportPicker) {
            LocalModelDocumentPicker(
                onPick: { url in
                    showImportPicker = false
                    Task { await importLocalModel(at: url) }
                },
                onCancel: { showImportPicker = false }
            )
        }
        .alert("Import failed",
               isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
               )) {
            Button(loc.t("OK"), role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert(loc.t("Clean up partial downloads?"),
               isPresented: Binding(
                get: { pendingCleanupBytes != nil },
                set: { if !$0 { pendingCleanupBytes = nil } }
               )) {
            Button(loc.t("Cancel"), role: .cancel) { pendingCleanupBytes = nil }
            Button(loc.t("Clean up"), role: .destructive) {
                let freed = center.cleanupOrphanedDownloads()
                center.refreshAllStates()
                HapticManager.impact(.medium)
                if freed > 0 {
                    ToastCenter.shared.success(
                        loc.t("Freed up space"),
                        detail: freed.formattedBytes
                    )
                }
                pendingCleanupBytes = nil
            }
        } message: {
            Text(loc.t("This removes leftover files from downloads that were cancelled or failed partway. Installed and in-progress models are not affected."))
        }
    }

    /// Surfaces leftover bytes from cancelled/failed downloads and offers a
    /// one-tap reclaim. Hidden when there's nothing to clean. These folders
    /// never reach `.ready`, so they're otherwise invisible in the catalog
    /// and can silently grow to many GB.
    @ViewBuilder
    private var cleanupRow: some View {
        let orphanBytes = center.orphanedDownloadBytes
        if orphanBytes > 0 {
            Button {
                pendingCleanupBytes = orphanBytes
                HapticManager.impact(.light)
            } label: {
                modelCardShell(accent: T.warn, prominence: 0.08, padding: Space.cardPadding) {
                    HStack(spacing: Space.s) {
                        Image(systemName: "trash.slash")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundColor(T.warn)
                            .frame(width: Size.control, height: Size.control)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                    .fill(T.warn.opacity(T.isDark ? 0.16 : 0.10))
                            )
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            KCaption(text: "Reclaim space", color: T.warn)
                            Text("Clean up partial downloads")
                                .font(T.sans(14, .semibold))
                                .foregroundColor(T.ink)
                            Text("\(orphanBytes.formattedBytes) from cancelled or failed downloads")
                                .font(T.mono(13))
                                .foregroundColor(T.ink3)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Text(orphanBytes.formattedBytes)
                            .font(T.mono(13, .semibold))
                            .foregroundColor(T.warn)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// "Import .mlx folder" affordance under the installed list. Wraps the
    /// existing LocalModelImportService — points the document picker at
    /// the user's Files app, then registers the imported folder into the
    /// catalog so it appears in the Installed list immediately.
    private var importLocalRow: some View {
        Button {
            showImportPicker = true
            HapticManager.impact(.light)
        } label: {
            modelCardShell(accent: T.accent, prominence: 0.08, padding: Space.cardPadding) {
                HStack(spacing: Space.s) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundColor(T.accent)
                        .frame(width: Size.control, height: Size.control)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(T.accentSoft)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .stroke(T.accent.opacity(0.35),
                                        style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        )
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        KCaption(text: "Import local model", color: T.accent)
                        Text("Import a model from Files")
                            .font(T.sans(14, .semibold))
                            .foregroundColor(T.ink)
                        Text("Add an MLX folder with `config.json` and weights, then surface it in Installed immediately.")
                            .font(T.mono(13))
                            .foregroundColor(T.ink3)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundColor(T.ink3)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func importLocalModel(at url: URL) async {
        do {
            let repoID = try await LocalModelImportService.shared.importModel(from: url)
            await MainActor.run {
                center.refreshAllStates()
                isLibrary = true
                filterAllCategories = true
                searchText = ""
                ToastCenter.shared.success("Model imported",
                                            detail: repoID)
                HapticManager.impact(.medium)
            }
        } catch {
            await MainActor.run {
                importError = error.localizedDescription
            }
        }
    }

    private func installedRow(
        _ model: DownloadableModel,
        activationCategory: DownloadableModel.Category? = nil
    ) -> some View {
        let role = activationCategory ?? model.category
        let selected = isActiveModel(model, as: role)
        let loaded: Bool = {
            switch role {
            case .assistant: return (assistant.state == .ready || assistant.state == .generating) && assistant.activeModel.repoID == model.sourceRepoID
            case .vlm: guard selected else { return false }; if case .ready = visionLoadPhase { return true }; return false
            case .voice: guard selected else { return false }; if case .ready = voiceLoadPhase { return true }; return false
            case .imageGen: return false
            }
        }()
        return ModelsCompactRow(
            name: model.displayName,
            subtitle: loc.t(sectionFor(role).rawValue) + " · " + model.sizeLabel,
            status: loc.t(loaded ? "Loaded" : selected ? "Selected" : "Installed"),
            runtime: LocalModelRegistry.descriptor(for: model).runtime,
            actionTitle: loc.t("Details"),
            action: { details = .model(model, role) }
        )
        .accessibilityIdentifier("models.installed.\(model.id)")
    }

    @ViewBuilder
    private func installedDetailRow(
        _ model: DownloadableModel,
        activationCategory: DownloadableModel.Category? = nil
    ) -> some View {
        // Unified active-state check across Installed + Catalog rows.
        // Previously the Installed row had inline logic that handled
        // assistant + VLM but not voice; voice models stayed badge-less
        // on Installed even when they were the user's active TTS
        // engine. Funnelling through `isActiveModel(_:)` keeps both
        // tabs consistent.
        let roleCategory = activationCategory ?? model.category
        let isActive = isActiveModel(model, as: roleCategory)
        modelCardShell(accent: accentColor(for: model), prominence: isActive ? 0.18 : 0.10) {
            VStack(alignment: .leading, spacing: Space.m) {
                detailHeaderLayout {
                    categoryGlyph(roleCategory)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(alignment: .top, spacing: Space.xs) {
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                KCaption(text: categoryEyebrow(roleCategory), color: T.ink3)
                                Text(model.displayName)
                                    .font(T.display(18, .semibold))
                                    .foregroundColor(T.ink)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                                    if isActive {
                                KActivePinkBadge(
                                    roleCategory == .assistant ? "DEFAULT" : "ACTIVE"
                                )
                            }
                        }
                        Text(LocalizedStringKey(model.subtitle))
                            .font(T.sans(13))
                            .foregroundColor(T.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let description = model.longDescription {
                            Text(LocalizedStringKey(description))
                                .font(T.sans(14))
                                .foregroundColor(T.ink3)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !model.capabilities.isEmpty {
                            KCapabilityPillRow(capabilities: Array(model.capabilities), size: .compact)
                        }
                    }
                    VStack(alignment: .trailing, spacing: Space.xs) {
                        metricBadge(model.sizeLabel)
                        if roleCategory == .assistant {
                            cardIconButton(
                                systemImage: "slider.horizontal.3",
                                accessibilityLabel: loc.t("Model settings")
                            ) {
                                presentAfterDetails { assistantSettingsTarget = settingsTarget(for: model) }
                            }
                        }
                    }
                }
                detailActionsLayout {
                    if !isActive, canSetActive(model, as: roleCategory) {
                        cardButton(
                            label: loc.t(
                                roleCategory == .assistant
                                    ? "Set as default"
                                    : "Set as active"
                            ),
                            kind: .primary
                        ) {
                            setActive(model, as: roleCategory)
                        }
                    } else if model.category == .voice && supportedVoiceEngine(for: model) == nil {
                        if isSpeechToText(model) {
                            // Whisper & co. are speech-to-text (dictation / voice
                            // conversation), not a TTS voice — "ready", not a warning.
                            Text(loc.t("Speech-to-text · ready"))
                                .font(T.mono(13, .semibold))
                                .foregroundColor(T.good)
                                .padding(.horizontal, Space.s)
                                .padding(.vertical, Space.xs)
                                .background(Capsule().fill(T.good.opacity(0.12)))
                                .overlay(Capsule().stroke(T.good.opacity(0.30), lineWidth: 0.5))
                        } else {
                            Text(loc.t("No in-app voice engine for this repo yet"))
                                .font(T.mono(13, .semibold))
                                .foregroundColor(T.warn)
                                .padding(.horizontal, Space.s)
                                .padding(.vertical, Space.xs)
                                .background(Capsule().fill(T.warn.opacity(0.10)))
                                .overlay(Capsule().stroke(T.warn.opacity(0.25), lineWidth: 0.5))
                        }
                    }
                    if model.downloader != nil {
                        cardButton(label: loc.t("Export to Files"), kind: .secondary) {
                            presentAfterDetails { exportingModel = model }
                            HapticManager.impact(.light)
                        }
                    }
                    if !model.isRequired {
                        cardButton(label: loc.t("Delete model"), kind: .destructive) {
                            presentAfterDetails { pendingDelete = model }
                        }
                    }
                    if let docURL = model.docURL, let url = URL(string: docURL) {
                        cardIconButton(
                            systemImage: "arrow.up.right",
                            accessibilityLabel: loc.t("Open on HuggingFace")
                        ) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
        }
    }

    /// True when the user has selected this catalog entry as the active
    /// default for its role. Mirrors the same comparison logic used in
    /// `installedRow` so the "ACTIVE" badge surfaces consistently
    /// across Installed and Catalog tabs. Three id shapes have to be
    /// reconciled here: bare preset id, `downloaded:author/name`, and
    /// `imported:local/name` — only the unprefixed tail compares
    /// against the catalog's bare `model.id`.
    private func settingsTarget(
        for model: DownloadableModel
    ) -> AssistantModelSettingsTarget {
        let repositoryID = model.sourceRepoID.isEmpty
            ? model.subtitle
            : model.sourceRepoID
        let preset = AssistantModelCatalog.presets.first {
            $0.repoID.caseInsensitiveCompare(repositoryID) == .orderedSame
                || $0.id == model.id
        }
        let inferredCapabilities = ModelCapability.inferred(
            repoID: repositoryID,
            tags: model.capabilities.map(\.rawValue)
        )
        return AssistantModelSettingsTarget(
            displayName: model.displayName,
            repositoryID: repositoryID,
            supportsThinking: preset?.supportsThinking == true
                || model.capabilities.contains(.thinking)
                || inferredCapabilities.contains(.thinking)
        )
    }

    private func isActiveModel(
        _ model: DownloadableModel,
        as activationCategory: DownloadableModel.Category? = nil
    ) -> Bool {
        switch activationCategory ?? model.category {
        case .assistant:
            let currentSelection = LocalModelRegistry.unwrapAssistantSelectionID(settings.assistantModelID)
            return currentSelection == model.id || currentSelection == model.sourceRepoID
        case .vlm:
            // FastVLM default = empty cameraVisualModelID; for all
            // others compare against the subtitle (which is the
            // repoID for VLM rows in the catalog).
            let currentSelection = LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
            if model.id == LocalModelRegistry.defaultVisionSelectionID {
                return LocalModelRegistry.isDefaultVisionSelection(currentSelection)
            }
            return currentSelection == model.sourceRepoID
                || currentSelection == model.subtitle
                || currentSelection == model.id
        case .imageGen:
            // No persistent "active" image model — generation picks one per run.
            return false
        case .voice:
            let engine = VoiceEngineKind(rawValue: settings.voiceEngine) ?? .appleSystem
            if let variant = KittenVariant(rawValue: model.id) {
                return engine == .kittenTTS
                    && VoiceSettingsStore.shared.selectedKittenVariant == variant
                    && voiceSvc.kittenState == .ready
            }
            if model.id.hasPrefix("kokoro") {
                return engine == .kokoro && voiceSvc.kokoroState == .ready
            }
            return false
        }
    }

    private func setActive(
        _ model: DownloadableModel,
        as activationCategory: DownloadableModel.Category? = nil
    ) {
        switch activationCategory ?? model.category {
        case .assistant:
            let storedID = LocalModelRegistry.assistantSelectionID(for: model)
            AppSettings.shared.assistantModelID = storedID
            AppSettings.shared.hasPickedAssistantModel = true
            ToastCenter.shared.success(
                loc.t("Default model updated"),
                detail: "\(model.displayName) will be used for new chats."
            )
        case .vlm:
            let selectionID = model.id == LocalModelRegistry.defaultVisionSelectionID
                ? LocalModelRegistry.defaultVisionSelectionID
                : model.sourceRepoID
            // Use the same pre-warm-and-commit path as the Lens picker. The old
            // direct settings write persisted Gemma before proving it could
            // load, so Lens retried the unsafe model on every visit.
            Task { @MainActor in
                if await VisualModelPickerView.applySelection(selectionID) {
                    ToastCenter.shared.info(loc.t("Set as active"),
                                             detail: model.displayName)
                }
            }
        case .voice:
            if let variant = KittenVariant(rawValue: model.id) {
                Task { @MainActor in
                    do {
                        try await voiceSvc.activateAndTestKittenVariant(variant)
                        ToastCenter.shared.success("Set as active", detail: "\(model.displayName) produced audio")
                    } catch {
                        ToastCenter.shared.error("Voice test failed", detail: error.localizedDescription)
                    }
                }
                return
            }
            guard let engine = supportedVoiceEngine(for: model) else {
                ToastCenter.shared.info(
                    "Voice model downloaded",
                    detail: "This repo is stored locally, but iOS Local LLM can only switch between Apple System Voice, KittenTTS, and Kokoro right now."
                )
                return
            }
            AppSettings.shared.voiceEngine = engine.rawValue
            ToastCenter.shared.info(loc.t("Set as active"),
                                     detail: "\(model.displayName) · \(engine.shortName)")
        case .imageGen:
            // Not activatable as a role; the Images tab drives generation.
            ToastCenter.shared.info(
                "Image-generation model",
                detail: "Open the Images tab to generate with on-device diffusion models."
            )
            return
        }
        HapticManager.impact(.medium)
    }

    // MARK: - Images section
    //
    // On-device text-to-image. These models live in ImageGenerationService
    // (not ModelDownloadCenter) because they load through the MLX
    // StableDiffusion library rather than the LLM/VLM/voice runtimes. The
    // section lists the supported models with their install state and opens
    // the full generator sheet.

    private var imagesSection: some View {
        VStack(spacing: Space.s) {
            modelCardShell(accent: T.accent, prominence: 0.16) {
                HStack(alignment: .center, spacing: Space.m) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(.body, weight: .semibold))
                        .foregroundColor(T.accent)
                        .frame(width: Size.control, height: Size.control)
                        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .fill(T.accentSoft))
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        KCaption(text: "Text to image", color: T.accent)
                        Text("Generate images on-device")
                            .font(T.display(18, .semibold))
                            .foregroundColor(T.ink)
                        Text("SD / SDXL diffusion via MLX. FLUX is too large for iOS memory.")
                            .font(T.mono(13))
                            .foregroundColor(T.ink3)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }

            ForEach(ImageGenerationService.catalog) { m in
                imageModelRow(m)
            }

            Button {
                showImageGen = true
                HapticManager.impact(.medium)
            } label: {
                HStack(spacing: Space.s) {
                    Image(systemName: "sparkles")
                    Text(loc.t("Open generator"))
                }
                .font(T.display(16, .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.m)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(T.roseHi))
            }
            .buttonStyle(.plain)
        }
    }

    private func imageModelRow(_ model: ImageGenerationService.Model) -> some View {
        ModelsCompactRow(
            name: model.displayName,
            subtitle: loc.t("Image") + " · " + model.sizeLabel,
            status: loc.t(imageGen.isInstalled(model) ? "Installed" : "Available to download"),
            runtime: .mlx,
            actionTitle: loc.t("Model details"),
            action: { details = .image(model) }
        )
        .accessibilityIdentifier("models.image.\(model.id)")
    }

    @ViewBuilder
    private func imageDetailRow(_ m: ImageGenerationService.Model) -> some View {
        ImageGenerationModelRow(model: m)
    }

    // MARK: - Catalog section
    //
    // Layout language (matches the Choose-a-Model spec):
    //   1. "Featured" eyebrow with 2–3 hero models — anything tagged
    //      .recommended or .best.
    //   2. Per-family groups, each with a header card (vendor thumb +
    //      family name + capability pills + "N models · M downloaded")
    //      followed by the variants as the existing rich cards
    //      (progress / download / retry inline).
    //
    // The existing `catalogRow(_:)` still renders every individual
    // model — we just present them in a tighter hierarchy than the
    // flat list this replaced.

    /// Curated downloadable models — even the ones not yet on disk.
    /// Cards expose download / progress / pause / retry inline.
    private var catalogSection: some View {
        // Lazy because the catalog can grow to 10-20 family groups (LLM +
        // VLM + voice vendors) with multiple variants each. Realising 30-50
        // catalogRow views eagerly on every parent re-render was a
        // measurable scroll-stutter source.
        LazyVStack(spacing: Space.m) {
            if !featuredModels.isEmpty {
                featuredBlock
            }
            // Family groups, bucketed under a per-category header so the
            // curated catalog reads the same way as Installed / Active.
            ForEach(Self.categoryOrder, id: \.self) { category in
                let groups = familyGroups.filter {
                    ($0.models.first?.category ?? .assistant) == category
                }
                if !groups.isEmpty {
                    categorySectionHeader(category)
                    ForEach(groups, id: \.id) { group in
                        familyBlock(group)
                    }
                }
            }
        }
    }

    // MARK: - Family grouping

    /// Models we surface in the "Featured" block at top of Catalog.
    /// Order: .recommended > .best > .newRelease. Each model appears
    /// once. Capped at 3 so the block stays scannable.
    private var featuredModels: [DownloadableModel] {
        let priority: [ModelCapability] = [.recommended, .best, .newRelease]
        var seen = Set<String>()
        var out: [DownloadableModel] = []
        for cap in priority {
            for m in center.models where m.capabilities.contains(cap) {
                if seen.insert(m.id).inserted { out.append(m) }
                if out.count >= 3 { return out }
            }
        }
        return out
    }

    @MainActor
    private struct FamilyGroup: Identifiable {
        let id: String          // familyID
        let displayName: String
        let vendor: ModelVendor
        let models: [DownloadableModel]
        // `isReady` reads MainActor-isolated download state, so this
        // computed prop has to be MainActor too. View body evaluation
        // is already on MainActor, so the @MainActor on the struct
        // costs nothing at call sites.
        var downloadedCount: Int { models.filter { $0.isReady }.count }
        /// Union of capabilities across all variants — what the family
        /// card displays. Strip .gated / .recommended / .best since
        /// those are individual-variant signals; the user wants to see
        /// "Vision · Thinking" on the family row, not noise.
        var displayCapabilities: Set<ModelCapability> {
            var caps = models.reduce(into: Set<ModelCapability>()) { $0.formUnion($1.capabilities) }
            caps.remove(.recommended)
            caps.remove(.best)
            caps.remove(.newRelease)
            return caps
        }
        var anyGated: Bool {
            models.contains(where: { $0.capabilities.contains(.gated) })
        }
        /// First non-nil long description across the variants — used as
        /// the family card subtitle.
        var description: String? {
            models.compactMap { $0.longDescription }.first
        }
    }

    /// Models grouped by familyID. Preserves insertion order (catalog
    /// build order) within each group; groups themselves are emitted
    /// in first-seen order — which means assistant LLMs land first,
    /// then VLMs, then voice models.
    private var familyGroups: [FamilyGroup] {
        var order: [String] = []
        var bins: [String: [DownloadableModel]] = [:]
        for m in center.models {
            if bins[m.familyID] == nil {
                order.append(m.familyID)
                bins[m.familyID] = []
            }
            bins[m.familyID]?.append(m)
        }
        return order.map { fid in
            let models = bins[fid] ?? []
            return FamilyGroup(
                id: fid,
                displayName: ModelFamily.displayName(forID: fid),
                vendor: models.first?.vendor ?? .generic,
                models: models
            )
        }
    }

    // MARK: - Featured block

    private var featuredBlock: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Image(systemName: "sparkles")
                    .font(.system(.caption2))
                    .foregroundColor(T.accent)
                KCaption(text: "FEATURED")
                Rectangle().fill(T.rule).frame(height: 1)
            }
            VStack(spacing: Space.s) {
                ForEach(featuredModels) { model in
                    catalogRow(model)
                }
            }
        }
    }

    // MARK: - Family block

    @ViewBuilder
    private func familyBlock(_ group: FamilyGroup) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            familyHeader(group)
            VStack(spacing: Space.s) {
                ForEach(group.models) { model in
                    catalogRow(model)
                }
            }
        }
    }

    @ViewBuilder
    private func familyHeader(_ group: FamilyGroup) -> some View {
        modelCardShell(accent: groupAccent(group), prominence: 0.11, padding: Space.cardPadding) {
            HStack(alignment: .top, spacing: Space.m) {
                KVendorThumb(vendor: group.vendor, size: .card)
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.s) {
                        Text(group.displayName)
                            .font(T.display(18, .semibold))
                            .foregroundColor(T.ink)
                        if group.anyGated {
                            Image(systemName: "lock.fill")
                                .font(.system(.caption2))
                                .foregroundColor(ModelCapability.gated.tint)
                        }
                        Spacer(minLength: 0)
                        metricBadge("\(group.models.count) item\(group.models.count == 1 ? "" : "s")")
                    }
                    if let description = group.description {
                        Text(LocalizedStringKey(description))
                            .font(T.mono(13))
                            .foregroundColor(T.ink3)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: Space.s) {
                        statusPill(
                            text: group.downloadedCount > 0
                                ? "\(group.downloadedCount) downloaded"
                                : "catalog family",
                            color: group.downloadedCount > 0 ? T.good : T.ink3
                        )
                        if !group.displayCapabilities.isEmpty {
                            KCapabilityPillRow(
                                capabilities: Array(group.displayCapabilities),
                                size: .compact
                            )
                        }
                    }
                }
            }
        }
    }

    private func catalogStatus(_ model: DownloadableModel) -> String {
        switch model.state {
        case .ready: return loc.t("Installed")
        case .enumerating: return loc.t("Preparing download…")
        case .downloading: return loc.t("Downloading") + " · " + model.progress.formatted(.percent.precision(.fractionLength(0)))
        case .failed: return loc.t("Download needs attention")
        case .idle: return loc.t(model.isPaused ? "Paused" : "Available to download")
        }
    }

    private func catalogRow(
        _ model: DownloadableModel,
        activationCategory: DownloadableModel.Category? = nil
    ) -> some View {
        ModelsCompactRow(
            name: model.displayName,
            subtitle: loc.t(sectionFor(activationCategory ?? model.category).rawValue) + " · " + model.sizeLabel,
            status: catalogStatus(model),
            runtime: LocalModelRegistry.descriptor(for: model).runtime,
            actionTitle: loc.t("Review compatibility and download options"),
            action: { details = .model(model, activationCategory ?? model.category) }
        )
        .accessibilityIdentifier("models.catalog.\(model.id)")
    }

    @ViewBuilder
    private func catalogDetailRow(
        _ model: DownloadableModel,
        activationCategory: DownloadableModel.Category? = nil
    ) -> some View {
        let roleCategory = activationCategory ?? model.category
        let active = isActiveModel(model, as: roleCategory)
        modelCardShell(accent: accentColor(for: model),
                       prominence: active ? 0.20 : (model.isReady ? 0.16 : 0.09)) {
        VStack(alignment: .leading, spacing: Space.m) {
            detailHeaderLayout {
                // Unified category glyph (pink-soft tile) — matches the
                // Active / Installed / Installing rows so every model
                // card reads the same regardless of which tab it lives
                // on. Vendor identity still surfaces on the family
                // header above the group.
                categoryGlyph(roleCategory)
                VStack(alignment: .leading, spacing: Space.xs) {
                    KCaption(text: categoryEyebrow(roleCategory), color: T.ink3)
                    HStack(alignment: .top, spacing: Space.xs) {
                        Text(model.displayName)
                            .font(T.display(18, .semibold))
                            .foregroundColor(T.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if active {
                            // Show the same pink ACTIVE badge here that
                            // the Installed list uses. Previously the
                            // Catalog gave no indication which entry
                            // was the user-selected default; users
                            // would tap "Set as active" on a model that
                            // was already active and see a no-op toast.
                            KActivePinkBadge(
                                roleCategory == .assistant ? "DEFAULT" : "ACTIVE"
                            )
                        }
                        if model.isRequired {
                            Text("required")
                                .font(T.mono(13, .semibold))
                                .foregroundColor(T.warn)
                                .padding(.horizontal, Space.xs).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(T.warn.opacity(0.15)))
                        }
                    }
                    Text(LocalizedStringKey(model.subtitle))
                        .font(T.mono(13))
                        .foregroundColor(T.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let description = model.longDescription {
                        Text(LocalizedStringKey(description))
                            .font(T.mono(13))
                            .foregroundColor(T.ink3)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.capabilities.isEmpty {
                        KCapabilityPillRow(
                            capabilities: Array(model.capabilities),
                            size: .compact
                        )
                        .padding(.top, Space.hair)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: Space.xs) {
                    metricBadge(model.sizeLabel)
                    if let compatibility = model.platformCompatibility {
                        platformCompatibilityBadge(compatibility)
                    }
                    if model.platformCompatibility?.supportsCurrentPlatform ?? true {
                        fitBadge(forFootprint: modelFootprint(model))
                    }
                    if roleCategory == .assistant {
                        cardIconButton(
                            systemImage: "slider.horizontal.3",
                            accessibilityLabel: loc.t("Model settings")
                        ) {
                            presentAfterDetails { assistantSettingsTarget = settingsTarget(for: model) }
                        }
                    }
                }
            }
            // Progress / status row
            switch model.state {
            case .downloading, .enumerating:
                progressStrip(progress: model.progress,
                              downloaded: model.downloadedBytes,
                              total: model.totalBytes,
                              file: model.currentFile)
                detailActionsLayout {
                    cardButton(label: loc.t("Pause"), kind: .secondary) {
                        HapticManager.impact(.light)
                        model.pause()
                    }
                    // Cancelling deletes what was downloaded, so it goes
                    // through the same confirmation as deleting a model.
                    cardButton(label: loc.t("Cancel download"), kind: .destructive) {
                        presentAfterDetails { pendingDelete = model }
                    }
                }
            case .ready:
                detailActionsLayout {
                    statusPill(text: loc.t("ready"), color: T.good)
                    // The Catalog row used to dead-end at "ready" with
                    // only a Delete button — the user had to navigate
                    // to Installed to activate the model. Showing
                    // "Set as active" here turns Catalog into a
                    // one-tap activation surface for any downloaded
                    // entry, which is the natural place to do it
                    // when the user is already browsing the catalog.
                    if !active, canSetActive(model, as: roleCategory) {
                        cardButton(
                            label: loc.t(
                                roleCategory == .assistant
                                    ? "Set as default"
                                    : "Set as active"
                            ),
                            kind: .primary
                        ) {
                            setActive(model, as: roleCategory)
                        }
                    } else if model.category == .voice && supportedVoiceEngine(for: model) == nil {
                        Text("Stored only - runtime not implemented")
                            .font(T.mono(13, .semibold))
                            .foregroundColor(T.warn)
                            .padding(.horizontal, Space.s)
                            .padding(.vertical, Space.xs)
                            .background(Capsule().fill(T.warn.opacity(0.10)))
                            .overlay(Capsule().stroke(T.warn.opacity(0.25), lineWidth: 0.5))
                    }
                    if !model.isRequired {
                        cardButton(label: loc.t("Delete model"), kind: .destructive) {
                            presentAfterDetails { pendingDelete = model }
                        }
                    }
                }
            case .failed(let msg):
                // Auth-specific failures get an inline "Set Token" CTA
                // instead of the generic Retry — the user can't fix
                // the underlying problem without entering a token, so
                // showing only Retry is misleading.
                let authFail = model.lastFailureKind == .tokenRequired
                            || model.lastFailureKind == .tokenRejected
                HStack(spacing: Space.xs) {
                    if authFail {
                        Image(systemName: "lock.fill")
                            .font(.system(.caption2))
                            .foregroundColor(ModelCapability.gated.tint)
                    }
                    Text(msg)
                        .font(T.mono(13))
                        .foregroundColor(authFail ? T.ink2 : T.bad)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                detailActionsLayout {
                    if authFail {
                        cardButton(label: loc.t("Set Token"), kind: .primary) {
                            presentAfterDetails { showingHFTokenSheet = true }
                        }
                        cardButton(label: loc.t("Retry"), kind: .secondary) {
                            HapticManager.impact(.medium)
                            model.start()
                        }
                    } else {
                        cardButton(label: loc.t("Retry"), kind: .primary) {
                            HapticManager.impact(.medium)
                            model.start()
                        }
                    }
                }
            case .idle:
                detailActionsLayout {
                    if model.platformCompatibility?.supportsCurrentPlatform ?? true {
                        cardButton(label: loc.t(model.isPaused ? "Resume" : "Download"), kind: .primary) {
                            HapticManager.impact(.medium)
                            model.start()
                        }
                        if model.isPaused {
                            cardButton(label: loc.t("Cancel download"), kind: .destructive) {
                                presentAfterDetails { pendingDelete = model }
                            }
                        }
                    } else if let compatibility = model.platformCompatibility {
                        statusPill(text: compatibility.label, color: T.bad)
                    }
                    if let docURL = model.docURL, let url = URL(string: docURL) {
                        cardButton(label: loc.t("Open on HuggingFace"), kind: .secondary) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
        }
        }
    }

    @ViewBuilder
    private func progressStrip(progress: Double, downloaded: Int64, total: Int64, file: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            ProgressView(value: progress)
                .tint(T.accent)
                .progressViewStyle(.linear)
            HStack(spacing: Space.xs) {
                Text("\(Int(progress * 100))%")
                    .font(T.mono(13, .semibold))
                    .foregroundColor(T.accent)
                if total > 0 {
                    Text("\(downloaded.formattedBytes) / \(total.formattedBytes)")
                        .font(T.mono(13))
                        .foregroundColor(T.ink3)
                }
                Spacer(minLength: 0)
                if !file.isEmpty {
                    Text(file)
                        .font(T.mono(13))
                        .foregroundColor(T.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - View helpers

    private var activeLoadedCount: Int {
        var count = 0
        switch assistant.state {
        case .ready, .generating: count += 1
        default: break
        }
        if LocalModelRegistry.isDefaultVisionSelection(
            LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        ) {
            if fastVLM.componentStatus.canGenerate { count += 1 }
        } else {
            switch vision.state {
            case .ready, .generating: count += 1
            default: break
            }
        }
        return count
    }

    /// Per-category brand tint — the single source for colour-coding cards,
    /// glyphs, headers and tabs by model type. Assistant=rose, Lens=sage,
    /// Voice=violet, Image=amber.
    // Every category now tracks the SELECTED accent so the Models page matches
    // the chosen theme. Categories stay distinguishable by their SF Symbol
    // glyph (brain / eye / waveform / wand), not by a fixed off-theme hue — the
    // old sage/violet/amber tints ignored the accent and read as "doesn't match
    // the theme".
    private func categoryTint(_ category: DownloadableModel.Category) -> Color {
        T.accent
    }

    /// Soft fill paired with `categoryTint` for glyph tiles / pills.
    private func categoryTintSoft(_ category: DownloadableModel.Category) -> Color {
        T.accentSoft
    }

    private func accentColor(for model: DownloadableModel) -> Color {
        categoryTint(model.category)
    }

    private func groupAccent(_ group: FamilyGroup) -> Color {
        categoryTint(group.models.first?.category ?? .assistant)
    }

    private func sectionAccent(for section: Section) -> Color {
        categoryTint(section.category)
    }

    // MARK: - Reusable card primitives

    private enum CardButtonKind { case primary, secondary, destructive, ghost }

    @ViewBuilder
    private func modelCardShell<Content: View>(
        accent: Color,
        prominence: Double,
        padding: CGFloat = Space.cardPadding,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // Native clear glass keeps large model lists airy while the restrained
        // role tint preserves wayfinding. The same helper backs active,
        // installed, catalog, recommendation, and utility cards.
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .kClearGlass(
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous),
                tint: accent.opacity(min(0.10, prominence * 0.55)),
                fallbackFill: T.surface,
                fallbackStroke: T.rule
            )
            // Pointer-device lift (iPad cursor, Stage Manager, Vision). No-op
            // on touch — UIKit only resolves .lift for indirect pointers, so
            // it costs nothing on iPhone while keeping the iPad affordance.
            .hoverEffect(.lift)
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    @ViewBuilder
    private func metricBadge(_ text: String) -> some View {
        Text(text)
            .font(T.mono(13, .semibold))
            .foregroundColor(T.ink2)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xxs)
            .background(
                Capsule()
                    .fill(T.surface2.opacity(0.95))
            )
            .overlay(
                Capsule()
                    .stroke(T.glassBorder, lineWidth: 0.5)
            )
    }

    /// Device-fit badge — "fits" (good), "tight" (warn), "too big" (bad).
    /// Tells the user at a glance whether a download will actually load on
    /// this iPhone, using the corrected memory math in `MemoryAdvisor`.
    @ViewBuilder
    private func fitBadge(forFootprint footprint: Int64) -> some View {
        let fit = MemoryAdvisor.fit(forFootprint: footprint)
        let (color, glyph): (Color, String) = {
            switch fit {
            case .fits:  return (T.good, "checkmark.circle.fill")
            case .tight: return (T.warn, "exclamationmark.circle.fill")
            case .over:  return (T.bad,  "xmark.circle.fill")
            }
        }()
        HStack(spacing: Space.xxs) {
            Image(systemName: glyph)
                .font(.system(.caption2, weight: .semibold))
            Text(loc.t(fit.label))
                .font(T.mono(13, .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, Space.xs).padding(.vertical, Space.xxs)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.22), lineWidth: 0.5))
    }

    @ViewBuilder
    private func platformCompatibilityBadge(_ compatibility: ModelPlatformCompatibility) -> some View {
        let supported = compatibility.supportsCurrentPlatform
        let color = supported ? T.ink2 : T.bad
        HStack(spacing: Space.xxs) {
            Image(systemName: compatibility.symbol)
                .font(.system(.caption2, weight: .semibold))
            Text(LocalizedStringKey(compatibility.label))
                .font(T.mono(13, .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, Space.xs).padding(.vertical, Space.xxs)
        .background(Capsule().fill(color.opacity(0.10)))
        .overlay(Capsule().stroke(color.opacity(0.22), lineWidth: 0.5))
        .accessibilityHint(Text(LocalizedStringKey(compatibility.detail)))
    }

    /// Repo-name label that keeps versions distinguishable. The old rows
    /// middle-truncated the full `org/name` to a single line, so two variants
    /// of the same model (…-4bit vs …-GGUF vs …-Q6_K) read as identical. Here
    /// the model NAME gets two lines (the distinguishing suffix stays visible)
    /// and the org sits beneath it as a quiet secondary line.
    @ViewBuilder
    private func repoNameLabel(_ repoID: String, font: Font) -> some View {
        let parts = repoID.split(separator: "/", maxSplits: 1).map(String.init)
        let org  = parts.count == 2 ? parts[0] : nil
        let name = parts.last ?? repoID
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(font)
                .foregroundColor(T.ink)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            if let org {
                Text(org)
                    .font(T.mono(13))
                    .foregroundColor(T.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func cardButton(label: String, kind: CardButtonKind, action: @escaping () -> Void) -> some View {
        // Keep action hierarchy consistent with the library's neutral controls.
        let fg: Color = {
            switch kind {
            case .primary:     return T.bg
            case .destructive: return T.bad
            case .ghost:       return T.ink2
            case .secondary:   return T.ink
            }
        }()
        return Button(action: action) {
            Text(label)
                .font(T.sans(14, .semibold))
                .foregroundColor(fg)
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.xs)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .background(
                    Group {
                        switch kind {
                        case .primary:
                            RoundedRectangle(cornerRadius: Radius.inner)
                                .fill(T.ink)
                        case .destructive:
                            RoundedRectangle(cornerRadius: Radius.inner)
                                .fill(T.bad.opacity(0.12))
                        case .ghost:
                            // No fill — borderless text affordance.
                            Color.clear
                        case .secondary:
                            RoundedRectangle(cornerRadius: Radius.inner)
                                .fill(T.surface2)
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.inner)
                        .stroke({
                            switch kind {
                            case .primary:     return Color.clear
                            case .destructive: return T.bad.opacity(0.4)
                            case .ghost:       return Color.clear
                            case .secondary:   return T.rule
                            }
                        }(), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    /// Compact trailing external-link affordance for model cards. Keeping this
    /// icon on the far trailing edge leaves the high-frequency local actions
    /// (activate, export, delete) grouped together and restores the arrow
    /// treatment users recognized from the earlier design.
    private func cardIconButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(.caption2, weight: .semibold))
                .foregroundColor(T.ink2)
                .frame(width: Size.control, height: Size.control)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                        .fill(T.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                        .stroke(T.rule, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func statusPill(text: String, color: Color) -> some View {
        HStack(spacing: Space.xxs) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .font(T.mono(13, .semibold))
                .foregroundColor(color)
        }
        .padding(.horizontal, Space.s).padding(.vertical, Space.xxs)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(
            Capsule().stroke(color.opacity(0.16), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func categoryGlyph(_ category: DownloadableModel.Category) -> some View {
        // Unified glyph used by every card across Active / Installed /
        // Installing / Catalog tabs. Pink-soft tile + brand-accent symbol
        // — the design language for "this is a model" regardless of
        // which tab the row lives on. Vision rows swap to the sage
        // accent so users can scan chat vs. camera at a glance without
        // breaking the overall rose palette.
        let icon: String = {
            switch category {
            case .assistant: return "brain"
            case .vlm:       return "eye"
            case .voice:     return "waveform"
            case .imageGen:  return "wand.and.stars"
            }
        }()
        Image(systemName: icon)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundColor(categoryTint(category))
            .frame(width: Size.control, height: Size.control)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(categoryTintSoft(category)))
    }

    /// Eyebrow label used above the model title on every card.
    /// Mirrors the "ASSISTANT (CHAT)" / "VISION (CAMERA)" labels on the
    /// Active tab so each card across the tabs reads the same way.
    private func categoryEyebrow(_ category: DownloadableModel.Category) -> String {
        switch category {
        case .assistant: return loc.t("Assistant (chat)").uppercased()
        case .vlm:       return loc.t("Vision (camera)").uppercased()
        case .voice:     return loc.t("Voice").uppercased()
        case .imageGen:  return loc.t("Image generation").uppercased()
        }
    }

    /// Fixed display order for the per-category headers used in the Active,
    /// Installed and Catalog sections, so a model always sits under the same
    /// header regardless of which section it's viewed in.
    private static let categoryOrder: [DownloadableModel.Category] =
        [.assistant, .vlm, .imageGen, .voice]

    /// (header title, SF Symbol, tint) for a category section header.
    private func categoryHeaderMeta(_ c: DownloadableModel.Category) -> (String, String, Color) {
        switch c {
        case .assistant: return (loc.t("Assistants").uppercased(),       "brain",          categoryTint(.assistant))
        case .vlm:       return (loc.t("Vision").uppercased(),           "eye",            categoryTint(.vlm))
        case .imageGen:  return (loc.t("Image generation").uppercased(), "wand.and.stars", categoryTint(.imageGen))
        case .voice:     return (loc.t("Voice").uppercased(),            "waveform",       categoryTint(.voice))
        }
    }

    /// Thin labelled divider that heads each category group — matches the
    /// "FEATURED" eyebrow used at the top of Catalog.
    @ViewBuilder
    private func categorySectionHeader(_ category: DownloadableModel.Category) -> some View {
        let (title, glyph, tint) = categoryHeaderMeta(category)
        HStack(spacing: Space.xs) {
            Image(systemName: glyph)
                .font(.system(.caption2))
                .foregroundColor(tint)
            KCaption(text: title, color: tint)
            Rectangle().fill(T.rule).frame(height: 1)
        }
    }

    @ViewBuilder
    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        modelCardShell(accent: T.accent, prominence: 0.06, padding: Space.l) {
            VStack(spacing: Space.s) {
                Image(systemName: icon)
                    .font(.system(.title, weight: .light))
                    .foregroundColor(T.ink3)
                Text(loc.t(title))
                    .font(T.sans(14, .semibold))
                    .foregroundColor(T.ink2)
                Text(loc.t(subtitle))
                    .font(T.sans(12))
                    .foregroundColor(T.ink3)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.l)
        }
    }
}

// (Int.compactCount lives in HFSearchService.swift.)

// MARK: - Recommended setup combos

extension ModelsManagerView {

    struct ComboPick: Identifiable {
        let id = UUID()
        let role: DownloadableModel.Category
        let catalogID: String
        let name: String
        let detail: String        // e.g. "4-bit · ~2.3 GB"
        let approxRAM: Int64       // peak RAM — drives the fit badge
        let downloadBytes: Int64   // rough on-disk download size
    }

    struct ModelCombo: Identifiable {
        let id: String
        let tier: String           // Light / Medium / Heavy
        let glyph: String
        let tagline: String
        let picks: [ComboPick]
        var totalDownload: Int64 { picks.reduce(0) { $0 + $1.downloadBytes } }
    }

    /// Curated full-stack combos. RAM figures are peak working sets (what the
    /// fit badge checks against the live per-process budget); download figures
    /// are rough on-disk sizes. These mirror the per-tier recommendations:
    /// Light runs on any Pro iPhone, Medium is the sweet spot, Heavy wants 12 GB.
    static let modelCombos: [ModelCombo] = [
        ModelCombo(
            id: "light", tier: "Light", glyph: "leaf.fill",
            tagline: "Runs on any Pro iPhone with room to spare. Fast, low-RAM.",
            picks: [
                ComboPick(role: .assistant, catalogID: "qwen3-1.7b", name: "Qwen3-1.7B", detail: "4-bit · ~1.0 GB", approxRAM: 1_500_000_000, downloadBytes: 1_000_000_000),
                ComboPick(role: .vlm, catalogID: "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF", name: "SmolVLM2-500M", detail: "GGUF · fast OCR", approxRAM: 700_000_000, downloadBytes: 520_000_000),
                ComboPick(role: .voice, catalogID: "kittentts-mini", name: "KittenTTS Mini", detail: "Core ML · 8 voices", approxRAM: 700_000_000, downloadBytes: 280_000_000),
                ComboPick(role: .imageGen, catalogID: "stabilityai/sd-turbo", name: "SD-Turbo", detail: "1 step · 512px", approxRAM: 2_600_000_000, downloadBytes: 5_000_000_000)
            ]
        ),
        ModelCombo(
            id: "medium", tier: "Medium", glyph: "gauge.medium",
            tagline: "The sweet spot — great quality, comfortable on 8 GB & 12 GB.",
            picks: [
                ComboPick(role: .assistant, catalogID: "qwen3-4b-2507", name: "Qwen3-4B 2507", detail: "4-bit · ~2.3 GB", approxRAM: 3_500_000_000, downloadBytes: 2_300_000_000),
                ComboPick(role: .vlm, catalogID: "mlx-community/Qwen3-VL-2B-Instruct-4bit", name: "Qwen3-VL-2B", detail: "4-bit · ~1.7 GB", approxRAM: 2_300_000_000, downloadBytes: 1_700_000_000),
                ComboPick(role: .voice, catalogID: "kokoro-82m", name: "Kokoro-82M", detail: "neural TTS", approxRAM: 400_000_000, downloadBytes: 100_000_000),
                ComboPick(role: .imageGen, catalogID: "stabilityai/stable-diffusion-2-1-base", name: "Stable Diffusion 2.1", detail: "20 steps · 512px", approxRAM: 2_600_000_000, downloadBytes: 5_200_000_000)
            ]
        ),
        ModelCombo(
            id: "heavy", tier: "Heavy", glyph: "flame.fill",
            tagline: "Best quality. Wants a 12 GB iPhone 17 Pro; tight on 8 GB.",
            picks: [
                ComboPick(role: .assistant, catalogID: "qwen3-4b-2507-8bit", name: "Qwen3-4B 2507 (8-bit)", detail: "8-bit · ~4.3 GB", approxRAM: 5_300_000_000, downloadBytes: 4_300_000_000),
                ComboPick(role: .vlm, catalogID: "mlx-community/Qwen3-VL-4B-Instruct-4bit", name: "Qwen3-VL-4B", detail: "4-bit · ~2.9 GB", approxRAM: 3_800_000_000, downloadBytes: 2_900_000_000),
                ComboPick(role: .voice, catalogID: "kokoro-82m", name: "Kokoro-82M", detail: "neural TTS", approxRAM: 400_000_000, downloadBytes: 100_000_000),
                ComboPick(role: .imageGen, catalogID: "stabilityai/sdxl-turbo", name: "SDXL-Turbo", detail: "1–4 steps · best", approxRAM: 4_200_000_000, downloadBytes: 6_900_000_000)
            ]
        )
    ]
}

/// Persistent actions remain available even when the inventory is empty or filtered.
private struct ModelsLibraryToolbar: View {
    @ObservedObject private var localization = LocalizationService.shared
    let downloadCount: Int
    let needsAttention: Bool
    let onImport: () -> Void
    let onDownloads: () -> Void
    let onStorage: () -> Void
    @Environment(\.koduTheme) private var theme

    var body: some View {
        KScreenHeader(
            title: localization.t("Models"),
            eyebrow: localization.t("Your model library")
        ) {
            HStack(spacing: Space.xxs) {
                Button(action: onImport) {
                    Label(localization.t("Import"), systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, Space.s)
                        .frame(minHeight: 44)
                        .kClearGlass(in: Capsule(), interactive: true)
                }
                .accessibilityLabel(localization.t("Import"))
                .accessibilityIdentifier("modelsImportButton")
                Menu {
                    Button(action: onDownloads) {
                        Label(localization.t("Downloads") + (downloadCount > 0 ? " (\(downloadCount))" : ""), systemImage: "arrow.down.circle")
                    }
                    .accessibilityIdentifier("models.downloads")
                    Button(action: onStorage) {
                        Label(localization.t("Storage"), systemImage: "internaldrive")
                    }
                    .accessibilityIdentifier("models.storage")
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: Size.control, height: Size.control)
                        .kClearGlass(in: Circle(), interactive: true)
                        .overlay(alignment: .topTrailing) {
                            if downloadCount > 0 || needsAttention {
                                Circle().fill(needsAttention ? theme.warn : theme.accent).frame(width: 7, height: 7)
                                    .padding(Space.xxs)
                            }
                        }
                }
                .accessibilityIdentifier("models.more")
                .accessibilityLabel(localization.t("Downloads and storage"))
                .accessibilityValue(needsAttention
                    ? localization.t("Download needs attention")
                    : downloadCount > 0 ? "\(downloadCount) " + localization.t("Downloads") : "")
            }
            .font(.body.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(theme.ink2)
        }
        .tint(theme.accent)
        .padding(.horizontal, Space.m)
        .padding(.top, Space.m)
        .padding(.bottom, Space.s)
        .background(theme.bg)
    }
}

private struct ModelsDestinationPicker: View {
    @ObservedObject private var localization = LocalizationService.shared
    @Binding var isLibrary: Bool
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        if textSize.isAccessibilitySize {
            destinations.pickerStyle(.menu)
        } else {
            destinations.pickerStyle(.segmented)
        }
    }

    private var destinations: some View {
        Picker(localization.t("Models"), selection: $isLibrary) {
            Text(localization.t("My Models")).tag(true)
            Text(localization.t("Discover")).tag(false)
        }
        .accessibilityIdentifier("modelsDestinationPicker")
    }
}

private struct ModelsCategoryFilter: View {
    @ObservedObject private var localization = LocalizationService.shared
    @Binding var selection: ModelsManagerView.Section?
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        if textSize.isAccessibilitySize {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Space.s)], alignment: .leading, spacing: Space.s) {
                filters
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) { filters }
            }
        }
    }

    @ViewBuilder private var filters: some View {
        KFilterChip(title: localization.t("All"), isSelected: selection == nil) {
            HapticManager.selection()
            selection = nil
        }
        .accessibilityIdentifier("modelsSection-All")
        ForEach(ModelsManagerView.Section.allCases) { section in
            KFilterChip(title: localization.t(section.rawValue), isSelected: selection == section) {
                HapticManager.selection()
                selection = section
            }
            .accessibilityIdentifier("modelsSection-\(section.rawValue)")
        }
    }
}

struct ModelsCompactRow: View {
    let name: String
    let subtitle: String
    let status: String
    var runtime: ModelRuntime? = nil
    let actionTitle: String
    let action: () -> Void
    @Environment(\.koduTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Space.s) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(name).font(.body.weight(.semibold)).foregroundStyle(theme.ink)
                    Text(LocalizedStringKey(subtitle)).font(.subheadline).foregroundStyle(theme.ink2)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Space.s) {
                            if let runtime { ModelRuntimeBadge(runtime: runtime) }
                            Text(LocalizedStringKey(status)).font(.subheadline).foregroundStyle(theme.ink2)
                        }
                        VStack(alignment: .leading, spacing: Space.xs) {
                            if let runtime { ModelRuntimeBadge(runtime: runtime) }
                            Text(LocalizedStringKey(status)).font(.subheadline).foregroundStyle(theme.ink2)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(theme.ink3).accessibilityHidden(true)
            }
            .padding(.vertical, Space.m)
            .padding(.horizontal, Space.xxs)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(theme.rule).frame(height: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityHint(actionTitle)
    }
}


/// One quiet, consistent label separates runtime identity from install/load status.
struct ModelRuntimeBadge: View {
    @ObservedObject private var localization = LocalizationService.shared
    let runtime: ModelRuntime
    @Environment(\.koduTheme) private var theme

    private var title: String {
        runtime.label
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.accent)
            .fontDesign(.monospaced)
            .padding(.vertical, Space.hair)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(localization.t("Runtime") + ": " + title)
    }
}
