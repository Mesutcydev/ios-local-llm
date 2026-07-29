import SwiftUI

// MARK: - LiquidPinkBackdrop
// Historical name retained for compatibility. This is backdrop content, not a
// tint inside the glass: restrained detail gives the native material live
// pixels to sample and makes its clarity/refraction visible in both modes.

struct LiquidPinkBackdrop: View {
    @Environment(\.koduTheme) private var T

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                T.bg

                Circle()
                    .fill(T.accent.opacity(T.isDark ? 0.18 : 0.10))
                    .frame(width: proxy.size.width * 1.05)
                    .blur(radius: 38)
                    .offset(x: -proxy.size.width * 0.42, y: -proxy.size.height * 0.26)

                Circle()
                    .fill(Color(red: 0.42, green: 0.78, blue: 0.72)
                        .opacity(T.isDark ? 0.13 : 0.12))
                    .frame(width: proxy.size.width * 0.86)
                    .blur(radius: 46)
                    .offset(x: proxy.size.width * 0.42, y: proxy.size.height * 0.04)

                RoundedRectangle(cornerRadius: 64, style: .continuous)
                    .fill(Color(red: 0.72, green: 0.62, blue: 0.96)
                        .opacity(T.isDark ? 0.12 : 0.10))
                    .frame(width: proxy.size.width * 1.15, height: proxy.size.height * 0.34)
                    .rotationEffect(.degrees(-18))
                    .blur(radius: 52)
                    .offset(x: proxy.size.width * 0.18, y: proxy.size.height * 0.39)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
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
