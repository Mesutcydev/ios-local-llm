import SwiftUI

enum LensPanelState: Equatable {
    case collapsed
    case composing
    case captured
    case analyzing
    case result
    case error
}

struct LensTaskPanel: View {
    @Binding var state: LensPanelState
    @Binding var mode: LensMode
    @Binding var prompt: String
    @FocusState.Binding var promptFocused: Bool

    let thumbnail: UIImage?
    let resultText: String
    let errorText: String?
    let isBusy: Bool
    let canAnalyze: Bool
    let onModeChange: (LensMode) -> Void
    let onAnalyze: () -> Void
    let onCancel: () -> Void
    let onCopy: () -> Void
    let onShare: () -> Void
    let onSpeak: () -> Void
    let onFollowUp: () -> Void
    let onRetake: () -> Void
    let onExpand: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 14) {
            if state != .analyzing && state != .captured {
                Capsule()
                    .fill(.white.opacity(0.42))
                    .frame(width: 38, height: 5)
                    .accessibilityHidden(true)

                LensModeSelector(selection: $mode, onSelection: onModeChange)
            }

            LensPanelContent(
                state: $state,
                mode: mode,
                prompt: $prompt,
                promptFocused: $promptFocused,
                thumbnail: thumbnail,
                resultText: resultText,
                errorText: errorText,
                canAnalyze: canAnalyze,
                onAnalyze: onAnalyze,
                onCancel: onCancel,
                onCopy: onCopy,
                onShare: onShare,
                onSpeak: onSpeak,
                onFollowUp: onFollowUp,
                onRetake: onRetake,
                onExpand: onExpand
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .foregroundStyle(.white)
        .background {
            let shape = RoundedRectangle(cornerRadius: 36, style: .continuous)
            if reduceTransparency {
                shape.fill(Color.black.opacity(0.92))
            } else {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.38))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .stroke(.white.opacity(contrast == .increased ? 0.48 : 0.20), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.16), radius: 28, y: 12)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.88), value: state)
        .accessibilityElement(children: .contain)
        .environment(\.colorScheme, .dark)
    }
}

private struct LensPanelContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var state: LensPanelState
    let mode: LensMode
    @Binding var prompt: String
    @FocusState.Binding var promptFocused: Bool
    let thumbnail: UIImage?
    let resultText: String
    let errorText: String?
    let canAnalyze: Bool
    let onAnalyze: () -> Void
    let onCancel: () -> Void
    let onCopy: () -> Void
    let onShare: () -> Void
    let onSpeak: () -> Void
    let onFollowUp: () -> Void
    let onRetake: () -> Void
    let onExpand: () -> Void

    var body: some View {
        switch state {
        case .collapsed:
            LensEmptyState(mode: mode, prompt: prompt) {
                state = .composing
                promptFocused = true
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
        case .composing:
            LensPromptEditor(
                mode: mode,
                prompt: $prompt,
                promptFocused: $promptFocused,
                canAnalyze: canAnalyze,
                onCollapse: { state = .collapsed },
                onAnalyze: onAnalyze
            )
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
        case .captured, .analyzing:
            LensProcessingView(thumbnail: thumbnail, captured: state == .captured, onCancel: onCancel)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
        case .result:
            LensResultView(
                mode: mode,
                thumbnail: thumbnail,
                resultText: resultText,
                onCopy: onCopy,
                onShare: onShare,
                onSpeak: onSpeak,
                onFollowUp: onFollowUp,
                onRetake: onRetake,
                onExpand: onExpand
            )
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.97)))
        case .error:
            LensErrorView(errorText: errorText, onRetry: onAnalyze, onRetake: onRetake)
                .transition(.opacity)
        }
    }
}

private struct LensEmptyState: View {
    let mode: LensMode
    let prompt: String
    let onCompose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(mode.accent.opacity(0.14))
                Image(systemName: mode.emptyStateSymbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(mode.accent)
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(mode.instruction)
                    .font(.headline)
                Text("Ask questions about anything you see")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.76))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onCompose) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(LensSpringButtonStyle())
            .accessibilityLabel("Ask Lens")
            .accessibilityHint(prompt.isEmpty ? "Enter a question about the camera view" : "Edit your Lens question")
        }
    }
}

private struct LensPromptEditor: View {
    let mode: LensMode
    @Binding var prompt: String
    @FocusState.Binding var promptFocused: Bool
    let canAnalyze: Bool
    let onCollapse: () -> Void
    let onAnalyze: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(mode.promptTitle).font(.headline)
                Spacer()
                Button(action: onCollapse) {
                    Image(systemName: "chevron.down").frame(width: 44, height: 44)
                }
                .buttonStyle(LensSpringButtonStyle())
                .accessibilityLabel("Collapse prompt")
            }

            TextField(mode.promptPlaceholder, text: $prompt, axis: .vertical)
                .font(.body)
                .lineLimit(2...5)
                .focused($promptFocused)
                .submitLabel(.go)
                .onSubmit { if canAnalyze { onAnalyze() } }
                .padding(14)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(promptFocused ? mode.accent.opacity(0.75) : .primary.opacity(0.09))
                }

            Button(action: onAnalyze) {
                Label("Analyze", systemImage: "viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(.white)
                    .background(mode.accent, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(LensSpringButtonStyle())
            .disabled(!canAnalyze)
            .opacity(canAnalyze ? 1 : 0.45)
        }
    }
}

