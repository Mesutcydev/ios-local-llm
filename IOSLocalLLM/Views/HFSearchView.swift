import SwiftUI

// MARK: - HFSearchView
// Live search of Hugging Face for downloadable models.
// Results can be downloaded into the app's Documents folder via HFModelDownloadManager.

struct HFSearchView: View {

    @StateObject private var search = HFSearchService()
    @State private var query: String
    @State private var filter: HFSearchService.Filter
    @State private var debounceTask: Task<Void, Never>?
    /// When true, hide HF results that OnDeviceCompatibility marks as
    /// `.blocked`. On by default — users almost never want to see GGUF or
    /// 70B PyTorch repos in a list filtered to "what I can actually run".
    @State private var showOnlyCompatible: Bool = true

    /// Lets callers pre-seed a category-specific landing page. The download
    /// manager uses this so "browse visual models" and "browse audio models"
    /// open the search already scoped to VLM / TTS / ASR respectively.
    init(initialFilter: HFSearchService.Filter = .mlx, initialQuery: String = "") {
        _filter = State(initialValue: initialFilter)
        _query  = State(initialValue: initialQuery)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Rectangle().fill(T.rule).frame(height: 1)
                resultsList
            }
            .background(LiquidPinkBackdrop())
            .navigationTitle("Find Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(T.ink)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "search models (qwen, llama, kokoro…)")
            .onChange(of: query) { _, _ in scheduleSearch() }
            .onChange(of: filter) { _, _ in scheduleSearch() }
            // Fire on appear when either a query is already set OR the user
            // arrived via a category landing (e.g. browse VLM models) so the
            // list isn't empty until they type something.
            .onAppear {
                if results.isEmpty && (!query.isEmpty || !filter.hfFilters.isEmpty) {
                    scheduleSearch()
                }
            }
        }
    }

    private var results: [HFModelSummary] {
        guard showOnlyCompatible else { return search.results }
        return search.results.filter { m in
            if case .blocked = OnDeviceCompatibility.verdict(for: m) { return false }
            return true
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(spacing: 12) {
            HStack {
                Menu {
                    ForEach(HFSearchService.Filter.allCases) { f in
                        Button {
                            filter = f
                            HapticManager.impact(.light)
                        } label: {
                            if filter == f {
                                Label(f.rawValue, systemImage: "checkmark")
                            } else {
                                Text(f.rawValue)
                            }
                        }
                    }
                } label: {
                    Label(filter.rawValue, systemImage: "line.3.horizontal.decrease")
                        .font(T.sans(14, .medium))
                        .foregroundColor(T.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .kGlassCapsule(fallbackFill: T.surface, fallbackStroke: T.glassBorder)
                }

                Spacer()

                // Show "N of M" when the compatibility filter is hiding some,
                // so filtered-out results aren't silently uncounted.
                Text(results.count == search.results.count
                     ? "\(results.count) models"
                     : "\(results.count) of \(search.results.count)")
                    .font(T.sans(12))
                    .foregroundColor(T.ink3)
            }

            Toggle(isOn: $showOnlyCompatible) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fits this iPhone")
                        .font(T.sans(14, .medium))
                        .foregroundColor(T.ink)
                    Text("Hide models that cannot run on this device")
                        .font(T.sans(11))
                        .foregroundColor(T.ink3)
                }
            }
            .toggleStyle(.switch)
            .tint(T.accent)
            .onChange(of: showOnlyCompatible) { _, _ in
                HapticManager.impact(.light)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Results list

    @ViewBuilder
    private var resultsList: some View {
        if search.isSearching && results.isEmpty {
            // Skeleton rows for native-feeling loading
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(0..<5, id: \.self) { _ in
                        SearchRowSkeleton()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        } else if let err = search.lastError {
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 30))
                    .foregroundColor(T.ink3)
                KMono(text: "search failed", size: 12, color: T.ink2)
                Text(err)
                    .font(T.sans(11))
                    .foregroundColor(T.ink3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if query.isEmpty {
            promotedSuggestions
        } else if results.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30))
                    .foregroundColor(T.ink3)
                KMono(text: "no matches", size: 12, color: T.ink2)
                KMono(text: "try a different query or filter.", size: 10, color: T.ink3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(results) { model in
                        HFSearchRow(model: model)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .refreshable {
                await search.search(query: query, filter: filter)
            }
        }
    }

    // MARK: - Promoted suggestions when no query

    private var promotedSuggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                KCaption(text: "Suggestions")
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                VStack(spacing: 0) {
                    ForEach(Array(curated.enumerated()), id: \.offset) { i, q in
                        if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                        Button {
                            query = q
                            HapticManager.impact(.light)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkle.magnifyingglass")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(T.accent)
                                Text(q)
                                    .font(T.sans(14))
                                    .foregroundColor(T.ink)
                                Spacer()
                                Image(systemName: "arrow.up.left")
                                    .font(.system(size: 10))
                                    .foregroundColor(T.ink3)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .kGlass(cornerRadius: 18, fallbackFill: T.surface, fallbackStroke: T.glassBorder)
                .padding(.horizontal, 16)

                infoBox
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            .padding(.bottom, 16)
        }
    }

    private let curated: [String] = [
        "mlx-community qwen", "mlx-community llama", "mlx-community mistral",
        "mlx-community gemma", "mlx-community phi", "kokoro tts",
        "fastvlm", "whisper coreml"
    ]

    private var infoBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(T.good)
                Text("Built for on-device use")
                    .font(T.sans(13, .semibold))
                    .foregroundColor(T.ink)
            }
            Text("Results filtered to on-device runtimes by default — MLX, Core ML, and supported GGUF vision repos. Files are stored privately in the app's Documents folder.")
                .font(T.sans(11))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .kGlass(cornerRadius: 18, fallbackFill: T.surface, fallbackStroke: T.glassBorder)
    }

    // MARK: - Debounced search

    private func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)   // 350 ms
            if Task.isCancelled { return }
            await search.search(query: query, filter: filter)
        }
    }
}

