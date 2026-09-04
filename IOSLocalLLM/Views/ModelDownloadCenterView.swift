import SwiftUI
import Combine

// MARK: - ModelDownloadCenterView
// Presents the full model catalog with per-model download cards.
// Accessible from Settings → "Download Models".

struct ModelDownloadCenterView: View {

    @StateObject private var center = ModelDownloadCenter.shared
    @State private var showSearch = false
    /// Which model role the catalog is currently showing. The selector at the
    /// top switches this so the screen presents ONE category's models (plus the
    /// search affordances related to it) instead of one long stacked scroll.
    @State private var selectedCategory: DownloadableModel.Category = .assistant
    /// Category-filtered search sheet. When set, opens HFSearchView pre-scoped
    /// to that filter so the user lands on a curated list instead of a blank
    /// search bar.
    @State private var presetSearchFilter: HFSearchService.Filter? = nil
    /// Richer preset that also seeds an initial query (used by the
    /// device-tier "recommended" row).
    @State private var presetSearch: PresetSearch? = nil

    struct PresetSearch: Identifiable {
        let id = UUID()
        let filter: HFSearchService.Filter
        let query: String
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Page header
                    VStack(alignment: .leading, spacing: 4) {
                        KCaption(text: "MODELS")
                        KPageTitle(title: "Download", size: 30)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    storageHeader
                    categorySelector
                    selectedCategoryContent
                    infoSection
                }
                .padding(.bottom, 32)
            }
            .refreshable {
                HapticManager.impact(.light)
                center.refreshAllStates()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(T.ink)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSearch) { HFSearchView() }
            .sheet(item: $presetSearchFilter) { filter in
                HFSearchView(initialFilter: filter)
            }
            .sheet(item: $presetSearch) { p in
                HFSearchView(initialFilter: p.filter, initialQuery: p.query)
            }
            .background(LiquidPinkBackdrop())
            .onAppear { center.refreshAllStates() }
            // Refresh when app comes back to foreground, in case the user
            // deleted files externally or another tab finished a download.
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification)) { _ in
                center.refreshAllStates()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .hfModelDownloadCompleted)) { _ in
                center.refreshAllStates()
            }
        }
    }

    // MARK: - Storage summary header

    private var storageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                KCaption(text: "storage")
                Rectangle().fill(T.rule).frame(height: 1)
            }
            .padding(.bottom, 8)

            KSpecTable(rows: [
                ("storage", "Documents · sandboxed"),
                ("ram", MemoryAdvisor.deviceSummary),
                ("source", "huggingface.co · resumable"),
            ], keyWidth: 80)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    // MARK: - Category selector
    //
    // A premium, native-feeling segmented control tinted per role (assistant =
    // rose, vision = sage, voice = violet, image = amber — the Models-hub tints
    // defined on the theme). Picking a role filters everything below to that
    // role, replacing the old all-categories-stacked scroll.

    private let categoryOrder: [DownloadableModel.Category] = [.assistant, .vlm, .voice, .imageGen]

    private var availableCategories: [DownloadableModel.Category] {
        categoryOrder.filter { cat in center.models.contains { $0.supportsCategory(cat) } }
    }

    private func categoryTitle(_ c: DownloadableModel.Category) -> String {
        switch c {
        case .assistant: return "assistant"
        case .vlm:       return "vision"
        case .voice:     return "voice"
        case .imageGen:  return "image"
        }
    }
    private func categorySymbol(_ c: DownloadableModel.Category) -> String {
        switch c {
        case .assistant: return "bubble.left.and.bubble.right.fill"
        case .vlm:       return "eye.fill"
        case .voice:     return "waveform"
        case .imageGen:  return "photo.fill"
        }
    }
    private func categoryTint(_ c: DownloadableModel.Category) -> Color {
        switch c {
        case .assistant: return T.accent
        case .vlm:       return T.accent2
        case .voice:     return T.voiceTint
        case .imageGen:  return T.imageTint
        }
    }

    private var categorySelector: some View {
        HStack(spacing: 4) {
            ForEach(availableCategories, id: \.self) { cat in
                let selected = cat == selectedCategory
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        selectedCategory = cat
                    }
                    HapticManager.impact(.light)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: categorySymbol(cat))
                            .font(.system(size: 14, weight: .semibold))
                        Text(categoryTitle(cat).capitalized)
                            .font(T.sans(11, .semibold))
                    }
                    .foregroundColor(selected ? categoryTint(cat) : T.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(selected ? categoryTint(cat).opacity(T.isDark ? 0.18 : 0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .kGlass(cornerRadius: 15, fallbackFill: T.surface)
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    // MARK: - Selected-category content

    @ViewBuilder
    private var selectedCategoryContent: some View {
        let items = center.models.filter { $0.supportsCategory(selectedCategory) }
        // Installed, required, and recommended models float to the top; the
        // long tail of near-identical variants collapses under "More models".
        let featured = items.filter { $0.isRequired || $0.isReady || $0.capabilities.contains(.recommended) }
        let rest = items.filter { m in !featured.contains(where: { $0.id == m.id }) }

        deviceTierHeader

        KSection(title: "\(categoryTitle(selectedCategory)) · \(items.count) models") {
            ForEach(Array(featured.enumerated()), id: \.element.id) { i, model in
                if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                modelCard(model)
            }
            if !rest.isEmpty {
                if !featured.isEmpty { Rectangle().fill(T.rule).frame(height: 1) }
                KDisclosureRows(title: "More models", count: rest.count) {
                    ForEach(rest, id: \.id) { model in
                        Rectangle().fill(T.rule).frame(height: 1)
                        modelCard(model)
                    }
                }
            }
        }

        categorySearch(for: selectedCategory)
    }

    @ViewBuilder
    private func modelCard(_ model: DownloadableModel) -> some View {
        ModelDownloadCard(model: model)
            .padding(14)
            .contextMenu {
                if let urlStr = model.docURL, let url = URL(string: urlStr) {
                    Button {
                        UIPasteboard.general.string = urlStr
                        ToastCenter.shared.info("Copied URL")
                    } label: {
                        Label("Copy repo URL", systemImage: "doc.on.doc")
                    }
                    Link(destination: url) {
                        Label("Open on huggingface.co", systemImage: "safari")
                    }
                }
                if model.isReady {
                    Button(role: .destructive) {
                        ModelDownloadCenter.shared.handleDeletion(of: model)
                    } label: {
                        Label("Delete model", systemImage: "trash")
                    }
                }
            }
    }

    // MARK: - Category-scoped search

    @ViewBuilder
    private func categorySearch(for category: DownloadableModel.Category) -> some View {
        KSection(title: "find more") {
            switch category {
            case .assistant:
                let tier = DeviceTierAdvisor.current
                searchRow(
                    icon: "wand.and.stars", tint: T.accent,
                    title: "recommended for \(tier.label) tier",
                    subtitle: tierAssistantHint(for: tier)
                ) {
                    presetSearch = .init(filter: .mlx, query: tierAssistantQuery(for: tier))
                }
                Rectangle().fill(T.rule).frame(height: 1)
            case .vlm:
                searchRow(
                    icon: "eye.fill", tint: T.accent2,
                    title: "more vision models",
                    subtitle: "qwen-vl · smolvlm · gemma vision"
                ) {
                    presetSearch = .init(filter: .vlm, query: "")
                }
                Rectangle().fill(T.rule).frame(height: 1)
            case .voice:
                searchRow(
                    icon: "speaker.wave.2.fill", tint: T.voiceTint,
                    title: "text-to-speech",
                    subtitle: "tts · kitten, kokoro, …"
                ) {
                    presetSearch = .init(filter: .tts, query: "")
                }
                Rectangle().fill(T.rule).frame(height: 1)
                searchRow(
                    icon: "mic.fill", tint: T.accent,
                    title: "speech-to-text",
                    subtitle: "asr · whisper · dictation"
                ) {
                    presetSearch = .init(filter: .asr, query: "")
                }
                Rectangle().fill(T.rule).frame(height: 1)
            case .imageGen:
                EmptyView()
            }
            searchRow(
                icon: "magnifyingglass", tint: T.ink2,
                title: "search all models",
                subtitle: "free text — auto-filtered to your device"
            ) {
                showSearch = true
            }
        }
    }

    /// Small headline summarizing the current device's classification so the
    /// "compatible" copy below doesn't feel arbitrary.
    private var deviceTierHeader: some View {
        let tier = DeviceTierAdvisor.current
        let ram = MemoryAdvisor.deviceTotalRAM.formattedBytes
        return HStack(spacing: 8) {
            Image(systemName: "iphone")
                .font(.system(size: 11))
                .foregroundColor(T.ink3)
            Text("this iphone · \(tier.label) tier · \(ram) ram")
                .font(T.mono(10, .semibold))
                .tracking(0.4)
                .foregroundColor(T.ink3)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    /// Recommended assistant query keywords per device tier.
    private func tierAssistantQuery(for tier: DeviceTier) -> String {
        switch tier {
        case .lite, .entry: return "qwen2.5 coder 1.5b"
        case .mid:          return "llama 3.2 3b mlx"
        case .pro:          return "qwen 4b mlx"
        case .max:          return "qwen 7b mlx"
        }
    }
    private func tierAssistantHint(for tier: DeviceTier) -> String {
        switch tier {
        case .lite:  return "smallest, fastest — fits in 3 GB"
        case .entry: return "1–2 GB · safe on 4 GB devices"
        case .mid:   return "3 B class · sweet spot on 6 GB"
        case .pro:   return "4 B class · richer answers on 8 GB"
        case .max:   return "7 B+ · top quality with plenty of headroom"
        }
    }

    @ViewBuilder
    private func searchRow(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            HapticManager.impact(.light)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(tint)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(T.mono(13, .semibold))
                        .foregroundColor(T.ink)
                    KMono(text: subtitle, size: 10, color: T.ink3)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(T.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Info footer

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                KCaption(text: "guarantees")
                Rectangle().fill(T.rule).frame(height: 1)
            }
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Text("●")
                        .font(T.mono(10))
                        .foregroundColor(T.good)
                    VStack(alignment: .leading, spacing: 2) {
                        KMono(text: "privacy", size: 11, weight: .semibold, color: T.ink)
                        Text("Downloaded models run locally. Optional web search, private-cloud models, and paired tools use the network when you enable them.")
                            .font(T.sans(11))
                            .foregroundColor(T.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Rectangle().fill(T.rule).frame(height: 1)
                HStack(alignment: .top, spacing: 8) {
                    Text("↻")
                        .font(T.mono(10))
                        .foregroundColor(T.ink2)
                    VStack(alignment: .leading, spacing: 2) {
                        KMono(text: "resumable", size: 11, weight: .semibold, color: T.ink)
                        Text("Interrupted downloads resume automatically. You can close the app mid-download.")
                            .font(T.sans(11))
                            .foregroundColor(T.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .kGlass(cornerRadius: 8, fallbackFill: T.surface)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }
}

// MARK: - ModelDownloadCard
// Full card for a single downloadable model.

struct ModelDownloadCard: View {

    @ObservedObject var model: DownloadableModel
    @ObservedObject private var downloaderObs: DownloadObserver
    @State private var showFixRepoSheet = false
    @State private var isAutoDiscovering = false
    @Environment(\.koduTheme) private var T

    init(model: DownloadableModel) {
        self.model = model
        self.downloaderObs = DownloadObserver(model: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row — vendor identity tile + name + capabilities + meta
            HStack(alignment: .top, spacing: 11) {
                // Premium gradient vendor thumbnail (replaces the old abstract
                // ▣/◉/◈/◆ glyph dot) — identifies the publisher at a glance.
                KVendorThumb(vendor: model.vendor, size: .row)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        KModelName(model.displayName,
                                   font: T.sans(15, .semibold),
                                   color: T.ink)
                        if model.isRequired {
                            KActivePill(text: "required")
                        }
                    }
                    // Capability markers (Recommended / Best / New / Vision /
                    // Thinking …) — present in the catalog data but never shown
                    // on this screen before.
                    if !model.capabilities.isEmpty {
                        KCapabilityPillRow(capabilities: Array(model.capabilities),
                                           size: .compact)
                    }
                    // Human one-liner.
                    KMono(text: model.subtitle, size: 11, color: T.ink2)
                        .lineLimit(2)
                    // Demoted developer meta: repo id · size (kept, not lost —
                    // just no longer the headline).
                    KMono(text: metaLine, size: 9.5, color: T.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 6)

                statusBadge
            }

            memoryWarning

            if downloaderObs.isActive { progressSection }

            actionRow
        }
        .sheet(isPresented: $showFixRepoSheet) {
            FixRepoSheet(model: model)
        }
        // Re-probe disk state each time the card becomes visible so models
        // that were downloaded in a previous session show "ready to use"
        // without requiring the user to tap Download.
        .task { model.checkIfReady() }
    }

    /// "mlx-community/Qwen3-… · ~2.3 GB" — repo id + size, kept visible but
    /// demoted to a muted line under the human copy.
    private var metaLine: String {
        let repo = model.downloader?.repoID ?? model.id
        return "\(repo) · \(model.sizeLabel)"
    }

    /// Triggers FastVLM auto-discovery and starts the resulting download.
    @MainActor
    private func runAutoDiscover() async {
        isAutoDiscovering = true
        defer { isAutoDiscovering = false }
        if let repoID = await FastVLMRepoAutoDiscovery.shared.discover() {
            ToastCenter.shared.success("Found FastVLM mirror", detail: repoID)
            // ModelDownloadCenter listens to changes and rebuilds the entry;
            // give it a beat to settle, then kick off the actual download.
            try? await Task.sleep(nanoseconds: 250_000_000)
            ModelDownloadCenter.shared.refreshAllStates()
            ModelDownloadCenter.shared.fastvlmModel?.start()
        } else {
            ToastCenter.shared.error(
                "No public FastVLM mirror responded",
                detail: "Try the 'find repo' picker or search HuggingFace manually."
            )
        }
    }
    // MARK: - Sub-views

    @ViewBuilder
    private var memoryWarning: some View {
        // Compact one-line chip; the full sentence is revealed on tap rather
        // than stacked as a multi-line tinted paragraph on every card.
        switch MemoryAdvisor.verdictWithCurrentlyLoaded(for: model.id) {
        case .marginal(let msg):
            HStack { KCompatChip(level: .tight, text: "Tight fit", detail: msg); Spacer() }
        case .wontFit(let msg):
            HStack { KCompatChip(level: .blocked, text: "Won't fit", detail: msg); Spacer() }
        case .fitsComfortably:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch downloaderObs.state {
        case .ready:
            // Ready is shown once — in the action row ("ready to use" + trash).
            EmptyView()
        case .downloading:
            KMono(text: String(format: "%.0f%%", downloaderObs.progress * 100),
                   size: 11, weight: .semibold, color: T.accent)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.18), value: downloaderObs.progress)
        case .enumerating:
            Text("Preparing…")
                .font(T.mono(10))
                .foregroundColor(T.warn)
        case .failed:
            KStatusBadge(glyph: .remote, label: "failed", color: T.bad)
        case .idle:
            EmptyView()
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Thin 2px progress bar in accent
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(T.surface2).frame(height: 2)
                    Rectangle().fill(T.accent)
                        .frame(width: geo.size.width * downloaderObs.progress, height: 2)
                        .animation(.linear(duration: 0.3), value: downloaderObs.progress)
                }
            }
            .frame(height: 2)

            HStack {
                KMono(text: downloaderObs.currentFile.isEmpty ? "starting…" : downloaderObs.currentFile,
                       size: 10, color: T.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if downloaderObs.totalBytes > 0 {
                    KMono(text: "\(downloaderObs.downloadedBytes.formattedBytes) / \(downloaderObs.totalBytes.formattedBytes)",
                           size: 10, color: T.ink3)
                }
            }

            HStack {
                if downloaderObs.filesTotal > 1 {
                    KMono(text: "\(downloaderObs.filesDone) / \(downloaderObs.filesTotal) files",
                           size: 10, color: T.ink3)
                }
                Spacer()
                if downloaderObs.bytesPerSec > 1024 {
                    KMono(text: rateAndETA, size: 10, color: T.ink2)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.25), value: downloaderObs.bytesPerSec)
                }
            }
        }
    }

    /// "12.4 MB/s · ~2 min left" — speed always, ETA when we have one.
    private var rateAndETA: String {
        let speed = "\(Int64(downloaderObs.bytesPerSec).formattedBytes)/s"
        guard let eta = downloaderObs.etaSeconds else { return speed }
        return "\(speed) · \(Self.formatETA(eta)) left"
    }

    private static func formatETA(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(s, 1))s" }
        let m = s / 60
        if m < 60 { return "~\(m) min" }
        let h = m / 60
        let rem = m % 60
        return rem == 0 ? "~\(h)h" : "~\(h)h \(rem)m"
    }

    @ViewBuilder
    private var actionRow: some View {
        let dlState: HFModelDownloadManager.DownloadState = downloaderObs.state
        HStack(spacing: 8) {
            switch dlState {
            case .idle, .failed:
                let isFailed: Bool = { if case .failed = dlState { return true } else { return false } }()
                Button {
                    model.start()
                    HapticManager.impact(.medium)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isFailed ? "arrow.clockwise" : "arrow.down")
                            .font(.system(size: 11, weight: .medium))
                        Text(isFailed ? "retry" : "download")
                            .font(T.mono(11, .semibold))
                            .tracking(0.3)
                    }
                    .foregroundColor(T.bg)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(T.ink))
                }
                .buttonStyle(.plain)

                // Recovery pills shown when a download fails.
                if isFailed {
                    // VLM gets an extra one-tap auto-find that probes every
                    // known FastVLM mirror and picks the first one alive.
                    if model.id == FastVLMService.modelID {
                        Button {
                            Task { await runAutoDiscover() }
                        } label: {
                            HStack(spacing: 4) {
                                if isAutoDiscovering {
                                    ProgressView().tint(T.accent).scaleEffect(0.55)
                                        .frame(width: 10, height: 10)
                                } else {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 10))
                                }
                                Text(isAutoDiscovering ? "finding…" : "auto-find")
                                    .font(T.mono(10, .semibold))
                            }
                            .foregroundColor(T.good)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 5).fill(T.good.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .disabled(isAutoDiscovering)
                    }

                    Button {
                        showFixRepoSheet = true
                        HapticManager.impact(.light)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.system(size: 10))
                            Text("find repo")
                                .font(T.mono(10, .semibold))
                        }
                        .foregroundColor(T.accent)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(T.accentSoft))
                    }
                    .buttonStyle(.plain)
                }

                if case .failed(let msg) = dlState {
                    KMono(text: msg, size: 9, color: T.bad)
                        .lineLimit(2)
                }

            case .enumerating:
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                    Text("preparing…")
                        .font(T.mono(11))
                }
                .foregroundColor(T.ink3)

            case .downloading:
                Button {
                    model.cancel()
                    HapticManager.impact(.light)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pause.circle")
                            .font(.system(size: 11))
                        Text("pause")
                            .font(T.mono(11, .semibold))
                    }
                    .foregroundColor(T.warn)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(T.warn.opacity(0.12)))
                }
                .buttonStyle(.plain)

            case .ready:
                KStatusBadge(glyph: .ready, label: "ready to use", color: T.good)

                Spacer()

                Button(role: .destructive) {
                    // handleDeletion resets active selections, unregisters
                    // custom entries, and surfaces failures as a toast.
                    ModelDownloadCenter.shared.handleDeletion(of: model)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(T.bad.opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if let urlStr = model.docURL, let url = URL(string: urlStr) {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11))
                        .foregroundColor(T.ink3)
                }
            }
        }
    }
}

