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
