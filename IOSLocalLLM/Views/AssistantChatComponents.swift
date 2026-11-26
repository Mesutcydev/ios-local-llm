import SwiftUI

#if targetEnvironment(macCatalyst)
import UIKit
#endif

/// The message and primary action share a row; quieter editing tools sit below.
struct AssistantComposer: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let canSend: Bool
    let isGenerating: Bool
    let hasCustomSampling: Bool
    let modelName: String
    let hasAttachments: Bool
    let onModel: () -> Void
    let onVoice: () -> Void
    let onAdd: () -> Void
    let onPhoto: () -> Void
    let onFile: () -> Void
    let onSampling: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void

    @Environment(\.koduTheme) private var theme
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject private var localization = LocalizationService.shared

    private var offersVoice: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAttachments && !isGenerating
    }

    #if targetEnvironment(macCatalyst)
    /// The Mac composer sends on Return. A SwiftUI multi-line TextField cannot
    /// express that — Return is always a newline — so this swaps in a UITextView
    /// that sends on a bare Return and keeps Shift/Option+Return for a line
    /// break. Everything else (snippets, dictation, draft clearing) still flows
    /// through the same `text` binding.
    private var macInput: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Message your assistant")
                    .font(.body)
                    .foregroundStyle(theme.ink3)
                    .padding(.leading, Space.xs)
                    .padding(.top, Space.s)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            MacComposerTextView(
                text: $text,
                ink: UIColor(theme.ink),
                accent: UIColor(theme.accent),
                maximumLines: textSize.isAccessibilitySize ? 4 : 6,
                canSend: canSend && !isGenerating,
                onSend: onSend
            )
            .padding(.leading, Space.xs)
        }
        .frame(minHeight: 44, alignment: .topLeading)
        .layoutPriority(1)
        .accessibilityLabel("Message your on-device assistant")
        .accessibilityIdentifier("assistant.composer.input")
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(alignment: .bottom, spacing: Space.s) {
                #if targetEnvironment(macCatalyst)
                macInput
                #else
                TextField("Message your assistant", text: $text, prompt: Text("Message your assistant").foregroundStyle(theme.ink3), axis: .vertical)
                .font(.body)
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .focused($isFocused)
                .lineLimit(1...(textSize.isAccessibilitySize ? 4 : 6))
                .submitLabel(.send)
                .onSubmit {
                    guard canSend, !isGenerating else { return }
                    onSend()
                }
                .frame(minHeight: 44, alignment: .center)
                .padding(.leading, Space.xs)
                .padding(.vertical, Space.hair)
                .layoutPriority(1)
                .accessibilityLabel("Message your on-device assistant")
                .accessibilityIdentifier("assistant.composer.input")
                #endif
                primaryAction
            }

            if textSize.isAccessibilitySize {
                modelButton
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: Space.hair) {
                Menu {
                    Button(action: onAdd) { Label("Prompt or snippet", systemImage: "text.badge.plus") }
                    Button(action: onPhoto) { Label("Photo", systemImage: "photo") }
                    Button(action: onFile) { Label("File", systemImage: "doc") }
                    Divider()
                    Button(action: onSampling) { Label("Sampling settings", systemImage: "slider.horizontal.3") }
                    if isFocused {
                        Button { isFocused = false; KeyboardDismiss.now() } label: {
                            Label("Dismiss keyboard", systemImage: "keyboard.chevron.compact.down")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(.title3, weight: .medium))
                        .frame(width: Size.control, height: Size.control)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Add a prompt or attachment")
                .accessibilityIdentifier("assistant.composer.add")
                if !textSize.isAccessibilitySize { modelButton }
                Spacer(minLength: 4)
                MicDictationButton(text: $text, compact: true, composerStyle: true)
                    .frame(width: Size.control, height: Size.control)
                    .accessibilityIdentifier("assistant.composer.dictation")
                if isFocused {
                    Button {
                        isFocused = false
                        KeyboardDismiss.now()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .frame(width: Size.control, height: Size.control)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss keyboard")
                    .accessibilityIdentifier("assistant.composer.dismissKeyboard")
                }
            }
            .foregroundStyle(theme.ink2)
        }
        .padding(.horizontal, Space.s)
        .padding(.top, Space.s)
        .padding(.bottom, Space.xs)
        .onChange(of: verticalSizeClass) { _, height in
            // ponytail: iOS 27.0 drops the keyboard inset when an iPhone turns
            // to landscape with the keyboard up, leaving this composer under
            // it. Showing the keyboard again once the turn has finished brings
            // the inset back. iPad rotation keeps its size class and is not
            // covered; delete this when the system re-applies the inset.
            guard height == .compact, isFocused else { return }
            isFocused = false
            KeyboardDismiss.now()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                isFocused = true
            }
        }
    }

    private var primaryAction: some View {
        let enabled = canSend || offersVoice || isGenerating
        return Button {
            if isGenerating { onStop() }
            else if offersVoice { onVoice() }
            else { onSend() }
        } label: {
            Image(systemName: isGenerating ? "stop.fill" : offersVoice ? "waveform" : "arrow.up")
                .font((isGenerating ? Font.body : .title3).weight(.semibold))
                .frame(width: Size.tile, height: Size.tile)
        }
        // The composer's main action: Apple's prominent glass circle.
        .glassButton(prominent: true)
        .buttonBorderShape(.circle)
        .disabled(!enabled)
        .accessibilityLabel(localization.t(isGenerating ? "Stop generating" : offersVoice ? "Start voice conversation" : "Send message"))
        .accessibilityHint(localization.t(isGenerating ? "Stops the current response" : offersVoice ? "Opens voice mode" : "Sends this message when the model is ready"))
        .accessibilityIdentifier("assistant.composer.primary")
    }

    private var modelButton: some View {
        Button(action: onModel) {
            HStack(spacing: Space.xs) {
                Text(verbatim: modelName)
                    .font(.caption.weight(.medium))
                    .lineLimit(textSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(.caption2, weight: .semibold))
                if hasCustomSampling {
                    Circle().fill(theme.accent).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, Space.s)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Model: \(modelName)"))
        .accessibilityHint("Choose a model")
        .accessibilityValue(localization.t(hasCustomSampling ? "Custom sampling settings" : "Default sampling settings"))
        .accessibilityIdentifier("assistant.composer.model")
    }
}

struct AssistantRuntimeDetailsSheet: View {
    @ObservedObject private var localization = LocalizationService.shared
    let model: AssistantModel
    let status: String
    let thermalStatus: String
    let onSwitchModel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Current model") {
                    LabeledContent("Model", value: model.displayName)
                    LabeledContent("Family", value: modelFamily)
                    LabeledContent("Approx. memory", value: model.approxRAMBytes.formattedBytes)
                    LabeledContent("State", value: localization.t(status))
                }
                Section("Runtime") {
                    LabeledContent("Engine", value: model.runtime.label)
                    LabeledContent("Quantization", value: localization.t(quantization))
                    LabeledContent("Context window", value: localization.t("\(model.contextWindowTokens.formatted()) tokens"))
                    LabeledContent("Thermal", value: localization.t(thermalStatus))
                }
                Section {
                    Button {
                        dismiss()
                        onSwitchModel()
                    } label: {
                        Label("Switch model", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .navigationTitle("On-device runtime")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var modelFamily: String {
        model.displayName.split(separator: " ").first.map(String.init) ?? model.displayName
    }

    private var quantization: String {
        let subtitle = model.subtitle.lowercased()
        if subtitle.contains("1-bit") { return "1-bit" }
        if subtitle.contains("2-bit") { return "2-bit" }
        if subtitle.contains("3-bit") { return "3-bit" }
        if subtitle.contains("4-bit") { return "4-bit" }
        if subtitle.contains("8-bit") { return "8-bit" }
        return "Model default"
    }
}

struct SamplingSettingsSheet: View {
    @Binding var temperature: Double?
    @Binding var topP: Double?
    @Binding var topK: Int?
    @Binding var repetitionPenalty: Double?
    let defaults: AssistantModelGenerationSettings

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    optionalSlider(
                        "Temperature",
                        value: $temperature,
                        fallback: defaults.temperature,
                        range: 0...1.5,
                        step: 0.05
                    )
                    optionalSlider(
                        "Top-p",
                        value: $topP,
                        fallback: defaults.topP,
                        range: 0.5...1,
                        step: 0.01
                    )

                    VStack(alignment: .leading, spacing: Space.s) {
                        LabeledContent("Top-k", value: "\(topK ?? defaults.topK)")
                        Slider(
                            value: Binding(
                                get: { Double(topK ?? defaults.topK) },
                                set: { topK = Int($0.rounded()) }
                            ),
                            in: 1...100,
                            step: 1
                        )
                    }

                    optionalSlider(
                        "Repetition penalty",
                        value: $repetitionPenalty,
                        fallback: defaults.repetitionPenalty,
                        range: 1...1.3,
                        step: 0.01
                    )
                } footer: {
                    Text("These values apply only to the next message. Empty controls use the selected model’s saved profile or the app defaults.")
                }

                Section {
                    Button("Reset to model defaults", role: .destructive) {
                        temperature = nil
                        topP = nil
                        topK = nil
                        repetitionPenalty = nil
                        HapticManager.selection()
                    }
                }
            }
            .navigationTitle("Sampling")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func optionalSlider(
        _ title: String,
        value: Binding<Double?>,
        fallback: Double,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            LabeledContent(title, value: String(format: "%.2f", value.wrappedValue ?? fallback))
            Slider(
                value: Binding(
                    get: { value.wrappedValue ?? fallback },
                    set: { value.wrappedValue = $0 }
                ),
                in: range,
                step: step
            )
        }
    }
}

