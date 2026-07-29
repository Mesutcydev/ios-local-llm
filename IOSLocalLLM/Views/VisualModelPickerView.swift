import SwiftUI

// MARK: - VisualModelPickerView
// Camera-side picker: choose which vision model the camera tab uses.
//
// Default is FastVLM (Apple's built-in). The user can swap in any MLX-format
// VLM they've downloaded (Qwen2-VL, SmolVLM, Paligemma, Gemma 3 Vision, etc.).
// Selecting "match camera" reverts to FastVLM.

struct VisualModelPickerView: View {

    @ObservedObject private var center = ModelDownloadCenter.shared
    @ObservedObject private var loc = LocalizationService.shared
    // NB: deliberately NOT observing MLXVisionService.shared. While the
    // picker is open the live caption auto-loop in the lens behind it
    // keeps ticking vision.state between .ready and .generating, which
    // re-renders the picker every few seconds. Combined with the
    // `.id(downloadTick)` rebuild trick that subtree-tear-down made the
    // sheet feel locked-up — tapping a downloaded VLM row appeared to
    // freeze the whole sheet because SwiftUI was rebuilding it under
    // your finger. We read vision.state lazily from the statusCard
    // instead; if it shows a stale state for a beat, the next render
    // (triggered by selectedID changing or the user dismissing) picks
    // up the fresh value.
    private var vision: MLXVisionService { MLXVisionService.shared }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    @State private var selectedID: String
    @State private var fastVLMStatus: FastVLMService.InstallStatus = .notInstalled
    @State private var showComparison = false
    @State private var isApplyingSelection = false
    /// VLM the user tapped to download from the "available" section. When its
    /// download finishes we auto-activate it — the one-tap "download & use"
    /// flow that matches the voice picker.
    @State private var pendingDownloadID: String?

    init() {
        _selectedID = State(initialValue: LocalModelRegistry.storedVisionSelectionID(
            AppSettings.shared.cameraVisualModelID
        ))
    }

    /// VLM-category downloaded models. Deduped by repoID. Uses the stricter
    /// per-backend runnability check (GGUF pair, MLX safetensors+config) on
    /// top of `isReady`, so a half-installed model can't be picked.
    private var downloadedVLMs: [DownloadableModel] {
        var seen = Set<String>()
        return center.models.filter { m in
            guard m.supportsCategory(.vlm) else { return false }
            // The FastVLM entry is required + handled by the default row.
            guard !m.isRequired else { return false }
            guard VisualModelInstallStatus.runStatus(for: m).isReady else { return false }
            return seen.insert(m.sourceRepoID).inserted
        }
    }

    /// True when a previous selection points to an MLX VLM no longer on disk
    /// (deleted in Models tab, reset, etc.). Used to surface a hint at the top
    /// so the user understands why the radio appears parked on FastVLM.
    private var hasStaleMLXSelection: Bool {
        !LocalModelRegistry.isDefaultVisionSelection(selectedID) &&
        !downloadedVLMs.contains(where: { $0.id == selectedID })
    }

