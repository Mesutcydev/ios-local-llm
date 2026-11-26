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
    @State private var pendingImageDelete: ImageGenerationService.Model?
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
                    // A short library needs no search or filters.
                    if !isLibrary || installedItemCount > 5 {
                        searchBar
                        ModelsCategoryFilter(selection: Binding(
                            get: { filterAllCategories ? nil : selectedSection },
                            set: { section in
                                filterAllCategories = section == nil
                                if let section { selectedSection = section }
                            }
                        ))
                    }
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
                onStorage: { showStorageCleanup = true },
                onGuidedSetup: { showingGuidedSetup = true }
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
        .confirmationDialog(
            pendingImageDelete.map { loc.t("Delete model") + " · " + $0.displayName } ?? "",
            isPresented: Binding(get: { pendingImageDelete != nil }, set: { if !$0 { pendingImageDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingImageDelete
        ) { model in
            Button(loc.t("Delete"), role: .destructive) { imageGen.deleteModel(model) }
        } message: { _ in
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
                        modelDetailContent(model, role: role)
                    case let .image(model):
                        imageDetailContent(model)
                    case let .voice(entry):
                        voiceDetailContent(entry)
                    }
                }
                .padding(Space.m)
                .frame(maxWidth: AppLayout.readingWidth)
                .frame(maxWidth: .infinity)
            }
            .background(LiquidPinkBackdrop())
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

    // MARK: - Model details (App Store-style page)

    @ViewBuilder
    private func modelDetailContent(_ model: DownloadableModel, role: DownloadableModel.Category) -> some View {
        let section = sectionFor(role)
        let runtime = LocalModelRegistry.descriptor(for: model).runtime
        let active = isActiveModel(model, as: role)
        let size = ModelsCompactRow.localizedNumbers(model.sizeLabel)
        let compatible = model.platformCompatibility?.supportsCurrentPlatform ?? true
        detailHeader(
            glyph: section.glyph,
            name: model.displayName,
            subtitle: [loc.t(section.rawValue), runtime?.label, size].compactMap { $0 }.joined(separator: " · "),
            description: model.longDescription ?? model.subtitle,
            features: model.capabilities.sorted { $0.rawValue < $1.rawValue }
                .map { loc.t($0.label) }.joined(separator: " · ")
        )
        modelPrimaryAction(model, role: role, active: active)
        ModelsListCard {
            detailInfoRow(loc.t("Size"), size)
            if compatible {
                let fit = fitValue(modelFootprint(model))
                detailInfoRow(loc.t("Memory"), fit.text, valueColor: fit.color)
            }
            if let compatibility = model.platformCompatibility {
                detailInfoRow(loc.t("Runs on"), loc.t(compatibility.label),
                              valueColor: compatible ? nil : T.bad)
            }
            if let runtime { detailInfoRow(loc.t("Runtime"), runtime.label) }
            if !model.sourceRepoID.isEmpty {
                detailInfoRow(loc.t("Repository"), model.sourceRepoID, monospaced: true)
            }
        }
        ModelsListCard(dividerInset: Space.m + Size.glyph + Space.s) {
            if role == .assistant {
                detailActionRow(loc.t("Model settings"), systemImage: "slider.horizontal.3") {
                    presentAfterDetails { assistantSettingsTarget = settingsTarget(for: model) }
                }
            }
            if model.isReady, model.downloader != nil {
                detailActionRow(loc.t("Export to Files"), systemImage: "square.and.arrow.up") {
                    HapticManager.impact(.light)
                    presentAfterDetails { exportingModel = model }
                }
            }
            if let docURL = model.docURL, let url = URL(string: docURL) {
                detailActionRow(loc.t("Open on HuggingFace"), systemImage: "arrow.up.right") {
                    UIApplication.shared.open(url)
                }
            }
            if model.isReady, !model.isRequired {
                detailActionRow(loc.t("Delete model"), systemImage: "trash", role: .destructive) {
                    presentAfterDetails { pendingDelete = model }
                }
            } else if model.hasUnfinishedDownload {
                // Cancelling deletes what was downloaded: same confirmation as Delete.
                detailActionRow(loc.t("Cancel download"), systemImage: "xmark.circle", role: .destructive) {
                    presentAfterDetails { pendingDelete = model }
                }
            }
        }
    }

    /// The one thing to do next with this model, full width.
    @ViewBuilder
    private func modelPrimaryAction(_ model: DownloadableModel, role: DownloadableModel.Category, active: Bool) -> some View {
        switch model.state {
        case .idle:
            if model.platformCompatibility?.supportsCurrentPlatform ?? true {
                KPrimaryButton(
                    label: loc.t(model.isPaused ? "Resume" : "Download"),
                    systemImage: "arrow.down.circle.fill",
                    trailing: ModelsCompactRow.localizedNumbers(model.sizeLabel)
                ) {
                    HapticManager.impact(.medium)
                    model.start()
                }
            }
        case .downloading, .enumerating:
            progressStrip(progress: model.progress, downloaded: model.downloadedBytes,
                          total: model.totalBytes, file: model.currentFile)
            Button {
                HapticManager.impact(.light)
                model.pause()
            } label: {
                Text(loc.t("Pause")).frame(maxWidth: .infinity)
            }
            .glassButton()
            .controlSize(.large)
        case .ready:
            if active {
                activeLoadControl(for: sectionFor(role))
            } else if canSetActive(model, as: role) {
                KPrimaryButton(
                    label: loc.t(role == .assistant ? "Set as default" : "Set as active"),
                    systemImage: "checkmark.circle"
                ) {
                    setActive(model, as: role)
                }
            } else if model.category == .voice && supportedVoiceEngine(for: model) == nil {
                Text(loc.t(isSpeechToText(model) ? "Speech-to-text · ready" : "No in-app voice engine for this repo yet"))
                    .font(.subheadline)
                    .foregroundStyle(isSpeechToText(model) ? T.good : T.warn)
            }
        case .failed(let message):
            let needsToken = model.lastFailureKind == .tokenRequired || model.lastFailureKind == .tokenRejected
            Text(message)
                .font(.subheadline)
                .foregroundStyle(needsToken ? T.ink2 : T.bad)
                .fixedSize(horizontal: false, vertical: true)
            if needsToken {
                KPrimaryButton(label: loc.t("Set Token"), systemImage: "key.fill") {
                    presentAfterDetails { showingHFTokenSheet = true }
                }
            }
            Button {
                HapticManager.impact(.medium)
                model.start()
            } label: {
                Text(loc.t("Retry")).frame(maxWidth: .infinity)
            }
            .glassButton(prominent: !needsToken)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private func voiceDetailContent(_ entry: VoiceCatalogEntry) -> some View {
        let model = entry.legacyDownloadID.flatMap { id in center.models.first { $0.id == id } }
        let size = entry.sizeLabel.map(ModelsCompactRow.localizedNumbers)
        let active = isActiveVoiceEntry(entry)
        detailHeader(
            glyph: Section.voice.glyph,
            name: entry.name,
            subtitle: [loc.t(entry.task == .textToSpeech ? "Text to Speech" : "Speech Recognition"), size]
                .compactMap { $0 }.joined(separator: " · "),
            description: entry.summary,
            features: ""
        )
        if entry.id == "tts.apple.system" {
            if active {
                activeLoadControl(for: .voice)
            } else {
                KPrimaryButton(label: loc.t("Select"), systemImage: "checkmark.circle") {
                    VoiceSettingsStore.shared.selectEngine(.appleSystem)
                }
            }
        } else if entry.isDownloadEnabled, let model {
            switch model.state {
            case .ready:
                if let variant = KittenVariant(rawValue: entry.id) {
                    if active {
                        activeLoadControl(for: .voice)
                    } else {
                        KPrimaryButton(label: loc.t("Select & Test"), systemImage: "play.circle") {
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
                } else {
                    modelPrimaryAction(model, role: .voice, active: active)
                }
            default:
                modelPrimaryAction(model, role: .voice, active: active)
            }
        } else {
            Text(loc.t(entry.statusLabel))
                .font(.subheadline)
                .foregroundStyle(T.warn)
        }
        ModelsListCard(dividerInset: Space.m + Size.glyph + Space.s) {
            if let size { detailInfoRow(loc.t("Size"), size) }
            if let source = entry.sourceURL, let url = URL(string: source) {
                detailActionRow(loc.t("Open Project"), systemImage: "arrow.up.right") {
                    UIApplication.shared.open(url)
                }
            }
            if let model, model.isReady, !model.isRequired {
                detailActionRow(loc.t("Delete model"), systemImage: "trash", role: .destructive) {
                    presentAfterDetails { pendingDelete = model }
                }
            } else if let model, model.hasUnfinishedDownload {
                detailActionRow(loc.t("Cancel download"), systemImage: "xmark.circle", role: .destructive) {
                    presentAfterDetails { pendingDelete = model }
                }
            }
        }
        .accessibilityIdentifier("models.voice.details.\(entry.id)")
    }

    @ViewBuilder
    private func imageDetailContent(_ model: ImageGenerationService.Model) -> some View {
        let size = ModelsCompactRow.localizedNumbers(model.sizeLabel)
        let installed = imageGen.isInstalled(model)
        detailHeader(
            glyph: Section.image.glyph,
            name: model.displayName,
            subtitle: [loc.t("Image"), ModelRuntime.mlx.label, size].joined(separator: " · "),
            description: model.subtitle,
            features: ""
        )
        if installed {
            KPrimaryButton(label: loc.t("Open generator"), systemImage: "sparkles") {
                imageGen.select(model.id)
                presentAfterDetails { showImageGen = true }
            }
        } else {
            ImageModelDownloadControl(model: model)
        }
        ModelsListCard(dividerInset: Space.m + Size.glyph + Space.s) {
            detailInfoRow(loc.t("Size"), size)
            let fit = fitValue(model.approxRAMBytes)
            detailInfoRow(loc.t("Memory"), fit.text, valueColor: fit.color)
            if installed {
                detailActionRow(loc.t("Delete model"), systemImage: "trash", role: .destructive) {
                    presentAfterDetails { pendingImageDelete = model }
                }
            }
        }
    }

    /// "In use" plus the one load control that applies right now.
    @ViewBuilder
    private func activeLoadControl(for section: Section) -> some View {
        let control: (phase: LoadPhase, load: () -> Void, unload: () -> Void, cancel: () -> Void)? = {
            switch section {
            case .assistant: return (assistantLoadPhase, loadAssistant, unloadAssistant, cancelAssistantLoad)
            case .lens: return (visionLoadPhase, loadVision, unloadVision, cancelVisionLoad)
            case .voice:
                return currentVoiceEngine == .appleSystem ? nil : (voiceLoadPhase, loadVoice, unloadVoice, cancelVoiceLoad)
            case .image: return nil
            }
        }()
        HStack(spacing: Space.s) {
            inUseLabel
            Spacer(minLength: Space.s)
            if let control {
                switch control.phase {
                case .unloaded, .failed:
                    Button(loc.t("Load"), action: control.load).glassButton(prominent: true)
                case .loading:
                    ProgressView().controlSize(.small)
                    Button(loc.t("Cancel"), action: control.cancel).glassButton()
                case .ready:
                    Button(loc.t("Unload"), action: control.unload).glassButton()
                }
            }
        }
        if case .failed(let message)? = control?.phase {
            Text(message)
                .font(.footnote)
                .foregroundStyle(T.bad)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inUseLabel: some View {
        Label(loc.t("In use"), systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(T.good)
    }

    private func detailHeader(glyph: String, name: String, subtitle: String,
                              description: String?, features: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                Image(systemName: glyph)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: Size.feature, height: Size.feature)
                    .background(T.accentStrong, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(T.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(T.ink2)
                }
            }
            if let description, !description.isEmpty {
                Text(LocalizedStringKey(description))
                    .font(.body)
                    .foregroundStyle(T.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !features.isEmpty {
                Text(features)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(T.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailInfoRow(_ label: String, _ value: String, valueColor: Color? = nil,
                               monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text(label)
                .font(.body)
                .foregroundStyle(T.ink)
            Spacer(minLength: Space.s)
            Text(value)
                .font(monospaced ? .footnote.monospaced() : .body)
                .foregroundStyle(valueColor ?? T.ink2)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .frame(minHeight: Size.control)
        .accessibilityElement(children: .combine)
    }

    private func detailActionRow(_ title: String, systemImage: String, role: ButtonRole? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: systemImage)
                    .frame(width: Size.glyph)
                    .accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.body)
            .foregroundStyle(role == .destructive ? T.bad : T.accent)
            .padding(.horizontal, Space.m)
            .frame(minHeight: Size.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fitValue(_ footprint: Int64) -> (text: String, color: Color) {
        let fit = MemoryAdvisor.fit(forFootprint: footprint)
        let color: Color = {
            switch fit {
            case .fits: return T.good
            case .tight: return T.warn
            case .over: return T.bad
            }
        }()
        return (loc.t(fit.label).sentenceCased, color)
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

    /// The Downloads "page" — a sheet listing every in-flight / failed
    /// download. Reuses InstallingRow so progress + cancel/retry work exactly
    /// as they do inline in each category.
    private var downloadsSheet: some View {
        let items = allInFlightDownloads
        let images = imageDownloads
        let coreAI = coreAIDownloads.downloads.filter { $0.state != .idle }
        return NavigationStack {
            ScrollView {
                VStack(spacing: Space.cardGap) {
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
            }
            .background(LiquidPinkBackdrop())
            .navigationTitle(loc.t("Downloads"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc.t("Done"), systemImage: "checkmark") { showDownloads = false }
                        .accessibilityIdentifier("models.downloads.close")
                }
            }
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

    // MARK: - Storage / counts strip
    //
    // README §Models split the four equal-weight stat cards into a two-
    // tile primary row (Storage + Active) and a small inline meta chip
    // row beneath (installed count · family count). Cuts visual noise in
    // half and stops the "0 MB used" + "6 installed" contradiction by
    // sourcing storage from `ModelDownloadCenter.totalStorageUsed`
    // (actual on-disk allocation), not the per-downloader totalBytes
    // expectation which drops to 0 once a download completes.

    private func totalStorageBytes() -> Int64 {
        center.totalStorageUsed
            + coreAIStore.installations.reduce(0) { $0 + $1.manifest.totalDownloadBytes }
    }

    private var installedItemCount: Int {
        center.models.filter(\.isReady).count
            + ImageGenerationService.catalog.filter { imageGen.isInstalled($0) }.count
            + coreAIStore.installations.count
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
            VStack(spacing: Space.cardGap) {
                if !isSearching && filterAllCategories {
                    recommendedSetupsCard
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
        // Filters are hidden in a short library, so they must not apply there.
        let filterAllCategories = self.filterAllCategories || installedItemCount <= 5
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

        let showsCoreAI = filterAllCategories || selectedSection == .assistant
        let hasCoreAI = showsCoreAI && coreAIStore.installations.contains(where: {
            $0.assistantModel != nil
                && (query.isEmpty || $0.manifest.displayName.localizedCaseInsensitiveContains(query))
        })

        if downloaded.isEmpty && downloadedImages.isEmpty && !hasCoreAI {
            if query.isEmpty && filterAllCategories {
                emptyState(
                    icon: "internaldrive",
                    title: loc.t("No models downloaded yet"),
                    subtitle: loc.t("Import a model from Files or discover a model to download.")
                )
                KPrimaryButton(label: loc.t("Guided model setup"), systemImage: "sparkles") {
                    showingGuidedSetup = true
                }
                .accessibilityIdentifier("models.guided.open")
                Button(loc.t("Discover models")) { isLibrary = false }
                    .glassButton()
                    .controlSize(.large)
                    .accessibilityIdentifier("models.discover.open")
            } else {
                emptyState(
                    icon: query.isEmpty ? "internaldrive" : "magnifyingglass",
                    title: query.isEmpty
                        ? loc.t("No downloaded models in this category")
                        : loc.t("No downloaded models found"),
                    subtitle: query.isEmpty
                        ? loc.t("Import a model from Files or discover a model to download.")
                        : loc.t("Try a broader search.")
                )
                if !query.isEmpty {
                    Button(loc.t("Clear search")) { searchText = "" }
                        .frame(minHeight: 44)
                }
            }
        } else {
            if query.isEmpty && filterAllCategories {
                storageSummary
                ModelsSectionHeader(title: loc.t("In use"))
                inUseCard
            }
            ModelsSectionHeader(title: loc.t(DeviceCopy.onThisDeviceTitle))
            ModelsListCard {
                if showsCoreAI {
                    CoreAIModelsSectionView(showsCatalog: false, query: query)
                }
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

    /// Space the models take and what is left, like Settings › iPhone Storage.
    private var storageSummary: some View {
        let used = totalStorageBytes()
        let free = HFModelDownloadManager.freeDiskBytes() ?? 0
        return Button {
            HapticManager.impact(.light)
            showStorageCleanup = true
        } label: {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(loc.t("Storage"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(T.ink)
                    Spacer(minLength: 0)
                    Text(used.formattedBytes)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(T.ink2)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(T.ink3)
                        .accessibilityHidden(true)
                }
                ProgressView(value: Double(used), total: Double(max(used + free, 1)))
                    .tint(T.accent)
                    .accessibilityHidden(true)
                if free > 0 {
                    Text("\(free.formattedBytes) \(loc.t("free"))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(T.ink2)
                }
            }
            .padding(Space.m)
            .background(T.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("models.storage.summary")
    }

    /// Which model each feature runs on; a tap opens that feature's picker.
    private var inUseCard: some View {
        ModelsListCard(dividerInset: Space.m + Size.control + Space.s) {
            inUseRow(.assistant, model: assistant.activeModel.displayName,
                     status: inUseStatus(assistantLoadPhase, installed: assistant.selectedModelIsInstalled)) {
                showingAssistantPicker = true
            }
            let lensModel = center.models.first { $0.supportsCategory(.vlm) && isActiveModel($0, as: .vlm) }
            inUseRow(.lens, model: lensModel?.displayName ?? visionDisplayName,
                     status: inUseStatus(visionLoadPhase, installed: lensModel?.isReady ?? true)) {
                showingVisualPicker = true
            }
            inUseRow(.voice, model: voiceDisplayName,
                     status: currentVoiceEngine == .appleSystem ? "" : inUseStatus(voiceLoadPhase)) {
                showingVoicePicker = true
            }
        }
    }

    private func inUseStatus(_ phase: LoadPhase, installed: Bool = true) -> String {
        switch phase {
        case .ready: return loc.t("Loaded")
        case .loading: return loc.t("Loading…")
        case .failed: return loc.t("Not loaded")
        case .unloaded: return installed ? "" : loc.t("Not downloaded")
        }
    }

    private func inUseRow(_ section: Section, model: String, status: String,
                          action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.impact(.light)
            action()
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: section.glyph)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(T.ink2)
                    .frame(width: Size.control, height: Size.control)
                    .background(T.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(loc.t(section.rawValue))
                        .font(.subheadline)
                        .foregroundStyle(T.ink2)
                    Text(model)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(T.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.xs)
                if !status.isEmpty {
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(T.ink2)
                }
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(T.ink3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("models.inUse.\(section.rawValue)")
    }

    // MARK: - Discovery categories

    // Discovery lists suggestions and explicit online search results. Runtime
    // controls live in each model's details; transfers stay in Downloads.
    /// In the All overview each category shows its top picks and a "See all"
    /// that switches the filter; a single category shows its full list.
    @ViewBuilder
    private func categoryPage(for section: Section) -> some View {
        let category = section.category
        let limit: Int? = filterAllCategories && !isSearching ? 3 : nil
        VStack(spacing: Space.cardGap) {
            ModelsSectionHeader(
                title: loc.t(section.rawValue),
                actionTitle: limit == nil ? nil : loc.t("See all"),
                action: {
                    HapticManager.selection()
                    filterAllCategories = false
                    selectedSection = section
                }
            )
            if isSearching {
                if section == .voice {
                    voiceCatalogBlock(query: searchText)
                }
                scopedSearchResults(category)
            } else if category == .imageGen {
                imageSuggestionsBlock(limit: limit)
            } else if section == .voice {
                voiceCatalogBlock(query: "", limit: limit)
            } else {
                suggestedBlock(category, limit: limit)
            }
            if section == .assistant && limit == nil {
                CoreAIModelsSectionView(query: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    // MARK: - Active role header

    // MARK: - Per-category model lists

    /// All not-installed candidates for a category, ranked so the best models
    /// that FIT this device surface first. Unfiltered — `suggestedModels`
    /// applies the safety/edge filter on top.
    private func rankedCandidates(_ category: DownloadableModel.Category) -> [DownloadableModel] {
        // Downloading and installed models stay in place (with progress or
        // "Installed") instead of jumping to another section.
        let candidates = center.models.filter { $0.supportsCategory(category) }
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

    // MARK: - Suggested block

    @ViewBuilder
    private func suggestedBlock(_ category: DownloadableModel.Category, limit: Int? = nil) -> some View {
        let suggested = suggestedModels(category)
        let hidden = hiddenCandidateCount(category)
        if suggested.isEmpty && hidden == 0 {
            emptyState(
                icon: selectedSection.glyph,
                title: loc.t("Nothing to suggest yet"),
                subtitle: loc.t("Search Hugging Face above to add a model.")
            )
        } else {
            if !suggested.isEmpty {
                ModelsListCard {
                    ForEach(limit.map { Array(suggested.prefix($0)) } ?? suggested) { model in
                        catalogRow(model, activationCategory: category)
                    }
                }
            }
            if limit == nil { edgeHiddenHint(hidden) }
        }
    }

    // MARK: - Production voice catalog

    /// The authoritative catalog rendered by the Models tab's Voice section.
    /// Runtime availability affects the action, never whether the card exists.
    @ViewBuilder
    private func voiceCatalogBlock(query: String, limit: Int? = nil) -> some View {
        let entries = voiceCatalog.entries(query: query.trimmingCharacters(in: .whitespacesAndNewlines))
        let useful = entries.filter { $0.isDownloadEnabled || $0.id == "tts.apple.system" }
        let future = entries.filter { !$0.isDownloadEnabled && $0.id != "tts.apple.system" }
        if entries.isEmpty {
            emptyState(icon: "magnifyingglass", title: loc.t("No voice models found"), subtitle: loc.t("Try a broader search."))
        } else {
            ModelsListCard {
                ForEach(limit.map { Array(useful.prefix($0)) } ?? useful) { entry in
                    voiceCatalogRow(entry)
                }
            }
            // Runtimes the app can't play yet are developer information.
            if limit == nil, settings.showEdgeModels, !future.isEmpty {
                DisclosureGroup(isExpanded: $showFutureVoiceIntegrations) {
                    ModelsListCard {
                        ForEach(future) { entry in voiceCatalogRow(entry) }
                    }
                    .padding(.top, Space.s)
                } label: {
                    Label("Future Runtime Integrations", systemImage: "shippingbox")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(T.ink2)
                }
                .padding(.horizontal, Space.xxs)
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
        let model = entry.legacyDownloadID.flatMap { id in center.models.first { $0.id == id } }
        let status: String = {
            if isActiveVoiceEntry(entry) { return loc.t("In use") }
            if let model { return catalogStatus(model) }
            // Built-in or not downloadable here: say why only when it isn't simply available.
            return entry.statusLabel == "Available" ? "" : loc.t(entry.statusLabel)
        }()
        return ModelsCompactRow(
            name: entry.name,
            subtitle: loc.t(entry.task == .textToSpeech ? "Text to Speech" : "Speech Recognition") + (entry.sizeLabel.map { " · " + $0 } ?? ""),
            status: status,
            actionTitle: loc.t("Review voice support and download options"),
            identifier: "modelsVoiceCatalogCard.\(entry.id)",
            progress: model.flatMap(downloadProgress),
            onGet: entry.isDownloadEnabled ? model.flatMap(getAction) : nil,
            action: { details = .voice(entry) }
        )
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
                    .font(.footnote)
                    .foregroundColor(T.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.xxs)
        }
    }

    @ViewBuilder
    private func imageSuggestionsBlock(limit: Int? = nil) -> some View {
        let visible = ImageGenerationService.catalog.filter { m in
            imageGen.isInstalled(m) || passesImageSafetyFilter(m)
        }
        let hidden = ImageGenerationService.catalog.count - visible.count
        if !visible.isEmpty {
            ModelsListCard {
                ForEach(limit.map { Array(visible.prefix($0)) } ?? visible) { m in
                    imageModelRow(m)
                }
            }
        }
        if limit == nil { edgeHiddenHint(hidden) }
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
                // Same header as the category sections below, plus a disclosure chevron.
                HStack(spacing: Space.xs) {
                    Text(loc.t("Recommended setups").uppercased())
                        .font(T.sans(13, .semibold))
                        .tracking(TextScale.capsTracking)
                        .foregroundColor(T.ink2)
                    Spacer(minLength: Space.s)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(T.ink3)
                        .rotationEffect(.degrees(showRecommendedSetups ? 180 : 0))
                }
                .padding(.horizontal, Space.xxs)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showRecommendedSetups {
                ModelsListCard {
                    ForEach(Self.modelCombos) { combo in
                        comboCard(combo)
                    }
                }
            }
        }
    }

    /// One tier: name, tagline, total download, and a warning only when the
    /// setup won't fit (free storage first, then the largest model's memory).
    @ViewBuilder
    private func comboCard(_ combo: ModelCombo) -> some View {
        let expanded = expandedComboID == combo.id
        let free = HFModelDownloadManager.freeDiskBytes() ?? .max
        let ramFit = MemoryAdvisor.fit(forFootprint: combo.picks.map(\.approxRAM).max() ?? 0)
        let warning: (text: String, color: Color)? = remainingDownloadBytes(combo) > free
            ? (loc.t("Low disk space"), T.warn)
            : ramFit == .over ? (loc.t(ramFit.label).sentenceCased, T.bad)
            : ramFit == .tight ? (loc.t(ramFit.label).sentenceCased, T.warn)
            : nil
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    expandedComboID = expanded ? nil : combo.id
                }
                HapticManager.impact(.light)
            } label: {
                HStack(spacing: Space.s) {
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(loc.t(combo.tier))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(T.ink)
                        Text(loc.t(combo.tagline))
                            .font(.subheadline)
                            .foregroundStyle(T.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Space.s)
                    VStack(alignment: .trailing, spacing: Space.hair) {
                        Text(combo.totalDownload.formattedBytes)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(T.ink2)
                        if let warning {
                            Text(warning.text)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(warning.color)
                        }
                    }
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(T.ink3)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
                .frame(minHeight: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(expanded ? .isSelected : [])

            if expanded {
                ForEach(combo.picks) { pick in
                    Divider().padding(.leading, Space.m)
                    comboPickRow(pick)
                }
                if remainingDownloadBytes(combo) > 0 {
                    KPrimaryButton(
                        label: loc.t("Download all"),
                        systemImage: "arrow.down.circle.fill",
                        trailing: remainingDownloadBytes(combo).formattedBytes
                    ) {
                        startDownloads(for: combo)
                    }
                    .padding(Space.m)
                }
            }
        }
    }

    /// The same rows Discover uses, so Get, progress and details behave alike.
    @ViewBuilder
    private func comboPickRow(_ pick: ComboPick) -> some View {
        if pick.role == .imageGen, let model = ImageGenerationService.model(forID: pick.catalogID) {
            imageModelRow(model)
        } else if let model = comboDownloadableModel(for: pick) {
            catalogRow(model, activationCategory: pick.role)
        } else {
            ModelsCompactRow(
                name: pick.name,
                subtitle: loc.t(sectionFor(pick.role).rawValue) + " · " + loc.t(pick.detail),
                actionTitle: loc.t("See all"),
                action: {
                    filterAllCategories = false
                    selectedSection = sectionFor(pick.role)
                }
            )
        }
    }

    /// What is still left to download for this tier.
    private func remainingDownloadBytes(_ combo: ModelCombo) -> Int64 {
        combo.picks.reduce(0) { total, pick in
            if pick.role == .imageGen, let model = ImageGenerationService.model(forID: pick.catalogID) {
                return imageGen.isInstalled(model) ? total : total + pick.downloadBytes
            }
            return comboDownloadableModel(for: pick)?.isReady == true ? total : total + pick.downloadBytes
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

    private func sectionFor(_ role: DownloadableModel.Category) -> Section {
        switch role {
        case .assistant: return .assistant
        case .vlm:       return .lens
        case .voice:     return .voice
        case .imageGen:  return .image
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

    /// Normalised lifecycle the In use control renders against. Folds the two
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
    // MARK: - Installing section
    //
    // MARK: - Installed section

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
            status: loaded ? loc.t("Loaded") : selected ? loc.t("In use") : "",
            runtime: LocalModelRegistry.descriptor(for: model).runtime,
            actionTitle: loc.t("Details"),
            identifier: "models.installed.\(model.id)",
            action: { details = .model(model, role) }
        )
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

    private func imageModelRow(_ model: ImageGenerationService.Model) -> some View {
        let installed = imageGen.isInstalled(model)
        let downloading = imageGen.isDownloading(model)
        let failed = imageGen.directDownloadErrors[model.id] != nil
        // Same gate as the Download button on the model page: the parental PIN
        // must allow image generation. When it doesn't, the row opens that page.
        let canGet = !installed && !downloading && !failed
            && ImageGenerationParentalControls.shared.canGenerate && !imageGen.isBusy
        return ModelsCompactRow(
            name: model.displayName,
            subtitle: loc.t("Image") + " · " + model.sizeLabel,
            status: failed ? loc.t("Download needs attention")
                : installed && !isLibrary ? loc.t("Installed") : "",
            runtime: .mlx,
            actionTitle: loc.t("Model details"),
            identifier: "models.image.\(model.id)",
            progress: downloading ? imageGen.downloadProgress(for: model) : nil,
            onGet: canGet ? {
                HapticManager.impact(.medium)
                imageGen.startDownload(model)
            } : nil,
            action: { details = .image(model) }
        )
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

    // MARK: - Family grouping

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

    // MARK: - Featured block

    // MARK: - Family block

    private func catalogStatus(_ model: DownloadableModel) -> String {
        switch model.state {
        case .ready: return loc.t("Installed")
        case .failed: return loc.t("Download needs attention")
        case .idle: return model.isPaused ? loc.t("Paused") : ""
        case .downloading, .enumerating: return ""
        }
    }

    private func downloadProgress(_ model: DownloadableModel) -> Double? {
        switch model.state {
        case .downloading, .enumerating: return model.progress
        default: return nil
        }
    }

    /// The row's Get button: same action as Download in the details sheet.
    private func getAction(_ model: DownloadableModel) -> (() -> Void)? {
        guard case .idle = model.state, !model.isPaused,
              model.platformCompatibility?.supportsCurrentPlatform ?? true else { return nil }
        return {
            HapticManager.impact(.medium)
            model.start()
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
            identifier: "models.catalog.\(model.id)",
            progress: downloadProgress(model),
            onGet: getAction(model),
            action: { details = .model(model, activationCategory ?? model.category) }
        )
    }

    @ViewBuilder
    private func progressStrip(progress: Double, downloaded: Int64, total: Int64, file: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            ProgressView(value: progress)
                .tint(T.accent)
                .progressViewStyle(.linear)
            HStack(spacing: Space.xs) {
                Text("\(Int(progress * 100))%")
                    .fontWeight(.semibold)
                    .foregroundColor(T.ink)
                if total > 0 {
                    Text("\(downloaded.formattedBytes) / \(total.formattedBytes)")
                        .foregroundColor(T.ink2)
                }
                Spacer(minLength: 0)
            }
            .font(.footnote.monospacedDigit())
        }
    }

    // MARK: - View helpers

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

    /// Fixed display order for the per-category headers used in the Active,
    /// Installed and Catalog sections, so a model always sits under the same
    /// header regardless of which section it's viewed in.
    private static let categoryOrder: [DownloadableModel.Category] =
        [.assistant, .vlm, .imageGen, .voice]

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
                ComboPick(role: .voice, catalogID: "tts.kitten.mini.0_8", name: "KittenTTS Mini", detail: "Official KittenML ONNX · 8 English voices.", approxRAM: 700_000_000, downloadBytes: 82_000_000),
                ComboPick(role: .imageGen, catalogID: "stabilityai/sd-turbo", name: "SD-Turbo", detail: "1 step · 512px", approxRAM: 2_600_000_000, downloadBytes: 5_000_000_000)
            ]
        ),
        ModelCombo(
            id: "medium", tier: "Medium", glyph: "gauge.medium",
            tagline: "The sweet spot — great quality, comfortable on 8 GB & 12 GB.",
            picks: [
                ComboPick(role: .assistant, catalogID: "qwen3-4b-2507", name: "Qwen3-4B 2507", detail: "4-bit · ~2.3 GB", approxRAM: 3_500_000_000, downloadBytes: 2_300_000_000),
                ComboPick(role: .vlm, catalogID: "mlx-community/Qwen3-VL-2B-Instruct-4bit", name: "Qwen3-VL-2B", detail: "4-bit · ~1.7 GB", approxRAM: 2_300_000_000, downloadBytes: 1_700_000_000),
                ComboPick(role: .voice, catalogID: "kokoro-82m", name: "Kokoro-82M", detail: "neural TTS", approxRAM: 400_000_000, downloadBytes: 330_000_000),
                ComboPick(role: .imageGen, catalogID: "stabilityai/stable-diffusion-2-1-base", name: "Stable Diffusion 2.1", detail: "20 steps · 512px", approxRAM: 2_600_000_000, downloadBytes: 5_200_000_000)
            ]
        ),
        ModelCombo(
            id: "heavy", tier: "Heavy", glyph: "flame.fill",
            tagline: "Best quality. Wants a 12 GB iPhone 17 Pro; tight on 8 GB.",
            picks: [
                ComboPick(role: .assistant, catalogID: "qwen3-4b-2507-8bit", name: "Qwen3-4B 2507 (8-bit)", detail: "8-bit · ~4.3 GB", approxRAM: 5_300_000_000, downloadBytes: 4_300_000_000),
                ComboPick(role: .vlm, catalogID: "mlx-community/Qwen3-VL-4B-Instruct-4bit", name: "Qwen3-VL-4B", detail: "4-bit · ~2.9 GB", approxRAM: 3_800_000_000, downloadBytes: 2_900_000_000),
                ComboPick(role: .voice, catalogID: "kokoro-82m", name: "Kokoro-82M", detail: "neural TTS", approxRAM: 400_000_000, downloadBytes: 330_000_000),
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
    let onGuidedSetup: () -> Void
    @ObservedObject private var settings = AppSettings.shared
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
                    Button(action: onGuidedSetup) {
                        Label(localization.t("Guided model setup"), systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("models.guided")
                    Divider()
                    // Shows models that only just fit, everywhere in the tab.
                    Toggle(isOn: $settings.showEdgeModels) {
                        Label(localization.t("Edge / developer mode"), systemImage: "hammer")
                    }
                    .accessibilityIdentifier("models.edgeMode")
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

/// One model in a list: its name, then "Role · Runtime · Size". The trailing
/// side carries the one thing that matters for the row: a Get button,
/// download progress, or a short status such as "In use".
struct ModelsCompactRow: View {
    let name: String
    let subtitle: String
    var status: String = ""
    var runtime: ModelRuntime? = nil
    let actionTitle: String
    var identifier: String = ""
    var progress: Double? = nil
    var onGet: (() -> Void)? = nil
    let action: () -> Void
    @Environment(\.koduTheme) private var theme
    @ObservedObject private var localization = LocalizationService.shared

    private var detail: String {
        var parts = subtitle.components(separatedBy: " · ").filter { !$0.isEmpty }
        if let runtime { parts.insert(runtime.label, at: min(1, parts.count)) }
        return Self.localizedNumbers(parts.joined(separator: " · "))
    }

    /// Catalog sizes are written as "~1.25 GB" while measured ones come from
    /// ByteCountFormatter in the user's locale; show both the same way.
    static func localizedNumbers(_ text: String) -> String {
        let separator = Locale.current.decimalSeparator ?? "."
        guard separator != "." else { return text }
        return text.replacingOccurrences(of: #"(\d)\.(\d)"#, with: "$1\(separator)$2", options: .regularExpression)
    }

    var body: some View {
        HStack(spacing: Space.s) {
            Button(action: action) {
                HStack(spacing: Space.s) {
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(theme.ink2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if onGet == nil && progress == nil {
                        if !status.isEmpty {
                            Text(status)
                                .font(.subheadline)
                                .foregroundStyle(theme.ink2)
                                .multilineTextAlignment(.trailing)
                        }
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(theme.ink3)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(actionTitle)
            .accessibilityIdentifier(identifier)

            if let progress {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(theme.ink2)
                    .accessibilityLabel(localization.t("Downloading"))
                    .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
            } else if let onGet {
                GlassGetButton(label: localization.t("Get"), tint: theme.accent, action: onGet)
                    .accessibilityLabel(localization.t("Get") + " " + name)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    }
}

/// Rows on one card with inset dividers, like a grouped list.
struct ModelsListCard<Content: View>: View {
    var dividerInset: CGFloat = Space.m
    @ViewBuilder var content: Content
    @Environment(\.koduTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    row
                    if row.id != rows.last?.id {
                        Divider().padding(.leading, dividerInset)
                    }
                }
            }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// Small-caps section title, the same as Home's "Recent", with an optional
/// trailing action such as "See all".
struct ModelsSectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.koduTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(theme.sans(13, .semibold))
                .tracking(TextScale.capsTracking)
                .foregroundColor(theme.ink2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.s)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline)
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(.horizontal, Space.xxs)
        .padding(.top, Space.m)
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
