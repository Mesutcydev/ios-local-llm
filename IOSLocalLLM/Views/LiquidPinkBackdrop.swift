import SwiftUI

// MARK: - LiquidPinkBackdrop
// Historical name retained for call-site compatibility. A quiet, solid canvas
// keeps content readable and preserves true black in OLED appearance.
struct LiquidPinkBackdrop: View {
    @Environment(\.koduTheme) private var T

    var body: some View {
        T.bg
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Card / pill primitives

struct LiquidGlassCard<Content: View>: View {
    @Environment(\.koduTheme) private var T
    let radius: CGFloat
    let intensity: Intensity
    let content: Content

    enum Intensity { case lo, med, hi }

    init(radius: CGFloat = 22, intensity: Intensity = .med, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.intensity = intensity
        self.content = content()
    }

    var body: some View {
        let fill: Color = {
            switch intensity {
            case .hi:  return T.surface2
            case .med: return T.surface
            case .lo:  return T.surface3
            }
        }()
        content
            .kGlass(
                cornerRadius: radius,
                fallbackFill: fill,
                fallbackStroke: T.rule
            )
    }
}

struct LiquidGlassPill<Content: View>: View {
    @Environment(\.koduTheme) private var T
    let active: Bool
    let content: Content

    init(active: Bool = false, @ViewBuilder content: () -> Content) {
        self.active = active
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .kClearGlass(
                in: Capsule(),
                tint: active ? T.accentStrong : nil,
                fallbackFill: active ? T.accentStrong : T.surface,
                fallbackStroke: active ? Color.clear : T.rule
            )
            .foregroundColor(active ? T.accentStrong : T.ink)
    }
}

struct LiquidGlassIconButton<Content: View>: View {
    @Environment(\.koduTheme) private var T
    let size: CGFloat
    let action: () -> Void
    let label: Content

    init(size: CGFloat = 36, action: @escaping () -> Void, @ViewBuilder label: () -> Content) {
        self.size = size
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(width: size, height: size)
                .kClearGlass(
                    in: Circle(),
                    interactive: true,
                    fallbackFill: T.surface,
                    fallbackStroke: T.rule
                )
                .foregroundColor(T.ink)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Active badge
struct KActivePinkBadge: View {
    @Environment(\.koduTheme) private var T
    let text: String

    init(_ text: String = "ACTIVE") { self.text = text }

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0)
        }
        .foregroundColor(T.ink)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .kClearGlass(
            in: RoundedRectangle(cornerRadius: 4),
            fallbackFill: T.surface2,
            fallbackStroke: T.rule
        )
    }
}
