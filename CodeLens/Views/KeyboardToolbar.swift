import SwiftUI

// MARK: - KeyboardToolbar
// Studio-themed accessory strip that floats above the system keyboard. Holds
// the composer's quick actions (paste / photo / snippets / mic / send) plus a
// dismiss pill, so the user can do everything without leaving the keyboard.
//
// Mounted as the trailing row of the composer's `safeAreaInset(edge: .bottom)`
// — that way SwiftUI handles keyboard offsets automatically.

struct KeyboardToolbar: View {

    // Bindings / callbacks supplied by the host (CodingAssistantView, etc.)
    @Binding var inputText: String
    @FocusState.Binding var inputFocused: Bool

    var onPaste: () -> Void
    var onPickPhoto: () -> Void
    var onPickSnippet: () -> Void
    /// Optional — when set, a paperclip button opens the file picker.
    var onPickFile: (() -> Void)? = nil
    var onSend: () -> Void
    var canSend: Bool
    var isSending: Bool = false

    @Environment(\.koduTheme) private var T

    // Local recent prompts strip
    @AppStorage("recentPromptsBlob") private var recentPromptsBlob: String = ""

    private var recentPrompts: [String] {
        recentPromptsBlob
            .split(separator: "\u{1F}")        // unit separator
            .map(String.init)
            .filter { !$0.isEmpty }
            .prefix(8)
            .reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Optional "recent prompts" strip — only when focused + has history
            if inputFocused && !recentPrompts.isEmpty {
                recentsStrip
                    .transition(.opacity)
            }

            // Main toolbar row — always visible while keyboard is up
            HStack(spacing: 6) {
                // Left cluster: editing accessories
                actionButton(icon: "doc.on.clipboard",
                             label: "paste",
                             action: onPaste)
                actionButton(icon: "photo",
                             label: "photo",
                             action: onPickPhoto)
                actionButton(icon: "text.badge.plus",
                             label: "snippet",
                             action: onPickSnippet)
                if let onPickFile {
                    actionButton(icon: "paperclip",
                                 label: "file",
                                 action: onPickFile)
                }
                MicDictationButton(text: $inputText, compact: true)
                    .accessibilityLabel("Voice dictation")

                Spacer(minLength: 4)

                // Right cluster: dismiss + send
                Button {
                    inputFocused = false
                    KeyboardDismiss.now()
                    HapticManager.impact(.light)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 11, weight: .medium))
                        Text("done")
                            .font(T.mono(11, .semibold))
                            .tracking(0.3)
                    }
                    .foregroundColor(T.ink2)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .kGlass(cornerRadius: 6, fallbackFill: T.surface2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide keyboard")

                sendButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(
            T.surface
                .overlay(alignment: .top) {
                    Rectangle().fill(T.rule).frame(height: 1)
                }
        )
        .animation(.easeInOut(duration: 0.16), value: inputFocused)
        .animation(.easeInOut(duration: 0.16), value: recentPrompts.count)
    }

    // MARK: - Recents strip

    private var recentsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                KCaption(text: "recent")
                    .padding(.leading, 4)
                ForEach(Array(recentPrompts.enumerated()), id: \.offset) { _, prompt in
                    Button {
                        let glue: String = inputText.isEmpty ? "" : (inputText.hasSuffix(" ") ? "" : " ")
                        inputText += glue + prompt
                        HapticManager.impact(.light)
                    } label: {
                        Text(prompt.prefix(48))
                            .font(T.mono(10))
                            .foregroundColor(T.ink2)
                            .lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5).fill(T.surface2))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(T.rule, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(
            T.bg
                .overlay(alignment: .bottom) {
                    Rectangle().fill(T.rule).frame(height: 1)
                }
        )
    }

    // MARK: - Action button

    @ViewBuilder
    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            HapticManager.impact(.light)
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(T.ink2)
                .frame(width: 34, height: 34)
                .kGlass(cornerRadius: 7, fallbackFill: T.surface2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Send button

    @ViewBuilder
    private var sendButton: some View {
        Button {
            // Save to recents before dispatching
            saveRecent(inputText)
            onSend()
        } label: {
            HStack(spacing: 4) {
                if isSending {
                    ProgressView().tint(T.bg).scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        // Bounce the arrow whenever the button transitions
                        // back to the idle "send" state — gives the eye a
                        // satisfying micro-confirmation that the previous
                        // message was dispatched. Driven off isSending so
                        // the bounce fires exactly when sending → idle.
                        .symbolEffect(.bounce, options: .nonRepeating, value: isSending)
                }
                Text(isSending ? "sending" : "send")
                    .font(T.mono(11, .semibold))
                    .tracking(0.3)
                    // Cross-fade the label text rather than snapping. Pairs
                    // with the symbol bounce above so the entire pill morphs
                    // as one unit on state change.
                    .contentTransition(.identity)
                    .animation(.easeInOut(duration: 0.18), value: isSending)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(minWidth: 78)
            .background(
                RoundedRectangle(cornerRadius: 9999, style: .continuous)
                    .fill(
                        canSend ? AnyShapeStyle(T.accentStrong) : AnyShapeStyle(T.ink3)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSend || isSending)
        .accessibilityLabel("Send")
    }

    // MARK: - Recents persistence

    /// Save the trimmed prompt to recents (max 8). Stored as a single
    /// UNIT-SEPARATOR-joined blob in UserDefaults; tiny payload.
    private func saveRecent(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else { return }
        var items = recentPrompts
        items.removeAll { $0 == trimmed }
        items.append(trimmed)
        if items.count > 8 { items = Array(items.suffix(8)) }
        recentPromptsBlob = items.joined(separator: "\u{1F}")
    }
}
