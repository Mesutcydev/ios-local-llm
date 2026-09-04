import SwiftUI
import Combine

// MARK: - OnboardingModelPickerView

// Choose a goal, then download a compatible model for that goal. Source-only
// installs contain no weights; Skip leaves setup available from Models.

struct OnboardingModelPickerView: View {

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var center   = ModelDownloadCenter.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.koduTheme) private var T

    /// Called by the parent OnboardingView when the user finishes
    /// (either via "Download & Continue" or "Skip"). The parent
    /// flips `hasSeenOnboarding` so we don't re-show the picker.
    var onComplete: () -> Void

    // MARK: - Selection state
    //
    // Default selections are seeded by `tierAwareDefaults()` on appear,
    // so a Pro/Max device starts on its tier-appropriate pick rather
    // than the safe-small fallback. The seed values below only apply
    // before `.onAppear` runs (a flash for one frame at most).

    @State private var pickedAssistantID: String = "qwen2.5-coder-1.5b"
    @State private var pickedVisualRepoID: String = "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF"

    /// Onboarding splits into the model picker and a download gate. The gate
    /// waits for the selected goal's model to finish downloading — but with a Skip so a
    /// flaky network can never lock a first launch out of the app.
    private enum Phase { case picking, downloading }
    @State private var phase: Phase = .picking
    private enum Goal: String, CaseIterable { case chat = "Chat", lens = "Lens", voice = "Voice" }
    @State private var goal: Goal = .chat
    private var needsAssistant: Bool { goal != .lens }
    private var needsVision: Bool { goal == .lens }
    /// Bumped by a 0.5s timer while downloading so progress bars re-render and
    /// the completion/failure checks run (download progress lives on the
    /// downloader, which doesn't republish `center.models`).
    @State private var gateTick = 0

    /// Defaults seeded by the current device tier so the wizard opens
    /// already selecting what `DeviceTierAdvisor` would silently pick on
    /// a Skip — the user can override but they don't have to.
    private func tierAwareDefaults() -> (assistantID: String, visualRepoID: String) {
        let tier = DeviceTierAdvisor.current
        let assistant: String = {
            switch tier {
            case .max:                  return "qwen3-4b"             // best of our picks
            case .pro:                  return "qwen3-4b"             // pro can fit 4B
            case .mid:                  return "llama-3.2-3b"
            case .entry, .lite:         return "qwen2.5-coder-1.5b"
            }
        }()
        let visual: String = {
            switch tier {
            case .max:                  return "mlx-community/Qwen3-VL-4B-Instruct-4bit"
            case .pro:                  return "mlx-community/Qwen3-VL-2B-Instruct-4bit"
            case .mid, .entry, .lite:   return "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF"
            }
        }()
        // Only return picks we actually have curated entries for —
        // otherwise the radio would have nothing to land on.
        let safeAssistant = assistantPicks.contains(where: { $0.id == assistant })
            ? assistant : "qwen2.5-coder-1.5b"
        let safeVisual = visualPicks.contains(where: { $0.id == visual })
            ? visual : "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF"
        return (safeAssistant, safeVisual)
    }

    // MARK: - Curated options
    //
    // Hand-picked 3 per slot. Order = display order (recommended
    // first). The recommendations match what DeviceTierAdvisor
    // would have picked on a mid-tier device — keeps Skip and
    // pick-the-default users in the same state.

    private struct AssistantPick: Identifiable {
        let id: String           // matches AssistantModel.id
        let displayName: String
        let summary: String
        let sizeLabel: String
        let vendor: ModelVendor
        let capabilities: Set<ModelCapability>
    }
    private let assistantPicks: [AssistantPick] = [
        AssistantPick(
            id: "qwen2.5-coder-1.5b",
            displayName: "Qwen 2.5 Coder 1.5B",
            summary: "Fast, code-tuned, runs on every device. The safe default.",
            sizeLabel: "~900 MB",
            vendor: .qwen,
            capabilities: [.recommended]
        ),
        AssistantPick(
            id: "qwen3-4b",
            displayName: "Qwen 3 4B",
            summary: "Stronger reasoning with /think mode. Needs ≥ 6 GB process memory.",
            sizeLabel: "~2.3 GB",
            vendor: .qwen,
            capabilities: [.thinking, .best]
        ),
        AssistantPick(
            id: "llama-3.2-3b",
            displayName: "Llama 3.2 3B",
            summary: "Meta's general-purpose chat model. Good fallback if Qwen feels too terse.",
            sizeLabel: "~1.8 GB",
            vendor: .meta,
            capabilities: []
        ),
    ]

    private struct VisualPick: Identifiable {
        let id: String           // = repoID
        let displayName: String
        let summary: String
        let sizeLabel: String
        let vendor: ModelVendor
        let capabilities: Set<ModelCapability>
    }
    private let visualPicks: [VisualPick] = [
        VisualPick(
            id: "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF",
            displayName: "SmolVLM 2 500M",
            summary: "A compact vision model. Download once, then use it offline.",
            sizeLabel: "~520 MB",
            vendor: .huggingFace,
            capabilities: [.vision, .recommended]
        ),
        VisualPick(
            id: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
            displayName: "Qwen 3 VL 2B",
            summary: "Compact vision-language model with /think mode. Mid-tier devices.",
            sizeLabel: "~1.7 GB",
            vendor: .qwen,
            capabilities: [.vision, .thinking]
        ),
        VisualPick(
            id: "mlx-community/Qwen3-VL-4B-Instruct-4bit",
            displayName: "Qwen 3 VL 4B",
            summary: "Sharper visual reasoning. Best on Pro / Max devices.",
            sizeLabel: "~2.9 GB",
            vendor: .qwen,
            capabilities: [.vision, .thinking, .best]
        ),
    ]

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                heroBlock
                Picker("Start with", selection: $goal) {
                    ForEach(Goal.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if needsAssistant { assistantSection }
                if needsVision { visualSection }
                if goal == .voice {
                    Text("Start with an assistant model. The Voice tab guides you through speech-model downloads and microphone permission when you are ready.")
                        .font(T.sans(14))
                }
                Color.clear.frame(height: 16)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(LiquidPinkBackdrop())
        .overlay {
            // The gate is a blocking setup state, so it gets a full-screen
            // scrim + solid panel rather than a gradient bottom bar. The old
            // gradient let the scrolling cards bleed through behind the gate
            // copy (the top of a tall gate sits in the transparent zone).
            if phase == .downloading { gateOverlay }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if phase == .picking { ctaBar }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            guard phase == .downloading else { return }
            gateTick &+= 1   // force progress bars to re-read downloader state
            if assistantSettled && visualSettled {
                HapticManager.notification(.success)
                onComplete()
            }
        }
        .onAppear {
            // Seed picks from device tier so the user lands on the right
            // recommendation. Avoid clobbering an explicit `commit()` /
            // re-entry — only seed when we're still on the static defaults.
            let defaults = tierAwareDefaults()
            if pickedAssistantID == "qwen2.5-coder-1.5b" {
                pickedAssistantID = defaults.assistantID
            }
            if pickedVisualRepoID == "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF" {
                pickedVisualRepoID = defaults.visualRepoID
            }
        }
    }

    // MARK: - Hero

    private var heroBlock: some View {
        VStack(spacing: 10) {
            // Custom hero glyph — concentric rings with a pick mark.
            // Differentiates from the reference's downward-arrow icon
            // while landing in the same conceptual space.
            ZStack {
                Circle()
                    .stroke(T.accent.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .frame(width: 88, height: 88)
                Circle()
                    .fill(T.accentSoft)
                    .frame(width: 60, height: 60)
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(T.accent)
            }
            .padding(.top, 4)

            VStack(spacing: 6) {
                KCaption(text: "STEP · MODEL PICK")
                Text("Choose your models")
                    .font(T.display(26, .semibold))
                    .tracking(-0.5)
                    .foregroundColor(T.ink)
                Text("Choose what you want to try first. Download only the model you need now; add the others later in Models.")
                    .font(T.sans(13.5))
                    .foregroundColor(T.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
        }
    }

    // MARK: - Sections

    private var assistantSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(eyebrow: "ASSISTANT",
                          title: "Text & code",
                          subtitle: "Chat, code review, refactoring, planning.")
            VStack(spacing: 10) {
                ForEach(assistantPicks) { pick in
                    assistantCard(pick)
                }
            }
        }
    }

    private var visualSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(eyebrow: "VISION",
                          title: "Multimodal",
                          subtitle: "Camera capture, screen reading, image-to-text. Only multimodal models — text-only LLMs can't fill this slot.")
            VStack(spacing: 10) {
                ForEach(visualPicks) { pick in
                    visualCard(pick)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(eyebrow: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                KCaption(text: eyebrow)
                    .fixedSize(horizontal: true, vertical: false)
                Rectangle().fill(T.rule).frame(height: 1)
            }
            Text(title)
                .font(T.display(18, .semibold))
                .foregroundColor(T.ink)
            Text(subtitle)
                .font(T.sans(11.5))
                .foregroundColor(T.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Cards

    @ViewBuilder
    private func assistantCard(_ pick: AssistantPick) -> some View {
        let selected = pickedAssistantID == pick.id
        let verdict = MemoryAdvisor.verdictWithCurrentlyLoaded(for: pick.id)
        modelCard(
            selected: selected,
            vendor: pick.vendor,
            title: pick.displayName,
            summary: pick.summary,
            sizeLabel: pick.sizeLabel,
            caps: pick.capabilities,
            verdict: verdict
        ) {
            pickedAssistantID = pick.id
            HapticManager.impact(.light)
        }
    }

    @ViewBuilder
    private func visualCard(_ pick: VisualPick) -> some View {
        let selected = pickedVisualRepoID == pick.id
        // Vision models store their repoID directly, but MemoryAdvisor
        // needs the normalized key shape to look up real on-disk sizes.
        let verdict = MemoryAdvisor.verdictWithCurrentlyLoaded(
            for: LocalModelRegistry.visionMemoryAdvisorKey(for: pick.id)
        )
        modelCard(
            selected: selected,
            vendor: pick.vendor,
            title: pick.displayName,
            summary: pick.summary,
            sizeLabel: pick.sizeLabel,
            caps: pick.capabilities,
            verdict: verdict
        ) {
            pickedVisualRepoID = pick.id
            HapticManager.impact(.light)
        }
    }

    // Shared card layout for both sections — keeps the geometry +
    // selection animation identical.
    @ViewBuilder
    private func modelCard(
        selected: Bool,
        vendor: ModelVendor,
        title: String,
        summary: String,
        sizeLabel: String,
        caps: Set<ModelCapability>,
        verdict: MemoryAdvisor.Verdict,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                if !dynamicTypeSize.isAccessibilitySize {
                    KVendorThumb(vendor: vendor, size: .card)
                }
                VStack(alignment: .leading, spacing: 4) {
                    let titleLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                    titleLayout {
                        Text(title)
                            .font(T.display(15, .semibold))
                            .tracking(-0.2)
                            .foregroundColor(T.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text(sizeLabel)
                            .font(T.mono(9.5, .semibold))
                            .foregroundColor(T.ink3)
                    }
                    Text(summary)
                        .font(T.sans(11.5))
                        .foregroundColor(T.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !caps.isEmpty {
                        KCapabilityPillRow(capabilities: Array(caps), size: .compact)
                            .padding(.top, 2)
                    }
                    deviceFitNotice(verdict: verdict)
                }
                radio(selected: selected)
                    .padding(.top, 4)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .kGlass(cornerRadius: 16,
                    tint: selected ? T.accentSoft : nil,
                    fallbackFill: selected ? T.accentSoft : T.surface)
            .overlay(
                // Selected: 1pt accent border + tiny glow.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(selected ? T.accent.opacity(0.7) : Color.clear,
                            lineWidth: 1.2)
            )
            .shadow(color: selected ? T.accent.opacity(0.20) : .clear,
                    radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: selected)
    }

    /// Small inline warning that surfaces marginal/wontFit verdicts on
    /// a card. Hidden when the verdict is green so cards stay tidy for
    /// the recommended picks.
    @ViewBuilder
    private func deviceFitNotice(verdict: MemoryAdvisor.Verdict) -> some View {
        switch verdict {
        case .fitsComfortably:
            EmptyView()
        case .marginal(let warning):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8.5, weight: .bold))
                Text(warning)
                    .font(T.mono(9.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
            .foregroundColor(T.warn)
            .padding(.top, 4)
        case .wontFit(let warning):
            HStack(spacing: 4) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 8.5, weight: .bold))
                Text(warning)
                    .font(T.mono(9.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }
            .foregroundColor(T.bad)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func radio(selected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(selected ? T.accent : T.ink4, lineWidth: 1.5)
                .frame(width: 20, height: 20)
            if selected {
                Circle()
                    .fill(T.accent)
                    .frame(width: 12, height: 12)
            }
        }
    }

    // MARK: - CTA bar

    private var ctaBar: some View {
        VStack(spacing: 6) {
            Button(action: commit) {
                Label(needsAnyDownload ? "Download model" : "Continue",
                      systemImage: needsAnyDownload ? "arrow.down.circle" : "arrow.right")
                    .font(T.sans(16, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(12)
                    .foregroundStyle(T.bg)
                    .background(T.ink, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("onboarding.install")
            .padding(.horizontal, 16)
        }
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(T.bg)
    }

    // MARK: - Download gate
    //
    // Downloads can continue after Skip. A source-only install still needs
    // compatible weights before running inference.

    private var assistantDLModel: DownloadableModel? {
        center.models.first { $0.id == pickedAssistantID }
    }
    private var visualDLModel: DownloadableModel? {
        center.models.first { $0.id == pickedVisualRepoID }
    }
    /// "Settled" = on disk, OR no catalog entry to track (so we never hang the
    /// gate waiting on something that can't report readiness).
    private var assistantSettled: Bool { !needsAssistant || (assistantDLModel.map { $0.isReady } ?? false) }
    private var visualSettled: Bool { !needsVision || (visualDLModel.map { $0.isReady } ?? false) }

    private func isFailed(_ m: DownloadableModel?) -> Bool {
        guard let s = m?.state else { return false }
        if case .failed = s { return true }
        return false
    }
    private var anyDownloadFailed: Bool {
        (needsAssistant && (assistantDLModel == nil || isFailed(assistantDLModel))) || (needsVision && (visualDLModel == nil || isFailed(visualDLModel)))
    }

    /// Full-screen blocking overlay for the download phase: a dimming scrim
    /// over the (now inert) picker plus the gate panel pinned to the bottom.
    /// The scrim is what stops the scroll content from showing through the
    /// gate copy — the panel itself is opaque too, belt-and-suspenders.
    private var gateOverlay: some View {
        ZStack(alignment: .bottom) {
            T.bg.opacity(0.97)
                .ignoresSafeArea()
            gateBar
        }
        .transition(.opacity)
    }

    private var gateBar: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("Setting up your models")
                    .font(T.display(17, .semibold))
                    .foregroundColor(T.ink)
                Text("Your selected model is downloading for offline use. You can continue to the app and track progress in Models.")
                    .font(T.sans(11.5))
                    .foregroundColor(T.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }

            VStack(spacing: 10) {
                if needsAssistant { gateProgressRow(label: "Assistant", model: assistantDLModel, settled: assistantSettled) }
                if needsVision { gateProgressRow(label: "Vision", model: visualDLModel, settled: visualSettled) }
            }

            if anyDownloadFailed {
                Button { retryDownloads() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        Text("Retry download").font(T.mono(11, .semibold))
                    }
                    .foregroundColor(T.bad)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(T.bad.opacity(0.10)))
                    .overlay(Capsule().stroke(T.bad.opacity(0.4), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            Button { onComplete() } label: {
                Text("Skip for now — finish in Models")
                    .font(T.mono(10, .semibold))
                    .tracking(0.5)
                    .foregroundColor(T.ink3)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(
            // Solid panel (no gradient): a rounded card edge fading the scrim
            // into a fully opaque surface so the gate copy always reads clean.
            ZStack {
                T.bg
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(T.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(T.glassBorder, lineWidth: 0.5)
                    )
                    .padding(.horizontal, 8)
            }
            .ignoresSafeArea(edges: .bottom)
        )
    }

    @ViewBuilder
    private func gateProgressRow(label: String, model: DownloadableModel?, settled: Bool) -> some View {
        let failed = isFailed(model)
        let progress = settled ? 1.0 : (model?.progress ?? 0)
        HStack(spacing: 10) {
            ZStack {
                if settled {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(T.good)
                } else if failed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(T.bad)
                } else {
                    ProgressView().scaleEffect(0.7).tint(T.accent)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    KMono(text: label, size: 11, color: T.ink2)
                    Spacer()
                    KMono(text: settled ? "ready" : (failed ? "failed" : "\(Int(progress * 100))%"),
                          size: 10, color: settled ? T.good : (failed ? T.bad : T.ink3))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(T.rule).frame(height: 3)
                        Capsule()
                            .fill(settled ? T.good : (failed ? T.bad : T.accent))
                            .frame(width: max(0, min(1, progress)) * geo.size.width, height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .kGlass(cornerRadius: 10, fallbackFill: T.surface)
    }

    private func retryDownloads() {
        if needsAssistant, let a = assistantDLModel, !a.isReady { a.start() }
        if needsVision, let v = visualDLModel, !v.isReady { v.start() }
        HapticManager.impact(.light)
    }

    /// True iff at least one picked model isn't already on disk.
    private var needsAnyDownload: Bool {
        !pickedAssistantIsReady || !pickedVisualIsReady
    }

    private var pickedAssistantIsReady: Bool {
        !needsAssistant || (center.models.first(where: { $0.id == pickedAssistantID })?.isReady ?? false)
    }
    private var pickedVisualIsReady: Bool {
        !needsVision || (center.models.first(where: { $0.id == pickedVisualRepoID })?.isReady ?? false)
    }

    // MARK: - Commit

    /// Save picks to AppSettings, kick off downloads, dismiss onboarding.
    /// Downloads run in the background — the user lands on the home tab
    /// where the Models tab Installing section surfaces progress.
    private func commit() {
        // Save assistant pick.
        if needsAssistant {
            settings.assistantModelID = pickedAssistantID
            settings.hasPickedAssistantModel = true
        }

        // Save visual pick — written as the camera-visual repo ID so
        // the lens tab picks it up without further plumbing.
        if needsVision {
            LocalModelRegistry.setVisionSelection(pickedVisualRepoID, settings: settings)
            settings.hasPickedCameraVisualModel = true
        }

        // Trigger downloads where needed.
        if needsAssistant, let assistant = center.models.first(where: { $0.id == pickedAssistantID }),
           !assistant.isReady {
            assistant.start()
        }
        if needsVision, let visual = center.models.first(where: { $0.id == pickedVisualRepoID }),
           !visual.isReady {
            visual.start()
        }

        // If the selected goal's model is already on disk, enter right away. Otherwise show
        // the download gate, which blocks entry until the required download finishes (with a Skip
        // escape so a slow/offline launch can't lock the user out).
        if assistantSettled && visualSettled {
            HapticManager.notification(.success)
            onComplete()
        } else {
            HapticManager.impact(.medium)
            withAnimation { phase = .downloading }
        }
    }
}
