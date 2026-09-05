import SwiftUI

struct AssistantComposer: View {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool

    let canSend: Bool
    let isGenerating: Bool
    let hasCustomSampling: Bool
    let onAdd: () -> Void
    let onPhoto: () -> Void
    let onFile: () -> Void
    let onSampling: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void

    @Environment(\.koduTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: AssistantSpacing.xxxSmall) {
            TextField("Message your on-device assistant", text: $text, axis: .vertical)
                .font(theme.sans(17))
                .foregroundStyle(.primary)
                .tint(theme.accent)
                .focused($isFocused)
                .lineLimit(1...6)
                .submitLabel(.send)
                .onSubmit {
                    guard canSend, !isGenerating else { return }
                    onSend()
                }
                .padding(.horizontal, AppSpacing.medium)
                .padding(.top, AssistantSpacing.small)
                .padding(.bottom, AssistantSpacing.xxxSmall)
                .accessibilityLabel("Message your on-device assistant")

            Divider()
                .overlay(theme.rule)
                .padding(.horizontal, AssistantSpacing.xSmall)

            HStack(spacing: 2) {
                Menu {
                    Button(action: onAdd) {
                        Label("Prompt or snippet", systemImage: "text.badge.plus")
                    }
                    Button(action: onPhoto) {
                        Label("Photo", systemImage: "photo")
                    }
                    Button(action: onFile) {
                        Label("File", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Add a prompt or attachment")
                composerButton("photo", label: "Attach a photo", action: onPhoto)
                composerButton("doc", label: "Attach a file", action: onFile)

                Button(action: onSampling) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .medium))
                            .frame(width: 44, height: 44)
                        if hasCustomSampling {
                            Circle()
                                .fill(theme.accent)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
                                .offset(x: -5, y: 5)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sampling settings")
                .accessibilityValue(hasCustomSampling ? "Customized" : "Model defaults")

                MicDictationButton(text: $text, compact: true)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Dictate a message")

                if isFocused {
                    Button {
                        isFocused = false
                        KeyboardDismiss.now()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss keyboard")
                }

                Spacer(minLength: AssistantSpacing.xxSmall)

                Button(action: isGenerating ? onStop : onSend) {
                    Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle((canSend || isGenerating) ? Color.white : Color.secondary)
                        .frame(width: 44, height: 44)
                        .background {
                            Circle().fill(
                                (canSend || isGenerating)
                                    ? AnyShapeStyle(theme.accentStrong)
                                    : AnyShapeStyle(Color.secondary.opacity(0.12))
                            )
                        }
                        .contentTransition(.symbolEffect(.replace))
                        .shadow(
                            color: (canSend || isGenerating) ? theme.accent.opacity(0.28) : .clear,
                            radius: 8,
                            y: 2
                        )
                }
                .buttonStyle(AssistantSendButtonStyle(reduceMotion: reduceMotion))
                .disabled(!canSend && !isGenerating)
                .accessibilityLabel(isGenerating ? "Stop generating" : "Send message")
                .accessibilityHint(sendAccessibilityHint)
            }
            .padding(.horizontal, AssistantSpacing.xxSmall)
            .padding(.bottom, AssistantSpacing.xxSmall)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: canSend)
        .animation(reduceMotion ? nil : .snappy(duration: 0.32), value: isGenerating)
    }

    private var sendAccessibilityHint: String {
        if isGenerating { return "Stops the current on-device response" }
        if !canSend { return "Enter a message and wait for the on-device model to be ready" }
        return "Sends this message"
    }

    private func composerButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct AssistantSendButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.24, dampingFraction: 0.82),
                       value: configuration.isPressed)
    }
}

struct AssistantRuntimeDetailsSheet: View {
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
                    LabeledContent("State", value: status)
                }
                Section("Runtime") {
                    LabeledContent("Engine", value: model.runtime.label)
                    LabeledContent("Quantization", value: quantization)
                    LabeledContent("Context window", value: model.contextWindowTokens.formatted() + " tokens")
                    LabeledContent("Thermal", value: thermalStatus)
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
                    Button("Done") { dismiss() }
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

                    VStack(alignment: .leading, spacing: AppSpacing.small) {
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
                    Button("Done") { dismiss() }
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
        VStack(alignment: .leading, spacing: AppSpacing.small) {
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
                    Button("Done") { dismiss() }
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

    private let tokenOptions = [512, 1_024, 2_048, 4_096]

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
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            LabeledContent(title) {
                Text(value, format: .number.precision(.fractionLength(2)))
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}
