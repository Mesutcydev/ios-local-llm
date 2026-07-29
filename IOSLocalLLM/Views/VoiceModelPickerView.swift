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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T
    @State private var query = ""
    @State private var selectedCatalogEntry: VoiceCatalogEntry?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    catalogSearch
                    catalogSections
                    hintCard
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
            .onAppear { center.refreshAllStates() }
            .onReceive(NotificationCenter.default.publisher(
                for: .hfModelDownloadCompleted)
            ) { _ in
                center.refreshAllStates()
            }
            .sheet(item: $selectedCatalogEntry) { entry in
                VoiceCatalogDetailView(entry: entry)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            KCaption(text: "VOICE")
            KPageTitle(title: "model catalog", size: 28)
            KMono(text: "all speech model families — unavailable runtimes remain visible",
                  size: 11, color: T.ink3)
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var catalogSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(T.ink3)
            TextField("Search voice models", text: $query)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("voiceCatalogSearch")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
            }
        }
        .padding(12)
        .kGlass(cornerRadius: 10, fallbackFill: T.surface)
        .padding(.horizontal, 16)
    }

    private var visibleCatalogEntries: [VoiceCatalogEntry] {
        catalog.entries(query: query)
    }

    @ViewBuilder
    private var catalogSections: some View {
        switch catalog.loadState {
        case .idle, .loading:
            ProgressView("Loading complete voice catalog…").padding(30)
        case .loaded, .failed:
            if catalog.loadState == .failed, let error = catalog.loadError {
                VStack(spacing: 8) {
                    Text(error).font(T.sans(11)).foregroundColor(T.bad)
                    Button("Retry") { catalog.load() }
                }.padding()
            }
            catalogSection(title: "text to speech", task: .textToSpeech)
            catalogSection(title: "speech recognition", task: .speechRecognition)
        }
    }

    private func catalogSection(title: String, task: VoiceCatalogTask) -> some View {
        let entries = visibleCatalogEntries.filter { $0.task == task }
        return Group {
            if !entries.isEmpty {
                KSection(title: title) {
                    ForEach(entries) { entry in
                        catalogCard(entry)
                        if entry.id != entries.last?.id {
                            Rectangle().fill(T.rule).frame(height: 1)
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    private func catalogCard(_ entry: VoiceCatalogEntry) -> some View {
        let downloadable = entry.legacyDownloadID.flatMap(downloadModel)
        return VStack(alignment: .leading, spacing: 9) {
            Button { selectedCatalogEntry = entry } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.task == .textToSpeech ? "waveform" : "mic")
                        .frame(width: 32, height: 32)
                        .foregroundColor(T.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(T.mono(13, .semibold)).foregroundColor(T.ink)
                        Text(entry.summary).font(T.sans(11)).foregroundColor(T.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(entry.statusLabel.uppercased())
                            .font(T.mono(9, .semibold))
                            .foregroundColor(entry.isDownloadEnabled ? T.good : T.warn)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundColor(T.ink3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                if entry.id == "tts.apple.system" {
                    Button("Select") { choose(.appleSystem, model: nil) }
                        .buttonStyle(.borderedProminent)
                } else if entry.isDownloadEnabled, let model = downloadable {
                    Button(primaryTitle(for: model)) { activate(entry, model: model) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(entry.statusLabel) {}
                        .buttonStyle(.bordered)
                        .disabled(true)
                }
                Button("Details") { selectedCatalogEntry = entry }.buttonStyle(.bordered)
                if let source = entry.sourceURL, let url = URL(string: source) {
                    Link("Open Project", destination: url).font(T.sans(11, .semibold))
                }
            }
            .font(T.sans(11, .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityIdentifier("voiceCatalogCard.\(entry.id)")
    }

    private func downloadModel(id: String) -> DownloadableModel? {
        center.models.first { $0.id == id }
    }

    private func primaryTitle(for model: DownloadableModel) -> String {
        switch model.state {
        case .ready: return "Select"
        case .downloading, .enumerating: return "Downloading…"
        case .idle, .failed: return "Download"
        }
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
        voiceSettings.selectEngine(kind)
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
        } else if case .failed = engineState(for: kind) {
            // On disk but the last load failed → clear and retry.
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
        }
    }

    private func engineState(for kind: VoiceEngineKind) -> VoiceModelState {
        switch kind {
        case .appleSystem: return voiceService.systemState
        case .kittenTTS:   return voiceService.kittenState
        case .kokoro:      return voiceService.kokoroState
        }
    }

    private func voiceList(for kind: VoiceEngineKind) -> [VoiceOption] {
        switch kind {
        case .appleSystem: return voiceService.systemEngine.availableVoices
        case .kittenTTS:   return KittenTTSService.kittenVoices
        case .kokoro:      return KokoroTTSService.kokoroVoices
        }
    }

    // MARK: - Hint

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("tip")
                .font(T.mono(9, .semibold))
                .tracking(0.5)
                .foregroundColor(T.ink3)
            Text("Apple System Voice ships with iOS premium voices and works offline out of the box — it's the most reliable choice. On-device neural voices (KittenTTS, Kokoro) are smaller English voices that some people prefer; if one ever fails its self-check, the app reads replies through System Voice automatically. Pick the specific voice and speed in Voice settings.")
                .font(T.sans(11))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kGlass(cornerRadius: 8, fallbackFill: T.surface)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

}

struct VoiceCatalogDetailView: View {
    let entry: VoiceCatalogEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(entry.name).font(T.display(28, .bold)).foregroundColor(T.ink)
                    Text(entry.summary).font(T.sans(15)).foregroundColor(T.ink2)
                    LabeledContent("Task", value: entry.task == .textToSpeech ? "Text to Speech" : "Speech Recognition")
                    LabeledContent("Support", value: entry.statusLabel)
                    if let source = entry.sourceURL, let url = URL(string: source) {
                        Link("Open Project", destination: url)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Model Details")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
