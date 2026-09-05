import SwiftUI

// MARK: - KaraokeTranscriptView
// Phrase-level highlighting with a prepared transcript.
// No full AttributedString rebuild on amplitude ticks.
// Auto-scroll only when the active phrase changes.

struct KaraokeTranscriptView: View {
    let text: String
    let activePhraseID: UUID?
    let activeRange: NSRange?
    let spokenUTF16End: Int
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    var onCopy: (() -> Void)? = nil
    var onReplay: (() -> Void)? = nil

    @Environment(\.koduTheme) private var T
    @State private var followSpeech = true
    @State private var showFollowButton = false
    @State private var prepared = KaraokePreparedTranscript.empty
    @State private var displayAttributed = AttributedString()
    @State private var lastScrollPhraseID: UUID?
    @State private var lastScrollAt = Date.distantPast

    private let collapsedMin: CGFloat = 150
    private let collapsedMax: CGFloat = 220

    /// Coalesces phrase + spoken-end publishes into a single highlight invalidation.
    private var highlightToken: String {
        let rangeKey: String = {
            guard let activeRange else { return "-" }
            return "\(activeRange.location):\(activeRange.length)"
        }()
        return "\(activePhraseID?.uuidString ?? "")|\(spokenUTF16End)|\(rangeKey)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    Text(displayAttributed)
                        .font(T.sans(17))
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityLabel(text)
                        .accessibilityHint("Assistant response transcript")
                        .id("karaoke-body")
                    Color.clear
                        .frame(height: 1)
                        .id("karaoke-bottom")
                }
                .frame(minHeight: isExpanded ? 280 : collapsedMin,
                       maxHeight: isExpanded ? .infinity : collapsedMax)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8).onChanged { _ in
                        if followSpeech {
                            followSpeech = false
                            showFollowButton = true
                        }
                    }
                )
                .onChange(of: followSpeech) { _, following in
                    guard following else { return }
                    // Resume immediately, even when speech is paused or finished.
                    proxy.scrollTo("karaoke-bottom", anchor: .bottom)
                }
                .onChange(of: highlightToken) { _, _ in
                    // Phrase + spoken end land together — one highlight pass.
                    refreshHighlight()
                    autoScroll(proxy: proxy, phraseID: activePhraseID)
                }
                .onChange(of: text) { _, newText in
                    rebuildPrepared(text: newText)
                    if followSpeech {
                        autoScroll(proxy: proxy, phraseID: activePhraseID)
                    }
                }
            }

            if isExpanded {
                HStack(spacing: 16) {
                    if let onCopy {
                        Button(action: onCopy) {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(T.mono(10, .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(T.ink2)
                    }
                    if let onReplay {
                        Button(action: onReplay) {
                            Label("Replay", systemImage: "arrow.clockwise")
                                .font(T.mono(10, .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(T.ink2)
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .kGlass(cornerRadius: 16, fallbackFill: T.surface)
        .onAppear {
            rebuildPrepared(text: text)
        }
        .onChange(of: text.isEmpty) { _, empty in
            if empty {
                followSpeech = true
                showFollowButton = false
                lastScrollPhraseID = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Text("ASSISTANT")
                .font(T.mono(9, .semibold))
                .tracking(0.6)
                .foregroundStyle(T.accent)
            Spacer()
            if showFollowButton && !followSpeech {
                Button {
                    followSpeech = true
                    showFollowButton = false
                } label: {
                    Label("Follow speech", systemImage: "text.alignleft")
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(T.accent)
                .accessibilityLabel("Follow speech")
            }
            Button(action: onToggleExpand) {
                Text(isExpanded ? "Collapse" : "Expand")
                    .font(T.mono(9, .semibold))
                    .foregroundStyle(T.ink2)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse transcript" : "Expand transcript")
        }
    }

    private func rebuildPrepared(text: String) {
        prepared = KaraokePreparedTranscript.prepare(
            text: text,
            ink: T.ink,
            inkSecondary: T.ink3
        )
        refreshHighlight()
    }

    private func refreshHighlight() {
        VoicePerformanceMonitor.shared.noteTranscriptRebuild()
        displayAttributed = prepared.highlighted(
            spokenUTF16End: spokenUTF16End,
            activeRange: activeRange,
            accent: T.accent
        )
    }

    private func autoScroll(proxy: ScrollViewProxy, phraseID: UUID?) {
        guard followSpeech else { return }
        guard phraseID != lastScrollPhraseID else { return }
        // Cap scroll rate (~3/s).
        let now = Date()
        guard now.timeIntervalSince(lastScrollAt) >= 0.34 else { return }
        lastScrollPhraseID = phraseID
        lastScrollAt = now
        VoicePerformanceMonitor.shared.noteAutoScroll()
        // Instant scroll — animated scroll transactions contend with the orb TimelineView.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo("karaoke-bottom", anchor: .bottom)
        }
    }
}

// MARK: - Prepared transcript
// Base attributed string built once per text change; highlight mutates
// only spoken + active ranges.

struct KaraokePreparedTranscript {
    let text: String
    let baseAttributedString: AttributedString
    let utf16Length: Int
    let ink: Color

    static let empty = KaraokePreparedTranscript(
        text: "",
        baseAttributedString: AttributedString(""),
        utf16Length: 0,
        ink: .primary
    )

    static func prepare(text: String, ink: Color, inkSecondary: Color) -> KaraokePreparedTranscript {
        guard !text.isEmpty else { return .empty }
        let ns = text as NSString
        var base = AttributedString(text)
        if let full = Range(NSRange(location: 0, length: ns.length), in: base) {
            base[full].foregroundColor = inkSecondary
        }
        return KaraokePreparedTranscript(
            text: text,
            baseAttributedString: base,
            utf16Length: ns.length,
            ink: ink
        )
    }

    func highlighted(
        spokenUTF16End: Int,
        activeRange: NSRange?,
        accent: Color
    ) -> AttributedString {
        guard !text.isEmpty else { return AttributedString("") }
        var result = baseAttributedString
        let spokenLen = min(max(0, spokenUTF16End), utf16Length)
        if spokenLen > 0,
           let spoken = Range(NSRange(location: 0, length: spokenLen), in: result) {
            // Color only — NEVER font. The old code set `.body` (17pt system)
            // on spoken text and semibold on the active phrase while the base
            // renders the shared body style: every phrase boundary re-laid out the whole
            // transcript and the karaoke line visibly jumped.
            result[spoken].foregroundColor = ink
        }
        if let active = activeRange,
           active.location >= 0,
           active.location + active.length <= utf16Length,
           let range = Range(active, in: result) {
            result[range].foregroundColor = accent
            result[range].backgroundColor = accent.opacity(0.14)
        }
        return result
    }
}

// MARK: - User bubble

struct VoiceUserTranscriptBubble: View {
    let text: String
    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("YOU")
                .font(T.mono(9, .semibold))
                .tracking(0.6)
                .foregroundStyle(T.ink2)
            Text(text)
                .font(T.sans(17))
                .foregroundStyle(T.ink)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .kGlass(cornerRadius: 16, fallbackFill: T.surface)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel("You said: \(text)")
    }
}

// Compatibility alias for older call sites / tests.
enum KaraokeTextBuilder {
    static func build(
        text: String,
        spokenUTF16End: Int,
        activeRange: NSRange?,
        ink: Color,
        inkSecondary: Color,
        accent: Color
    ) -> AttributedString {
        KaraokePreparedTranscript.prepare(text: text, ink: ink, inkSecondary: inkSecondary)
            .highlighted(spokenUTF16End: spokenUTF16End, activeRange: activeRange, accent: accent)
    }
}