// MARK: - DownloadObserver
// A small ObservableObject that bridges the DownloadableModel's underlying
// downloader(s) to the card view, updating on every published change.

@MainActor
final class DownloadObserver: ObservableObject {
    @Published var state: HFModelDownloadManager.DownloadState = .idle
    @Published var progress: Double = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var currentFile: String = ""
    @Published var filesDone: Int = 0
    @Published var filesTotal: Int = 0
    /// Smoothed download throughput in bytes/sec. Drives the speed + ETA
    /// readout so a multi-GB download tells the user how long it'll take
    /// instead of just creeping a progress bar.
    @Published var bytesPerSec: Double = 0

    var isActive: Bool { state == .downloading || state == .enumerating }

    /// Estimated seconds remaining, or nil when we can't make a trustworthy
    /// estimate (not downloading, no rate yet, unknown total).
    var etaSeconds: Double? {
        guard state == .downloading, bytesPerSec > 1024, totalBytes > 0 else { return nil }
        let remaining = Double(totalBytes - downloadedBytes)
        guard remaining > 0 else { return nil }
        return remaining / bytesPerSec
    }

    private var cancellables = Set<AnyCancellable>()
    private let model: DownloadableModel

    // Rolling-rate state. We sample at most ~2×/sec and smooth with an EMA so
    // the readout doesn't jitter on every chunk callback.
    private var lastSampleBytes: Int64 = 0
    private var lastSampleTime: Date?

