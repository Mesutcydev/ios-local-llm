import SwiftUI

// MARK: - CodeModeView
// The redesigned Code Mode surface, presented after a tap-to-capture still.
// Shows the frozen frame, the faithfully-extracted (and editable) code, a task
// chip row (extract · explain · review · debug), and the streamed reasoning
// from the on-device code LLM. Bottom bar: re-capture, save snippet, send to
// chat. No VLM is involved — extraction is Apple Vision OCR, reasoning is the
// chat-tab code model.

struct CodeModeView: View {
    @ObservedObject var controller: CodeModeController
    /// Called when the user wants to shoot again — dismiss + reset upstream.
    var onRecapture: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    @State private var showImage = true
    @State private var didCopy = false
    @State private var didSaveSnippet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.cardGap) {
                    capturedImageSection
                    taskChipRow
                    extractedCodeSection
                    outputSection
                }
                .padding(T.pad)
            }
            .background(LiquidPinkBackdrop())
            .safeAreaInset(edge: .bottom) { actionBar }
            .navigationTitle("Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(T.ink3)
                    }
                }
            }
        }
    }

    // MARK: - Captured still

    @ViewBuilder
    private var capturedImageSection: some View {
        if let image = controller.capturedImage {
            VStack(alignment: .leading, spacing: Space.xs) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { showImage.toggle() }
                } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: showImage ? "chevron.down" : "chevron.forward")
                            .font(.caption2.weight(.bold))
                        Text("capture")
                            .scaledFont(size: 12, weight: .semibold, design: .monospaced)
                        Spacer()
                        if controller.phase == .extracting {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .foregroundStyle(T.ink3)
                }
                .buttonStyle(.plain)

                if showImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .strokeBorder(T.rule2, lineWidth: 1)
                        )
                }
            }
        }
    }

    // MARK: - Task chips

    private var taskChipRow: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(CodeTask.allCases) { task in
                        chip(task)
                    }
                }
            }
            HStack(spacing: Space.xs) {
                Text(controller.selectedTask.hint)
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundStyle(T.ink3)
                if controller.autoPickedDebug, controller.selectedTask == .debug {
                    Text("· auto-picked")
                        .scaledFont(size: 11, design: .monospaced)
                        .foregroundStyle(T.warn)
                }
            }
        }
    }

    private func chip(_ task: CodeTask) -> some View {
        let selected = controller.selectedTask == task
        return Button {
            HapticManager.impact(.light)
            controller.runTask(task)
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: task.systemImage).font(.system(.caption2, weight: .semibold))
                Text(task.label).scaledFont(size: 12, weight: .semibold, design: .monospaced)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .background(
                Capsule().fill(selected ? T.accent : T.surface2)
            )
            .overlay(
                Capsule().strokeBorder(selected ? Color.clear : T.rule2, lineWidth: 1)
            )
            .foregroundStyle(selected ? Color.white : T.ink2)
        }
        .buttonStyle(.plain)
        .disabled(controller.phase != .ready)
    }

    // MARK: - Extracted code (editable)

    private var extractedCodeSection: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text("extracted")
                    .scaledFont(size: 12, weight: .semibold, design: .monospaced)
                    .foregroundStyle(T.ink3)
                if let lang = controller.detectedLanguage {
                    Text(lang.lowercased())
                        .scaledFont(size: 11, weight: .medium, design: .monospaced)
                        .padding(.horizontal, Space.xs).padding(.vertical, Space.hair)
                        .background(Capsule().fill(T.accentSoft))
                        .foregroundStyle(T.accent)
                }
                Text("\(controller.lineCount) ln")
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundStyle(T.ink4)
                Spacer()
                Button {
                    UIPasteboard.general.string = controller.extractedCode
                    didCopy = true
                    HapticManager.impact(.light)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { didCopy = false }
                } label: {
                    Label(didCopy ? "copied" : "copy",
                          systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(didCopy ? T.good : T.ink2)
                }
                .buttonStyle(.plain)
            }

            // Editable so the user can fix the odd OCR slip before reasoning.
            TextEditor(text: $controller.extractedCode)
                .scaledFont(size: 13, design: .monospaced)
                .foregroundStyle(T.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120, maxHeight: 280)
                .padding(Space.s)
                .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(T.surface2))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(T.rule2, lineWidth: 1))

            if controller.selectedTask.usesLLM {
                Button {
                    HapticManager.impact(.light)
                    controller.runTask(controller.selectedTask)
                } label: {
                    Label("re-run on edited code", systemImage: "arrow.clockwise")
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(T.accent)
                }
                .buttonStyle(.plain)
                .disabled(controller.isReasoning)
            }
        }
    }

    // MARK: - Task output

    @ViewBuilder
    private var outputSection: some View {
        switch controller.phase {
        case .failed(let msg):
            calloutCard(icon: "exclamationmark.triangle.fill", tint: T.bad,
                        text: "Extraction failed: \(msg)")
        case .extracting:
            calloutCard(icon: "text.viewfinder", tint: T.ink3, text: "Reading the frame…")
        case .idle, .ready:
            if controller.selectedTask != .extract {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.s) {
                        Image(systemName: controller.selectedTask.systemImage)
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(T.accent)
                        Text(controller.selectedTask.label)
                            .scaledFont(size: 12, weight: .semibold, design: .monospaced)
                            .foregroundStyle(T.ink3)
                        if controller.isReasoning {
                            ProgressView().controlSize(.mini)
                        }
                        Spacer()
                    }
                    if controller.taskOutput.isEmpty && controller.isReasoning {
                        Text("Thinking…")
                            .scaledFont(size: 13, design: .monospaced)
                            .foregroundStyle(T.ink3)
                    } else {
                        MarkdownTextView(markdown: controller.taskOutput)
                    }
                }
                .padding(Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .kGlass(cornerRadius: Radius.control, fallbackFill: T.surface)
            }
        }
    }

    private func calloutCard(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).scaledFont(size: 13).foregroundStyle(T.ink2)
            Spacer()
        }
        .padding(Space.s)
        .kGlass(cornerRadius: Radius.control, fallbackFill: T.surface2)
    }

    // MARK: - Bottom action bar

    private var actionBar: some View {
        HStack(spacing: Space.s) {
            actionButton("Re-capture", systemImage: "camera.viewfinder") {
                onRecapture()
                dismiss()
            }
            actionButton(didSaveSnippet ? "Saved" : "Snippet",
                         systemImage: didSaveSnippet ? "checkmark" : "bookmark") {
                let title = "Code Mode · \(controller.detectedLanguage ?? "capture")"
                SnippetStore.shared.add(title: title, body: controller.extractedCode)
                ToastCenter.shared.success("Saved to Snippets")
                didSaveSnippet = true
                HapticManager.impact(.light)
            }
            .disabled(controller.extractedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            actionButton("Send to Chat", systemImage: "bubble.left.and.bubble.right",
                         prominent: true) {
                AppBridge.shared.sendToAssistant(code: controller.extractedCode, source: "Code Mode")
                dismiss()
            }
            .disabled(controller.extractedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, T.pad)
        .padding(.vertical, Space.s)
        .kClearGlass(in: Rectangle())
    }

    private func actionButton(_ title: String, systemImage: String,
                              prominent: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Space.xxs) {
                Image(systemName: systemImage).font(.system(.subheadline, weight: .semibold))
                Text(title).scaledFont(size: 10, weight: .semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.s)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(prominent ? T.accent : T.surface2)
            )
            .foregroundStyle(prominent ? Color.white : T.ink2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - CodeFramingGuide
// Lightweight viewfinder overlay for Code Mode: a centred capture rectangle
// with corner ticks and a "tap to capture" hint. Purely decorative framing —
// the shutter does the work. Shown over the live preview while the user lines
// up the code on screen.

struct CodeFramingGuide: View {
    var busy: Bool
    @Environment(\.koduTheme) private var T

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * 0.82
            let h = geo.size.height * 0.42
            ZStack {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(
                        Color.white.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])
                    )
                    .frame(width: w, height: h)

                VStack(spacing: Space.xs) {
                    Image(systemName: busy ? "hourglass" : "chevron.left.forwardslash.chevron.right")
                        .font(.system(.body, weight: .semibold))
                        .symbolEffect(.pulse, isActive: busy)
                    Text(busy ? "capturing…" : "frame code · tap to capture")
                        .scaledFont(size: 12, weight: .semibold, design: .monospaced)
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                .background(Capsule().fill(.black.opacity(0.35)))
                .offset(y: h / 2 + 26)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