// MARK: - HFSearchRow

struct HFSearchRow: View {
    let model: HFModelSummary

    @State private var isExpanded = false
    @State private var estimatedSize: Int64? = nil
    @State private var didFetchSize = false

    @StateObject private var downloader: HFModelDownloadManager
    @State private var didStartDownload = false
    @Environment(\.koduTheme) private var T

    init(model: HFModelSummary) {
        self.model = model
        // Reuse an existing catalog-registered downloader when possible so
        // search and download-center views share the same progress state.
        if let existing = ModelDownloadCenter.shared.existingDownloader(forRepoID: model.id) {
            self._downloader = StateObject(wrappedValue: existing)
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dest = docs.appendingPathComponent("HFModels", isDirectory: true)
                .appendingPathComponent(model.id.replacingOccurrences(of: "/", with: "_"))
            self._downloader = StateObject(wrappedValue:
                HFModelDownloadManager(repoID: model.id, destination: dest))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: pipelineIcon)
                    .foregroundColor(T.accent)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(T.accentSoft)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    KModelName(
                        model.modelName,
                        font: T.display(16, .semibold),
                        color: T.ink
                    )
                    Text(model.author)
                        .font(T.sans(11))
                        .foregroundColor(T.ink3)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 6) {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 9))
                            Text(model.downloads.compactCount)
                                .font(T.mono(9))
                        }
                        HStack(spacing: 2) {
                            Image(systemName: "heart")
                                .font(.system(size: 9))
                            Text(model.likes.compactCount)
                                .font(T.mono(9))
                        }
                    }
                    .foregroundColor(T.ink3)
                    if let size = estimatedSize {
                        Text(size.formattedBytes)
                            .font(T.sans(11, .medium))
                            .foregroundColor(T.ink2)
                    }
                }
            }

            compatibilityBadge

            if !chipTags.isEmpty {
                KFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(chipTags, id: \.self) { tag in
                        Text(tag)
                            .font(T.sans(11, .medium))
                            .foregroundColor(tagColor(tag).contentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(tagColor(tag).background))
                            .overlay(Capsule()
                                .stroke(tagColor(tag).contentColor.opacity(0.22), lineWidth: 0.5))
                    }
                }
            }

            Rectangle().fill(T.rule).frame(height: 1)

            HStack(spacing: 8) {
                downloadButton

                Spacer()

                if let url = model.hfURL {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(T.ink2)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(T.surface2))
                    }
                }

                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(T.ink2)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(T.surface2))
                }
                .buttonStyle(.plain)
            }

            if isExpanded { expandedDetail }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kGlass(cornerRadius: 22, fallbackFill: T.surface, fallbackStroke: T.glassBorder)
        .task {
            if !didFetchSize {
                didFetchSize = true
                estimatedSize = await HFSearchService.estimatedSize(for: model.id)
            }
        }
    }

    // MARK: - Sub-views

    /// Compatibility pill — green/orange/red one-liner explaining whether
    /// the model can actually run on this iPhone.
    @ViewBuilder
    private var compatibilityBadge: some View {
        let verdict = OnDeviceCompatibility.verdict(for: model)
        // The runtime/quant ("MLX 4-bit") is already shown as a chip below the
        // row, so the verdict pill states only the verdict — no duplication.
        switch verdict {
        case .runnable(let notes):
            badgePill(symbol: "checkmark.circle.fill",
                      text: "runs on this iPhone",
                      detail: notes, color: T.good)
        case .marginal(let notes):
            badgePill(symbol: "exclamationmark.triangle.fill",
                      text: "tight fit",
                      detail: notes, color: T.warn)
        case .blocked(let reason):
            badgePill(symbol: "xmark.octagon.fill",
                      text: "won't run on this iPhone",
                      detail: reason, color: T.bad)
        }
    }

    @ViewBuilder
    private func badgePill(symbol: String, text: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.top, 1)
                Text(text)
                    .font(T.sans(12, .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(color)
            if isExpanded {
                Text(detail)
                    .font(T.sans(11))
                    .foregroundColor(T.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 19)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(color.opacity(0.09)))
    }

    @ViewBuilder
    private var downloadButton: some View {
        let state: HFModelDownloadManager.DownloadState = downloader.state
        let verdict = OnDeviceCompatibility.verdict(for: model)
        let isBlocked: Bool = { if case .blocked = verdict { return true } else { return false } }()
        if categoryGuess == .imageGen {
            // Diffusion models can only be installed from the curated Images
            // tab — surface that here instead of a (broken) generic download.
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .semibold))
                Text("Images tab")
                    .font(T.sans(13, .semibold))
            }
            .foregroundColor(T.accent2)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Capsule().fill(T.accent2.opacity(0.12)))
        } else {
        switch state {
        case .idle, .failed:
            let isFailed: Bool = { if case .failed = state { return true } else { return false } }()
            Button {
                downloader.start()
                didStartDownload = true
                // Register in the catalog so the user can find it later
                ModelDownloadCenter.shared.registerCustom(
                    repoID: model.id,
                    displayName: model.modelName,
                    subtitle: model.id,
                    category: categoryGuess,
                    sizeLabel: estimatedSize?.formattedBytes ?? "?",
                    docURL: model.hfURL?.absoluteString,
                    downloader: downloader
                )
                HapticManager.impact(.medium)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isFailed ? "arrow.clockwise" : "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                    Text(isFailed ? "retry" : (isBlocked ? "incompatible" : "download"))
                        .font(T.sans(13, .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Capsule().fill(isBlocked ? T.ink3 : T.accentStrong))
            }
            .buttonStyle(.plain)
            .disabled(isBlocked)
            .opacity(isBlocked ? 0.6 : 1)
        case .enumerating:
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9))
                Text("checking…")
                    .font(T.mono(10))
            }
            .foregroundColor(T.ink3)
        case .downloading:
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(T.surface2).frame(height: 2)
                        Rectangle().fill(T.accent)
                            .frame(width: geo.size.width * downloader.progress, height: 2)
                    }
                }
                .frame(width: 80, height: 2)
                KMono(text: String(format: "%.0f%%", downloader.progress * 100),
                       size: 10, weight: .semibold, color: T.accent)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.18), value: downloader.progress)
                Button { downloader.cancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(T.warn)
                }
                .buttonStyle(.plain)
            }
        case .ready:
            KStatusBadge(glyph: .ready, label: "downloaded", color: T.good)
        }
        }
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(T.rule).frame(height: 1)
                .padding(.vertical, 4)

            if let license = model.licenseTag {
                KMono(text: "license · \(license)", size: 10, color: T.ink2)
            }
            if let ts = model.lastModified {
                KMono(text: "updated · \(ts.formatted(date: .abbreviated, time: .omitted))",
                       size: 10, color: T.ink2)
            }
            // (Compatibility is stated authoritatively by the always-visible
            // verdict pill above — the old expanded dot used a weaker heuristic
            // that could contradict it, so it's been removed.)
            KMono(text: "→ HFModels/\(model.id.replacingOccurrences(of: "/", with: "_"))",
                   size: 9, color: T.ink3)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.top, 2)
    }

    // MARK: - Helpers

    private var categoryGuess: DownloadableModel.Category {
        LocalModelRegistry.category(for: model)
    }

    private var pipelineIcon: String {
        switch model.pipelineTag {
        case "text-generation":          return "text.bubble"
        case "image-text-to-text":       return "eye.and.bubble"
        case "text-to-speech":           return "speaker.wave.2"
        case "automatic-speech-recognition": return "mic"
        case "image-classification":     return "photo"
        default:                         return "cube"
        }
    }

    /// A compact selection of the most useful tags for display.
    private var chipTags: [String] {
        var picked: [String] = []
        if model.isMLX    { picked.append("MLX") }
        if model.isCoreML { picked.append("Core ML") }
        if model.isGGUF   { picked.append("GGUF") }
        if let l = model.licenseTag { picked.append(l) }
        if let p = model.pipelineTag {
            picked.append(p.replacingOccurrences(of: "-", with: " "))
        }
        return Array(picked.prefix(5))
    }

    private struct TagStyle { let background: Color; let contentColor: Color }
    private func tagColor(_ tag: String) -> TagStyle {
        switch tag.lowercased() {
        case "mlx":     return TagStyle(background: T.accent.opacity(0.10), contentColor: T.accent)
        case "core ml": return TagStyle(background: T.good.opacity(0.10),   contentColor: T.good)
        case "gguf":    return TagStyle(background: T.warn.opacity(0.10),   contentColor: T.warn)
        default:        return TagStyle(background: T.surface2,             contentColor: T.ink2)
        }
    }
}

// MARK: - SearchRowSkeleton
// Studio-styled skeleton row with a soft pulse while the search request runs.

struct SearchRowSkeleton: View {
    @Environment(\.koduTheme) private var T

    var body: some View {
        HStack(spacing: 10) {
            // Each shape gets the shimmer modifier individually so the
            // gradient sweep masks the actual placeholder geometry rather
            // than a uniform rectangle behind everything. The cumulative
            // effect reads as "filling in" rather than "fading".
            RoundedRectangle(cornerRadius: 3)
                .fill(T.surface2)
                .frame(width: 18, height: 18)
                .shimmer(duration: 1.4)
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(T.surface2)
                    .frame(height: 12)
                    .frame(maxWidth: .infinity)
                    .shimmer(duration: 1.4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(T.surface2)
                    .frame(width: 110, height: 9)
                    .shimmer(duration: 1.4)
            }
            Spacer()
            RoundedRectangle(cornerRadius: 4)
                .fill(T.surface2)
                .frame(width: 70, height: 24)
                .shimmer(duration: 1.4)
        }
        .padding(16)
        .kGlass(cornerRadius: 22, fallbackFill: T.surface)
    }
}
