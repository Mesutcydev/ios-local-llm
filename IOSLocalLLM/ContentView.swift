import SwiftUI
import PhotosUI

// MARK: - ContentView

struct ContentView: View {
    // App opens on the Home dashboard. Assistant / Lens are one tap away.
    @State private var selectedTab: Tab = .home
    @StateObject private var bridge = AppBridge.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var legal = LegalAcceptanceManager.shared
    @ObservedObject private var loc = LocalizationService.shared

    @StateObject private var camera: CameraService
    @StateObject private var analysis: AnalysisService
    @StateObject private var reviewPrompt = ReviewPromptService.shared

    @State private var showSettings = false
    // Mac/Bridge is reached from a Home button now (Models took its tab slot).
    // Presented as a sheet. AppBridge.requestTab(.mac) (index 3) also opens it.
    @State private var showMac = false
    @State private var showImageGeneration = false
    // Bottom tabs: Home · Assistant · Lens · Voice · Models.
    enum Tab: CaseIterable, Hashable {
        case home, assistant, camera, voice, models
    }

    init() {
        let cam = CameraService()
        _camera = StateObject(wrappedValue: cam)
        _analysis = StateObject(wrappedValue: AnalysisService(camera: cam))
    }

    var body: some View {
        // Native tab bar only — it renders Apple's Liquid Glass on iOS 26.
        TabView(selection: $selectedTab) {
            // Order: home → assistant → lens → voice → models. Home is the
            // landing dashboard (on-device status, recents, gateway to Settings
            // + Mac). Assistant and Lens are the two most-used surfaces. Voice
            // keeps hands-free conversation first-class. Models (the management
            // hub) sits at the right edge; Mac/Bridge moved to a Home button.
            homeTab
                .tag(Tab.home)
                .tabItem { Label("Home", systemImage: "house") }

            assistantTab
                .tag(Tab.assistant)
                .tabItem { Label("Assistant", systemImage: "brain") }

            cameraTab
                .tag(Tab.camera)
                .tabItem { Label("Lens", systemImage: "camera.viewfinder") }

            VoiceLibraryView(isActive: selectedTab == .voice)
                .tag(Tab.voice)
                .tabItem { Label("Voice", systemImage: "waveform") }

            ModelsManagerView(isActive: selectedTab == .models)
                .tag(Tab.models)
                .tabItem { Label("Models", systemImage: "cube.box") }
        }
        .tint(T.accent)
        // Re-probe every model's on-disk state whenever the user lands on
        // either tab. Catches the common case where a download finished while
        // the user was on the other tab — without this, the card kept showing
        // "Download" until you tapped it again to nudge the state machine.
        //
        // Also: unload the OTHER tab's model. The assistant LLM (~2.3 GB)
        // and the lens VLM (~1 GB) together with camera buffers + KV cache
        // exceeded iOS's 6 GB high-watermark and got Jetsam-killed
        // (EXC_RESOURCE on real iPhones). Keep only the active tab's model
        // resident; the inactive one re-loads from its cached weights on
        // demand. Cost of an unload+reload is ~1–2 seconds; cost of a
        // Jetsam kill is "the app dies", so the trade is obvious.
        .onChange(of: selectedTab) { oldTab, newTab in
            updateToastLane(for: newTab)
            // Tactile feedback on every tab change. iOS 18+ tab bar has
            // its own subtle system haptic; this layers our brand selection
            // tap on top so it feels consistent with the rest of the app's
            // haptic vocabulary (capture, send, success). The programmatic
            // bridge-driven path below also fires HapticManager.tabSwitch();
            // a double-fire is benign — the generators dedupe at the
            // Core Haptics layer when triggered within a few ms.
            HapticManager.tabSwitch()
            ModelDownloadCenter.shared.refreshAllStates()

            // Tab-leave cleanup. iOS 18+ `TabView` does NOT reliably fire
            // `.onDisappear` on tab swap (the view stays alive in memory),
            // so the previous version's reliance on `VoiceConversationView`'s
            // `.onDisappear { conv.stop() }` and `CameraRootView`'s
            // `LensVoiceNarrator.deactivate()` both leaked work after
            // the user navigated away — mic stayed hot, TTS kept
            // playing, lens narration kept consuming hooks. The
            // selectedTab change is the canonical signal — drive
            // cleanup from here.
            switch oldTab {
            case .voice:
                VoiceConversationService.shared.stop()
            case .camera:
                LensVoiceNarrator.shared.deactivate()
                // Stop the capture session — it otherwise keeps the sensor
                // + ISP running (and draining battery / making heat) behind
                // every other tab. `start()`/`stop()` are idempotent.
                camera.stop()
            case .assistant, .home, .models:
                break
            }
            // Keep one inference runtime resident at a time. A static weight
            // estimate cannot account for camera buffers, KV cache, allocator
            // pooling, or Metal commands still finishing after cancellation.
            // Every backend's load path also performs an awaitable drain, so a
            // very fast tab/model change remains safe even though this SwiftUI
            // callback itself is synchronous.
            let sharedRepo = AssistantModelCatalog.currentSelection().repoID
            let preserveSharedDualRole = DualRoleModelPolicy.selectionsMatch(repoID: sharedRepo)
                && LensInferenceLoop.shared.sharedContainer(for: sharedRepo) != nil
            switch newTab {
            case .camera:
                // Headed to the Lens — always drop the Assistant LLM.
                CodingAssistantService.shared.unload()
                // Resume the capture session stopped on tab-leave above.
                // Safe on first entry too: start() guards on isRunning,
                // and CameraRootView's `.task { analysis.start() }` path
                // configures the session and calls start() itself (a
                // no-op once we're already running).
                camera.start()
            case .assistant:
                // Headed to chat — drop the camera VLM + FastVLM
                // unless both can coexist. FastVLM is unrelated to
                // the LLM/VLM coexistence question (separate small
                // service), but it's lightweight enough that we
                // unload it unconditionally to avoid double-counting.
                // Both VLM backends (MLX + llama.cpp) get the same
                // treatment — only one is ever resident at a time
                // anyway (the routing in AnalysisService picks one
                // per active repo).
                if !preserveSharedDualRole {
                    MLXVisionService.shared.unload()
                }
                LlamaCppVLMService.shared.unload()
                FastVLMService.shared.unload()
            case .voice:
                // Voice mode runs the LLM (for replies) but never the
                // VLM stack. Drop the vision services so Whisper + the
                // assistant LLM + TTS audio buffers have headroom.
                MLXVisionService.shared.unload()
                LlamaCppVLMService.shared.unload()
                FastVLMService.shared.unload()
            case .models:
                // Keep the assistant LLM resident so returning to chat is
                // instant — model "activating" was slow when visiting Models
                // unloaded it. Only the vision stack is dropped (downloads still
                // get the camera VLM's headroom, and MemoryPressureCoordinator
                // sheds the LLM if RAM gets tight).
                if !preserveSharedDualRole {
                    MLXVisionService.shared.unload()
                }
                LlamaCppVLMService.shared.unload()
                FastVLMService.shared.unload()
            case .home:
                // Home shows the assistant's live readiness — keep the LLM
                // resident so the hero reflects a real "ready" and New chat is
                // instant. Only the vision stack (camera/VLM) is dropped here;
                // Lens reloads it on demand, and switching to Lens/Voice still
                // unloads the LLM when both models can't coexist.
                if !preserveSharedDualRole {
                    MLXVisionService.shared.unload()
                }
                LlamaCppVLMService.shared.unload()
                FastVLMService.shared.unload()
            }
        }
        // Same idea for cold-launch + foreground resumes.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willEnterForegroundNotification)
        ) { _ in
            ModelDownloadCenter.shared.refreshAllStates()
        }
        .onAppear {
            updateToastLane(for: selectedTab)
            // Setup ordering matters here.
            //
            // 1. DeviceTierAdvisor.apply*IfNeeded MUST run synchronously on
            //    .onAppear because they set cameraVisualModelID and
            //    assistantModelID — the user can tap capture (or send a
            //    message) within a few hundred ms of launch and those
            //    settings must already reflect the right defaults, or the
            //    capture path falls into the no-model branch and nothing
            //    streams. They're cheap (settings + a couple of
            //    ModelCacheProbe walks that short-circuit on the first
            //    config + weights file found).
            //
            // 2. BundledVLMInstaller.installIfNeeded() is the actually
            //    expensive piece on a fresh install — it copies ~1 GB of
            //    bundled SmolVLM2 weights into the HubApi cache. Even
            //    `isInstalled` does a fileExists on a multi-level path.
            //    Move only this off the main thread to keep launch snappy.
            //
            // 3. ModelDownloadCenter.refreshAllStates() iterates the full
            //    catalog and does a fileExists check per model — fast,
            //    but bundled with the installer for symmetry.
            DeviceTierAdvisor.applyDefaultIfNeeded()
            DeviceTierAdvisor.applyDefaultVisualModelIfNeeded()
            // Begin watching the kernel memory-pressure signal: dump model
            // weights on .critical (imminent Jetsam) and shed them when
            // backgrounded with low headroom. Idempotent.
            MemoryPressureCoordinator.shared.start()
            Task.detached(priority: .userInitiated) {
                BundledVLMInstaller.installIfNeeded()
                await MainActor.run {
                    ModelDownloadCenter.shared.refreshAllStates()
                }
            }
            // A Siri/Shortcuts App Intent can set `requestedTab` before this
            // view mounts on a cold launch — `.onChange` won't fire for a
            // value already present at first render, so apply it here too.
            if bridge.requestedTab != nil { applyRequestedTab(bridge.requestedTab) }
            // Seed the Spotlight index with existing chats on launch (the
            // per-save reindex in ConversationStore.persist keeps it fresh
            // thereafter).
            SpotlightIndexer.reindexAll(ConversationStore.shared.conversations)
        }
        // colorScheme is set by IOSLocalLLMApp root via AppSettings.appearance
        // Switch tabs when the camera bridge requests it. Use a no-animation
        // transaction so the previous tab's subtree is torn down before the
        // new one mounts — a spring animation here used to keep both subtrees
        // resident and bleed the assistant's cream T.bg onto the lens.
        .onChange(of: bridge.requestedTab) { _, newTab in
            applyRequestedTab(newTab)
        }
        // Settings sheet
        .sheet(isPresented: $showSettings) {
            SettingsView(assistant: CodingAssistantService.shared)
                // FastVLM status is now observed live inside SettingsView via FastVLMService.shared
        }
        // Mac / Bridge sheet — reached from the Home "Mac" button (it's no
        // longer a bottom tab). BridgePairingView owns its own NavigationStack;
        // the drag indicator makes swipe-to-dismiss discoverable.
        .sheet(isPresented: $showMac) {
            BridgePairingView()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showImageGeneration) {
            ImageGenerationView()
        }
        // Legal acceptance is the FIRST gate — must accept before anything else.
        // Gate on ANY outstanding acceptance (EULA version, AI disclaimer, or
        // device-safety notice), not just the version, so each can re-prompt.
        .fullScreenCover(isPresented: Binding(
            get: { legal.needsAnyAcceptance },
            set: { _ in }
        )) {
            LegalAcceptanceView { /* dismiss when accepted */ }
        }
        // Onboarding full-screen cover on first launch (after legal accepted)
        .fullScreenCover(isPresented: Binding(
            get: { !legal.needsAnyAcceptance && !settings.hasSeenOnboarding },
            set: { if !$0 { settings.hasSeenOnboarding = true } }
        )) {
            OnboardingView()
        }
        // Rate-the-app pre-prompt — service decides when (≥5 turns,
        // ≥3 days installed, ≥30 days cooldown). Mounted at the root so
        // it surfaces regardless of which tab is active when the
        // threshold is hit. Suppressed during onboarding/legal so we
        // never stack sheets.
        .sheet(isPresented: Binding(
            get: { reviewPrompt.shouldShowPrompt
                    && !legal.needsAnyAcceptance
                    && settings.hasSeenOnboarding },
            set: { newValue in
                if !newValue { reviewPrompt.userDeferred() }
            }
        )) {
            ReviewPromptSheet()
        }
    }

    /// Applies a tab navigation request (from the camera bridge, share
    /// extension, or a Siri/Shortcuts App Intent) and clears it. No-animation
    /// transaction so the previous tab's subtree tears down before the new one
    /// mounts — a spring here used to keep both resident and bleed the
    /// assistant's cream background onto the lens.
    private func applyRequestedTab(_ newTab: Int?) {
        guard let tab = newTab else { return }
        // 0 = camera, 1 = assistant, 2 = models, 3 = mac, 4 = voice.
        // Mac is no longer a tab — index 3 presents the Mac sheet instead
        // (keeps every existing `requestTab(.mac)` call site working).
        if tab == 3 {
            showMac = true
            HapticManager.tabSwitch()
            bridge.requestedTab = nil
            return
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            switch tab {
            case 1: selectedTab = .assistant
            case 2: selectedTab = .models
            case 4: selectedTab = .voice
            default: selectedTab = .camera
            }
        }
        HapticManager.tabSwitch()
        bridge.requestedTab = nil
    }

    /// Keeps transient notifications below each tab's top chrome. Assistant's
    /// two-line model picker is taller than a standard navigation row.
    private func updateToastLane(for tab: Tab) {
        switch tab {
        case .assistant:
            ToastCenter.shared.setTopPadding(96)
        case .models:
            ToastCenter.shared.setTopPadding(8)
        case .home, .camera, .voice:
            ToastCenter.shared.setTopPadding(52)
        }
    }

    // MARK: - Tabs

    private var cameraTab: some View {
        CameraRootView(camera: camera, analysis: analysis,
                       onShowSettings: { showSettings = true },
                       onClose: { selectedTab = .home },
                       isLensActive: selectedTab == .camera)
            // Camera is always dark and uses the app-wide black accent. Upgrade
            // the background to true black when the user picked OLED.
            .koduTheme(KoduTheme.make(
                appearance: settings.appearance == "oled" ? "oled" : "dark",
                accent: KoduTheme.appAccent))
            .preferredColorScheme(.dark)
    }

    private var assistantTab: some View {
        CodingAssistantView(
            isActive: selectedTab == .assistant,
            onClose: { selectedTab = .home }
        )
    }

    private var homeTab: some View {
        HomeView(
            onNewChat: { AppBridge.shared.startNewChat() },
            onOpenLens: { selectedTab = .camera },
            onOpenVoice: { selectedTab = .voice },
            onOpenModels: { selectedTab = .models },
            onOpenMac: { showMac = true },
            onGenerateImage: { showImageGeneration = true },
            onOpenSettings: { showSettings = true },
            onOpenConversation: { AppBridge.shared.openConversation(id: $0.id) }
        )
    }

    @Environment(\.koduTheme) private var T
}

