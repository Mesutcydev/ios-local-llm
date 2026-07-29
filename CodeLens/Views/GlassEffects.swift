import SwiftUI

// MARK: - Centralized Liquid Glass renderer

enum GlassRole {
    case hero, card, listRow, button, capsule, icon, badge, toolbarButton, tabBar

    var radius: CGFloat {
        switch self {
        case .hero: 24
        case .card, .listRow: 18
        case .button: 16
        case .capsule, .badge: 999
        case .icon, .toolbarButton: 14
        case .tabBar: 30
        }
    }

    var interactive: Bool {
        switch self {
        case .button, .capsule, .icon, .badge, .toolbarButton, .tabBar: true
        default: false
        }
    }

    var materialOpacity: Double {
        switch self {
        case .hero, .card, .listRow: 0.30
        case .button: 0.34
        case .capsule, .icon, .badge, .toolbarButton, .tabBar: 0.52
        }
    }
}

@available(iOS 26.0, *)
private func nativeGlass(for role: GlassRole) -> Glass {
    var glass: Glass = .clear
    if role.interactive { glass = glass.interactive() }
    return glass
}

private struct GlassSurfaceModifier: ViewModifier {
    let role: GlassRole
    let cornerRadius: CGFloat?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let radius = cornerRadius ?? role.radius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        if #available(iOS 26.0, *), !reduceTransparency {
            // Geometry-lock the optical layer so iOS 27 cannot use the glass'
            // ideal bounds to expand a flexible row or button. Only this
            // background is translucent; foreground content stays fully opaque.
            content.background {
                GeometryReader { geometry in
                    Color.clear
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .glassEffect(nativeGlass(for: role), in: .rect(cornerRadius: radius))
                        .opacity(role.materialOpacity)
                }
            }
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    func glassSurface(
        _ role: GlassRole = .card,
        cornerRadius: CGFloat? = nil
    ) -> some View {
        modifier(GlassSurfaceModifier(role: role, cornerRadius: cornerRadius))
    }
}

// MARK: - Compatibility helpers
// Existing call sites route into the renderer above. Parameters retained here
// preserve source compatibility, but color is never injected into the glass.

extension View {
    /// Apple Liquid Glass on iOS 26+. Pre-26 renders
    /// an ultra-thin material with the same light-catching silhouette. This is
    /// the single surface primitive the whole theme routes through.
    @ViewBuilder
    func kClearGlass<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        fallbackFill: Color = .clear,
        fallbackStroke: Color = .clear
    ) -> some View {
        modifier(ShapeGlassSurfaceModifier(
            shape: shape,
            role: interactive ? .button : .capsule
        ))
    }

    /// Applies a Liquid Glass material on iOS 26+, with a graceful fallback
    /// to a flat fill + stroke for older OSes so the layout stays identical.
    ///
    /// `tint` colors the glass pill subtly — pass `T.accent.opacity(0.18)`
    /// for an "active" state.
    @ViewBuilder
    func kGlass(
        cornerRadius: CGFloat = 10,
        tint: Color? = nil,
        fallbackFill: Color = .clear,
        fallbackStroke: Color = .clear
    ) -> some View {
        glassSurface(.card, cornerRadius: cornerRadius)
    }

    /// Capsule variant of `kGlass`. Same fallback story.
    @ViewBuilder
    func kGlassCapsule(
        tint: Color? = nil,
        fallbackFill: Color = .clear,
        fallbackStroke: Color = .clear
    ) -> some View {
        modifier(ShapeGlassSurfaceModifier(
            shape: Capsule(),
            role: .capsule
        ))
    }
}

private struct ShapeGlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let role: GlassRole

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content.background {
                GeometryReader { geometry in
                    Color.clear
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .glassEffect(nativeGlass(for: role), in: shape)
                        .opacity(role.materialOpacity)
                }
            }
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

// MARK: - Container

/// Wraps a group of glass elements so iOS can morph them as one shape during
/// transitions. No-op pre-iOS 26.
struct KGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 0, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Shimmer
//
// Gradient sweep that animates across a view to indicate "loading" or
// "the model is thinking". Used on:
//   • streaming assistant bubbles before tokens arrive
//   • search result placeholders while a network query is in flight
//   • model card skeletons during catalog resolve
//
// Implementation: a moving angular highlight masked by the host view's
// shape, drawn with `.blendMode(.softLight)` so it lights the underlying
// surface instead of recoloring it. The phase is driven by a single
// @State on the modifier; we deliberately animate offset (not opacity)
// because offset animation is GPU-cheap and runs on the compositor.

extension View {
    /// Adds a shimmering highlight that travels across `self` while
    /// `isActive` is true. No-op when false (and stops cleanly).
    ///
    /// `intensity` (0...1) controls the brightness of the sweep; default
    /// 0.55 reads as a soft material highlight rather than a flashy
    /// "skeleton screen" effect.
    func shimmer(
        isActive: Bool = true,
        duration: Double = 1.4,
        intensity: Double = 0.55
    ) -> some View {
        modifier(ShimmerModifier(isActive: isActive, duration: duration, intensity: intensity))
    }
}

private struct ShimmerModifier: ViewModifier {
    let isActive: Bool
    let duration: Double
    let intensity: Double

    @State private var phase: CGFloat = -1.0

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    GeometryReader { geo in
                        let width = geo.size.width
                        // Width of the highlight band relative to the host.
                        // 0.65 lets the band feel like a deliberate sweep
                        // rather than a thin streak (which can read as a
                        // rendering glitch on small surfaces).
                        let bandWidth = width * 0.65
                        LinearGradient(
                            stops: [
                                .init(color: .clear,                    location: 0.0),
                                .init(color: .white.opacity(intensity), location: 0.5),
                                .init(color: .clear,                    location: 1.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: bandWidth)
                        // Phase goes -1 → 1; multiply by (width + bandWidth)
                        // so the band fully clears the host on both sides.
                        // Without this, on narrow surfaces the band's tail
                        // would still be visible at the wrap point and the
                        // loop would read as a snap.
                        .offset(x: phase * (width + bandWidth))
                        .blendMode(.softLight)
                    }
                    .allowsHitTesting(false)
                }
            }
            .mask(content)
            .onAppear {
                guard isActive else { return }
                withAnimation(
                    .linear(duration: duration).repeatForever(autoreverses: false)
                ) { phase = 1.0 }
            }
            .onChange(of: isActive) { _, nowActive in
                if nowActive {
                    phase = -1.0
                    withAnimation(
                        .linear(duration: duration).repeatForever(autoreverses: false)
                    ) { phase = 1.0 }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { phase = -1.0 }
                }
            }
    }
}
