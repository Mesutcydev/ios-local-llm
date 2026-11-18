import SwiftUI

// MARK: - VoiceModelPickerView
//
// THE single place to pick which engine reads replies aloud. Parallel to
// AssistantModelPickerView (chat tab) and VisualModelPickerView (camera tab).
//
// One-tap model. Tapping a row IS the whole interaction — there is no
// separate "download", "load engine", and "Done-to-commit" dance anymore:
//
//   • Apple System Voice — activates instantly (always on device).
//   • A neural engine already on disk + loaded — activates instantly.
//   • A neural engine on disk but not loaded / previously failed — the
//     tap loads it (retrying a failed load) and it activates when ready.
//   • A neural engine not yet downloaded — the tap starts the download
//     right here (no Models-tab round trip); VoiceService's
//     download-complete observer auto-loads it, and the row flips to
//     "active" on its own when the engine reports ready.
//
// Selection commits immediately to `AppSettings.voiceEngine` (+ a matching
// `voiceID`). While a freshly-picked engine is still downloading/loading,
// voice mode keeps reading through System Voice — VoiceService.resolvedEngine
// falls back automatically — so an in-progress pick never breaks playback.
// "Done" only dismisses.

struct VoiceModelPickerView: View {
    @ObservedObject private var voiceSettings = VoiceSettingsStore.shared
    @ObservedObject private var catalog = VoiceCatalogStore.shared