// MARK: - CameraRootView

struct CameraRootView: View {
    @ObservedObject var camera: CameraService
    @ObservedObject var analysis: AnalysisService
    let onShowSettings: () -> Void
    /// Closes the Lens (returns to Home) — wired to the design-03 top-left ×.
    var onClose: () -> Void = {}
    /// True only while the Lens is the selected tab. Threaded in from
    /// ContentView (`selectedTab == .camera`) because iOS 18 `TabView` does
    /// NOT reliably fire `.onDisappear` on a tab swap — so the live-caption
    /// loop and its `lens-live-loop` keep-awake reason must be torn down off
    /// this reliable signal, not `.onDisappear`, or they leak past tab leave.
    var isLensActive: Bool = true
    /// Gallery import selection for the shutter-row photo button.
    @State private var photoItem: PhotosPickerItem?

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var bridge = AppBridge.shared
    @ObservedObject private var loc = LocalizationService.shared
    @ObservedObject private var liveOCR = LiveOCRService.shared
    // Intentionally NOT observing MLXVisionService here. Its `state` ticks
    // 10–20× per second during a model download (each HubApi progress
    // callback publishes a new value). Every tick re-rendered the whole
    // CameraRootView, which in turn caused AVCaptureVideoPreviewLayer to
    // briefly render at a partial-laid-out size — the centred translucent
    // strip the user kept circling. The `activeVLMReady` computed
    // property below reads `.shared.state` lazily; the HUD pill won't
    // animate to green the instant the model is ready, but any other
    // state change (fps tick, detection update) refreshes it shortly
    // after — well worth the trade for a strip-free lens tab.

    @State private var showAnalysisPanel = false
    @State private var panelDetent: PresentationDetent = .fraction(0.55)
    @State private var captureButtonScale: CGFloat = 1.0
    @State private var showHistory = false
    @State private var showDownloadCenter = false
    @State private var showDocumentScanner = false
    @State private var showVisualModelPicker = false
    @State private var didCopyCaption = false
    @State private var presetPickerSheet = false
    /// Redesigned Code Mode: tap-to-capture still → faithful OCR → code LLM.
    /// Owns its own flow independent of the VLM-based AnalysisService.
    @StateObject private var codeMode = CodeModeController()
    @State private var showCodeMode = false
    @State private var isCapturingStill = false
    /// Last non-empty caption — kept across capture cycles so the pill
    /// doesn't flicker to empty between auto-refreshes.
    @State private var lastCaption: String = ""
    /// Gate for the live-caption follow-up burst. False until the user has
    /// explicitly tapped capture once this session. Without it the burst
    /// fires the moment the lens tab is opened in visual mode, racing
    /// AVFoundation's first frame and MLX's lazy model load — the most
    /// common path to the Metal command-buffer SIGABRT users keep
    /// hitting on cold launch. Tap-to-start makes the lens tab itself
    /// always safe; the model only runs when the user asks for it.
    @State private var hasStartedLiveLoop: Bool = false
    @State private var lensPanelState: LensPanelState = .collapsed
    @State private var selectedLensMode: LensMode = .ask
    @FocusState private var lensPromptFocused: Bool
    @Environment(\.koduTheme) private var T

