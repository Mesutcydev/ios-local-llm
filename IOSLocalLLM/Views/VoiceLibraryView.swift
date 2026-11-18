import SwiftUI

// MARK: - VoiceLibraryView
// The Voice tab — design screen 04 ("Voice · Browse & pick speech models")
// from the local LLM foundation handoff, rebuilt in KoduTheme.
//
// This replaces the bare conversation orb as the Voice tab's landing surface:
// it's a browsable library of the on-device speech voices for the active
// engine, with an "active voice" hero, locale filters and per-voice preview.
// The live voice conversation is NOT removed — it's one tap away via the
// "Start a conversation" button.
struct VoiceLibraryView: View {
    /// True only while the Voice tab is the selected tab. Threaded in from
    /// ContentView (`selectedTab == .voice`) because iOS 18 `TabView` does NOT
    /// reliably fire `.onDisappear` on a tab swap — so the hero equalizer's
    /// display-link timeline must freeze off this reliable signal, not just
    /// `.onDisappear`, or it keeps ticking at ~24fps behind the active tab.
    var isActive: Bool = true

    @Environment(\.koduTheme) private var T
    @ObservedObject private var voice = VoiceService.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var loc = LocalizationService.shared

    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var showConversation = false
    @State private var showEnginePicker = false
    // Drives the hero equalizer animation — frozen while the tab is offscreen.
    @State private var tabVisible = true
    // Cached so we don't re-enumerate AVSpeechSynthesisVoice.speechVoices()
    // (100+ system voices) on every body evaluation.
    @State private var allVoices: [VoiceOption] = []
    /// False until the first voice list arrives, so an empty list while
    /// loading is not reported as "no voices match".
    @State private var voicesLoaded = false

