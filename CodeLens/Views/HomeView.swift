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
    /// Present the Mac / Bridge screen.
    var onOpenMac: () -> Void
    /// Present the on-device image generation studio.
    var onGenerateImage: () -> Void
    /// Present Settings.
    var onOpenSettings: () -> Void
    /// Open the Assistant tab focused on a past conversation (best-effort).
    var onOpenConversation: (StoredConversation) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                heroCard
                quickActions
                imageGenerationCard
                recentSection
                privacyCard
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(LiquidPinkBackdrop())
        .scrollIndicators(.hidden)
    }

    // MARK: Header — greeting + avatar/settings

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(greeting.uppercased())
                    .font(T.sans(13, .semibold))
                    .tracking(0)
                    .foregroundColor(T.ink3)
                Text("Studio")
                    .font(T.display(30, .semibold))
                    .foregroundColor(T.ink)
            }
            Spacer()
            Button(action: { HapticManager.impact(.light); onOpenSettings() }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(T.ink2)
                    .frame(width: 40, height: 40)
                    .kClearGlass(
                        in: Circle(),
                        interactive: true,
                        fallbackFill: T.surface,
                        fallbackStroke: T.rule
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc.t("settings"))
        }
        .padding(.top, 6)
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
                return (T.ink3, loc.t("Tap New chat to start"))
            }
            return (T.bad, loc.t("Model needs setup"))
        case .unloaded:
            return downloadInProgress
                ? (T.warn, loc.t("Preparing model…"))
                : (T.ink3, loc.t("Tap New chat to start"))
        }
    }

    /// Subtitle under the hero title — shows the live load progress / error
    /// while preparing or failed, otherwise the model name + privacy tagline.
    private var heroSubtitle: String {
        if case .loading(let m) = assistant.state, !m.isEmpty { return m }
        if case .failed(let e) = assistant.state, !e.isEmpty,
           !e.localizedCaseInsensitiveContains("cancel") { return e }
        return "\(assistant.activeModel.displayName) — \(loc.t("replies stay on your iPhone"))"
    }

    /// True while any model is actively downloading — so the hero reads
    /// "Preparing…" instead of a misleading "ready"/idle state.
    private var downloadInProgress: Bool {
        center.models.contains { m in
            switch m.state {
            case .downloading, .enumerating: return true
            default: return false
            }
        }
    }

    private var heroCard: some View {
        let state = heroState
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(state.dot)
                    .frame(width: 7, height: 7)
                Text(loc.t("Running on-device").uppercased())
                    .font(T.sans(12, .bold)).tracking(0)
                    .foregroundColor(T.ink3)
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(T.ink3)
            }
            Text(state.title)
                .font(T.display(22, .semibold))
                .foregroundColor(T.ink)
                .padding(.top, 13)
            Text(heroSubtitle)
                .font(T.sans(14))
                .foregroundColor(T.ink2)
                .padding(.top, 3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(action: { HapticManager.impact(.medium); onNewChat() }) {
                    Text(loc.t("New chat"))
                        .font(T.sans(15, .semibold))
                        .foregroundColor(T.accentStrong)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .kClearGlass(
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                            tint: T.accentStrong.opacity(0.26),
                            interactive: true,
                            fallbackFill: T.accentStrong,
                            fallbackStroke: T.accent.opacity(0.35)
                        )
                }
                .buttonStyle(.plain)
                Button(action: { HapticManager.impact(.light); onOpenVoice() }) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(T.ink)
                        .frame(width: 48, height: 46)
                        .kClearGlass(
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                            interactive: true,
                            fallbackFill: T.surface2,
                            fallbackStroke: T.rule
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc.t("voice"))
            }
            .padding(.top, 18)
        }
        .padding(20)
        .background(card(20))
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 12) {
            quickAction(icon: "camera.viewfinder", label: loc.t("lens"), action: onOpenLens)
            quickAction(icon: "waveform", label: loc.t("voice"), action: onOpenVoice)
            quickAction(icon: "desktopcomputer", label: loc.t("mac"), action: onOpenMac)
        }
    }

    private func quickAction(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: { HapticManager.impact(.light); action() }) {
            VStack(spacing: 9) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(T.ink2)
                }
                .frame(width: 40, height: 40)
                .kGlass(cornerRadius: 8, fallbackFill: T.surface2)
                Text(label)
                    .font(T.sans(12.5, .semibold))
                    .foregroundColor(T.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(card(18))
        }
        .buttonStyle(.plain)
    }

    private var imageGenerationCard: some View {
        Button {
            HapticManager.impact(.medium)
            onGenerateImage()
        } label: {
            HStack(spacing: 13) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(T.accentStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Generate an Image")
                        .font(.headline)
                        .foregroundStyle(T.ink)
                    Text("Create images privately with on-device models")
                        .font(.subheadline)
                        .foregroundStyle(T.ink2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(T.ink3)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(card(20))
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
        return VStack(alignment: .leading, spacing: 9) {
                Text(loc.t("Recent").uppercased())
                .font(T.sans(13, .semibold)).tracking(0)
                .foregroundColor(T.ink2)
                .padding(.leading, 4)
                .padding(.top, 4)

            if recent.isEmpty {
                HStack(spacing: 12) {
                    iconTile("message", tint: T.accent)
                    Text(loc.t("No recent activity yet"))
                        .font(T.sans(15)).foregroundColor(T.ink3)
                    Spacer()
                }
                .padding(14)
                .background(card(20))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { idx, convo in
                        Button(action: { HapticManager.impact(.light); onOpenConversation(convo) }) {
                            recentRow(convo, isLast: idx == recent.count - 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(card(20))
            }
        }
    }

    private func recentRow(_ convo: StoredConversation, isLast: Bool) -> some View {
        HStack(spacing: 12) {
            iconTile("message", tint: T.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(convo.title.isEmpty ? loc.t("Untitled chat") : convo.title)
                    .font(T.sans(15, .medium)).foregroundColor(T.ink)
                    .lineLimit(1)
                Text("\(loc.t("assistant")) · \(Self.relative(convo.updatedAt))")
                    .font(T.sans(12.5)).foregroundColor(T.ink3)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(T.ink4)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(T.rule).frame(height: 0.5).padding(.leading, 59) }
        }
        .contentShape(Rectangle())
    }

    // MARK: Privacy / manage

    private var privacyCard: some View {
        let readyCount = center.models.filter { $0.isReady }.count
        return HStack(spacing: 13) {
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
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .kClearGlass(
                        in: Capsule(),
                        interactive: true,
                        fallbackFill: T.surface2,
                        fallbackStroke: T.rule
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(15)
        .background(card(20))
    }

    // MARK: Reusable bits

    private func iconTile(_ symbol: String, tint: Color, filledTile: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: filledTile ? 11 : 9, style: .continuous)
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
