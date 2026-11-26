import SwiftUI
import PhotosUI

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
    /// User-toggled continuous captioning. Unlike the short post-capture
    /// burst it runs until turned off, with the same interval/thermal gates.
    @State private var liveMode = false
    @State private var lensPanelState: LensPanelState = .collapsed
    @State private var selectedLensMode: LensMode = .ask
    @FocusState private var lensPromptFocused: Bool
    @Environment(\.koduTheme) private var T

    private static let liveCaptionFollowUpLimit = 2
    private static let minimumLiveCaptionIntervalMS = 6_000
    private static let maximumLiveCaptionIntervalMS = 30_000
    /// Pause between Live captions (after the previous one finishes).
    private static let liveModeGapMS = 1_500

    private var activeMode: AnalysisMode {
        AnalysisMode(rawValue: settings.analysisMode) ?? .code
    }

    /// OCR is built in; image descriptions use an explicitly selected model.
    private var activeVLMLabel: String {
        let selectionID = LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        if LocalModelRegistry.isDefaultVisionSelection(selectionID) {
            return LocalizationService.shared.t("text recognition")
        }
        // The catalog's display name; the header truncates it if needed.
        return selectedVLMEntry?.displayName
            ?? selectionID.split(separator: "/").last.map(String.init)
            ?? selectionID
    }

    /// Catalog entry behind the Lens selection, when it has one.
    private var selectedVLMEntry: DownloadableModel? {
        let id = LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        return ModelDownloadCenter.shared.models.first { $0.id == id || $0.sourceRepoID == id }
    }

    /// The selected vision model is in the catalog but not on this device.
    private var activeVLMMissing: Bool {
        guard let entry = selectedVLMEntry else { return false }
        return !entry.isReady && !entry.state.isActive
    }

    /// Built-in OCR is ready for code mode without model residency.
    private var activeVLMReady: Bool {
        if LocalModelRegistry.isDefaultVisionSelection(
            LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        ) {
            return activeMode == .code
        }
        if case .ready = selectedVisionState { return true }
        return false
    }

    /// State of the backend the Lens selection actually routes to. GGUF
    /// models (LFM3 Omni, SmolVLM2) run on llama.cpp, so reading only
    /// MLXVisionService left their pill grey and hid load failures.
    private var selectedVisionState: LensInferenceLoop.State {
        let id = LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        guard LocalModelRegistry.visionRuntime(
            forStoredSelectionID: id, catalog: ModelDownloadCenter.shared.models
        ) == .llamaCpp else { return MLXVisionService.shared.state }
        switch LlamaCppVLMService.shared.state {
        case .unloaded: return .unloaded
        case .loading(let message): return .loading(message)
        case .ready: return .ready
        case .generating: return .generating
        case .failed(let message): return .failed(message)
        }
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
            VStack(alignment: .leading, spacing: Space.xxs) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.inner))
                    .overlay(RoundedRectangle(cornerRadius: Radius.inner)
                        .stroke(.white.opacity(0.18), lineWidth: 1))
                if let info = vision.lastModelInputInfo {
                    Text("\(info.inputWidth)×\(info.inputHeight)")
                        .font(T.mono(9, .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, Space.xxs).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.6)))
                    Text(info.requestID.uuidString.prefix(8).description)
                        .font(T.mono(8))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, Space.xxs).padding(.vertical, 1)
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
            HStack(spacing: Space.s) {
                LensModelStatusIndicator(color: cameraModelStatusColor, isReady: activeVLMReady)
                VStack(alignment: .leading, spacing: 1) {
                    Label {
                        Text(activeVLMLabel)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } icon: {
                        Image(systemName: "cpu")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    Text(activeVLMMissing ? "Model not installed" : (activeVLMReady ? "Ready · On-device" : "On-device"))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(.horizontal, Space.s)
            .frame(maxWidth: .infinity, minHeight: 44)
            .glassSurface(.capsule, cornerRadius: Radius.panel)
            .environment(\.colorScheme, .dark)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
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
            // Built-in OCR — always present in the menu, even when
            // not fully installed. Picking it while it's not installed
            // surfaces a toast via applySelection's install-status
            // check; better that than hiding the canonical option.
            Button {
                HapticManager.impact(.light)
                Task { await VisualModelPickerView.applySelection(LocalModelRegistry.defaultVisionSelectionID) }
            } label: {
                if LocalModelRegistry.isDefaultVisionSelection(current) {
                    Label("Text recognition (OCR)", systemImage: "checkmark")
                } else {
                    Text("Text recognition (OCR)")
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
            return activeMode == .code ? T.good : T.ink3
        }
        switch selectedVisionState {
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
        "\(activeMode.rawValue)-\(settings.smolVLMIntervalMS)-\(hasStartedLiveLoop)-\(liveMode)-\(isLensActive)"
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

            if camera.error == nil, let paused = camera.interruptionMessage {
                Label(paused, systemImage: "pause.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(Space.m)
                    .appPanel(cameraSafe: true)
                    .environment(\.colorScheme, .dark)
                    .padding(Space.l)
                    .accessibilityIdentifier("lens.camera.paused")
            }

            if let cameraError = camera.error {
                VStack(spacing: Space.s) {
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
                        .glassButton(prominent: true)
                        .controlSize(.large)
                    }
                }
                .padding(Space.l)
                .appPanel(cameraSafe: true)
                .environment(\.colorScheme, .dark)
                .padding(Space.l)
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
                    .padding(.horizontal, Space.m)
                    .avoidingDisplayDivision()
                    .padding(.top, Space.s)
                Spacer()
            }

            // Scan frame (design 03) — pink corner brackets in the upper-center
            // viewfinder area, kept clear of the mode switcher / answer card
            // that live in the lower portion of the screen. Hidden without a
            // live feed: the brackets drew through the camera error and
            // paused panels centred in the same area.
            if camera.error == nil, camera.interruptionMessage == nil {
                VStack {
                    scanFrame.padding(.top, 84)
                    Spacer()
                }
            }

            // Debug overlay — shows the EXACT image the model received,
            // post-orientation and post-resize. Off by default; toggle
            // via Settings → INTERFACE → "show model input debug". When
            // captions don't match the camera, this surfaces whether the
            // pipeline is at fault (thumb mismatches preview) or the
            // model is (thumb matches but caption is wrong).
            if settings.showModelInputDebug {
                modelInputDebugOverlay
                    .padding(.leading, Space.m)
                    .padding(.top, 180)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topLeading)
                    .allowsHitTesting(false)
            }

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
                // Same edge as the Lens top bar.
                .padding(.horizontal, Space.screenMargin)
                .avoidingDisplayDivision()
                .padding(.bottom, Space.s)
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
            guard activeMode == .visual, hasStartedLiveLoop || liveMode, isLensActive else { return }
            // Keep the screen awake while the follow-up burst runs — auto-lock
            // would background the app and kill in-flight GPU work. The
            // defer restores it on every exit (tab leave, mode switch,
            // key change all cancel this task), and DeviceSafetyMonitor's
            // background observer force-clears it as a backstop.
            DeviceSafetyMonitor.shared.setKeepAwake(true, reason: "lens-live-loop")
            defer { DeviceSafetyMonitor.shared.setKeepAwake(false, reason: "lens-live-loop") }
            if liveMode {
                // Back-to-back small captions (AnalysisService.liveSized):
                // next one starts a short gap after the last finishes, 3×
                // longer when warm or in Low Power, none while unsafe.
                while !Task.isCancelled {
                    let safety = DeviceSafetyMonitor.shared
                    if !safety.shouldStopHeavyWork, !analysis.isAnalyzing {
                        analysis.captureAndAnalyzeBest(live: true)
                    }
                    while analysis.isAnalyzing, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    // A hard error (no model files, load failure, camera
                    // denied) won't fix itself; show it once, stop retrying.
                    if !Task.isCancelled, lensErrorText != nil {
                        liveMode = false
                        lensPanelState = .error
                        return
                    }
                    let gap = Self.liveModeGapMS * (safety.shouldThrottle || safety.lowPowerMode ? 3 : 1)
                    try? await Task.sleep(for: .milliseconds(gap))
                }
                return
            }
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
                hasStartedLiveLoop = false; liveMode = false
                // Code mode reviews with the Assistant; keep a shared Omni.
                CodingAssistantService.shared.adoptLensRuntime()
                MLXVisionService.shared.unload()
                LlamaCppVLMService.shared.unload()
                FastVLMService.shared.unload()
            } else {
                LlamaCppVLMService.shared.adoptAssistantRuntime()
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
            hasStartedLiveLoop = false; liveMode = false
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
                hasStartedLiveLoop = false; liveMode = false
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
            // Live captions update the overlay in place; no photo-style
            // processing → answer card flips (or haptics) per refresh.
            guard !liveMode else { return }
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
                // Decode off the main thread and downsampled: a full-size
                // 48 MP decode here froze the UI and cost ~190 MB per copy.
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = await Task.detached(priority: .userInitiated, operation: {
                       AnalysisService.downsampledImage(from: data)
                   }).value {
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
        VStack(spacing: Space.s) {
            if activeMode == .visual, liveMode {
                liveCaptionCard
            } else if activeMode == .visual {
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
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("CODE · ON-DEVICE")
                        .font(AppTypography.eyebrow)
                        .foregroundStyle(.secondary)
                    Text("Frame code and capture a still for OCR and review.")
                        .font(.headline)
                }
                .padding(Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appPanel(cameraSafe: true)
            }

            if (lensPanelState == .collapsed && !liveMode) || activeMode == .code {
                shutterRow
                    .padding(.horizontal, Space.m)
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
        guard analysis.captureAndAnalyzeBest() else {
            withAnimation(AppAnimation.state) { lensPanelState = .collapsed }
            ToastCenter.shared.error("Nothing captured", detail: analysis.statusMessage)
            return
        }
        hasStartedLiveLoop = true
        withAnimation(AppAnimation.state) { lensPanelState = .analyzing }
    }

    private func cancelLensAnalysis() {
        liveMode = false   // Cancel means stop, not "skip one caption".
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
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: "eye.slash")
                    .font(.system(.footnote, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
                Text(loc.t(hasSelection
                           ? "vision model not loaded"
                           : "no vision model loaded"))
                    .font(T.mono(11, .semibold))
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
                HStack(spacing: Space.xs) {
                    Image(systemName: hasSelection
                          ? "arrow.triangle.2.circlepath"
                          : "arrow.down.circle")
                        .font(.system(.caption, weight: .semibold))
                    Text(loc.t(missingVisionModelButtonLabel(hasSelection: hasSelection)))
                        .font(T.mono(11, .semibold))
                }
            }
            .glassButton(prominent: true)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.m)
        .background(Color.black.opacity(0.72))
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
    }

    private func missingVisionModelButtonLabel(hasSelection: Bool) -> String {
        "open models"
    }

    private func handleMissingVisionModelAction(hasSelection: Bool) {
        AppBridge.shared.requestModels(.lens)
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
    /// an explicitly selected vision model). OCR-only
    /// fallback paths get hidden chips since the model can't actually obey.
    private var supportsPromptPresets: Bool {
        if !LocalModelRegistry.isDefaultVisionSelection(
            LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        ) { return true }
        return false
    }

    /// True when the active visual model has no inference path available
    /// right now — either the selected MLX VLM failed to load, or the user
    /// has selected built-in OCR in image-description mode. In that case
    /// the capture button is disabled and routes to the download/picker
    /// flow instead of swallowing a tap.
    private var visualModelMissing: Bool {
        // Only relevant in visual mode — code mode (OCR) always has a path.
        guard activeMode == .visual else { return false }
        if !LocalModelRegistry.isDefaultVisionSelection(
            LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        ) {
            // User picked an MLX VLM: must be loaded, or fail honestly.
            // MLX only: a failed llama.cpp run keeps weights resident and
            // tryLlamaCppVisionPath retries it, so don't disable capture.
            if case .failed = MLXVisionService.shared.state { return true }
            // .loading/.unloaded/.generating count as "still warming" — allow
            // taps so users can re-trigger after the model finishes warming.
            return false
        }
        // OCR cannot provide general image descriptions.
        return true
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
        HStack(spacing: Space.s) {
            lensCircleButton("xmark") { onClose() }
            lensTopStrip
            if activeMode == .visual { liveModeButton }
            lensMoreMenu
        }
    }

    /// Top bar, not the shutter row: the shutter hides behind every answer
    /// card, and in live mode an answer card is almost always showing.
    private var liveModeButton: some View {
        Button {
            HapticManager.impact(.light)
            if liveMode { stopLiveMode(); return }
            guard !visualModelMissing else {
                ToastCenter.shared.info("Choose a vision model first",
                                        detail: "Live mode describes the camera with a vision model.")
                return
            }
            // Drop any photo answer so the overlay starts fresh; the loop
            // takes the first caption immediately.
            analysis.cancelCurrentAnalysis()
            lensPromptFocused = false
            KeyboardDismiss.now()
            lastCaption = ""
            lensPanelState = .collapsed
            liveMode = true
        } label: {
            Image(systemName: "livephoto")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundColor(.white)
                .symbolEffect(.pulse, isActive: liveMode)
                .frame(width: Size.control, height: Size.control)
                .background(Circle().fill(liveMode ? Color.red : Color.clear))
                .glassSurface(.toolbarButton, cornerRadius: Radius.panel)
                .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Live mode")
        .accessibilityValue(liveMode ? "On" : "Off")
        .accessibilityHint("Keeps describing what the camera sees until you turn it off")
        .accessibilityIdentifier("lens.live")
    }

    private func stopLiveMode() {
        liveMode = false
        hasStartedLiveLoop = false
        analysis.cancelCurrentAnalysis()
        lensPanelState = .collapsed
    }

    /// Newest caption text: the one streaming now, else the last finished
    /// one, so the overlay never blanks between refreshes.
    private var liveCaptionText: String {
        if let streaming = analysis.activeResult?.extractedCode, !streaming.isEmpty {
            return String(streaming.prefix(Self.captionMaxChars))
        }
        return lastCaption.isEmpty
            ? (analysis.activeResult?.fallbackReason ?? "")
            : lastCaption
    }

    private var liveCaptionCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Label("LIVE", systemImage: "circle.fill")
                    .font(AppTypography.eyebrow)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                Spacer()
                Button("Stop", systemImage: "stop.fill") {
                    HapticManager.impact(.light)
                    stopLiveMode()
                }
                .glassButton()
                .controlSize(.small)
                .tint(.white)
                .accessibilityIdentifier("lens.live.stop")
            }
            Text(liveCaptionText.isEmpty ? "Looking…" : liveCaptionText)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: liveCaptionText)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("lens.live.caption")
        }
        .padding(Space.m)
        .appPanel(cameraSafe: true)
    }

    private func lensCircleLabel(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: Size.control, height: Size.control)
            .glassSurface(.toolbarButton, cornerRadius: Radius.panel)
            .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
    }

    private func lensCircleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.impact(.light); action()
        } label: {
            lensCircleLabel(icon)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.circleButtonLabel[icon] ?? "Lens control")
    }

    private static let circleButtonLabel = [
        "xmark": "Close Lens", "doc.viewfinder": "Scan a document",
        "bolt.fill": "Turn off torch", "bolt.slash.fill": "Turn on torch",
    ]

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
                .font(.system(.subheadline, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: Size.control, height: Size.control)
                .glassSurface(.toolbarButton, cornerRadius: Radius.panel)
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
                        .padding(.horizontal, Space.s).padding(.vertical, Space.xs)
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
        HStack(spacing: Space.xs) {
            ForEach(LensMode.allCases) { m in
                let on = currentLensMode == m
                Button { selectLensMode(m) } label: {
                    Text(loc.t(m.label))
                        .font(T.sans(13, on ? .semibold : .medium))
                        .foregroundColor(.white.opacity(on ? 0.96 : 0.72))
                        .padding(.horizontal, on ? 18 : 15)
                        .padding(.vertical, Space.s)
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
        return VStack(alignment: .leading, spacing: Space.xs) {
            Text("\(loc.t(mode.label).uppercased()) · \(loc.t("ON-DEVICE"))")
                .font(T.sans(11, .bold)).tracking(TextScale.capsTracking)
                .foregroundColor(T.accentStrong)
            Text(settings.lensCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? loc.t(mode.question)
                 : settings.lensCustomPrompt)
                .font(T.sans(17, .semibold)).foregroundColor(cardInk)
            if streaming && capped.isEmpty {
                HStack(spacing: Space.s) {
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
            HStack(spacing: Space.s) {
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .fill(Color.black.opacity(0.10))
                    .frame(width: Size.glyph, height: Size.glyph)
                Text(streaming ? loc.t("Identifying on-device…") : loc.t("Identified on-device"))
                    .font(T.sans(12)).foregroundColor(cardInk2)
                Spacer(minLength: 0)
                if !capped.isEmpty && !streaming {
                    Button {
                        UIPasteboard.general.string = capped; HapticManager.impact(.medium)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(.footnote, weight: .semibold)).foregroundColor(cardInk2)
                            .frame(width: Size.control, height: Size.control)
                            .background(Circle().fill(Color.black.opacity(0.06)))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.top, Space.hair)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        // ponytail: opaque white card, not glass — clear glass renders the
        // dark ink text unreadable over the live camera feed. Matches the
        // `fallbackFill: .white` the design already asked for.
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .stroke(.black.opacity(streaming ? 0.20 : 0.08), lineWidth: 1)
        )
    }

    // MARK: Shutter row

    private var shutterRow: some View {
        HStack {
            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                lensCircleLabel("photo.on.rectangle")
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
                    .font(.system(.title2, weight: .semibold))
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
                    .mask(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
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
        HStack(spacing: Space.s) {
            Image(systemName: "text.bubble")
                .font(.system(.footnote, weight: .semibold))
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
                        .font(.system(.subheadline, weight: .semibold))
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
                        .frame(width: Size.control, height: Size.control)
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(.footnote, weight: .bold))
                            .foregroundStyle(trimmedPrompt.isEmpty ? .white.opacity(0.45) : .black)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(trimmedPrompt.isEmpty || isBusy)
            .accessibilityLabel("Ask Lens")
        }
        .padding(.leading, Space.m)
        .padding(.trailing, Space.s)
        .padding(.vertical, Space.s)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
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
        case .ask: return LocalizationService.shared.t("Ask")
        case .translate: return LocalizationService.shared.t("Translate")
        case .scan: return LocalizationService.shared.t("Scan")
        case .solve: return LocalizationService.shared.t("Solve")
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
        VStack(alignment: .leading, spacing: Space.s) {
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