    private static let liveCaptionFollowUpLimit = 2
    private static let minimumLiveCaptionIntervalMS = 6_000
    private static let maximumLiveCaptionIntervalMS = 30_000

    private var activeMode: AnalysisMode {
        AnalysisMode(rawValue: settings.analysisMode) ?? .code
    }

    /// Short label for the HUD's VLM pill — switches from "fastvlm" to the
    /// downloaded model's short name as soon as the user picks a non-default
    /// VLM in VisualModelPickerView. Previously the pill was hard-coded to
    /// "vlm" and always read FastVLM state, so picking SmolVLM gave no
    /// visible confirmation that the routing had changed.
    ///
    /// FastVLM honesty: when the user is on the default (FastVLM) route but
    /// the decoder/projector/tokenizer aren't actually ready — only the
    /// encoder is — the pill reads "fastvlm·enc" instead of "fastvlm", so
    /// users don't think the full visual-language pipeline is online.
    private var activeVLMLabel: String {
        let selectionID = LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        if LocalModelRegistry.isDefaultVisionSelection(selectionID) {
            let s = analysis.fastVLMStatus
            // Encoder up, but the decoder side isn't — be honest about it.
            if s.encoder.isReady && !s.canGenerate { return "fastvlm·enc" }
            return "fastvlm"
        }
        let lastComponent = selectionID.split(separator: "/").last.map(String.init) ?? selectionID
        return lastComponent
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .prefix(12)
            .description
    }

    /// Ready state for whichever VLM `activeVLMLabel` represents. Reads
    /// MLXVisionService.shared lazily (NOT observed — see the comment on
    /// the `mlxVision` property removal above).
    ///
    /// For FastVLM, "ready" means the full pipeline can generate — not
    /// merely that the encoder loaded. With an encoder-only build the HUD
    /// pill stays dim, signalling that visual descriptions won't actually
    /// stream until the rest of the pipeline lands.
    private var activeVLMReady: Bool {
        if LocalModelRegistry.isDefaultVisionSelection(
            LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        ) {
            return analysis.fastVLMStatus.canGenerate
        }
        if case .ready = MLXVisionService.shared.state { return true }
        return false
    }