private struct LensProcessingView: View {
    let thumbnail: UIImage?
    let captured: Bool
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 16) {
            LensFrameThumbnail(image: thumbnail, size: 72)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.blue.opacity(pulsing ? 0.85 : 0.28), lineWidth: 2)
                        .scaleEffect(pulsing ? 1.04 : 1)
                }
                .shimmer(isActive: !reduceMotion, duration: 1.35, intensity: 0.42)

            VStack(alignment: .leading, spacing: 8) {
                Label(captured ? "Frame captured" : "Processing on device", systemImage: "cpu")
                    .font(.headline)
                    .contentTransition(.interpolate)
                ProgressView().tint(.blue)
                Text("Your frame never leaves this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) { pulsing = true }
        }
    }
}

private struct LensResultView: View {
    let mode: LensMode
    let thumbnail: UIImage?
    let resultText: String
    let onCopy: () -> Void
    let onShare: () -> Void
    let onSpeak: () -> Void
    let onFollowUp: () -> Void
    let onRetake: () -> Void
    let onExpand: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                LensFrameThumbnail(image: thumbnail, size: 68)
                    .opacity(reveal ? 1 : 0)
                VStack(alignment: .leading, spacing: 5) {
                    Text(mode.resultTitle)
                        .font(.title3.weight(.semibold))
                    Label("Processed locally", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
                .opacity(reveal ? 1 : 0)
                .offset(y: reveal || reduceMotion ? 0 : 6)
                Spacer()
            }

            ScrollView {
                AssistantMarkdownView(content: resultText, isStreaming: false)
                    .font(.body)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .scrollDismissesKeyboard(.interactively)
            .opacity(reveal ? 1 : 0)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    LensActionButton(title: "Copy", symbol: "doc.on.doc", action: onCopy)
                    LensActionButton(title: "Share", symbol: "square.and.arrow.up", action: onShare)
                    if mode == .translate {
                        LensActionButton(title: "Speak", symbol: "speaker.wave.2", action: onSpeak)
                    }
                    LensActionButton(title: "Ask Again", symbol: "bubble.left", action: onFollowUp)
                    LensActionButton(title: "Retake", symbol: "arrow.clockwise", action: onRetake)
                    LensActionButton(title: "Expand", symbol: "arrow.up.left.and.arrow.down.right", action: onExpand)
                }
                .padding(.vertical, 2)
            }
            .opacity(reveal ? 1 : 0)
            .offset(y: reveal || reduceMotion ? 0 : 8)
        }
        .onAppear {
            if reduceMotion { reveal = true }
            else { withAnimation(.spring(response: 0.48, dampingFraction: 0.9).delay(0.04)) { reveal = true } }
        }
    }
}

private struct LensActionButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(LensSpringButtonStyle())
    }
}

private struct LensErrorView: View {
    let errorText: String?
    let onRetry: () -> Void
    let onRetake: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Lens couldn’t finish", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(errorText ?? "The selected model could not analyze this frame.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                LensActionButton(title: "Retry", symbol: "arrow.clockwise", action: onRetry)
                LensActionButton(title: "Retake", symbol: "camera", action: onRetake)
            }
        }
    }
}

private struct LensFrameThumbnail: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "camera.viewfinder")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityLabel("Captured frame")
    }
}

struct LensModeSelector: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: LensMode
    let onSelection: (LensMode) -> Void
    @Namespace private var selectionAnimation

    var body: some View {
        HStack(spacing: 3) {
            ForEach(LensMode.allCases) { mode in
                Button {
                    selection = mode
                    onSelection(mode)
                } label: {
                    Text(mode.label)
                        .font(.subheadline.weight(selection == mode ? .semibold : .regular))
                        .foregroundStyle(selection == mode ? .primary : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background {
                            if selection == mode {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(mode.accent.opacity(0.16))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(mode.accent.opacity(0.32), lineWidth: 0.75)
                                    }
                                    .matchedGeometryEffect(id: "lens-mode", in: selectionAnimation)
                            }
                        }
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityLabel("\(mode.label) mode")
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
        .padding(3)
        .background(.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88), value: selection)
    }
}

private struct LensSpringButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

extension LensMode {
    var promptTitle: String {
        switch self {
        case .ask: "Ask Lens"
        case .translate: "Translate with Lens"
        case .scan: "Scan with Lens"
        case .solve: "Solve with Lens"
        }
    }

    var promptPlaceholder: String {
        switch self {
        case .ask: "Ask about what the camera sees"
        case .translate: "Choose or enter the target language"
        case .scan: "Capture text or a document"
        case .solve: "Capture a problem to solve"
        }
    }

    var instruction: String {
        switch self {
        case .ask: "Point your camera"
        case .translate: "Frame text to translate"
        case .scan: "Frame text or a document"
        case .solve: "Frame a problem to solve"
        }
    }

    var resultTitle: String {
        switch self {
        case .ask: "Lens Answer"
        case .translate: "Translation"
        case .scan: "Recognized Text"
        case .solve: "Suggested Solution"
        }
    }

    var accent: Color {
        switch self {
        case .ask: .blue
        case .translate: .purple
        case .scan: .green
        case .solve: .orange
        }
    }

    var emptyStateSymbol: String {
        switch self {
        case .ask: "camera.viewfinder"
        case .translate: "character.bubble"
        case .scan: "doc.viewfinder"
        case .solve: "function"
        }
    }
}
