import SwiftUI

// MARK: - HomeView
// Dashboard / on-device status — design screen 01 ("Home") from the Local AI
// Studio handoff, rebuilt in the app's KoduTheme so it honours the selected
// accent palette and light/dark appearance.
//
// This is the landing tab. It is the ONLY place that reaches Settings and the
// Models hub now that neither is a bottom tab:
//   • the avatar / gear button (top-right) opens Settings,
//   • the "Models" quick action and the "Manage" pill open the Models hub.
// Lens / Voice quick actions switch to those bottom tabs.
//
// All callbacks are injected by ContentView so this view stays navigation-free
// and testable.
struct HomeView: View {
    @Environment(\.koduTheme) private var T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var assistant = CodingAssistantService.shared
    @ObservedObject private var center = ModelDownloadCenter.shared
    @ObservedObject private var convos = ConversationStore.shared
    @ObservedObject private var loc = LocalizationService.shared

    /// Start a fresh chat (→ Assistant tab).
    var onNewChat: () -> Void
    /// Switch to the Lens (camera) tab.
    var onOpenLens: () -> Void
    /// Switch to the Voice tab.
    var onOpenVoice: () -> Void
    /// Open the Models tab.
    var onOpenModels: () -> Void
    /// Present the local API server workspace.
    var onOpenLocalAPIServer: () -> Void
    /// Present the on-device image generation studio.
    var onGenerateImage: () -> Void
    /// Present Settings.
    var onOpenSettings: () -> Void
    /// Open the Assistant tab focused on a past conversation (best-effort).
    var onOpenConversation: (StoredConversation) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Space.m) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(
                    minimum: dynamicTypeSize.isAccessibilitySize ? 440 : 300
                ), spacing: Space.cardGap)], alignment: .leading, spacing: Space.cardGap) {
                    heroCard
                    VStack(spacing: Space.cardGap) {
                        quickActions
                        imageGenerationCard
                    }
                    recentSection
                    privacyCard
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.top, Space.m)
            .padding(.bottom, Space.l)
            .frame(maxWidth: AppLayout.dashboardWidth)
            .frame(maxWidth: .infinity)
        }
        .background(LiquidPinkBackdrop())
        .scrollIndicators(.hidden)
    }

    // MARK: Header — greeting + avatar/settings

    private var header: some View {
        KScreenHeader(title: loc.t("Studio"), eyebrow: greeting) {
            Button(action: { HapticManager.impact(.light); onOpenSettings() }) {
                Image(systemName: "gearshape")
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(T.ink2)
                    .frame(width: Size.control, height: Size.control)
                    .kClearGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(KTactileButtonStyle())
            .accessibilityLabel(loc.t("settings"))
            .accessibilityIdentifier("home.settings")
        }
    }

    // MARK: Hero — assistant ready

    private var heroState: (dot: Color, title: String) {
        switch assistant.state {
        case .ready:      return (T.good, loc.t("Assistant is ready"))
        case .generating: return (T.good, loc.t("Assistant is thinking…"))
        case .loading:    return (T.warn, loc.t("Preparing model…"))
        case .failed(let e):
            // A cancelled load (tab switch, memory pressure) isn't a real
            // failure — present it as the calm idle state, not an alarm.
            if e.localizedCaseInsensitiveContains("cancel") {
                return needsModelSetup
                    ? (T.accent, loc.t("Choose a model to get started"))
                    : (T.ink3, loc.t("Tap New chat to start"))
            }
            return (T.bad, loc.t("Model needs setup"))
        case .unloaded:
            return downloadInProgress
                ? (T.warn, loc.t("Downloading model…"))
                : needsModelSetup
                    ? (T.accent, loc.t("Choose a model to get started"))
                    : (T.ink3, loc.t("Tap New chat to start"))
        }
    }

    /// Subtitle under the hero title — shows the live load progress / error
    /// while preparing or failed, otherwise the model name + privacy tagline.
    private var heroSubtitle: String {
        if case .loading(let m) = assistant.state, !m.isEmpty { return m }
        if case .failed(let e) = assistant.state, !e.isEmpty,
           !e.localizedCaseInsensitiveContains("cancel") { return e }
        if needsModelSetup {
            return loc.t("Choose and download a model in Models before starting a local chat.")
        }
        return "\(assistant.activeModel.displayName) — \(loc.t("replies stay on your iPhone"))"
    }

    private var needsModelSetup: Bool {
        guard assistant.activeExecutionLocation == .localDownloaded else { return false }
        switch assistant.state {
        case .unloaded, .failed:
            return !downloadInProgress && !assistant.selectedModelIsInstalled
        case .loading, .ready, .generating:
            return false
        }
    }

    /// True while any model is actively downloading — so the hero reads
    /// "Preparing…" instead of a misleading "ready"/idle state.
    private var downloadInProgress: Bool {
        center.models.contains { m in
            guard m.sourceRepoID == assistant.activeModel.repoID else { return false }
            switch m.state {
            case .downloading, .enumerating: return true
            default: return false
            }
        }
    }

    private var heroCard: some View {
        let state = heroState
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s) {
                Circle().fill(state.dot)
                    .frame(width: 7, height: 7)
                Text(loc.t("Your local AI studio"))
                    .font(T.sans(12, .bold))
                    .foregroundColor(T.ink3)
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(T.ink3)
            }
            Text(state.title)
                .font(T.display(22, .semibold))
                .foregroundColor(T.ink)
                .padding(.top, Space.m)
            Text(heroSubtitle)
                .font(T.sans(14))
                .foregroundColor(T.ink2)
                .padding(.top, Space.xxs)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.s) {
                KPrimaryButton(
                    label: loc.t(needsModelSetup ? "Choose a model" : "New chat"),
                    systemImage: "square.and.pencil"
                ) {
                    HapticManager.impact(.medium)
                    if needsModelSetup { onOpenModels() } else { onNewChat() }
                }
                .accessibilityIdentifier("home.assistant.start")
                Button(action: { HapticManager.impact(.light); onOpenVoice() }) {
                    Image(systemName: "mic.fill")
                        .font(.body.weight(.semibold))
                }
                .glassButton()
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .accessibilityLabel(loc.t("Voice"))
            }
            .padding(.top, Space.m)
            .avoidingDisplayDivision()
        }
        .padding(Space.m)
        .background(card(Radius.card))
    }

    // MARK: Quick actions

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(
            minimum: dynamicTypeSize.isAccessibilitySize ? 150 : 88
        ), spacing: Space.s)], spacing: Space.s) {
            quickAction(icon: "camera.viewfinder", label: loc.t("Lens"), action: onOpenLens)
            quickAction(icon: "waveform", label: loc.t("Voice"), action: onOpenVoice)
            quickAction(icon: "server.rack", label: loc.t("Local API Server"), action: onOpenLocalAPIServer)
                .accessibilityIdentifier("home.api.open")
        }
        .fixedSize(horizontal: false, vertical: true)
        .avoidingDisplayDivision()
    }

    private func quickAction(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: { HapticManager.impact(.light); action() }) {
            VStack(spacing: Space.s) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(.title3, weight: .regular))
                        .foregroundColor(T.ink2)
                }
                .frame(width: Size.control, height: Size.control)
                .kGlass(cornerRadius: Radius.inner, fallbackFill: T.surface2)
                Text(label)
                    .font(T.sans(12.5, .semibold))
                    .foregroundColor(T.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Space.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, Space.m)
            .background(card(Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var imageGenerationCard: some View {
        Button {
            HapticManager.impact(.medium)
            onGenerateImage()
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: "wand.and.stars")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Size.control, height: Size.control)
                    .background(T.accentStrong, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))

                VStack(alignment: .leading, spacing: Space.hair) {
                    Text("Generate an Image")
                        .font(.headline)
                        .foregroundStyle(T.ink)
                    Text("Create images privately with on-device models")
                        .font(.subheadline)
                        .foregroundStyle(T.ink2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(T.ink3)
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(card(Radius.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the on-device image generation studio")
    }

    // MARK: Recent

    private var recentSection: some View {
        let recent = Array(convos.conversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(3))
        return VStack(alignment: .leading, spacing: Space.s) {
                Text(loc.t("Recent").uppercased())
                .font(T.sans(13, .semibold)).tracking(TextScale.capsTracking)
                .foregroundColor(T.ink2)
                .padding(.leading, Space.xxs)
                // Section break: card gap + m = l above the header, s below.
                .padding(.top, Space.m)

            if recent.isEmpty {
                HStack(spacing: Space.s) {
                    iconTile("message", tint: T.accent)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(loc.t("No recent activity yet"))
                            .font(T.sans(15, .medium)).foregroundStyle(T.ink)
                        Text(loc.t("Your conversations will appear here."))
                            .font(T.sans(13)).foregroundStyle(T.ink2)
                    }
                    Spacer()
                }
                .padding(Space.m)
                .background(card(Radius.card))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { idx, convo in
                        Button(action: { HapticManager.impact(.light); onOpenConversation(convo) }) {
                            recentRow(convo, isLast: idx == recent.count - 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(card(Radius.card))
            }
        }
    }

    private func recentRow(_ convo: StoredConversation, isLast: Bool) -> some View {
        HStack(spacing: Space.s) {
            iconTile("message", tint: T.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(convo.title.isEmpty ? loc.t("Untitled chat") : convo.title)
                    .font(T.sans(15, .medium)).foregroundColor(T.ink)
                    .lineLimit(1)
                Text("\(loc.t("assistant")) · \(Self.relative(convo.updatedAt))")
                    .font(T.sans(12.5)).foregroundColor(T.ink3)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.forward")
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(T.ink4)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(T.rule).frame(height: 0.5).padding(.leading, 59) }
        }
        .contentShape(Rectangle())
    }

    // MARK: Privacy / manage

    private var privacyCard: some View {
        let readyCount = center.models.filter { $0.isReady }.count
        return HStack(spacing: Space.s) {
            iconTile("lock.fill", tint: T.accent, filledTile: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(loc.t("Private by design"))
                    .font(T.sans(15, .semibold)).foregroundColor(T.ink)
                Text("\(readyCount) \(loc.t("models")) · \(Self.bytes(center.totalStorageUsed)) \(loc.t("on this iPhone"))")
                    .font(T.sans(12.5)).foregroundColor(T.ink3)
            }
            Spacer(minLength: 6)
            Button(action: { HapticManager.impact(.light); onOpenModels() }) {
                Text(loc.t("Manage"))
                    .font(T.sans(13, .semibold)).foregroundColor(T.ink)
                    .padding(.horizontal, Space.m).padding(.vertical, Space.xs)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Capsule())
                    .kClearGlass(
                        in: Capsule(),
                        interactive: true,
                        fallbackFill: T.surface2,
                        fallbackStroke: T.rule
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(Space.m)
        .background(card(Radius.card))
    }

    // MARK: Reusable bits

    private func iconTile(_ symbol: String, tint: Color, filledTile: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(filledTile ? AnyShapeStyle(T.accentStrong) : AnyShapeStyle(T.surface2))
            Image(systemName: symbol)
                .font(.system(size: filledTile ? 18 : 16, weight: .regular))
                .foregroundColor(filledTile ? .white : T.ink2)
        }
        .frame(width: filledTile ? 38 : 32, height: filledTile ? 38 : 32)
    }

    private func card(_ radius: CGFloat) -> some View {
        Color.clear
            .kGlass(
                cornerRadius: radius,
                fallbackFill: T.surface,
                fallbackStroke: T.rule
            )
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<12:  return loc.t("Good morning")
        case 12..<18: return loc.t("Good afternoon")
        default:      return loc.t("Good evening")
        }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private static func bytes(_ n: Int64) -> String {
        guard n > 0 else { return "0 MB" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = n >= 1_000_000_000 ? [.useGB] : [.useMB]
        return f.string(fromByteCount: n)
    }
}