    /// Compact thumbnail of the exact image MLX last received, with
    /// dimensions + request id below. Diagnostic only — surfaces a
    /// preprocessing bug instantly: if this thumb shows a sideways/cropped
    /// image while the live preview behind it is upright/full, the bug
    /// is in our pipeline, not the model.
    @ViewBuilder
    private var modelInputDebugOverlay: some View {
        let vision = MLXVisionService.shared
        if let img = vision.lastModelInput {
            VStack(alignment: .leading, spacing: 4) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(.white.opacity(0.18), lineWidth: 1))
                if let info = vision.lastModelInputInfo {
                    Text("\(info.inputWidth)×\(info.inputHeight)")
                        .font(T.mono(9, .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.6)))
                    Text(info.requestID.uuidString.prefix(8).description)
                        .font(T.mono(8))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.5)))
                }
            }
        }
    }

    /// Unified top strip — replaces the prior left HUD + right model pill.
    /// Layout: [status dot] model · fps · activity            ⌃⌄
    /// The whole strip is the anchor for a SwiftUI Menu that lists the
    /// installed visual models inline, so switching is one tap + one
    /// tap (vs the old two-screen detour through the Models tab). A
    /// "Browse models…" entry at the bottom still opens the full picker
    /// sheet for downloading new ones.
    private var lensTopStrip: some View {
        Menu {
            lensTopStripMenuContent
        } label: {
            HStack(spacing: AppSpacing.small) {
                LensModelStatusIndicator(color: cameraModelStatusColor, isReady: activeVLMReady)
                VStack(alignment: .leading, spacing: 1) {
                    Label {
                        Text(activeVLMLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "cpu")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    Text(activeVLMReady ? "Ready · On-device" : "On-device")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(.horizontal, AppSpacing.medium)
            .frame(maxWidth: .infinity, minHeight: 44)
            .glassSurface(.capsule, cornerRadius: 22)
            .environment(\.colorScheme, .dark)
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: AppStroke.hairline)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .accessibilityLabel("Vision model: \(activeVLMLabel), \(activeVLMReady ? "ready" : "not ready"), on device")
    }

    /// Menu body for the lens top strip — built lazily when the menu
    /// opens, so we can read `ModelDownloadCenter.shared.models`
    /// directly without subscribing CameraRootView to it (subscribing
    /// would re-render the whole camera surface on every HF progress
    /// tick).
    @ViewBuilder
    private var lensTopStripMenuContent: some View {
        let current = LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        let readyVLMs = lensTopStripReadyVLMs()

        Section(loc.t("vision model")) {
            // FastVLM default — always present in the menu, even when
            // not fully installed. Picking it while it's not installed
            // surfaces a toast via applySelection's install-status
            // check; better that than hiding the canonical option.
            Button {
                HapticManager.impact(.light)
                Task { await VisualModelPickerView.applySelection(LocalModelRegistry.defaultVisionSelectionID) }
            } label: {
                if LocalModelRegistry.isDefaultVisionSelection(current) {
                    Label("FastVLM (built-in)", systemImage: "checkmark")
                } else {
                    Text("FastVLM (built-in)")
                }
            }

            ForEach(readyVLMs, id: \.id) { model in
                Button {
                    HapticManager.impact(.light)
                    Task { await VisualModelPickerView.applySelection(model.sourceRepoID) }
                } label: {
                    if current == model.sourceRepoID {
                        Label(model.displayName, systemImage: "checkmark")
                    } else {
                        Text(model.displayName)
                    }
                }
            }
        }

        Divider()

        Button {
            showVisualModelPicker = true
        } label: {
            Label(loc.t("Browse models…"), systemImage: "ellipsis.circle")
        }
    }

    /// Same filter VisualModelPickerView uses for its "downloaded VLMs"
    /// section — dedup by id, skip the required FastVLM entry (handled
    /// by the default row), and only surface entries that pass the
    /// stricter `runStatus` gate so a half-downloaded model can't be
    /// picked from the menu.
    private func lensTopStripReadyVLMs() -> [DownloadableModel] {
        var seen = Set<String>()
        return ModelDownloadCenter.shared.models.filter { m in
            guard m.supportsCategory(.vlm) else { return false }
            guard !m.isRequired else { return false }
            guard VisualModelInstallStatus.runStatus(for: m).isReady else { return false }
            return seen.insert(m.sourceRepoID).inserted
        }
    }

    /// Trimmed activity string for the top strip. Empty when the analysis
    /// pipeline isn't doing anything noteworthy so the line stays short.
    private var lensTopStripActivity: String {
        let msg = analysis.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return "" }
        // Cap at ~16 chars so the strip never overflows on narrow devices.
        return String(msg.prefix(18))
    }

    /// Colour for the lens pill's status dot. Matches the assistant's
    /// good/warn/bad palette so the two indicators feel consistent.
    private var cameraModelStatusColor: Color {
        if LocalModelRegistry.isDefaultVisionSelection(
            LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        ) {
            let status = analysis.fastVLMStatus
            if status.canGenerate { return T.good }
            if status.isLoading   { return T.warn }
            return T.ink3
        }
        switch MLXVisionService.shared.state {
        case .ready:      return T.good
        case .generating: return T.accent
        case .loading:    return T.warn
        case .failed:     return T.bad
        case .unloaded:   return T.ink3
        }
    }

    /// Composite key for the live-caption follow-up burst. Changing any field
    /// cancels the running task and restarts it — that's how a fresh mode,
    /// interval, or user-tapped "start" actually takes effect. The
    /// hasStartedLiveLoop bit is included so flipping the gate open kicks
    /// the loop awake without needing a mode toggle.
    private var liveLoopKey: String {
        // `isLensActive` is part of the key so leaving the Lens tab flips it
        // false → the .task(id:) is cancelled → its `defer` clears the
        // keep-awake. This is the reliable replacement for the unreliable
        // iOS-18 .onDisappear teardown.
        "\(activeMode.rawValue)-\(settings.smolVLMIntervalMS)-\(hasStartedLiveLoop)-\(isLensActive)"
    }

    @State private var pinchInitialZoom: CGFloat? = nil


    var body: some View {
        ZStack {
            // Hard black backdrop, full-bleed. Anything transparent in the
            // children falls back to this — never to the (light) parent bg.
            Color.black
                .ignoresSafeArea(.all)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Camera preview — placed directly in the ZStack (no
            // GeometryReader wrap) and forced to fill every dimension. On
            // iOS 26 a UIViewRepresentable inside a GeometryReader can
            // collapse to its intrinsic size when the safe-area inset is
            // resolved twice (once by the GeometryReader, once by the
            // `.ignoresSafeArea()` modifier), leaving a centred band of
            // black-fallback bleeding through from the parent ZStack.
            // Removing the GeometryReader + explicitly forcing a maxFrame
            // is what finally clears the residual strip.
            CameraPreviewView(session: camera.captureSession)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.all)

            if let cameraError = camera.error {
                VStack(spacing: AppSpacing.medium) {
                    Image(systemName: "camera.fill")
                        .font(.largeTitle)
                    Text("Camera unavailable")
                        .font(.title2.weight(.semibold))
                    Text(cameraError.localizedDescription)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if case .permissionDenied = cameraError {
                        Button("Open Settings") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .padding(AppSpacing.xLarge)
                .appPanel(cameraSafe: true)
                .padding(AppSpacing.xLarge)
                .accessibilityElement(children: .combine)
            }

            // Transparent gesture overlay — separate from the preview so
            // gesture sizing can't influence the preview layer's bounds.
            // Also the right attach point for `.lensDebugOverlay()`: it's
            // the topmost touch surface, so a long-press registered here
            // doesn't get swallowed by anything stacked above.
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { event in
                                if lensPromptFocused || lensPanelState == .composing {
                                    lensPromptFocused = false
                                    KeyboardDismiss.now()
                                    withAnimation(AppAnimation.state) {
                                        lensPanelState = .collapsed
                                    }
                                    return
                                }
                                let p = CGPoint(
                                    x: event.location.x / geo.size.width,
                                    y: event.location.y / geo.size.height
                                )
                                camera.focus(at: p)
                                HapticManager.impact(.light)
                            }
                    )
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale in
                                let base = pinchInitialZoom ?? camera.zoomFactor
                                if pinchInitialZoom == nil { pinchInitialZoom = base }
                                camera.setZoom(base * scale)
                            }
                            .onEnded { _ in pinchInitialZoom = nil }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                guard value.translation.height > 24 else { return }
                                lensPromptFocused = false
                                KeyboardDismiss.now()
                                if lensPanelState == .composing {
                                    withAnimation(AppAnimation.state) {
                                        lensPanelState = .collapsed
                                    }
                                }
                            }
                    )
                    .lensDebugOverlay()
            }
            .ignoresSafeArea(.all)

            GeometryReader { geo in
                // Code Mode is now tap-to-capture-still: the user frames the
                // code and taps the shutter, getting a high-fidelity OCR pass
                // routed to the code LLM. The old per-region tap-to-extract
                // overlay is gone in favour of a clean viewfinder + framing
                // guide (added below).
                //
                // Live OCR stays as an independent, opt-in overlay: when the
                // user flips it on from the toolbar, its tappable text boxes
                // render here regardless of mode. The service no-ops when the
                // toggle is off, so there's no cost otherwise.
                if liveOCR.enabled {
                    LiveOCROverlayView(containerSize: geo.size)
                }

                // Focus reticle
                if let p = camera.focusIndicator {
                    FocusReticle()
                        .position(x: p.x * geo.size.width, y: p.y * geo.size.height)
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.2), value: camera.focusIndicator)
                }
            }
            .ignoresSafeArea()

            // Top chrome — a single compact strip combines status dot,
            // model name, FPS, and current activity into one line so the
            // viewfinder isn't fenced in by two separate panels. The strip
            // is tappable end-to-end and routes to the Models tab, taking
            // over the role the old model picker pill played on the right.
            VStack {
                lensTopBar
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                Spacer()
            }

            // Scan frame (design 03) — pink corner brackets in the upper-center
            // viewfinder area, kept clear of the mode switcher / answer card
            // that live in the lower portion of the screen.
            VStack {
                scanFrame.padding(.top, 84)
                Spacer()
            }

            // Debug overlay — shows the EXACT image the model received,
            // post-orientation and post-resize. Off by default; toggle
            // via Settings → INTERFACE → "show model input debug". When
            // captions don't match the camera, this surfaces whether the
            // pipeline is at fault (thumb mismatches preview) or the
            // model is (thumb matches but caption is wrong).
            if settings.showModelInputDebug {
                modelInputDebugOverlay
                    .padding(.leading, 16)
                    .padding(.top, 180)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topLeading)
                    .allowsHitTesting(false)
            }

            // Setup banner — only relevant for FastVLM (code-mode default).
            // The Download Center already toasts on completion, so this is
            // strictly a "no model yet" affordance.
            VStack {
                Spacer().frame(height: 168)
                SetupBannerView { showDownloadCenter = true }
                    .padding(.horizontal, 16)
                Spacer()
            }
            .animation(.easeOut(duration: 0.25), value: analysis.fastVLMLoaded)

            // Code Mode framing guide — a centred capture rectangle with a
            // "tap to capture" hint, replacing the old detection-count chip.
            // Tells the user to frame the code and shoot; nothing streams
            // until they tap the shutter.
            if activeMode == .code, !showCodeMode {
                CodeFramingGuide(busy: isCapturingStill)
                    .allowsHitTesting(false)
            }

        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            lensBottomControls
                .padding(.horizontal, AppSpacing.medium)
                .padding(.bottom, AppSpacing.small)
        }
        .sheet(isPresented: $showAnalysisPanel, onDismiss: {
            // Reset detent so the next presentation starts at the comfy size
            panelDetent = .fraction(0.55)
        }) {
            if let result = analysis.activeResult {
                AnalysisPanelView(result: result,
                                  analysis: analysis,
                                  isPresented: $showAnalysisPanel)
                    .presentationDetents([.fraction(0.45), .fraction(0.75), .large], selection: $panelDetent)
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(20)
                    .presentationBackground(.clear)
                    // Light selection tap each time the user snaps the
                    // sheet to a new detent. iOS handles the actual drag
                    // + rubber-banding; this just adds the "click" so the
                    // detent change feels physical rather than silent.
                    .onChange(of: panelDetent) { _, _ in
                        HapticManager.selection()
                    }
            }
        }
        .sheet(isPresented: $showHistory) {
            AnalysisHistoryView(analysis: analysis, openPanel: $showAnalysisPanel)
        }
        .sheet(isPresented: $showDownloadCenter) {
            ModelDownloadCenterView()
        }
        .sheet(isPresented: $showVisualModelPicker) {
            VisualModelPickerView()
        }
        .sheet(isPresented: $presetPickerSheet) {
            LensPromptPresetSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showDocumentScanner) {
            DocumentScannerView { pages in
                guard let first = pages.first else { return }
                // Feed the first page through the standard analysis pipeline
                analysis.analyzeImportedImage(first)
                showAnalysisPanel = true
                if pages.count > 1 {
                    ToastCenter.shared.info(
                        "\(pages.count) pages scanned",
                        detail: "Analysing the first; share extension can handle the rest."
                    )
                }
            }
        }
        .fullScreenCover(isPresented: $showCodeMode) {
            CodeModeView(controller: codeMode, onRecapture: { codeMode.reset() })
        }
        .task { await analysis.start() }
        // Live caption follow-up burst — runs only AFTER the user has tapped
        // capture once this session (hasStartedLiveLoop flag). Without
        // that gate, opening the lens tab in visual mode raced AVFoundation's
        // first frame and MLX's lazy model load, reliably tripping a
        // Metal command-buffer SIGABRT (mlx::core::gpu::check_error) on
        // some devices. Tap-to-start keeps the lens tab itself always
        // safe — MLX only runs when the user explicitly asks.
        .task(id: liveLoopKey) {
            guard activeMode == .visual, hasStartedLiveLoop, isLensActive else { return }
            // Keep the screen awake while the follow-up burst runs — auto-lock
            // would background the app and kill in-flight GPU work. The
            // defer restores it on every exit (tab leave, mode switch,
            // key change all cancel this task), and DeviceSafetyMonitor's
            // background observer force-clears it as a backstop.
            DeviceSafetyMonitor.shared.setKeepAwake(true, reason: "lens-live-loop")
            defer { DeviceSafetyMonitor.shared.setKeepAwake(false, reason: "lens-live-loop") }
            var remainingFollowUps = Self.liveCaptionFollowUpLimit
            while !Task.isCancelled, remainingFollowUps > 0 {
                let safety = DeviceSafetyMonitor.shared
                // Minimum interval is 6000ms. The live caption burst needs the
                // GPU to fully drain between
                // captures or KV-cache residency accumulates and trips
                // iokit_user_client_trap mid-decode (SIGABRT), and an
                // unbounded loop is exactly the kind of workload that makes
                // user devices feel hot compared with peer camera apps.
                var ms = max(Self.minimumLiveCaptionIntervalMS,
                             min(Self.maximumLiveCaptionIntervalMS, settings.smolVLMIntervalMS))
                // Warm device or low-power mode → back the loop off 3×.
                if safety.shouldThrottle || safety.lowPowerMode { ms *= 3 }
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                if Task.isCancelled { break }

                // Thermal/memory gate: when the device is unsafe for heavy
                // work, don't capture at all — just poll until it recovers.
                if DeviceSafetyMonitor.shared.shouldStopHeavyWork {
                    continue
                }
                if !analysis.isAnalyzing {
                    analysis.captureAndAnalyzeBest()
                    remainingFollowUps -= 1
                }
            }
            if !Task.isCancelled {
                hasStartedLiveLoop = false
            }
        }
        // Stash the latest non-empty caption so we can keep showing it while
        // the next capture is still streaming (avoids a flicker to empty).
        .onChange(of: analysis.activeResult?.extractedCode) { _, new in
            if let new, !new.isEmpty { lastCaption = new }
        }
        // Speak the caption when low-vision (read-aloud) mode is on AND
        // the streaming pass has just finished. Fallback path —
        // mutually exclusive with the streaming narrator (see the
        // `voiceSpeakInLens` gate below). Per-token TTS would
        // otherwise stutter the speech engine; the deferred-until-
        // complete approach gives one clean readout per scene.
        .onChange(of: analysis.activeResult?.isStreaming) { _, isStreaming in
            guard isStreaming == false,
                  activeMode == .visual,
                  let result = analysis.activeResult,
                  !result.extractedCode.isEmpty
            else { return }
            // Two mutually-exclusive read-aloud paths fire on describe
            // completion: the streaming-style narrator (voiceSpeakInLens, with
            // scene-change dedup + its own AudioQueue) takes precedence;
            // otherwise the plain speak-on-final path (voiceAutoRead). The
            // narrator is fed HERE because it replaced the removed per-frame
            // streaming pipeline — `analysis` is only in scope at this layer.
            if settings.voiceSpeakInLens {
                LensVoiceNarrator.shared.narrate(result.extractedCode)
            } else if settings.voiceAutoRead {
                VoiceService.shared.speak(result.extractedCode)
            }
        }
        // Lens streaming narrator — opt-in alternative to the
        // speak-on-final path above. Activates when the user is on
        // the lens tab AND `voiceSpeakInLens` is on; deactivates
        // when either condition flips. The narrator owns its own
        // AudioQueue + frame-rate guard so the ~35fps inference loop
        // doesn't stutter speech (see LensVoiceNarrator.swift).
        .onAppear {
            selectedLensMode = currentLensMode
            ModelPrefetcher.shared.recordCameraOpen()
            if settings.voiceSpeakInLens {
                LensVoiceNarrator.shared.activate()
            }
            // Cold-launch drain: a share-extension image set pendingSharedImage
            // before this view mounted, so the .onChange below (which skips the
            // initial value) never fires and the image was silently dropped.
            if let img = bridge.pendingSharedImage {
                analysis.analyzeImportedImage(img)
                showAnalysisPanel = true
                bridge.pendingSharedImage = nil
            }
        }
        .onChange(of: settings.voiceSpeakInLens) { _, newValue in
            if newValue {
                LensVoiceNarrator.shared.activate()
            } else {
                LensVoiceNarrator.shared.deactivate()
            }
        }
        // Reset the live-loop gate when the user leaves visual mode so
        // re-entering it requires a fresh capture tap to start the loop. A
        // mode change is also a runtime handoff: cancel/unload the backend the
        // old mode owned before the new mode can lazy-load its model.
        .onChange(of: settings.analysisMode) { _, new in
            if new != AnalysisMode.visual.rawValue {
                hasStartedLiveLoop = false
                MLXVisionService.shared.unload()
                LlamaCppVLMService.shared.unload()
                FastVLMService.shared.unload()
            } else {
                CodingAssistantService.shared.unload()
            }
        }
        // Same on leaving the lens tab entirely — don't carry the gate
        // across tab switches. Also tear down the streaming narrator
        // so it doesn't keep narrating after the user navigated away.
        // .onDisappear is unreliable on iOS 18 TabView, so the authoritative
        // teardown is the isLensActive change below; this stays as a backstop
        // for the cases where it does fire (app teardown, sheet cover).
        .onDisappear {
            hasStartedLiveLoop = false
            lensPromptFocused = false
            KeyboardDismiss.now()
            analysis.cancelCurrentAnalysis()
            LensVoiceNarrator.shared.deactivate()
        }
        // Reliable tab-leave teardown: when the Lens stops being the selected
        // tab, reset the live-loop gate and stop the narrator. The loop task
        // itself is cancelled via liveLoopKey (which includes isLensActive),
        // and its defer clears the keep-awake — so nothing outlives the tab.
        .onChange(of: isLensActive) { _, active in
            if !active {
                hasStartedLiveLoop = false
                lensPromptFocused = false
                KeyboardDismiss.now()
                analysis.cancelCurrentAnalysis()
                lensPanelState = .collapsed
                LensVoiceNarrator.shared.deactivate()
            } else {
                selectedLensMode = currentLensMode
            }
        }
        .onChange(of: analysis.isAnalyzing) { _, analyzing in
            if analyzing {
                withAnimation(AppAnimation.state) { lensPanelState = .analyzing }
                return
            }
            guard activeMode == .visual else { return }
            if lensErrorText != nil, lensResultText.isEmpty {
                withAnimation(AppAnimation.state) { lensPanelState = .error }
            } else if !lensResultText.isEmpty {
                withAnimation(AppAnimation.state) { lensPanelState = .result }
                HapticManager.analysisComplete()
            } else if lensPanelState == .analyzing || lensPanelState == .captured {
                withAnimation(AppAnimation.state) { lensPanelState = .error }
            }
        }
        // Pick up images dropped in via the share extension
        .onChange(of: bridge.pendingSharedImage) { _, newImage in
            guard let img = newImage else { return }
            analysis.analyzeImportedImage(img)
            showAnalysisPanel = true
            bridge.pendingSharedImage = nil
        }
        // Gallery import (shutter-row photo button).
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run {
                        if activeMode != .visual {
                            settings.analysisMode = AnalysisMode.visual.rawValue
                        }
                        lensPromptFocused = false
                        KeyboardDismiss.now()
                        lensPanelState = .analyzing
                        analysis.analyzeImportedImage(img)
                    }
                }
                await MainActor.run { photoItem = nil }
            }
        }
    }

    /// Caption card — compact, always-inline layout. Description hugs its
    /// content (no fixed-height ScrollView); Copy/Share/preset and the
    /// merged camera-toolbar row sit below it. Tap-to-expand was removed:
    /// users complained the expanded card stretched into a huge empty
    /// surface when the caption was short.
    /// Per-render character cap for the streaming caption Text. CoreText's
    /// internal Futhark line-break allocator (`Futhark createNewLineseg`)
    /// rebuilds its line-segment buffer on every text change, and with
    /// rapid token streaming + a long output it eventually fails its
    /// realloc and SIGABRTs at the next store. Hard-capping the visible
    /// string to a few KB keeps Futhark's worst-case allocation bounded.
    /// We also drop `.textSelection(.enabled)` while a stream is in
    /// flight — selection support triggers an extra layout pass per
    /// change, which is what tips Futhark over the edge in practice.
    private static let captionMaxChars = 1200

    @ViewBuilder
    private var lensBottomControls: some View {
        VStack(spacing: AppSpacing.medium) {
            if activeMode == .visual {
                LensTaskPanel(
                    state: $lensPanelState,
                    mode: $selectedLensMode,
                    prompt: $settings.lensCustomPrompt,
                    promptFocused: $lensPromptFocused,
                    thumbnail: analysis.activeResult?.thumbnail,
                    resultText: lensResultText,
                    errorText: lensErrorText,
                    isBusy: analysis.isAnalyzing,
                    canAnalyze: !visualModelMissing && !analysis.isAnalyzing,
                    onModeChange: selectLensMode,
                    onAnalyze: captureLensTask,
                    onCancel: cancelLensAnalysis,
                    onCopy: {
                        UIPasteboard.general.string = lensResultText
                        HapticManager.impact(.light)
                        ToastCenter.shared.info("Copied")
                    },
                    onShare: { presentShareSheet(for: lensResultText) },
                    onSpeak: { VoiceService.shared.speak(lensResultText) },
                    onFollowUp: {
                        settings.lensCustomPrompt = ""
                        lensPanelState = .composing
                        lensPromptFocused = true
                    },
                    onRetake: resetLensPanel,
                    onExpand: { showAnalysisPanel = analysis.activeResult != nil }
                )
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    Text("CODE · ON-DEVICE")
                        .font(AppTypography.eyebrow)
                        .foregroundStyle(.secondary)
                    Text("Frame code and capture a still for OCR and review.")
                        .font(.headline)
                }
                .padding(AppSpacing.large)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appPanel(cameraSafe: true)
            }

            if lensPanelState == .collapsed || activeMode == .code {
                shutterRow
                    .padding(.horizontal, AppSpacing.large)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .animation(AppAnimation.state, value: lensPanelState)
    }

    private var lensResultText: String {
        analysis.activeResult?.extractedCode ?? lastCaption
    }

    private var lensErrorText: String? {
        if let error = camera.error?.errorDescription { return error }
        if let reason = analysis.activeResult?.fallbackReason { return reason }
        let status = analysis.statusMessage.lowercased()
        if status.contains("error") || status.contains("failed") {
            return analysis.statusMessage
        }
        return nil
    }

    private func captureLensTask() {
        guard !analysis.isAnalyzing, !visualModelMissing else { return }
        lensPromptFocused = false
        KeyboardDismiss.now()
        withAnimation(AppAnimation.state) { lensPanelState = .captured }
        HapticManager.capture()
        analysis.captureAndAnalyzeBest()
        hasStartedLiveLoop = true
        withAnimation(AppAnimation.state) { lensPanelState = .analyzing }
    }

    private func cancelLensAnalysis() {
        analysis.cancelCurrentAnalysis()
        lensPromptFocused = false
        KeyboardDismiss.now()
        withAnimation(AppAnimation.state) { lensPanelState = .collapsed }
    }

    private func resetLensPanel() {
        analysis.cancelCurrentAnalysis()
        analysis.dismissActiveResult()
        lastCaption = ""
        lensPromptFocused = false
        KeyboardDismiss.now()
        withAnimation(AppAnimation.state) { lensPanelState = .collapsed }
    }

    /// Full-card empty state shown when the visual model isn't ready.
    /// Replaces the old "tap to install model" pinned warning that the
    /// toolbar partially occluded. Same dark glass surface as the live
    /// caption pill so the bottom of the screen still reads as one panel.
    private var noVisionModelCard: some View {
        let hasSelection = !LocalModelRegistry.isDefaultVisionSelection(
            LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
                Text(loc.t(hasSelection
                           ? "vision model not loaded"
                           : "no vision model loaded"))
                    .font(T.mono(11, .semibold))
                    .tracking(0.4)
                    .foregroundColor(.white.opacity(0.92))
                Spacer()
            }
            Text(loc.t(hasSelection
                       ? "the selected model failed to load. open the models tab to fix it."
                       : "install a vision model to caption what the camera sees."))
                .font(T.sans(13))
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                HapticManager.impact(.medium)
                handleMissingVisionModelAction(hasSelection: hasSelection)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: hasSelection
                          ? "arrow.triangle.2.circlepath"
                          : "arrow.down.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Text(loc.t(missingVisionModelButtonLabel(hasSelection: hasSelection)))
                        .font(T.mono(11, .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule(style: .continuous)
                        .fill(T.accentStrong)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.72))
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
    }

    private func missingVisionModelButtonLabel(hasSelection: Bool) -> String {
        guard !hasSelection,
              let model = ModelDownloadCenter.shared.fastvlmModel else {
            return "open models"
        }
        switch model.state {
        case .ready:
            return "load fastvlm 0.5b"
        case .enumerating, .downloading:
            return "view fastvlm download"
        case .failed:
            return "retry fastvlm download"
        case .idle:
            return "download fastvlm 0.5b · ~400 mb"
        }
    }

    private func handleMissingVisionModelAction(hasSelection: Bool) {
        guard !hasSelection else {
            AppBridge.shared.requestModels(.lens)
            return
        }
        guard let model = ModelDownloadCenter.shared.fastvlmModel else {
            ToastCenter.shared.error("FastVLM unavailable",
                                     detail: "The model catalog could not be loaded.")
            AppBridge.shared.requestModels(.lens)
            return
        }
        switch model.state {
        case .ready:
            Task { await FastVLMService.shared.load() }
        case .enumerating, .downloading:
            AppBridge.shared.requestModels(.lens)
        case .idle, .failed:
            model.start()
            AppBridge.shared.requestModels(.lens)
        }
    }



    /// Hands `text` to the system share sheet. The camera tab is presented
    /// edge-to-edge with no NavigationStack, so we resolve the topmost
    /// view controller directly.
    private func presentShareSheet(for text: String) {
        // Prefer the foreground-active key window, but fall back to any
        // connected window scene's first window. On iPad multi-scene / Stage
        // Manager — or transiently during a state change — the strict
        // key-window lookup can miss, which used to make the Share tap a silent
        // no-op. Surface a toast if we still can't find a presenter.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let scene,
              let root = (scene.windows.first(where: \.isKeyWindow)
                          ?? scene.windows.first)?.rootViewController
        else {
            ToastCenter.shared.error("Couldn't open the share sheet")
            return
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let av = UIActivityViewController(activityItems: [text],
                                          applicationActivities: nil)
        av.popoverPresentationController?.sourceView = top.view
        top.present(av, animated: true)
    }

    /// True when the active VLM can take natural-language prompts (basically:
    /// any MLX VLM, or FastVLM when the full decoder is ready). OCR-only
    /// fallback paths get hidden chips since the model can't actually obey.
    private var supportsPromptPresets: Bool {
        if !LocalModelRegistry.isDefaultVisionSelection(
            LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        ) { return true }
        return analysis.fastVLMStatus.canGenerate
    }

    /// True when the active visual model has no inference path available
    /// right now — either the selected MLX VLM failed to load, or the user
    /// is on the FastVLM default and the pipeline isn't ready. In that case
    /// the capture button is disabled and routes to the download/picker
    /// flow instead of swallowing a tap.
    private var visualModelMissing: Bool {
        // Only relevant in visual mode — code mode (OCR) always has a path.
        guard activeMode == .visual else { return false }
        if !LocalModelRegistry.isDefaultVisionSelection(
            LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        ) {
            // User picked an MLX VLM: must be loaded, or fail honestly.
            if case .failed = MLXVisionService.shared.state { return true }
            if case .ready = MLXVisionService.shared.state { return false }
            // .loading/.unloaded/.generating count as "still warming" — allow
            // taps so users can re-trigger after the model finishes warming.
            return false
        }
        // Default FastVLM route: needs the full pipeline, not just encoder.
        return !analysis.fastVLMStatus.canGenerate
    }

    // MARK: - Code Mode capture
    //
    // Tap-to-capture a high-fidelity still, then open CodeModeView which runs
    // the OCR-extract → code-LLM pipeline. Independent of AnalysisService /
    // the VLM — code reasoning goes through the chat-tab code model instead,
    // which is far stronger on code and needs no VLM resident.
    private func startCodeCapture() {
        guard !isCapturingStill, !showCodeMode else { return }
        isCapturingStill = true
        let orientation = UIDevice.current.orientation
        Task {
            let buffer = await camera.captureHighResFrame()
            isCapturingStill = false
            guard let buffer else {
                ToastCenter.shared.error("Couldn't capture frame")
                return
            }
            codeMode.begin(pixelBuffer: buffer, deviceOrientation: orientation)
            showCodeMode = true
        }
    }

    // MARK: - Lens design-03 chrome

    /// Top bar: × close · model/status pill · ⋯ more.
    private var lensTopBar: some View {
        HStack(spacing: 10) {
            lensCircleButton("xmark") { onClose() }
            lensTopStrip
            lensMoreMenu
        }
    }

    private func lensCircleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.impact(.light); action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .glassSurface(.toolbarButton, cornerRadius: 22)
                .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon == "xmark" ? "Close Lens" : "Lens control")
    }

    /// ⋯ menu — the contextual actions that used to live in the bottom
    /// toolbar (history, document scan, read-aloud, OCR, model, mode).
    private var lensMoreMenu: some View {
        Menu {
            Button {
                showHistory = true; HapticManager.impact(.light)
            } label: { Label(loc.t("history"), systemImage: "clock.arrow.circlepath") }

            Button {
                showDocumentScanner = true; HapticManager.impact(.light)
            } label: { Label(loc.t("scan"), systemImage: "doc.viewfinder") }

            Button {
                settings.voiceAutoRead.toggle(); HapticManager.impact(.light)
                if settings.voiceAutoRead, !visualModelMissing {
                    if activeMode != .visual { settings.analysisMode = AnalysisMode.visual.rawValue }
                    analysis.captureAndAnalyzeBest(); hasStartedLiveLoop = true
                } else if settings.voiceAutoRead {
                    // Turned ON but no vision model installed — tell the user
                    // instead of leaving the toggle a silent no-op.
                    ToastCenter.shared.info("Install a vision model first",
                                            detail: "Read-aloud needs a vision model to describe the scene.")
                } else {
                    VoiceService.shared.stop()
                }
            } label: {
                Label(settings.voiceAutoRead ? loc.t("aloud") + " · on" : loc.t("aloud") + " · off",
                      systemImage: settings.voiceAutoRead ? "ear.fill" : "ear")
            }

            Button {
                LiveOCRService.shared.enabled.toggle(); HapticManager.impact(.light)
            } label: {
                Label(LiveOCRService.shared.enabled ? loc.t("ocr") + " · on" : loc.t("ocr") + " · off",
                      systemImage: "text.viewfinder")
            }

            Divider()

            Button {
                AppBridge.shared.requestTab(.models); HapticManager.impact(.light)
            } label: { Label(loc.t("model"), systemImage: "eye") }

            Button {
                let next = activeMode == .code ? AnalysisMode.visual : AnalysisMode.code
                settings.analysisMode = next.rawValue; HapticManager.impact(.light)
            } label: {
                Label(activeMode == .visual ? loc.t("switch to code") : loc.t("switch to visual"),
                      systemImage: activeMode.systemImage)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .glassSurface(.toolbarButton, cornerRadius: 22)
                .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .accessibilityLabel("More Lens options")
    }

    // MARK: Scan frame

    private var scanFrame: some View {
        LensScanFrame(accent: currentLensMode.accent, isScanning: activeMode == .visual && analysis.isAnalyzing)
            .frame(width: 220, height: 220)
            .overlay(alignment: .top) {
                if activeMode == .visual, analysis.isAnalyzing {
                    Text(loc.t("Scanning…"))
                        .font(T.sans(12, .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Color.black.opacity(0.72)))
                        .offset(y: -30)
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.2), value: analysis.isAnalyzing)
    }

    // MARK: Mode switcher

    private var currentLensMode: LensMode {
        LensMode.from(preset: LensPromptPreset.from(rawValue: settings.lensPromptPresetID))
    }

    private func selectLensMode(_ m: LensMode) {
        HapticManager.selection()
        selectedLensMode = m
        lensPromptFocused = false
        KeyboardDismiss.now()
        settings.lensCustomPrompt = ""
        settings.lensPromptPresetID = m.preset.rawValue
        if activeMode != .visual { settings.analysisMode = AnalysisMode.visual.rawValue }
        analysis.cancelCurrentAnalysis()
        analysis.dismissActiveResult()
        lastCaption = ""
        withAnimation(AppAnimation.state) { lensPanelState = .collapsed }
    }

    private func submitCustomLensPrompt() {
        let trimmed = settings.lensCustomPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !analysis.isAnalyzing, !visualModelMissing else { return }
        settings.lensCustomPrompt = String(trimmed.prefix(240))
        if activeMode != .visual { settings.analysisMode = AnalysisMode.visual.rawValue }
        HapticManager.impact(.medium)
        analysis.captureAndAnalyzeBest()
        hasStartedLiveLoop = true
    }

    private func clearCustomLensPrompt() {
        settings.lensCustomPrompt = ""
        HapticManager.impact(.light)
    }

    private var modeSwitcher: some View {
        HStack(spacing: 7) {
            ForEach(LensMode.allCases) { m in
                let on = currentLensMode == m
                Button { selectLensMode(m) } label: {
                    Text(loc.t(m.label))
                        .font(T.sans(13, on ? .semibold : .medium))
                        .foregroundColor(.white.opacity(on ? 0.96 : 0.72))
                        .padding(.horizontal, on ? 18 : 15)
                        .padding(.vertical, 8)
                        .background(
                            ZStack {
                                Capsule().fill(Color.black.opacity(on ? 0.78 : 0.44))
                                if on {
                                    Capsule().stroke(.white.opacity(0.22), lineWidth: 1)
                                }
                            }
                        )
                        .overlay(Capsule().stroke(.white.opacity(on ? 0.22 : 0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: currentLensMode)
    }

    // MARK: Answer card (white, design 03)

    private var cardInk: Color { Color(red: 0.110, green: 0.110, blue: 0.118) }
    private var cardInk2: Color { Color(red: 0.42, green: 0.42, blue: 0.45) }

    private var answerCard: some View {
        let mode = currentLensMode
        let result = analysis.activeResult
        let answer: String = {
            if let r = result, r.mode == .visual, !r.extractedCode.isEmpty { return r.extractedCode }
            if !lastCaption.isEmpty { return lastCaption }
            return ""
        }()
        let streaming = (result?.isStreaming ?? false)
        let capped = answer.count > Self.captionMaxChars ? String(answer.suffix(Self.captionMaxChars)) : answer
        return VStack(alignment: .leading, spacing: 7) {
            Text("\(loc.t(mode.label).uppercased()) · \(loc.t("ON-DEVICE"))")
                .font(T.sans(11, .bold)).tracking(0.5)
                .foregroundColor(T.accentStrong)
            Text(settings.lensCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? loc.t(mode.question)
                 : settings.lensCustomPrompt)
                .font(T.sans(17, .semibold)).foregroundColor(cardInk)
            if streaming && capped.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().tint(T.accent).scaleEffect(0.8)
                    Text(loc.t("Looking…")).font(T.sans(14)).foregroundColor(cardInk2)
                }
            } else if !capped.isEmpty {
                Text(capped)
                    .font(T.sans(14.5)).foregroundColor(cardInk2).lineSpacing(2)
                    .lineLimit(6).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(StreamSafeTextSelection(streaming: streaming))
            } else {
                Text(loc.t("Point at something and tap the shutter."))
                    .font(T.sans(14)).foregroundColor(cardInk2)
            }
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.10))
                    .frame(width: 22, height: 22)
                Text(streaming ? loc.t("Identifying on-device…") : loc.t("Identified on-device"))
                    .font(T.sans(12)).foregroundColor(cardInk2)
                Spacer(minLength: 0)
                if !capped.isEmpty && !streaming {
                    Button {
                        UIPasteboard.general.string = capped; HapticManager.impact(.medium)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(cardInk2)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.black.opacity(0.06)))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // ponytail: opaque white card, not glass — clear glass renders the
        // dark ink text unreadable over the live camera feed. Matches the
        // `fallbackFill: .white` the design already asked for.
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.black.opacity(streaming ? 0.20 : 0.08), lineWidth: 1)
        )
    }

    // MARK: Shutter row

    private var shutterRow: some View {
        HStack {
            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.72))
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                }
                .frame(width: 40, height: 40)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .minimumInteractiveSize()
            .accessibilityLabel("Import a photo")
            .accessibilityHint("Choose an image from the photo library to analyze")

            Spacer()

            captureButton

            Spacer()

            // Right control — torch when available, else document scan.
            if camera.torchAvailable {
                lensCircleButton(camera.torchOn ? "bolt.fill" : "bolt.slash.fill") {
                    camera.toggleTorch()
                }
            } else {
                lensCircleButton("doc.viewfinder") { showDocumentScanner = true }
            }
        }
    }

    private var captureButton: some View {
        let missing = visualModelMissing
        return Button {
            // Missing-model tap routes into the download/picker flow rather
            // than firing a useless analyze. Matches the spec's Part 12.
            if missing {
                // Missing model — route the user to the Models tab.
                // Whether they need to download (cameraVisualModelID
                // empty → catalog section) or fix a failed load
                // (cameraVisualModelID set → installed section), the
                // Models tab is the right destination.
                HapticManager.impact(.medium)
                AppBridge.shared.requestTab(.models)
                return
            }
            guard !analysis.isAnalyzing else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { captureButtonScale = 0.92 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { captureButtonScale = 1.0 }
            }
            if activeMode == .visual {
                // Visual mode: force an immediate refresh of the caption
                // card. Tapping capture also flips on the follow-up burst
                // gate so the scene updates a couple more times without
                // turning the phone into a continuous VLM workload.
                captureLensTask()
            } else {
                // Code mode: tap-to-capture a high-fidelity still, OCR it,
                // and hand the text to the code LLM in CodeModeView.
                HapticManager.capture()
                startCodeCapture()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(missing ? Color(white: 0.28) : Color.white)
                    .frame(width: 68, height: 68)
                Circle()
                    .stroke(.white.opacity(missing ? 0.4 : 0.95), lineWidth: 4)
                    .frame(width: 82, height: 82)
                Image(systemName: missing
                      ? "exclamationmark.triangle.fill"
                      : (analysis.isAnalyzing ? "hourglass" : "camera.viewfinder"))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(missing ? .white : .black)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(captureButtonScale)
        .disabled(analysis.isAnalyzing && !missing)
        .accessibilityLabel(missing ? "Vision model unavailable" : "Capture frame")
        .accessibilityHint(missing ? "Opens Models so you can install a vision model" : "Captures and analyzes the current camera frame on device")
        // The missing-model hint is now carried by `noVisionModelCard`
        // above (full-card empty state) per README §Lens. Capture button
        // stays unlabelled in both states so the merged toolbar below
        // doesn't fight a small red label for attention.
    }
}

private struct LensModelStatusIndicator: View {
    let color: Color
    let isReady: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.24))
                .frame(width: 14, height: 14)
                .scaleEffect(breathing ? 1.25 : 0.78)
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .onAppear {
            guard isReady, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathing = true }
        }
        .accessibilityHidden(true)
    }
}