// MARK: - Persistent per-model settings

struct AssistantModelSettingsTarget: Identifiable {
    let displayName: String
    let repositoryID: String
    let supportsThinking: Bool

    var id: String { repositoryID.lowercased() }

    init(model: AssistantModel) {
        displayName = model.displayName
        repositoryID = model.repoID
        supportsThinking = model.supportsThinking
    }

    init(
        displayName: String,
        repositoryID: String,
        supportsThinking: Bool
    ) {
        self.displayName = displayName
        self.repositoryID = repositoryID
        self.supportsThinking = supportsThinking
    }
}

struct AssistantModelSettingsView: View {
    let target: AssistantModelSettingsTarget

    @ObservedObject private var appSettings = AppSettings.shared
    @ObservedObject private var store = AssistantModelSettingsStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var draft = AssistantModelGenerationSettings.standard
    @State private var isCustomized = false
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            Form {
                AssistantModelSettingsIdentitySection(
                    displayName: target.displayName,
                    repositoryID: target.repositoryID,
                    isCustomized: isCustomized
                )

                Section {
                    Toggle("Customize this model", isOn: $isCustomized)
                } footer: {
                    Text("Off uses the app-wide Assistant settings. Turn it on to save an independent profile for this model.")
                }

                AssistantModelSettingsSummarySection(
                    settings: displayedSettings,
                    sourceLabel: isCustomized ? "Custom profile" : "App defaults"
                )

                if isCustomized {
                    AssistantModelBehaviorSettingsSection(
                        settings: $draft,
                        supportsThinking: target.supportsThinking
                    )
                    AssistantModelSamplingSettingsSection(settings: $draft)

                    Section {
                        Button("Reset to app defaults", role: .destructive) {
                            isCustomized = false
                            HapticManager.selection()
                        }
                    }
                }
            }
            .navigationTitle("Model settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .task(id: target.id) {
            load()
        }
        .onChange(of: isCustomized) { _, customized in
            guard hasLoaded else { return }
            if customized {
                draft = .appDefaults(
                    from: appSettings,
                    supportsThinking: target.supportsThinking
                )
                saveDraft()
            } else {
                store.reset(repositoryID: target.repositoryID)
            }
        }
        .onChange(of: draft) { _, _ in
            guard hasLoaded, isCustomized else { return }
            saveDraft()
        }
    }

    private var displayedSettings: AssistantModelGenerationSettings {
        if isCustomized { return draft }
        return .appDefaults(
            from: appSettings,
            supportsThinking: target.supportsThinking
        )
    }

    private func load() {
        if let saved = store.settings(for: target.repositoryID) {
            draft = saved
            isCustomized = true
        } else {
            draft = .appDefaults(
                from: appSettings,
                supportsThinking: target.supportsThinking
            )
            isCustomized = false
        }
        hasLoaded = true
    }

    private func saveDraft() {
        store.save(
            draft,
            for: target.repositoryID,
            supportsThinking: target.supportsThinking
        )
    }
}