    /// Catalog VLMs not yet on disk — listed so the user can download them
    /// right here instead of bouncing to the Model Center. Excludes the
    /// built-in FastVLM (its own row) and anything already runnable (those
    /// are in `downloadedVLMs`). Needs a downloader to be actionable.
    private var availableVLMs: [DownloadableModel] {
        var seen = Set<String>()
        return center.models.filter { m in
            guard m.supportsCategory(.vlm), !m.isRequired, m.downloader != nil else { return false }
            guard !VisualModelInstallStatus.runStatus(for: m).isReady else { return false }
            return seen.insert(m.sourceRepoID).inserted
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    if hasStaleMLXSelection { staleSelectionCard }
                    defaultRow
                    if !downloadedVLMs.isEmpty {
                        downloadedSection
                    }
                    if !availableVLMs.isEmpty {
                        availableSection
                    }
                    compareCard
                    browseMoreCard
                    hintCard
                    statusCard
                }
                .padding(.bottom, 32)
                // NB: previous shape was `.id(downloadTick)` on this VStack
                // to force a full subtree rebuild when a download finished.
                // That worked but tore the picker apart on every tick —
                // including mid-tap — which felt like the sheet was frozen
                // when a row was selected. center.models is already
                // @Published, so SwiftUI rebuilds the affected rows on its
                // own when a download completes; no manual id-bump needed.
            }
            .background(LiquidPinkBackdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.t("Close")) { dismiss() }
                    .foregroundColor(T.ink)
                }
            }
            // Re-poll on-disk state and re-render whenever any HF download
            // finishes — without this the picker stayed empty even after a
            // VLM finished downloading while the sheet was open.
            .onReceive(NotificationCenter.default.publisher(
                for: .hfModelDownloadCompleted)
            ) { _ in
                center.refreshAllStates()
                fastVLMStatus = FastVLMService.installStatus()
                // One-tap "download & use": when the model the user tapped in
                // the available section finishes, activate it automatically.
                if let pending = pendingDownloadID,
                   let m = center.models.first(where: { $0.sourceRepoID == pending }),
                   VisualModelInstallStatus.runStatus(for: m).isReady {
                    pendingDownloadID = nil
                    Task { @MainActor in
                        if await Self.applySelection(pending) { selectedID = pending }
                    }
                }
            }
            .onAppear {
                fastVLMStatus = FastVLMService.installStatus()
            }
            .sheet(isPresented: $showComparison) {
                VisualModelComparisonView()
            }
        }
    }

    /// Card-style launcher for the A/B comparison sheet. Lives below the
    /// downloaded section so it sits where the user is after picking;
    /// promoting it to a primary nav slot is overkill for a power-user
    /// feature.
    private var compareCard: some View {
        Button {
            HapticManager.impact(.light)
            showComparison = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.2x1.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(T.accent)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 6).fill(T.accentSoft))
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.t("compare models"))
                        .font(T.mono(12, .semibold))
                        .foregroundColor(T.ink)
                    KMono(text: loc.t("run two VLMs on the same image side by side"),
                          size: 10, color: T.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(T.ink3)
            }
            .padding(12)
        }
        .buttonStyle(.plain)
        .kGlass(cornerRadius: 8, fallbackFill: T.surface)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            KCaption(text: loc.t("CAMERA"))
            KPageTitle(title: loc.t("vision model"), size: 28)
            KMono(text: loc.t("tap a row to switch instantly"),
                  size: 11, color: T.ink3)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var defaultRow: some View {
        KSection(title: loc.t("default")) {
            Button {
                Task { await applySelectionAndDismiss(LocalModelRegistry.defaultVisionSelectionID) }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    radio(selected: LocalModelRegistry.isDefaultVisionSelection(selectedID)).padding(.top, 2)
                    KVendorThumb(vendor: .apple, size: .row)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(loc.t("FastVLM (built-in)"))
                                .font(T.mono(13, .semibold))
                                .foregroundColor(T.ink)
                            if LocalModelRegistry.isDefaultVisionSelection(selectedID) {
                                KActivePill(text: loc.t("active"))
                            }
                            if !fastVLMStatus.isFullyInstalled {
                                statusBadge(text: loc.t(fastVLMStatus.shortLabel), warning: true)
                            }
                        }
                        badgeRow(
                            formatLabel: "Core ML + MLX",
                            ramBytes: MemoryAdvisor.estimatedFootprint(for: FastVLMService.modelID),
                            verdict: fastVLMVerdict,
                            tokensPerSecond: ModelUsageTracker.shared.avgTPS(for: FastVLMService.modelID)
                        )
                        KMono(text: loc.t("Apple's encoder + MLX decoder — runs everywhere"),
                              size: 10, color: T.ink3)
                        if !fastVLMStatus.isFullyInstalled {
                            KMono(text: loc.t(fastVLMStatus.actionMessage),
                                  size: 10, color: T.bad)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .disabled(isApplyingSelection)
        }
    }

    /// Standard badge stack shown under the model name on every row:
    /// format pill, vision-capability pill, RAM estimate, perf history,
    /// and a coloured dot reflecting the MemoryAdvisor verdict. Each
    /// piece collapses when it has nothing to show, so half-installed
    /// rows degrade gracefully.
    @ViewBuilder
    private func badgeRow(
        formatLabel: String,
        ramBytes: Int64,
        verdict: MemoryAdvisor.Verdict,
        tokensPerSecond: Double?
    ) -> some View {
        HStack(spacing: 6) {
            formatPill(text: formatLabel)
            KCapabilityPill(capability: .vision, size: .compact)
            if ramBytes > 0 {
                ramPill(bytes: ramBytes, verdict: verdict)
            }
            if let tps = tokensPerSecond {
                perfPill(tokensPerSecond: tps)
            }
        }
    }

    /// Perf pill — average tokens/sec for this model across recorded
    /// runs. Hidden when there is no history yet (avoids a "0 tok/s"
    /// lie on a fresh download).
    @ViewBuilder
    private func perfPill(tokensPerSecond: Double) -> some View {
        let label = String(format: "%.0f tok/s", tokensPerSecond)
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8, weight: .bold))
            Text(label)
                .font(T.mono(8.5, .semibold))
                .tracking(0.4)
        }
        .foregroundColor(T.accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(T.accent.opacity(0.10)))
        .overlay(Capsule().stroke(T.accent.opacity(0.32), lineWidth: 0.5))
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Neutral pill used to label the inference backend (MLX / GGUF /
    /// Core ML + MLX). Visually parallel to KCapabilityPill but in the
    /// theme's ink color so it doesn't compete with semantic markers.
    @ViewBuilder
    private func formatPill(text: String) -> some View {
        Text(text.uppercased())
            .font(T.mono(8.5, .semibold))
            .tracking(0.6)
            .foregroundColor(T.ink2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill(T.ink2.opacity(0.10))
            )
            .overlay(
                Capsule().stroke(T.ink2.opacity(0.28), lineWidth: 0.5)
            )
            .fixedSize(horizontal: true, vertical: false)
    }

    /// RAM estimate pill with a verdict-coloured leading dot (green = fits
    /// comfortably, amber = marginal, red = won't fit on this device).
    @ViewBuilder
    private func ramPill(bytes: Int64, verdict: MemoryAdvisor.Verdict) -> some View {
        let color: Color = {
            switch verdict {
            case .fitsComfortably: return Color(red: 0.255, green: 0.722, blue: 0.392)
            case .marginal:        return Color(red: 0.961, green: 0.486, blue: 0.149)
            case .wontFit:         return T.bad
            }
        }()
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(bytes.formattedBytes)
                .font(T.mono(8.5, .semibold))
                .tracking(0.4)
                .foregroundColor(T.ink2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(color.opacity(0.10)))
        .overlay(Capsule().stroke(color.opacity(0.32), lineWidth: 0.5))
        .fixedSize(horizontal: true, vertical: false)
    }

    /// FastVLM verdict — kept as a computed property so callers don't have
    /// to know about the `verdictWithCurrentlyLoaded` MainActor requirement.
    private var fastVLMVerdict: MemoryAdvisor.Verdict {
        MemoryAdvisor.verdictWithCurrentlyLoaded(for: FastVLMService.modelID)
    }

    /// Small inline pill used for install-state badges. Mirrors KActivePill's
    /// look but tinted by whether the state is a warning vs neutral.
    @ViewBuilder
    private func statusBadge(text: String, warning: Bool) -> some View {
        Text(text)
            .font(T.mono(9, .semibold))
            .tracking(0.3)
            .foregroundColor(warning ? T.bad : T.ink2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill((warning ? T.bad : T.ink2).opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke((warning ? T.bad : T.ink2).opacity(0.25), lineWidth: 0.5)
            )
    }

    /// Shown when the previously selected MLX VLM is no longer on disk
    /// (e.g. deleted from Models tab). Explains why the picker appears parked
    /// on FastVLM and offers a one-tap clear.
    private var staleSelectionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc.t("previous selection unavailable"))
                .font(T.mono(9, .semibold))
                .tracking(0.5)
                .foregroundColor(T.bad)
            Text(loc.t("The VLM you previously picked was deleted or moved. Pick a model below, or re-download it from the Model Center."))
                .font(T.sans(11))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
            KMono(text: selectedID, size: 9, color: T.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(T.bad.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.bad.opacity(0.4), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Footer card pointing users at the Download Center to add more visual
    /// models. Direct deep-link is intentionally avoided here so the sheet
    /// stays single-purpose — it just hints; tap the path in the Models tab.
    private var browseMoreCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc.t("want more models?"))
                .font(T.mono(9, .semibold))
                .tracking(0.5)
                .foregroundColor(T.ink3)
            Text(loc.t("Browse Qwen3-VL, Gemma 3 Vision, SmolVLM2 and more in Models → Download Center. The picker updates automatically when a download finishes."))
                .font(T.sans(11))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kGlass(cornerRadius: 8, fallbackFill: T.surface)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var downloadedSection: some View {
        KSection(title: loc.t("downloaded_vlms")) {
            ForEach(Array(downloadedVLMs.enumerated()), id: \.offset) { i, m in
                if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                row(for: m)
            }
        }
    }

    // MARK: - Available to download (inline)

    private var availableSection: some View {
        KSection(title: loc.t("available")) {
            ForEach(Array(availableVLMs.enumerated()), id: \.element.id) { i, m in
                if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                availableRow(for: m)
            }
        }
    }

    /// A not-yet-downloaded catalog VLM. Tapping starts the download in place
    /// and marks it pending; the `.hfModelDownloadCompleted` handler activates
    /// it when the files land. Mirrors the voice picker's one-tap flow.
    @ViewBuilder
    private func availableRow(for m: DownloadableModel) -> some View {
        let vendor = ModelVendor.infer(from: m.sourceRepoID)
        let ram = VisualModelInstallStatus.ramEstimate(for: m)
        let verdict = VisualModelInstallStatus.memoryVerdict(for: m)
        let downloading = m.state == .downloading || m.state == .enumerating

        Button {
            guard !downloading else { return }
            pendingDownloadID = m.sourceRepoID
            m.start()
            HapticManager.impact(.medium)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Download glyph in the radio's slot — nothing to select until
                // the files are on disk.
                Image(systemName: downloading ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 16))
                    .foregroundColor(T.accent)
                    .frame(width: 16, height: 16)
                    .padding(.top, 2)
                KVendorThumb(vendor: vendor, size: .row)
                VStack(alignment: .leading, spacing: 4) {
                    KModelName(m.displayName,
                               font: T.mono(13, .semibold),
                               color: T.ink)
                    badgeRow(
                        formatLabel: VisualModelInstallStatus.formatLabel(for: m),
                        ramBytes: ram,
                        verdict: verdict,
                        tokensPerSecond: nil
                    )
                    KMono(text: m.sourceRepoID, size: 9, color: T.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if downloading {
                        HStack(spacing: 6) {
                            ProgressView().tint(T.accent).scaleEffect(0.6)
                            KMono(text: m.state == .enumerating
                                    ? loc.t("preparing…")
                                    : "\(loc.t("downloading")) \(Int(m.progress * 100))%",
                                  size: 10, color: T.ink2)
                        }
                    } else {
                        KMono(text: "\(m.sizeLabel) · \(loc.t("tap to download & use"))",
                              size: 10, color: T.accent)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(downloading)
    }

    @ViewBuilder
    private func row(for m: DownloadableModel) -> some View {
        let isSelected = selectedID == m.sourceRepoID
        let vendor = ModelVendor.infer(from: m.sourceRepoID)
        let format = VisualModelInstallStatus.formatLabel(for: m)
        let ram = VisualModelInstallStatus.ramEstimate(for: m)
        let verdict = VisualModelInstallStatus.memoryVerdict(for: m)
        Button {
            Task { await applySelectionAndDismiss(m.sourceRepoID) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                radio(selected: isSelected).padding(.top, 2)
                KVendorThumb(vendor: vendor, size: .row)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // KModelName: soft-break + scale + 2-line wrap.
                        // VLM names tend to be the longest in the catalog
                        // (e.g. "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF")
                        // so this picker was the worst offender for clipped
                        // suffixes before the upgrade.
                        KModelName(m.displayName,
                                   font: T.mono(13, .semibold),
                                   color: T.ink)
                        if isSelected {
                            KActivePill(text: loc.t("active"))
                        }
                    }
                    badgeRow(
                        formatLabel: format,
                        ramBytes: ram,
                        verdict: verdict,
                        tokensPerSecond: VisualModelInstallStatus.avgTokensPerSecond(for: m)
                    )
                    KMono(text: m.sourceRepoID, size: 9, color: T.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if case .wontFit(let warning) = verdict {
                        KMono(text: warning, size: 9, color: T.bad)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if case .marginal(let warning) = verdict {
                        KMono(text: warning, size: 9, color: Color(red: 0.961, green: 0.486, blue: 0.149))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .disabled(isApplyingSelection)
    }

    @ViewBuilder
    private func radio(selected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(selected ? T.accent : T.rule2, lineWidth: 1.5)
                .frame(width: 16, height: 16)
            if selected {
                Circle().fill(T.accent).frame(width: 9, height: 9)
            }
        }
    }

    // MARK: - Hint + status

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc.t("tip"))
                .font(T.mono(9, .semibold))
                .tracking(0.5)
                .foregroundColor(T.ink3)
            Text(loc.t("FastVLM is fastest. Swap in Qwen2-VL or Gemma 3 Vision if you want richer descriptions and have the RAM for it."))
                .font(T.sans(11))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text(loc.t("Download more VLMs in the Download Center → browse visual models."))
                .font(T.sans(11))
                .foregroundColor(T.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kGlass(cornerRadius: 8, fallbackFill: T.surface)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var statusCard: some View {
        switch vision.state {
        case .loading(let msg):
            HStack(spacing: 8) {
                ProgressView().tint(T.accent).scaleEffect(0.7)
                Text(msg).font(T.mono(11)).foregroundColor(T.ink2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(T.accentSoft))
            .padding(.horizontal, 16)
            .padding(.top, 8)
        case .failed(let msg):
            Text(msg)
                .font(T.mono(11))
                .foregroundColor(T.bad)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.bad.opacity(0.10)))
                .padding(.horizontal, 16)
                .padding(.top, 8)
        default:
            EmptyView()
        }
    }

    // MARK: - Apply

    private func applySelectionAndDismiss(_ id: String) async {
        guard !isApplyingSelection else { return }
        isApplyingSelection = true
        selectedID = id
        HapticManager.impact(.light)
        let didApply = await Self.applySelection(id)
        isApplyingSelection = false
        if didApply {
            dismiss()
        }
    }

    /// Commit a camera-VLM selection. Shared with the lens top-bar menu
    /// in `CameraRootView` so picking from the menu and picking from this
    /// sheet have identical side-effects: AppSettings is updated, the
    /// non-matching backend is unloaded to free RAM, and the chosen
    /// backend is pre-warmed via its own `switchTo`. The picker rows and
    /// the lens top-strip menu both funnel through here so activation stays
    /// consistent no matter where the user switches models.
    @MainActor
    @discardableResult
    static func applySelection(_ selectedID: String) async -> Bool {
        let vision = MLXVisionService.shared
        if LocalModelRegistry.isDefaultVisionSelection(selectedID) {
            // Default = FastVLM. Re-check install state at apply time so a
            // delete between picker-open and tap can't drive the camera into
            // a half-loaded state. Always save the preference (the user's
            // intent), but only drop any loaded MLX VLM when FastVLM is
            // actually usable — otherwise we'd leave the app with no working
            // vision model at all.
            let status = FastVLMService.installStatus()
            if status.isFullyInstalled {
                // Free anything else currently resident. FastVLM owns its
                // own residency through FastVLMService, so we just drop
                // the MLX and GGUF VLM containers that the picker might
                // have started earlier in the session.
                vision.unload()
                LlamaCppVLMService.shared.unload()
                LocalModelRegistry.setVisionSelection(selectedID)
                // Persist only after a runnable backend is confirmed. Saving a
                // failed heavy model first made every later Lens entry retry it.
                AppSettings.shared.hasPickedCameraVisualModel = true
                ToastCenter.shared.info("FastVLM is now active")
                return true
            } else {
                ToastCenter.shared.error(
                    "FastVLM needs download",
                    detail: status.actionMessage
                )
                return false
            }
        } else {
            // Hot-swap to a downloaded VLM. Two checks guard the path:
            //   1. The model must still be in the catalog AND pass the
            //      stricter `runStatus` gate (covers GGUF half-pairs and
            //      mid-sheet deletes that the simple `isReady` flag misses).
            //   2. We pre-warm the CORRECT backend service. AnalysisService
            //      routes GGUF repoIDs to LlamaCppVLMService at analysis
            //      time, but pre-warming the wrong one (MLX for a GGUF
            //      repo) would just churn — and worse, leave a confused
            //      "loading…" state on screen until the user re-triggers.
            let center = ModelDownloadCenter.shared
            guard let model = center.models.first(where: {
                $0.id == selectedID || $0.sourceRepoID == selectedID
            }),
                  VisualModelInstallStatus.runStatus(for: model).isReady else {
                ToastCenter.shared.error(
                    "Model not installed",
                    detail: "Download \(selectedID) in the Model Center before using it."
                )
                return false
            }
            switch VisualModelInstallStatus.backend(for: model) {
            case .gguf:
                // GGUF VLMs run through llama.cpp + mtmd. Drop any MLX
                // residency so the GPU isn't holding two pipelines at once.
                vision.unload()
                await LlamaCppVLMService.shared.switchTo(repoID: selectedID)
                if case .ready = LlamaCppVLMService.shared.state,
                   LlamaCppVLMService.shared.activeRepoID == selectedID {
                    LocalModelRegistry.setVisionSelection(selectedID)
                    AppSettings.shared.hasPickedCameraVisualModel = true
                    ToastCenter.shared.info("Switched to \(model.displayName)")
                    return true
                }
                return false
            case .mlx:
                let required = LensInferenceLoop.requiredVisionLoadBytes(repoID: selectedID)
                let available = UInt64(max(0, MemoryAdvisor.availableMemoryForModel))
                guard LensInferenceLoop.canSafelyLoadVision(
                    repoID: selectedID,
                    availableBytes: available
                ) else {
                    Diagnostics.shared.notice(
                        "Lens rejected · \(selectedID) · required=\(Int64(required).formattedBytes) · available=\(Int64(available).formattedBytes) · text-only model cannot serve as Lens",
                        category: "lens"
                    )
                    // Revert to the currently valid Lens selection. Never
                    // retain a text-only model (Bonsai-27B) as the Lens
                    // preference — it was rejected by VLM preflight and
                    // must not appear as the active vision model.
                    // settings.cameraVisualModelID already holds the correct
                    // safe value (setVisionSelection was never called for the
                    // rejected model); the picker UI will re-read it.
                    ToastCenter.shared.info(
                        "Keep this model in Assistant",
                        detail: "Its text runtime fits, but image analysis needs more memory. Lens will keep using the current smaller visual model."
                    )
                    return false
                }
                // Drop any GGUF residency to free RAM before MLX takes
                // over. switchTo() short-circuits when already loaded.
                LlamaCppVLMService.shared.unload()
                // Selecting the same repository in both pickers does not prove
                // the runtime is shared. Lens must drain any independently
                // owned Assistant text container before loading vision.
                await vision.switchTo(repoID: selectedID)
                if case .ready = vision.state, vision.activeRepoID == selectedID {
                    LocalModelRegistry.setVisionSelection(selectedID)
                    AppSettings.shared.hasPickedCameraVisualModel = true
                    ToastCenter.shared.info("Switched to \(model.displayName)")
                    return true
                }
                return false
            case .fastVLM:
                // FastVLM is the "default" row; selectedID-non-empty
                // should never resolve to it, but be tolerant in case
                // catalog wiring changes.
                vision.unload()
                LlamaCppVLMService.shared.unload()
                LocalModelRegistry.setVisionSelection(selectedID)
                AppSettings.shared.hasPickedCameraVisualModel = true
                return true
            }
        }
    }
}