private struct LensScanFrame: View {
    let accent: Color
    let isScanning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var beamPosition: CGFloat = -1

    var body: some View {
        ZStack {
            ScanCornersShape(cornerLength: 34, radius: 8)
                .stroke(.white.opacity(isScanning ? 0.94 : 0.72), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .shadow(color: accent.opacity(isScanning ? 0.75 : 0.32), radius: isScanning ? 10 : 5)
                .scaleEffect(breathing ? 1.012 : 0.995)

            if isScanning {
                LinearGradient(colors: [.clear, accent.opacity(0.5), .white.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 34)
                    .offset(y: beamPosition * 92)
                    .mask(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .transition(.opacity)
            }
        }
        .onAppear { updateAnimations() }
        .onChange(of: isScanning) { _, _ in updateAnimations() }
        .accessibilityHidden(true)
    }

    private func updateAnimations() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { breathing = true }
        if isScanning {
            beamPosition = -1
            withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) { beamPosition = 1 }
        } else {
            beamPosition = -1
        }
    }
}

// MARK: - Live Lens question composer

/// A compact, camera-safe prompt surface for VLMs that accept natural-language
/// instructions. It stays separate from `CameraRootView` so typing only
/// invalidates this small subtree rather than the full preview hierarchy.
private struct LensPromptComposer: View {
    @Binding var prompt: String
    let isBusy: Bool
    let onAsk: () -> Void
    let onClear: () -> Void

