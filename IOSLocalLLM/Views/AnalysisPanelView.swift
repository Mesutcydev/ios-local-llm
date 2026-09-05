import SwiftUI

// MARK: - AnalysisPanelView

struct AnalysisPanelView: View {
    let staticResult: AnalysisResult
    @ObservedObject var analysis: AnalysisService
    @Binding var isPresented: Bool
    @State private var selectedTab = 0
    @State private var showCodeEditor = false
    @State private var editableCode: String = ""
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var pendingQuestion: String = ""
    @FocusState private var questionFocused: Bool
    /// Presents OnboardingModelPickerView when a result's suggested
    /// action is .pickVisualModel — keeps the recovery flow inline
    /// rather than dumping the user on the Models tab.
    @State private var showModelPickerSheet: Bool = false
    private let bridge = AppBridge.shared
    private let settings = AppSettings.shared

    @Environment(\.koduTheme) private var T

    init(result: AnalysisResult, analysis: AnalysisService, isPresented: Binding<Bool>) {
        self.staticResult = result
        self.analysis = analysis
        self._isPresented = isPresented
    }

    /// Always reflect the latest stored copy of the result (for live Q&A streaming).
    private var result: AnalysisResult {
        analysis.analysisResults.first(where: { $0.id == staticResult.id })
            ?? analysis.activeResult
            ?? staticResult
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            if result.mode == .visual {
                // Visual mode: single description panel, no tabs
                Divider().background(Color.white.opacity(0.1))
                visualDescriptionTab
            } else {
                // Code mode: Code / Review tabs + Q&A bar
                Picker("", selection: $selectedTab) {
                    Text("Code").tag(0)
                    Text("Review").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider().background(Color.white.opacity(0.1))

                TabView(selection: $selectedTab) {
                    codeTab.tag(0)
                    reviewWithQATab.tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(T.bg)
                .ignoresSafeArea()
        )
        .onAppear {
            editableCode = result.extractedCode
            // Auto-read if enabled
            if settings.voiceAutoRead {
                let textToRead: String = {
                    if result.mode == .visual { return result.extractedCode }
                    return [result.reviewMarkdown, result.extractedCode].filter { !$0.isEmpty }.first ?? ""
                }()
                if !textToRead.isEmpty {
                    VoiceService.shared.speak(textToRead)
                }
            }
        }
        .onDisappear { VoiceService.shared.stop() }
        .sheet(isPresented: $showCodeEditor) {
            CodePanelView(code: $editableCode, language: detectLanguage(result.extractedCode))
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        // Visual-model picker invoked from the inline action button
        // under a "FastVLM not available" fallback banner.
        .sheet(isPresented: $showModelPickerSheet) {
            NavigationStack {
                OnboardingModelPickerView {
                    showModelPickerSheet = false
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { showModelPickerSheet = false }
                            .font(T.conversationBody)
                            .foregroundColor(T.ink2)
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
            }
            .preferredColorScheme(settings.resolvedColorScheme)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("analysis")
                            .font(T.display(17, .semibold))
                            .tracking(-0.4)
                            .foregroundColor(T.ink)
                        if result.isStreaming {
                            sourcePill(label: "streaming", color: T.warn)
                        } else if result.ocrFallback {
                            sourcePill(label: "ocr fallback", color: T.warn)
                        } else if result.mode == .visual {
                            sourcePill(label: "fastvlm vision", color: T.accent)
                        } else {
                            sourcePill(label: "fastvlm", color: T.good)
                        }
                    }
                    HStack(spacing: 6) {
                        KMono(text: result.detection.label, size: 11, color: T.ink3)
                            .lineLimit(1)
                        KMono(text: "·", size: 11, color: T.ink4)
                        KMono(text: result.timestamp.formatted(date: .omitted, time: .shortened),
                               size: 11, color: T.ink3)
                            .fixedSize()
                    }
                }
                Spacer(minLength: 8)
                KIconButton {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(T.ink)
                } action: {
                    withAnimation(.spring(duration: 0.3)) { isPresented = false }
                }
            }

            // Fallback reason banner — flat warn box. Includes the
            // inline action button beneath it when the result carries
            // a SuggestedAction (passive error → one-tap recovery).
            if let reason = result.fallbackReason {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("◉")
                            .font(T.mono(11))
                            .foregroundColor(T.warn)
                        Text(reason)
                            .font(T.mono(10))
                            .foregroundColor(T.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let action = result.suggestedAction {
                        suggestedActionButton(action)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(T.warn.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(T.warn.opacity(0.3), lineWidth: 1))
            }

            // Action row — adapts to mode. Horizontal scroll keeps all buttons
            // accessible on narrow widths without wrapping.
            let hasContent = !result.extractedCode.isEmpty
            if hasContent {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                    // Primary: Ask Assistant — Studio ink-on-bg fill
                    Button {
                        HapticManager.impact(.medium)
                        let source = result.ocrFallback ? "Camera OCR"
                            : result.mode == .visual ? "FastVLM Vision" : "FastVLM"
                        bridge.sendToAssistant(
                            code: result.extractedCode,
                            source: source,
                            image: result.ciImage.map { UIImage(ciImage: $0) } ?? result.thumbnail
                        )
                        withAnimation { isPresented = false }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "brain")
                                .font(.system(size: 12, weight: .medium))
                            Text("ask assistant")
                                .font(T.mono(12, .semibold))
                                .tracking(0.2)
                        }
                        .foregroundColor(T.bg)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(T.ink))
                    }
                    .buttonStyle(.plain)

                    // Share — secondary
                    Button {
                        shareItems = [result.fullMarkdown]
                        showShareSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 12))
                            Text("share")
                                .font(T.mono(12))
                        }
                        .foregroundColor(T.ink2)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .kGlass(cornerRadius: 6, fallbackFill: T.surface)
                    }
                    .buttonStyle(.plain)