    enum Filter: String, CaseIterable, Identifiable {
        case all, english, multilingual
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return LocalizationService.shared.t("All")
            case .english: return LocalizationService.shared.t("English")
            case .multilingual: return LocalizationService.shared.t("Multilingual")
            }
        }
    }

    private var voices: [VoiceOption] { allVoices }

    private func reloadVoices() {
        allVoices = voice.availableVoicesForCurrentEngine
        voicesLoaded = true
    }

    private var current: VoiceOption? {
        voices.first { $0.id == settings.voiceID } ?? voices.first
    }

    private func matches(_ v: VoiceOption) -> Bool {
        switch filter {
        case .all:          return true
        case .english:      return v.locale.lowercased().hasPrefix("en")
        case .multilingual: return !v.locale.lowercased().hasPrefix("en")
        }
    }

    private var filtered: [VoiceOption] {
        voices.filter { v in
            (query.isEmpty || v.name.localizedCaseInsensitiveContains(query)
                || (v.description ?? "").localizedCaseInsensitiveContains(query))
            && matches(v)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Space.cardGap) {
                header
                if let c = current { activeHero(c) }
                enginePicker
                conversationCTA
                chips
                library
            }
            .padding(.horizontal, Space.m)
            .padding(.top, Space.m)
            .padding(.bottom, Space.l)
            .frame(maxWidth: AppLayout.readingWidth)
            .frame(maxWidth: .infinity)
        }
        .background(LiquidPinkBackdrop())
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { tabVisible = true }
        .onDisappear { tabVisible = false }
        .task {
            await voice.load()
            await voice.systemEngine.refreshVoices()
            reloadVoices()
        }
        .onChange(of: settings.voiceEngine) { _, _ in reloadVoices() }
        .sheet(isPresented: $showConversation,
               onDismiss: { VoiceConversationService.shared.stop() }) {
            VoiceConversationView()
        }
        .sheet(isPresented: $showEnginePicker, onDismiss: { reloadVoices() }) {
            VoiceModelPickerView()
        }
    }

    // MARK: Header

    private var header: some View {
        KScreenHeader(title: loc.t("Voice"), eyebrow: loc.t("On-device speech")) {
            EmptyView()
        }
    }

    // MARK: Active-voice hero

    private func activeHero(_ v: VoiceOption) -> some View {
        VStack(spacing: Space.m) {
            // Tile and its label are one group: s, not m.
            HStack(spacing: Space.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(LinearGradient(colors: [T.roseHi, T.accentStrong],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "waveform")
                        .font(.system(.title2, weight: .semibold)).foregroundColor(.white)
                }
                .frame(width: Size.feature, height: Size.feature)

                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(loc.t("NOW USING"))
                        .font(T.sans(11.5, .semibold)).foregroundColor(T.ink2)
                    Text(v.name).font(T.display(20, .semibold)).foregroundColor(T.ink).fixedSize(horizontal: false, vertical: true)
                    Text(voiceSubtitle(v)).font(T.sans(13)).foregroundColor(T.ink2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.xs)

                Button(action: { preview(v) }) {
                    ZStack {
                        Circle().fill(LinearGradient(colors: [T.roseHi, T.accentStrong],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: voice.isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(.callout, weight: .bold)).foregroundColor(.white)
                            .offset(x: voice.isPlaying ? 0 : 1)
                    }
                    .frame(width: Size.control, height: Size.control)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voice.isPlaying ? loc.t("Stop preview") : loc.t("Preview voice"))
            }

            // Motion communicates playback; idle and reduced-motion states rest.
            EqualizerBars(playing: voice.isPlaying, active: isActive && tabVisible)
                .frame(height: 30)
        }
        .padding(Space.m)
        .kClearGlass(
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous),
            tint: T.accent.opacity(0.08),
            fallbackFill: T.surface,
            fallbackStroke: T.rule
        )
    }

    // MARK: Conversation entry (keeps the live orb reachable)

    private var conversationCTA: some View {
        KPrimaryButton(label: loc.t("Start a voice conversation"), systemImage: "waveform") {
            HapticManager.impact(.medium)
            showConversation = true
        }
    }

    // MARK: Voice engine selector

    // Lets the user switch the speech engine (Apple System / KittenTTS /
    // Kokoro) — the library below shows that engine's voices. Opens the
    // existing one-tap engine picker.
    private var enginePicker: some View {
        Button(action: { HapticManager.impact(.light); showEnginePicker = true }) {
            HStack(spacing: Space.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(T.accentSoft)
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(.callout, weight: .semibold)).foregroundColor(T.accent)
                }
                .frame(width: Size.control, height: Size.control)
                VStack(alignment: .leading, spacing: 1) {
                    Text(loc.t("Voice engine").uppercased())
                        .font(T.sans(11, .bold)).tracking(TextScale.capsTracking).foregroundColor(T.ink3)
                    Text(voice.currentEngineKind.displayName)
                        .font(T.sans(15.5, .semibold)).foregroundColor(T.ink)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.forward")
                    .font(.system(.caption, weight: .semibold)).foregroundColor(T.ink4)
            }
            .padding(Space.m)
            .kClearGlass(
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous),
                interactive: true,
                fallbackFill: T.surface,
                fallbackStroke: T.rule
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Filter chips + search

    private var chips: some View {
        VStack(spacing: Space.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(Filter.allCases) { f in
                        KFilterChip(title: loc.t(f.label), isSelected: filter == f) {
                            HapticManager.selection()
                            filter = f
                        }
                    }
                }
                .padding(.horizontal, Space.hair)
            }
            KSearchField(placeholder: loc.t("Search voices"), text: $query)
        }
    }

    // MARK: Library list

    private var library: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(loc.t("Library").uppercased())
                .font(T.sans(13, .semibold)).tracking(TextScale.capsTracking).foregroundColor(T.ink2)
                // Section break: card gap + m = l above, s below.
                .padding(.leading, Space.xxs).padding(.top, Space.m)

            LazyVStack(spacing: 0) {
                if !voicesLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.l)
                } else if filtered.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Label(loc.t("No voices match."), systemImage: "magnifyingglass")
                            .font(T.sans(15, .semibold)).foregroundStyle(T.ink)
                        Text(loc.t("Try another name or language filter."))
                            .font(T.sans(13)).foregroundStyle(T.ink2)
                        Button {
                            query = ""
                            filter = .all
                        } label: {
                            Text(loc.t("Clear filters"))
                                .font(T.sans(13, .semibold))
                                .foregroundStyle(T.accent)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.m)
                } else {
                    ForEach(filtered, id: \.id) { v in
                        voiceRow(v)
                    }
                }
            }
            .kClearGlass(
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous),
                fallbackFill: T.surface,
                fallbackStroke: T.rule
            )
        }
    }

    private func voiceRow(_ v: VoiceOption) -> some View {
        let isCurrent = v.id == current?.id
        return Button(action: { preview(v) }) {
            HStack(spacing: Space.s) {
                Circle()
                    .fill(LinearGradient(colors: avatarColors(for: v),
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: Size.control, height: Size.control)
                    .overlay {
                        if isCurrent {
                            Circle().strokeBorder(T.accent, lineWidth: 2)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(v.name).font(T.sans(15.5, .semibold)).foregroundColor(T.ink).lineLimit(2)
                    Text(voiceSubtitle(v)).font(T.sans(13)).foregroundColor(T.ink2).lineLimit(2)
                }
                Spacer(minLength: 6)
                ZStack {
                    Circle().fill(isCurrent ? T.ink : T.accentSoft).frame(width: Size.control, height: Size.control)
                    Image(systemName: isCurrent ? "checkmark" : "play.fill")
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundColor(isCurrent ? T.bg : T.accent)
                        .offset(x: isCurrent ? 0 : 1)
                }
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.s)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(T.rule).frame(height: 0.5).padding(.leading, 59)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityHint(loc.t("Selects this voice and plays a preview"))
    }

    // MARK: Helpers

    private func preview(_ v: VoiceOption) {
        HapticManager.impact(.light)
        // Tapping the voice that's CURRENTLY playing = stop. Tapping a
        // DIFFERENT voice switches to it (speak() stops any current playback
        // internally) — previously a tap while playing only stopped and never
        // selected the new voice, so selection silently failed mid-preview.
        if voice.isPlaying && v.id == settings.voiceID {
            voice.stop()
            return
        }
        settings.voiceID = v.id
        // Localize the TEMPLATE then interpolate — interpolating first made the
        // lookup key include the voice name, so it never matched a translation
        // and the phrase was always English.
        voice.speak(String(format: loc.t("Hi, I'm %@. This is how I sound."), v.name))
    }

    private func voiceSubtitle(_ v: VoiceOption) -> String {
        let desc = v.description?.isEmpty == false ? v.description! : ""
        let locale = localeLabel(v.locale)
        return [desc, locale].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func localeLabel(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code)
            ?? Locale.current.localizedString(forLanguageCode: String(code.prefix(2)))
            ?? code
    }

    // Stable per-voice avatar gradient (hash the id so colours are consistent).
    private func avatarColors(for v: VoiceOption) -> [Color] {
        let palettes: [[Color]] = [
            [Color(red: 1, green: 0.70, blue: 0.42), Color(red: 1, green: 0.42, blue: 0.21)],
            [Color(red: 0.42, green: 0.66, blue: 1), Color(red: 0.24, green: 0.36, blue: 1)],
            [Color(red: 0.36, green: 0.88, blue: 0.75), Color(red: 0.06, green: 0.64, blue: 0.50)],
            [Color(red: 0.72, green: 0.61, blue: 1), Color(red: 0.43, green: 0.29, blue: 0.84)],
            [T.roseHi, T.accentStrong]
        ]
        // Stable, crash-safe index (abs(Int.min) would trap).
        let idx = ((v.id.hashValue % palettes.count) + palettes.count) % palettes.count
        return palettes[idx]
    }
}

// MARK: - EqualizerBars
// The hero animates only during visible playback, and respects Reduce Motion.
// Pausing the timeline also avoids waking it behind another tab.
private struct EqualizerBars: View {
    var playing: Bool = false
    /// False when the Voice tab is offscreen — freezes the animation. iOS 18
    /// TabView keeps hidden tabs alive, so an always-on TimelineView(.animation)
    /// burned CPU/GPU/battery behind whatever tab the user was actually on.
    var active: Bool = true
    @Environment(\.koduTheme) private var T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animates = active && playing && !reduceMotion
        return TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !animates)) { ctx in
            GeometryReader { proxy in
                let count = max(1, min(44, Int(proxy.size.width / 7)))
                let time = animates ? ctx.date.timeIntervalSinceReferenceDate : 0
                HStack(alignment: .center, spacing: Space.xxs) {
                    ForEach(0..<count, id: \.self) { index in
                        let position = Double(index) / Double(max(count - 1, 1))
                        let envelope = sin(position * .pi)
                        let wave = 0.5 + 0.5 * sin(time * 5 + Double(index) * 0.65)
                        let height = 4 + envelope * (animates ? 8 + 18 * wave : 7 + 10 * wave)
                        Capsule()
                            .fill(T.ink.opacity(animates ? 0.65 : 0.28))
                            .frame(width: 3, height: height)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 30)
        }
        .accessibilityHidden(true)
    }
}