    @FocusState private var isFocused: Bool

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))

            TextField("Ask about what the camera sees…", text: $prompt, axis: .vertical)
                .font(.subheadline)
                .foregroundStyle(.white)
                .tint(.white)
                .focused($isFocused)
                .lineLimit(1...3)
                .submitLabel(.go)
                .onSubmit(onAsk)
                .onChange(of: prompt) { _, newValue in
                    if newValue.count > 240 {
                        prompt = String(newValue.prefix(240))
                    }
                }

            if !trimmedPrompt.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Lens question")
            }

            Button(action: onAsk) {
                ZStack {
                    Circle()
                        .fill(trimmedPrompt.isEmpty || isBusy
                              ? Color.white.opacity(0.12)
                              : Color.white)
                        .frame(width: 34, height: 34)
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(trimmedPrompt.isEmpty ? .white.opacity(0.45) : .black)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(trimmedPrompt.isEmpty || isBusy)
            .accessibilityLabel("Ask Lens")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(isFocused ? 0.34 : 0.16), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

// MARK: - LensMode (design-03 mode switcher)
// The four camera "modes" map onto LensPromptPreset values so the existing
// VLM pipeline drives them unchanged — selecting a mode just swaps the prompt.
enum LensMode: String, CaseIterable, Identifiable {
    case ask, translate, scan, solve
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ask: return "Ask"
        case .translate: return "Translate"
        case .scan: return "Scan"
        case .solve: return "Solve"
        }
    }
    var question: String {
        switch self {
        case .ask: return "What am I looking at?"
        case .translate: return "What does this say in English?"
        case .scan: return "Transcribe the text"
        case .solve: return "Solve what's shown"
        }
    }
    var preset: LensPromptPreset {
        switch self {
        case .ask: return .describe
        case .translate: return .translate
        case .scan: return .extractCode
        case .solve: return .solve
        }
    }
    static func from(preset: LensPromptPreset) -> LensMode {
        switch preset {
        case .translate: return .translate
        case .extractCode, .reviewCode, .findErrors, .explainUI: return .scan
        case .solve: return .solve
        default: return .ask
        }
    }
}