private struct AssistantModelSettingsIdentitySection: View {
    let displayName: String
    let repositoryID: String
    let isCustomized: Bool

    var body: some View {
        Section {
            LabeledContent("Model", value: displayName)
            LabeledContent("Repository", value: repositoryID)
            LabeledContent("Settings", value: isCustomized ? "Custom" : "App defaults")
        }
    }
}

private struct AssistantModelSettingsSummarySection: View {
    let settings: AssistantModelGenerationSettings
    let sourceLabel: String

    var body: some View {
        Section("Effective settings") {
            LabeledContent("Source", value: sourceLabel)
            LabeledContent("Response length") {
                Text("\(settings.maxTokens) tokens")
            }
            LabeledContent("Temperature") {
                Text(
                    settings.temperature,
                    format: .number.precision(.fractionLength(2))
                )
            }
            LabeledContent("Top-p") {
                Text(
                    settings.topP,
                    format: .number.precision(.fractionLength(2))
                )
            }
        }
    }
}

private struct AssistantModelBehaviorSettingsSection: View {
    @Binding var settings: AssistantModelGenerationSettings
    let supportsThinking: Bool

    private let tokenOptions = [512, 1_024, 2_048, 4_096, 8_192]

    var body: some View {
        Section {
            Picker("Response length", selection: $settings.maxTokens) {
                ForEach(tokenOptions, id: \.self) { tokens in
                    Text("\(tokens) tokens").tag(tokens)
                }
            }

            if supportsThinking {
                Toggle("Thinking mode", isOn: $settings.thinkingEnabled)
            }
        } header: {
            Text("Behavior")
        } footer: {
            Text("Device safety limits can still shorten a response when the phone is hot or memory is constrained.")
        }
    }
}