    init(model: DownloadableModel) {
        self.model = model
        sync()
        subscribe()
    }

    private func sync() {
        let previousState = state
        state          = model.state
        progress       = model.progress
        downloadedBytes = model.downloadedBytes
        totalBytes     = model.totalBytes
        currentFile    = model.currentFile
        filesDone      = model.downloader?.filesDone ?? 0
        filesTotal     = model.downloader?.filesTotal ?? 0
        updateRate(enteredDownloading: previousState != .downloading && state == .downloading)
    }

    private func updateRate(enteredDownloading: Bool) {
        guard state == .downloading else {
            bytesPerSec = 0
            lastSampleTime = nil
            return
        }
        if enteredDownloading || lastSampleTime == nil {
            lastSampleBytes = downloadedBytes
            lastSampleTime = Date()
            return
        }
        let now = Date()
        let dt = now.timeIntervalSince(lastSampleTime!)
        guard dt >= 0.4 else { return }   // throttle: don't sample on every chunk
        let delta = Double(downloadedBytes - lastSampleBytes)
        if delta >= 0 {                   // ignore the dip when a resume rewinds bytes
            let instantaneous = delta / dt
            bytesPerSec = bytesPerSec == 0 ? instantaneous
                                           : bytesPerSec * 0.7 + instantaneous * 0.3
        }
        lastSampleBytes = downloadedBytes
        lastSampleTime = now
    }

    private func subscribe() {
        // Observe HFModelDownloadManager if present
        if let d = model.downloader {
            d.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.sync() }
                .store(in: &cancellables)
        }
    }
}