// MARK: - ScanCornersShape
// Four rounded L-brackets forming the centered viewfinder frame (design 03).
struct ScanCornersShape: Shape {
    var cornerLength: CGFloat = 34
    var radius: CGFloat = 8
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let l = cornerLength, r = radius
        // top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        // top-right
        p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        // bottom-right
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        // bottom-left
        p.move(to: CGPoint(x: rect.minX + l, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return p
    }
}

// MARK: - CaptureAura
//
// Pulsing concentric rings behind the capture disc while inference is in
// flight. Each ring scales 0.85 → 1.45 and fades to zero opacity over its
// cycle, staggered so the eye reads a continuous outward sonar wave.
//
// Lives in its own subview so the repeat-forever animation isolates from
// the parent's redraw cycle — otherwise every analysis-state change in
// CameraRootView would reinstall the animation and the rings would jitter.

private struct CaptureAura: View {
    let color: Color
    var diameter: CGFloat = 68

    @State private var phase: CGFloat = 0

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .stroke(color.opacity(0.55), lineWidth: 2)
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(0.85 + (phase * 0.6))
                    .opacity(Double(1.0 - phase))
                    .animation(
                        .easeOut(duration: 1.6)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.8),
                        value: phase
                    )
            }
        }
        .onAppear { phase = 1 }
    }
}