private struct AssistantModelSamplingSettingsSection: View {
    @Binding var settings: AssistantModelGenerationSettings

    var body: some View {
        Section {
            AssistantModelSettingsSliderRow(
                title: "Temperature",
                value: $settings.temperature,
                range: 0...1.5,
                step: 0.05
            )
            AssistantModelSettingsSliderRow(
                title: "Top-p",
                value: $settings.topP,
                range: 0.05...1,
                step: 0.01
            )

            Stepper(value: $settings.topK, in: 0...100, step: 5) {
                LabeledContent("Top-k", value: settings.topK.formatted())
            }

            AssistantModelSettingsSliderRow(
                title: "Min-p",
                value: $settings.minP,
                range: 0...0.5,
                step: 0.01
            )
            AssistantModelSettingsSliderRow(
                title: "Repetition penalty",
                value: $settings.repetitionPenalty,
                range: 1...1.3,
                step: 0.01
            )
        } header: {
            Text("Sampling")
        } footer: {
            Text("These values are restored automatically whenever this model becomes active.")
        }
    }
}

private struct AssistantModelSettingsSliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            LabeledContent(title) {
                Text(value, format: .number.precision(.fractionLength(2)))
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

#if targetEnvironment(macCatalyst)
// MARK: - MacComposerTextView
//
// Mac chat fields send on Return. SwiftUI's multi-line TextField cannot do
// that — Return is always a newline for a vertical-axis field, and `.onSubmit`
// never fires — so the Mac composer wraps a UITextView instead. A bare Return
// sends; Shift+Return and Option+Return still insert a line break. The
// modifier state is tracked in `pressesBegan` because `shouldChangeTextIn`
// does not report modifiers.
//
// Height follows the text between one and `maximumLines` lines, then the view
// scrolls, matching the iPhone composer's `lineLimit`.

struct MacComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let ink: UIColor
    let accent: UIColor
    let maximumLines: Int
    let canSend: Bool
    let onSend: () -> Void

    func makeUIView(context: Context) -> ComposerUITextView {
        let view = ComposerUITextView()
        view.delegate = context.coordinator
        view.onSend = onSend
        view.canSend = canSend
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: Space.s, left: 0, bottom: Space.s, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.tintColor = accent
        view.textColor = ink
        view.text = text
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: ComposerUITextView, context: Context) {
        context.coordinator.parent = self
        view.onSend = onSend
        view.canSend = canSend
        view.tintColor = accent
        view.textColor = ink
        // Snippets and dictation write through the binding; mirror them and
        // leave the caret at the end so the next keystroke appends.
        if view.text != text {
            view.text = text
            let end = (text as NSString).length
            view.selectedRange = NSRange(location: end, length: 0)
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ComposerUITextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 1 else { return nil }
        let fitting = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let lineHeight = uiView.font?.lineHeight ?? 20
        let cap = lineHeight * CGFloat(max(maximumLines, 1)) + insets
        uiView.isScrollEnabled = fitting > cap + 0.5
        return CGSize(width: width, height: min(fitting, cap))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MacComposerTextView

        init(_ parent: MacComposerTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard replacement == "\n" else { return true }
            guard let view = textView as? ComposerUITextView else { return true }
            // Shift/Option+Return is the explicit line break.
            let flags = view.lastModifierFlags
            if flags.contains(.shift) || flags.contains(.alternate) { return true }
            guard parent.canSend else { return true }
            parent.onSend()
            return false
        }
    }
}

final class ComposerUITextView: UITextView {
    var onSend: () -> Void = {}
    var canSend = false
    fileprivate var lastModifierFlags: UIKeyModifierFlags = []

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = presses.first?.key {
            lastModifierFlags = key.modifierFlags
            if key.keyCode == .keyboardReturnOrEnter,
               !key.modifierFlags.contains(.shift),
               !key.modifierFlags.contains(.alternate),
               canSend {
                onSend()
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        lastModifierFlags = []
        super.pressesEnded(presses, with: event)
    }
}
#endif
