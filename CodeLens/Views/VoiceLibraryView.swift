import SwiftUI

// MARK: - VoiceLibraryView
// The Voice tab — design screen 04 ("Voice · Browse & pick speech models")
// from the Local AI Studio handoff, rebuilt in KoduTheme.
//
// This replaces the bare conversation orb as the Voice tab's landing surface:
// it's a browsable library of the on-device speech voices for the active
// engine, with an "active voice" hero, locale filters, per-voice preview, and
// a "Clone your voice" row that surfaces the feature as Coming soon (it has no
// on-device backend yet). The live voice conversation is NOT removed — it's one
// tap away via the "Start a conversation" button.
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
    @State private var showCloneSoon = false
    @State private var showEnginePicker = false
    // Drives the hero equalizer animation — frozen while the tab is offscreen.
    @State private var tabVisible = true
    // Cached so we don't re-enumerate AVSpeechSynthesisVoice.speechVoices()
    // (100+ system voices) on every body evaluation.
    @State private var allVoices: [VoiceOption] = []

    enum Filter: String, CaseIterable, Identifiable {
        case all, english, multilingual, cloned
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .english: return "English"
            case .multilingual: return "Multilingual"
            case .cloned: return "Cloned"
            }
        }
    }

    private var voices: [VoiceOption] { allVoices }

    private func reloadVoices() {
        allVoices = voice.availableVoicesForCurrentEngine
    }

    private var current: VoiceOption? {
        voices.first { $0.id == settings.voiceID } ?? voices.first
    }

    private func matches(_ v: VoiceOption) -> Bool {
        switch filter {
        case .all:          return true
        case .english:      return v.locale.lowercased().hasPrefix("en")
        case .multilingual: return !v.locale.lowercased().hasPrefix("en")
        case .cloned:       return false   // no cloned voices yet — see Coming soon
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
            VStack(spacing: 16) {
                header
                if let c = current { activeHero(c) }
                enginePicker
                conversationCTA
                chips
                library
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(LiquidPinkBackdrop())
        .scrollIndicators(.hidden)
        .onAppear { tabVisible = true }
        .onDisappear { tabVisible = false }
        .task {
            await voice.load()
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
        .alert(loc.t("Coming soon"), isPresented: $showCloneSoon) {
            Button(loc.t("Done"), role: .cancel) {}
        } message: {
            Text(loc.t("Voice cloning — record 30 seconds and train a voice that runs entirely on-device — is coming in a future update."))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(loc.t("On-device speech").uppercased())
                    .font(T.sans(13, .semibold)).tracking(0.7)
                    .foregroundColor(T.accent)
                Text(loc.t("Voices"))
                    .font(T.display(32, .bold)).foregroundColor(T.ink)
            }
            Spacer()
        }
        .padding(.top, 6)

        // (Search is provided inline below via the field in `chips`.)
    }

    // MARK: Active-voice hero

    private func activeHero(_ v: VoiceOption) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [T.roseHi, T.accentStrong],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "waveform")
                        .font(.system(size: 24, weight: .semibold)).foregroundColor(.white)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.t("NOW USING"))
                        .font(T.sans(11.5, .bold)).tracking(0.6).foregroundColor(T.accentStrong)
                    Text(v.name).font(T.display(20, .bold)).foregroundColor(T.ink).lineLimit(1)
                    Text(voiceSubtitle(v)).font(T.sans(13)).foregroundColor(T.ink2).lineLimit(1)
                }
                Spacer(minLength: 6)

                Button(action: { preview(v) }) {
                    ZStack {
                        Circle().fill(LinearGradient(colors: [T.roseHi, T.accentStrong],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: voice.isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                            .offset(x: voice.isPlaying ? 0 : 1)
                    }
                    .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc.t("Preview voice"))
            }

            // Always-on animated equalizer (design 04 hero) — calmer when idle,
            // more energetic while a preview is playing.
            EqualizerBars(playing: voice.isPlaying, active: isActive && tabVisible)
                .frame(height: 30)
        }
        .padding(16)
        .kClearGlass(
            in: RoundedRectangle(cornerRadius: 22, style: .continuous),
            tint: T.accent.opacity(0.08),
            fallbackFill: T.surface,
            fallbackStroke: T.rule
        )
    }

    // MARK: Conversation entry (keeps the live orb reachable)

    private var conversationCTA: some View {
        Button(action: { HapticManager.impact(.medium); showConversation = true }) {
            HStack(spacing: 11) {
                Image(systemName: "mic.fill").font(.system(size: 16, weight: .semibold))
                Text(loc.t("Start a voice conversation")).font(T.sans(15, .semibold))
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(T.accentStrong)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .kClearGlass(
                in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                tint: T.accentStrong.opacity(0.72),
                interactive: true,
                fallbackFill: T.accentStrong,
                fallbackStroke: T.accent.opacity(0.35)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Voice engine selector

    // Lets the user switch the speech engine (Apple System / KittenTTS /
    // Kokoro) — the library below shows that engine's voices. Opens the
    // existing one-tap engine picker.
    private var enginePicker: some View {
        Button(action: { HapticManager.impact(.light); showEnginePicker = true }) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(T.accentSoft)
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold)).foregroundColor(T.accent)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(loc.t("Voice engine").uppercased())
                        .font(T.sans(11, .bold)).tracking(0.4).foregroundColor(T.ink3)
                    Text(voice.currentEngineKind.displayName)
                        .font(T.sans(15.5, .semibold)).foregroundColor(T.ink)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(T.ink4)
            }
            .padding(14)
            .kClearGlass(
                in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                interactive: true,
                fallbackFill: T.surface,
                fallbackStroke: T.rule
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Filter chips + search

    private var chips: some View {
        VStack(spacing: 11) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Filter.allCases) { f in
                        let on = filter == f
                        Button(action: { HapticManager.impact(.light); filter = f }) {
                            Text(loc.t(f.label))
                                .font(T.sans(13.5, on ? .semibold : .medium))
                                .foregroundColor(on ? .white : T.ink2)
                                .padding(.horizontal, 15).padding(.vertical, 7)
                                .kClearGlass(
                                    in: Capsule(),
                                    tint: on ? T.accent.opacity(0.72) : nil,
                                    interactive: true,
                                    fallbackFill: on ? T.accent : T.surface,
                                    fallbackStroke: T.rule
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .regular)).foregroundColor(T.ink3)
                TextField(loc.t("Search voices"), text: $query)
                    .font(T.sans(15)).foregroundColor(T.ink).tint(T.accent)
                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(T.ink4)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .kClearGlass(
                in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                fallbackFill: T.surface,
                fallbackStroke: T.rule
            )
        }
    }

    // MARK: Library list

    private var library: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(loc.t("Library").uppercased())
                .font(T.sans(13, .semibold)).tracking(0.3).foregroundColor(T.ink2)
                .padding(.leading, 4).padding(.top, 4)

            LazyVStack(spacing: 0) {
                if filter == .cloned {
                    clonedEmptyRow
                } else if filtered.isEmpty {
                    Text(loc.t("No voices match."))
                        .font(T.sans(14)).foregroundColor(T.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(15)
                } else {
                    ForEach(filtered, id: \.id) { v in
                        voiceRow(v, isLast: false)
                    }
                }
                cloneRow   // always the last row
            }
            .kClearGlass(
                in: RoundedRectangle(cornerRadius: 20, style: .continuous),
                fallbackFill: T.surface,
                fallbackStroke: T.rule
            )
        }
    }

    private func voiceRow(_ v: VoiceOption, isLast: Bool) -> some View {
        let isCurrent = v.id == current?.id
        return Button(action: { preview(v) }) {
            HStack(spacing: 12) {
                Circle()
                    .fill(LinearGradient(colors: avatarColors(for: v),
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                    .overlay {
                        if isCurrent {
                            Circle().strokeBorder(T.accent, lineWidth: 2)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(v.name).font(T.sans(15.5, .semibold)).foregroundColor(T.ink).lineLimit(1)
                    Text(voiceSubtitle(v)).font(T.sans(12.5)).foregroundColor(T.ink3).lineLimit(1)
                }
                Spacer(minLength: 6)
                ZStack {
                    Circle().fill(isCurrent ? T.accent : T.accentSoft).frame(width: 36, height: 36)
                    Image(systemName: isCurrent ? "checkmark" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isCurrent ? .white : T.accent)
                        .offset(x: isCurrent ? 0 : 1)
                }
            }
            .padding(.horizontal, 15).padding(.vertical, 11)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(T.rule).frame(height: 0.5).padding(.leading, 59)
            }
        }
        .buttonStyle(.plain)
    }

    // "Clone your voice" — Coming soon (big feature, no on-device backend yet)
    private var cloneRow: some View {
        Button(action: { HapticManager.impact(.light); showCloneSoon = true }) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundColor(T.accent)
                    Image(systemName: "mic.fill").font(.system(size: 15, weight: .semibold))
                        .foregroundColor(T.accent)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(loc.t("Clone your voice"))
                        .font(T.sans(15.5, .semibold)).foregroundColor(T.accent)
                    Text(loc.t("Record 30s · trained on-device"))
                        .font(T.sans(12.5)).foregroundColor(T.ink3)
                }
                Spacer(minLength: 6)
                Text(loc.t("Coming soon"))
                    .font(T.sans(11, .bold)).foregroundColor(T.ink3)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(T.surface3))
            }
            .padding(.horizontal, 15).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var clonedEmptyRow: some View {
        VStack(spacing: 6) {
            Text(loc.t("No cloned voices yet"))
                .font(T.sans(15, .semibold)).foregroundColor(T.ink)
            Text(loc.t("Clone your voice to add one — coming soon."))
                .font(T.sans(13)).foregroundColor(T.ink3).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18).padding(.horizontal, 15)
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
// Always-on animated equalizer for the "now using" hero (design 04). Uses
// TimelineView so it animates continuously while the Voice tab is on screen
// (SwiftUI pauses the timeline when the tab is hidden, so there's no
// background cost). Bars cycle through pink shades like the handoff and run
// calmer when idle, more energetic while a preview is playing.
private struct EqualizerBars: View {
    var playing: Bool = false
    /// False when the Voice tab is offscreen — freezes the animation. iOS 18
    /// TabView keeps hidden tabs alive, so an always-on TimelineView(.animation)
    /// burned CPU/GPU/battery behind whatever tab the user was actually on.
    var active: Bool = true
    @Environment(\.koduTheme) private var T
    var body: some View {
        let shades = [T.accent, T.roseHi, T.accent.opacity(0.6)]
        let speed = playing ? 6.0 : 3.2
        let floor = playing ? 0.22 : 0.30
        let amp   = playing ? 0.78 : 0.55
        // ~24 fps when visible (vs .animation's 60–120 fps display link), and a
        // 1-hour schedule (effectively frozen) + static bars when offscreen.
        let schedule: PeriodicTimelineSchedule = active
            ? .periodic(from: Date(), by: 1.0 / 24.0)
            : .periodic(from: Date(), by: 3600)
        return TimelineView(schedule) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<13, id: \.self) { i in
                    let phase = Double(i) * 0.55
                    let h = active ? floor + amp * (0.5 + 0.5 * sin(t * speed + phase)) : 0.5
                    Capsule()
                        .fill(shades[i % shades.count])
                        .frame(height: CGFloat(30 * h))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30, alignment: .center)
        }
    }
}