                    // Read Aloud / Stop
                    let voiceText: String = {
                        if result.mode == .visual { return result.extractedCode }
                        return selectedTab == 0 ? result.extractedCode : result.reviewMarkdown
                    }()
                    VoiceControlsView(text: voiceText)

                    // Copy
                    KIconButton {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundColor(T.ink2)
                    } action: {
                        UIPasteboard.general.string = result.extractedCode
                        HapticManager.impact(.light)
                    }
                    }   // HStack
                    .padding(.trailing, 4)
                }       // ScrollView
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// Mode-source pill (FastVLM / OCR / Vision / streaming) — flat.
    @ViewBuilder
    private func sourcePill(label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            if label == "streaming" {
                Circle().fill(color).frame(width: 5, height: 5)
                    .modifier(BlinkModifier())
            }
            Text(label)
                .font(T.mono(9, .semibold))
                .tracking(0.5)
        }
        .foregroundColor(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.12)))
    }

    // MARK: - Visual description tab

    private var visualDescriptionTab: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Tappable area to dismiss keyboard
                        Color.clear.frame(height: 0)
                        if result.extractedCode.isEmpty && result.isStreaming {
                            HStack(spacing: 6) {
                                StreamingCaret()
                                KMono(text: "describing scene…", size: 11, color: T.ink3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        } else if result.extractedCode.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "eye.slash")
                                    .font(.system(size: 28))
                                    .foregroundColor(T.ink3)
                                Text(result.fallbackReason ?? "FastVLM pipeline required for Visual mode.")
                                    .font(T.sans(12))
                                    .foregroundColor(T.ink3)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        } else {
                            // Scene description (with caret while streaming)
                            VStack(alignment: .leading, spacing: 0) {
                                // Selection toggled by streaming state to keep
                                // CoreText's Futhark line-break allocator from
                                // overflowing on long, rapidly-updating output.
                                // See StreamSafeTextSelection in ContentView.swift.
                                Text(result.extractedCode)
                                    .font(T.conversationBody)
                                    .foregroundColor(T.ink)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .modifier(StreamSafeTextSelection(streaming: result.isStreaming))
                                if result.isStreaming {
                                    StreamingCaret().padding(.top, 4)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .kGlass(cornerRadius: 8, fallbackFill: T.surface)

                            // Q&A exchanges
                            ForEach(result.questionAnswers) { qa in
                                qaBubble(qa).id(qa.id)
                            }
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    TapGesture().onEnded { questionFocused = false }
                )
                .onChange(of: result.questionAnswers.last?.answer) { _, _ in
                    if let last = result.questionAnswers.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            askQuestionBar
        }
    }

    // MARK: - Q&A bubble

    @ViewBuilder
    private func qaBubble(_ qa: AnalysisResult.QAExchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // USER ───────
            HStack(spacing: 6) {
                Text("USER")
                    .font(T.mono(9))
                    .tracking(0.5)
                    .foregroundColor(T.ink3)
                Rectangle().fill(T.rule).frame(height: 1)
            }
            Text(qa.question)
                .font(T.sans(13, .medium))
                .foregroundColor(T.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            // QWEN ← ─────
            HStack(spacing: 6) {
                Text("QWEN ←")
                    .font(T.mono(9, .semibold))
                    .tracking(0.5)
                    .foregroundColor(T.accent)
                Rectangle().fill(T.rule).frame(height: 1)
                if qa.isStreaming {
                    Text("generating")
                        .font(T.mono(9))
                        .foregroundColor(T.warn)
                }
            }
            HStack(alignment: .bottom, spacing: 4) {
                Text(qa.answer.isEmpty && qa.isStreaming ? "thinking…" : qa.answer)
                    .font(T.conversationBody)
                    .foregroundColor(T.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(StreamSafeTextSelection(streaming: qa.isStreaming))
                if qa.isStreaming { StreamingCaret() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kGlass(cornerRadius: 8, fallbackFill: T.surface)
    }

    // MARK: - Ask Question bar

    @ViewBuilder
    private var askQuestionBar: some View {
        if result.ciImage != nil, FastVLMService.shared.componentStatus.canGenerate {
            VStack(spacing: 0) {
                Rectangle().fill(T.rule).frame(height: 1)

                // Question text field — matches the assistant chat composer
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.bubble")
                        .font(.system(size: 13))
                        .foregroundColor(T.ink3)
                    TextField("ask about this image…",
                              text: $pendingQuestion,
                              axis: .vertical)
                        .font(T.sans(14))
                        .foregroundColor(T.ink)
                        .tint(T.accent)
                        .lineLimit(1...3)
                        .focused($questionFocused)
                        .submitLabel(.send)
                        .onSubmit { submitQuestion() }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(T.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(questionFocused ? T.accent.opacity(0.55) : T.rule, lineWidth: 1)
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .animation(.easeOut(duration: 0.15), value: questionFocused)

                // Studio-themed toolbar above the keyboard (only while focused)
                if questionFocused {
                    KeyboardToolbar(
                        inputText: $pendingQuestion,
                        inputFocused: $questionFocused,
                        onPaste: {
                            if let t = UIPasteboard.general.string, !t.isEmpty {
                                pendingQuestion = t
                            }
                        },
                        onPickPhoto: {},       // not relevant inside the analysis sheet
                        onPickSnippet: {},     // ditto
                        onSend: submitQuestion,
                        canSend: canSendQuestion,
                        isSending: false
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .kClearGlass(in: Rectangle(), fallbackFill: T.bg)
            .animation(.easeInOut(duration: 0.18), value: questionFocused)
        }
    }

    private var canSendQuestion: Bool {
        !pendingQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitQuestion() {
        let q = pendingQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        pendingQuestion = ""
        questionFocused = false
        KeyboardDismiss.now()
        HapticManager.messageSent()
        analysis.askQuestion(q, about: result)
    }

    private var codeTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if result.extractedCode.isEmpty && result.isStreaming {
                    // Streaming placeholder
                    HStack(spacing: 6) {
                        StreamingCaret()
                        KMono(text: "waiting for first token…", size: 11, color: T.ink3)
                    }
                    .padding()
                } else if result.extractedCode.isEmpty {
                    KMono(text: "no code extracted.", size: 12, color: T.ink3).padding()
                } else {
                    ZStack(alignment: .topTrailing) {
                        VStack(alignment: .leading, spacing: 0) {
                            SyntaxHighlightedText(
                                code: result.extractedCode,
                                language: detectLanguage(result.extractedCode)
                            )
                            if result.isStreaming {
                                StreamingCaret()
                                    .padding(.top, 2)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(T.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).stroke(T.rule, lineWidth: 1)
                        )

                        if !result.isStreaming {
                            Button { showCodeEditor = true } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                                    .padding(6)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(T.surface2))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(T.rule, lineWidth: 1))
                                    .foregroundColor(T.ink2)
                            }
                            .padding(8)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var reviewTab: some View {
        ScrollView {
            if result.reviewMarkdown.isEmpty {
                Text("No review available.").foregroundColor(.secondary).padding()
            } else {
                MarkdownTextView(markdown: result.reviewMarkdown).padding()
            }
        }
    }

    /// Review tab + Q&A exchanges + ask bar. Used in Code mode tab 1.
    private var reviewWithQATab: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !result.reviewMarkdown.isEmpty {
                        MarkdownTextView(markdown: result.reviewMarkdown)
                    } else if result.questionAnswers.isEmpty {
                        Text("No review available. Ask a question below to analyse this capture further.")
                            .font(T.sans(12))
                            .foregroundColor(T.ink3)
                    }
                    ForEach(result.questionAnswers) { qa in
                        qaBubble(qa)
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded { questionFocused = false }
            )
            askQuestionBar
        }
    }

    private func detectLanguage(_ code: String) -> String {
        let l = code.lowercased()
        if l.contains("func ") && (l.contains("var ") || l.contains("let ")) { return "Swift" }
        if l.contains("def ") || (l.contains("import ") && l.contains(":")) { return "Python" }
        if l.contains("const ") || l.contains("=>") { return "JavaScript" }
        if l.contains("#include") { return "C/C++" }
        return "Code"
    }

    // MARK: - Suggested action button
    //
    // Inline button that lets the user fix the underlying issue
    // (no visual model picked, FastVLM disabled, etc.) in a single
    // tap rather than reading the banner, dismissing the panel,
    // navigating to settings, finding the right toggle, and so on.

    @ViewBuilder
    private func suggestedActionButton(_ action: AnalysisResult.SuggestedAction) -> some View {
        let (label, icon, tint): (String, String, Color) = {
            switch action {
            case .pickVisualModel: return ("Pick visual model",   "checkmark.circle",       T.accent)
            case .downloadFastVLM: return ("Download FastVLM",    "arrow.down.circle",      T.accent)
            case .enableFastVLM:   return ("Enable in Settings",  "gearshape",              T.accent)
            }
        }()
        Button {
            HapticManager.impact(.light)
            handleSuggestedAction(action)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(T.mono(11, .semibold))
                    .tracking(0.3)
            }
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().stroke(tint.opacity(0.40), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func handleSuggestedAction(_ action: AnalysisResult.SuggestedAction) {
        switch action {
        case .pickVisualModel:
            // Present the picker inline as a sheet on the panel —
            // keeps the user in context (didn't dismiss their result)
            // and avoids tab-hopping. Once they commit a pick, the
            // sheet closes; the next capture uses the new model.
            showModelPickerSheet = true

        case .downloadFastVLM:
            // Switch to Models tab; the FastVLM entry's Download
            // button is the next tap. Dismiss the panel so the user
            // sees the tab change immediately.
            isPresented = false
            bridge.requestTab(.models)

        case .enableFastVLM:
            // Settings is reachable from the Models tab via the gear
            // icon. Surface that route by switching there and let the
            // user open Settings themselves. (We don't have a global
            // "present Settings sheet" hook from arbitrary contexts.)
            isPresented = false
            bridge.requestTab(.models)
        }
    }
}

// MARK: - StreamingCaret
// Blinking caret shown while FastVLM is generating.

struct StreamingCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.koduTheme) private var T
    @ScaledMetric(relativeTo: .body) private var caretHeight: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion || scenePhase != .active)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * .pi * 2 / 1.2
            RoundedRectangle(cornerRadius: 1)
                .fill(T.ink)
                .frame(width: 2, height: caretHeight)
                .opacity(reduceMotion ? 0.65 : 0.35 + 0.65 * (sin(phase) + 1) / 2)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - BlinkModifier
// Subtle pulse for status dots while a stream is in progress.

struct BlinkModifier: ViewModifier {
    @State private var faded = false
    func body(content: Content) -> some View {
        content
            .opacity(faded ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    faded.toggle()
                }
            }
    }
}

// MARK: - ShareSheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - MarkdownTextView (unchanged — kept here for co-location)

struct MarkdownTextView: View {
    let markdown: String
    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in block }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [AnyView] {
        StudioTextBlocks.parse(markdown).flatMap { block -> [AnyView] in
            switch block {
            case .code(let language, let code):
                return [AnyView(CodeBlock(language: language, code: code))]
            case .thinking(let text, let open):
                return [AnyView(ThinkingBlock(content: text, isOpen: open))]
            case .math(let source):
                return [AnyView(MathBlock(latex: source))]
            case .text(let text):
                return text.components(separatedBy: "\n").map { AnyView(renderLine($0)) }
            }
        }
    }

    @ViewBuilder
    private func renderLine(_ line: String) -> some View {
        if line.hasPrefix("# ") {
            Text(String(line.dropFirst(2)))
                .font(T.display(20, .semibold))
                .tracking(-0.5)
                .foregroundColor(T.ink)
                .padding(.top, 8)
        } else if line.hasPrefix("## ") {
            Text(String(line.dropFirst(3)))
                .font(T.display(16, .semibold))
                .foregroundColor(T.ink)
                .padding(.top, 6)
        } else if line.hasPrefix("### ") {
            Text(String(line.dropFirst(4)))
                .font(T.sans(13, .semibold))
                .foregroundColor(T.ink)
        } else if line.hasPrefix("**") && line.hasSuffix("**") && line.count > 4 {
            Text(String(line.dropFirst(2).dropLast(2)))
                .font(T.sans(13, .semibold))
                .foregroundColor(T.ink)
        } else if line.hasPrefix("- ") {
            HStack(alignment: .top, spacing: 6) {
                Text("·").foregroundColor(T.ink3)
                Text(String(line.dropFirst(2)))
                    .font(T.sans(13))
                    .foregroundColor(T.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if line.hasPrefix("> ") {
            Text(String(line.dropFirst(2)))
                .font(T.mono(11))
                .foregroundColor(T.ink2)
                .padding(.leading, 10)
                .overlay(Rectangle().fill(T.warn.opacity(0.6)).frame(width: 2), alignment: .leading)
        } else if line.isEmpty {
            Spacer().frame(height: 4)
        } else {
            Text(line)
                .font(T.sans(13))
                .foregroundColor(T.ink2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
