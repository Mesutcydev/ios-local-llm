import SwiftUI

// MARK: - TipsManager
// Tracks which one-shot tooltips have been dismissed so they only ever
// appear once per user. Backed by UserDefaults so dismissal survives
// app launches.

@MainActor
final class TipsManager: ObservableObject {

    static let shared = TipsManager()

    /// All tip identifiers. Add new ones here as features get tooltips.
    enum TipID: String, CaseIterable {
        case modeToggle     = "tip.mode_toggle"
        case historyButton  = "tip.history_button"
        case documentScanner = "tip.document_scanner"
        case longPressHistory = "tip.long_press_history"
        case swipeToDelete  = "tip.swipe_to_delete"
        case dictation      = "tip.dictation"
    }

    @Published private(set) var dismissed: Set<String> = []

    private init() {
        if let arr = UserDefaults.standard.array(forKey: "dismissedTips") as? [String] {
            dismissed = Set(arr)
        }
    }

    func isDismissed(_ tip: TipID) -> Bool {
        dismissed.contains(tip.rawValue)
    }

    func dismiss(_ tip: TipID) {
        dismissed.insert(tip.rawValue)
        UserDefaults.standard.set(Array(dismissed), forKey: "dismissedTips")
    }

    func resetAll() {
        dismissed.removeAll()
        UserDefaults.standard.removeObject(forKey: "dismissedTips")
    }
}

// MARK: - TipBubble
// Small floating popover that points at a feature. Auto-dismisses on tap.

struct TipBubble: View {
    let tip: TipsManager.TipID
    let title: String
    let message: String
    /// Direction the arrow should point. Default = up (tip sits below the
    /// element it explains).
    var arrow: Edge = .top

    @ObservedObject private var tips = TipsManager.shared
    @Environment(\.koduTheme) private var T

    var body: some View {
        if !tips.isDismissed(tip) {
            VStack(alignment: .leading, spacing: 6) {
                if arrow == .top { arrowShape }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 11))
                        .foregroundColor(T.warn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(T.mono(11, .semibold))
                            .foregroundColor(T.ink)
                        Text(message)
                            .font(T.sans(11))
                            .foregroundColor(T.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button {
                        tips.dismiss(tip)
                        HapticManager.impact(.light)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(T.ink3)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss tip")
                }
                .padding(10)
                .kGlass(cornerRadius: 8, fallbackFill: T.surface)

                if arrow == .bottom { arrowShape }
            }
            .frame(maxWidth: 240)
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }

    private var arrowShape: some View {
        Triangle()
            .fill(T.surface)
            .overlay(Triangle().stroke(T.rule, lineWidth: 1))
            .frame(width: 12, height: 6)
            .rotationEffect(.degrees(arrow == .bottom ? 180 : 0))
    }
}

// MARK: - Triangle

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