// MARK: - StreamingGradientEdge
//
// 1px conic-gradient edge that rotates around the host card while the
// VLM is streaming. Animating the AngularGradient's `angle` parameter
// re-rasterizes the gradient texture every frame, which jittered when
// stacked on top of the live camera + token-stream redraws. Instead,
// the gradient is built once and rotated via `.rotationEffect`, which
// the render server handles as a transform on the cached layer. No
// `.drawingGroup()` — the offscreen Metal pass that forces crashes
// the app if the gradient is still animating while the app drops to
// the background (Metal won't accept GPU submissions from a
// background process).

private struct StreamingGradientEdge: View {
    let cornerRadius: CGFloat
    let color: Color
    let active: Bool

    @State private var rotation: Double = 0

    var body: some View {
        AngularGradient(
            gradient: Gradient(colors: [
                color.opacity(0.0),
                color.opacity(0.85),
                color.opacity(0.35),
                color.opacity(0.85),
                color.opacity(0.0),
            ]),
            center: .center
        )
        .rotationEffect(.degrees(rotation))
        .mask(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.black, lineWidth: 1)
        )
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: active)
        .onAppear { startIfNeeded() }
        .onChange(of: active) { _, _ in startIfNeeded() }
        .allowsHitTesting(false)
    }

    private func startIfNeeded() {
        guard active else { return }
        rotation = 0
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }
}

// MARK: - CaptionSkeleton
//
// Three pulsing skeleton lines, used as the empty-streaming state of the
// caption pill. Each line pulses on a staggered delay so the eye reads a
// rolling "still working" rhythm rather than three lines breathing in
// unison.

private struct CaptionSkeleton: View {
    @State private var phase: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .frame(maxWidth: i == 2 ? 180 : .infinity)
                    .frame(height: 10)
                    .opacity(phase ? 1.0 : 0.35)
                    .animation(
                        .easeInOut(duration: 1.2)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.18),
                        value: phase
                    )
            }
        }
        .onAppear { phase = true }
    }
}


// MARK: - StreamSafeTextSelection
// Toggles `.textSelection(.enabled)` only when the stream has settled.
// Selection support forces CoreText to retain selection-anchor state across
// every layout pass — combined with rapid token-by-token updates from the
// VLM, that pushes Futhark's line-segment allocator (the one in the crash
// report) over its capacity and the next store SIGABRTs. Disabling
// selection while streaming, then re-enabling once the result is final,
// gives users the copy-from-text affordance without the crash risk.
//
// `.textSelection(.enabled)` and `.textSelection(.disabled)` return
// different opaque types, so the conditional has to branch at the type
// level via @ViewBuilder.

struct StreamSafeTextSelection: ViewModifier {
    let streaming: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if streaming {
            content.textSelection(.disabled)
        } else {
            content.textSelection(.enabled)
        }
    }
}

// MARK: - FocusReticle
// Small animated square shown briefly at the user's tap-to-focus point.

struct FocusReticle: View {
    @State private var scale: CGFloat = 1.6
    @State private var opacity: Double = 0.0
    @Environment(\.koduTheme) private var T

    var body: some View {
        Rectangle()
            .stroke(T.warn, lineWidth: 1)
            .frame(width: 64, height: 64)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.18)) {
                    scale = 1.0
                    opacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    withAnimation(.easeIn(duration: 0.25)) {
                        opacity = 0.0
                    }
                }
            }
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