    @ObservedObject private var center = ModelDownloadCenter.shared
    @ObservedObject private var voiceService = VoiceService.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var loc = LocalizationService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T
    @State private var query = ""
    @State private var selectedCatalogEntry: VoiceCatalogEntry?
    @State private var confirmDownload: VoiceCatalogEntry?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    KSearchField(placeholder: "Search voice models", text: $query)
                        .accessibilityIdentifier("voiceCatalogSearch")
                        .padding(.horizontal, Space.m)
                        .padding(.top, Space.m)
                    catalogSections
                    hintCard
                }
                .padding(.bottom, Space.l)
            }
            .background(LiquidPinkBackdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark") { dismiss() }.foregroundColor(T.ink)
                }
            }
            .onAppear { center.refreshAllStates() }
            .onReceive(NotificationCenter.default.publisher(
                for: .hfModelDownloadCompleted)
            ) { _ in
                center.refreshAllStates()
            }
            .sheet(item: $selectedCatalogEntry) { entry in
                VoiceCatalogDetailView(entry: entry)
            }
            .confirmationDialog(
                loc.t("Download \(confirmDownload?.name ?? "")"),
                isPresented: Binding(
                    get: { confirmDownload != nil },
                    set: { if !$0 { confirmDownload = nil } }
                ),
                titleVisibility: .visible,
                presenting: confirmDownload
            ) { entry in
                Button(sizeText(for: entry).map { loc.t("Download \($0)") } ?? loc.t("Download")) {
                    startDownload(entry)
                }
                Button(loc.t("Cancel"), role: .cancel) {}
            } message: { entry in
                if entry.task == .textToSpeech {
                    Text(loc.t("This model isn't on your device yet. Voice mode switches to it when the download finishes."))
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            KCaption(text: "VOICE")
            KPageTitle(title: "Voice engines", size: 28)
            Text(loc.t("Choose the voice that reads replies aloud. Downloaded voices run offline on this iPhone."))
                .font(T.sans(13))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.hair)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.m)
        .padding(.top, Space.s)
    }

    private var visibleCatalogEntries: [VoiceCatalogEntry] {
        catalog.entries(query: query)
    }

    @ViewBuilder
    private var catalogSections: some View {
        switch catalog.loadState {
        case .idle, .loading:
            ProgressView(loc.t("Loading…")).padding(Space.l)
        case .loaded, .failed:
            if catalog.loadState == .failed, let error = catalog.loadError {
                VStack(spacing: Space.s) {
                    Text(error).font(T.sans(12)).foregroundColor(T.bad)
                    Button(loc.t("Retry")) { catalog.load() }.buttonStyle(.kSecondary)
                }
                .padding()
            }
            let usable = visibleCatalogEntries.filter(isUsableOnDevice)
            catalogSection(title: "text to speech", entries: usable.filter { $0.task == .textToSpeech })
            catalogSection(title: "speech recognition", entries: usable.filter { $0.task == .speechRecognition })
            let unavailable = visibleCatalogEntries.filter { !isUsableOnDevice($0) }
            if !unavailable.isEmpty {
                // Every model family stays visible, but the ones this iPhone
                // can't run sit behind one row instead of pushing the usable
                // engines off screen. A search opens it.
                KCollapsibleSection(title: "Unavailable",
                                    rowTitle: "\(loc.t("More models")) · \(unavailable.count)",
                                    defaultExpanded: !query.isEmpty) {
                    ForEach(unavailable) { entry in
                        unavailableRow(entry)
                        if entry.id != unavailable.last?.id {
                            Rectangle().fill(T.rule).frame(height: 1).padding(.leading, Space.m)
                        }
                    }
                }
                .id(query.isEmpty)
            }
        }
    }

    private func catalogSection(title: String, entries: [VoiceCatalogEntry]) -> some View {
        Group {
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        KCaption(text: title)
                        Rectangle().fill(T.rule).frame(height: 1)
                    }
                    LazyVStack(spacing: Space.s) {
                        ForEach(entries) { entry in catalogCard(entry) }
                    }
                }
                .padding(.horizontal, Space.m)
                .padding(.top, Space.l)
            }
        }
    }

    // MARK: - Rows

    private enum RowState: Equatable {
        case builtIn
        case ready
        case notDownloaded
        case downloading(Double)
        case failed
        case unavailable
    }

    private func isUsableOnDevice(_ entry: VoiceCatalogEntry) -> Bool {
        entry.id == "tts.apple.system" || entry.isDownloadEnabled
    }

    private func rowState(_ entry: VoiceCatalogEntry, model: DownloadableModel?) -> RowState {
        if entry.id == "tts.apple.system" { return .builtIn }
        guard entry.isDownloadEnabled, let model else { return .unavailable }
        switch model.state {
        case .ready: return .ready
        case .downloading, .enumerating: return .downloading(model.progress)
        case .failed: return .failed
        case .idle: return .notDownloaded
        }
    }

    /// The engine voice mode reads with. Kitten variants share one engine,
    /// so they also match on the saved variant.
    private func isActive(_ entry: VoiceCatalogEntry, model: DownloadableModel?) -> Bool {
        guard entry.task == .textToSpeech else { return false }
        if entry.id == "tts.apple.system" { return voiceSettings.selectedEngine == .appleSystem }
        guard let model, let kind = LocalModelRegistry.voiceEngine(for: model),
              voiceSettings.selectedEngine == kind else { return false }
        if kind == .kittenTTS { return voiceSettings.selectedKittenVariant.rawValue == model.id }
        return true
    }

    private func sizeText(for entry: VoiceCatalogEntry) -> String? {
        if let label = entry.sizeLabel, label.lowercased() != "built in" { return label }
        return entry.legacyDownloadID.flatMap(downloadModel)?.sizeLabel
    }

    private func catalogCard(_ entry: VoiceCatalogEntry) -> some View {
        let model = entry.legacyDownloadID.flatMap(downloadModel)
        let state = rowState(entry, model: model)
        let active = isActive(entry, model: model)
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.s) {
                Button { cardTapped(entry, model: model, state: state) } label: {
                    HStack(alignment: .top, spacing: Space.s) {
                        engineTile(entry, active: active)
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            HStack(spacing: Space.xs) {
                                Text(entry.name)
                                    .font(T.display(17, .semibold))
                                    .foregroundColor(T.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                if active { KActivePill(text: "active") }
                            }
                            Text(LocalizedStringKey(entry.summary))
                                .font(T.sans(12))
                                .foregroundColor(T.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                            // The Download button below already names the
                            // size, so a not-downloaded row needs no chip.
                            if state != .notDownloaded || entry.supportLevel == .experimental {
                                KFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                                    if state != .notDownloaded { statusChip(state) }
                                    if entry.supportLevel == .experimental {
                                        KTag(text: "Experimental", size: 9)
                                    }
                                }
                                .padding(.top, Space.xxs)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])

                Button { selectedCatalogEntry = entry } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(T.ink3)
                        .frame(width: Size.control, height: Size.control)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, -10)
                .padding(.trailing, -10)
                .accessibilityLabel(loc.t("Details"))
            }

            switch state {
            case .notDownloaded:
                Button {
                    confirmDownload = entry
                } label: {
                    Label(sizeText(for: entry).map { loc.t("Download \($0)") } ?? loc.t("Download"),
                          systemImage: "arrow.down")
                }
                .buttonStyle(.kPrimary)
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: Space.xs) {
                    ProgressView(value: progress).tint(T.accent)
                    Text(loc.t("Downloading \(progress.formatted(.percent.precision(.fractionLength(0))))"))
                        .font(T.mono(10))
                        .foregroundColor(T.ink3)
                }
            case .failed:
                Button(loc.t("Retry")) { model?.start() }
                    .buttonStyle(.kSecondary)
            case .builtIn, .ready, .unavailable:
                EmptyView()
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kGlass(cornerRadius: Radius.card)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .stroke(active ? T.accent.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .accessibilityIdentifier("voiceCatalogCard.\(entry.id)")
    }

    private func engineTile(_ entry: VoiceCatalogEntry, active: Bool) -> some View {
        Image(systemName: active ? "checkmark" : (entry.task == .textToSpeech ? "waveform" : "mic"))
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(active ? T.bg : T.accent)
            .frame(width: Size.control, height: Size.control)
            .background(
                active ? T.accent : T.accentSoft,
                in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    /// One plain word per state, so "Available" no longer means both
    /// "installed" and "not downloaded yet".
    @ViewBuilder
    private func statusChip(_ state: RowState) -> some View {
        switch state {
        case .builtIn, .ready:
            KStatusBadge(glyph: .ready, label: state == .builtIn ? "ready" : "Downloaded", color: T.good)
        case .notDownloaded:
            KStatusBadge(glyph: .download, label: "Download", color: T.ink3)
        case .downloading:
            KStatusBadge(glyph: .streaming, label: "Downloading…", color: T.accent)
        case .failed:
            KStatusBadge(glyph: .remote, label: "Unavailable", color: T.bad)
        case .unavailable:
            KStatusBadge(glyph: .remote, label: "Unavailable", color: T.ink3)
        }
    }

    private func unavailableRow(_ entry: VoiceCatalogEntry) -> some View {
        Button { selectedCatalogEntry = entry } label: {
            HStack(spacing: Space.s) {
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(entry.name).font(T.sans(14, .semibold)).foregroundColor(T.ink)
                    Text(loc.t(entry.statusLabel)).font(T.sans(12)).foregroundColor(T.ink3)
                }
                Spacer(minLength: 8)
                Image(systemName: "info.circle").foregroundStyle(T.ink3).accessibilityHidden(true)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("voiceCatalogCard.\(entry.id)")
    }

    // MARK: - Actions

    private func cardTapped(_ entry: VoiceCatalogEntry, model: DownloadableModel?, state: RowState) {
        switch state {
        case .builtIn:
            choose(.appleSystem, model: nil)
        case .ready:
            if entry.task == .textToSpeech, let model {
                activate(entry, model: model)
            } else {
                selectedCatalogEntry = entry
            }
        case .notDownloaded:
            confirmDownload = entry
        case .failed:
            model?.start()
        case .downloading, .unavailable:
            selectedCatalogEntry = entry
        }
    }

    private func startDownload(_ entry: VoiceCatalogEntry) {
        guard let model = entry.legacyDownloadID.flatMap(downloadModel) else { return }
        if entry.task == .textToSpeech {
            activate(entry, model: model)   // commits the pick, then downloads
        } else {
            model.start()
        }
    }

    private func downloadModel(id: String) -> DownloadableModel? {
        center.models.first { $0.id == id }
    }

    private func activate(_ entry: VoiceCatalogEntry, model: DownloadableModel) {
        if let kind = LocalModelRegistry.voiceEngine(for: model) {
            choose(kind, model: model)
        } else if model.state != .ready {
            model.start()
        }
    }

    // MARK: - One-tap action

    private func choose(_ kind: VoiceEngineKind, model: DownloadableModel?) {
        HapticManager.impact(.light)

        // Commit immediately. VoiceService.resolvedEngine falls back to
        // System until this engine is actually ready, so selecting one
        // that's still downloading/loading never breaks playback — and the
        // download-complete observer keys off `voiceEngine`, so we must set
        // it BEFORE kicking the download.
        // Kitten variants share one engine: record WHICH variant was picked,
        // and reload when it changes, or voice keeps the old (maybe missing)
        // variant and silently falls back to System.
        let variantChanged: Bool
        if kind == .kittenTTS, let id = model?.id, let variant = KittenVariant(rawValue: id) {
            variantChanged = voiceSettings.selectedKittenVariant != variant
            voiceSettings.selectKittenVariant(variant)
        } else {
            variantChanged = false
            voiceSettings.selectEngine(kind)
        }
        let voices = voiceList(for: kind)
        if !voices.contains(where: { $0.id == settings.voiceID }),
           let first = voices.first {
            let chosen = kind == .appleSystem
                ? voiceService.systemEngine.upgradedVoice(for: first)
                : first
            settings.voiceID = chosen.id
        } else if kind == .appleSystem,
                  let current = voices.first(where: { $0.id == settings.voiceID }) {
            let upgraded = voiceService.systemEngine.upgradedVoice(for: current)
            if upgraded.id != current.id {
                settings.voiceID = upgraded.id
            }
        }

        guard kind != .appleSystem else { return }   // always ready

        if !filesPresent(for: kind) {
            // Not downloaded → start it here. The download-complete
            // observer auto-loads the now-preferred engine.
            model?.start()
        } else if variantChanged || { if case .failed = engineState(for: kind) { return true }; return false }() {
            // On disk but the last load failed (or a different Kitten
            // variant was picked) → clear and reload.
            voiceService.unloadAll()
            Task { await voiceService.load() }
        } else if engineState(for: kind) != .ready {
            // On disk, just not loaded into memory yet.
            Task { await voiceService.load() }
        }
    }

    // MARK: - Helpers

    private func filesPresent(for kind: VoiceEngineKind) -> Bool {
        switch kind {
        case .appleSystem: return true
        case .kittenTTS:   return VoiceModelBundleValidator.isKittenTTSAvailable()
        case .kokoro:      return VoiceModelBundleValidator.isKokoroAvailable()
        case .paradee:     return ParadeeTTSService.isAvailable
        case .supertonic:  return SupertonicTTSService.isAvailable
        }
    }

    private func engineState(for kind: VoiceEngineKind) -> VoiceModelState {
        switch kind {
        case .appleSystem: return voiceService.systemState
        case .kittenTTS:   return voiceService.kittenState
        case .kokoro:      return voiceService.kokoroState
        case .paradee:     return voiceService.paradeeState
        case .supertonic:  return voiceService.supertonicState
        }
    }

    private func voiceList(for kind: VoiceEngineKind) -> [VoiceOption] {
        switch kind {
        case .appleSystem: return voiceService.systemEngine.availableVoices
        case .kittenTTS:   return KittenTTSService.kittenVoices
        case .kokoro:      return KokoroTTSService.kokoroVoices
        case .paradee:     return ParadeeTTSService.paradeeVoices
        case .supertonic:  return SupertonicTTSService.supertonicVoices
        }
    }

    // MARK: - Hint

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("tip")
                .font(T.mono(9, .semibold))
                .foregroundColor(T.ink3)
            Text("Apple System Voice ships with iOS premium voices and works offline out of the box — it's the most reliable choice. On-device neural voices (KittenTTS, Kokoro) are smaller English voices that some people prefer; if one ever fails its self-check, the app reads replies through System Voice automatically. Pick the specific voice and speed in Voice settings.")
                .font(T.sans(11))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kGlass(cornerRadius: Radius.card)
        .padding(.horizontal, Space.m)
        .padding(.top, Space.l)
    }

}

struct VoiceCatalogDetailView: View {
    let entry: VoiceCatalogEntry
    @ObservedObject private var loc = LocalizationService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        KCaption(text: "Model Details")
                        Text(entry.name)
                            .font(T.display(28, .semibold))
                            .foregroundColor(T.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(LocalizedStringKey(entry.summary))
                            .font(T.sans(15))
                            .foregroundColor(T.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Space.hair)
                    }
                    VStack(spacing: 0) {
                        detailRow("Task", entry.task == .textToSpeech ? "Text to Speech" : "Speech Recognition")
                        Rectangle().fill(T.rule).frame(height: 1)
                        detailRow("Support", entry.statusLabel)
                        if let size = entry.sizeLabel, size.lowercased() != "built in" {
                            Rectangle().fill(T.rule).frame(height: 1)
                            detailRow("Storage", size)
                        }
                    }
                    .kGlass(cornerRadius: Radius.card)
                    if let source = entry.sourceURL, let url = URL(string: source) {
                        Link(destination: url) {
                            Label(loc.t("Open Project"), systemImage: "arrow.up.right")
                        }
                        .buttonStyle(.kSecondary)
                    }
                }
                .padding(Space.m)
            }
            .background(LiquidPinkBackdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "checkmark") { dismiss() }.foregroundColor(T.ink)
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(loc.t(label)).font(T.sans(14)).foregroundColor(T.ink2)
            Spacer(minLength: 12)
            Text(loc.t(value)).font(T.sans(14, .semibold)).foregroundColor(T.ink)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, Space.m)
        .frame(minHeight: 48)
    }
}
