import SwiftUI

// MARK: - Shared semantic design tokens

// MARK: - Scale
// One rule for every spacing, radius and text size in the app. Audit and
// rationale: build/ui-metrics-audit-2026-11-18 (local, not in git).

/// Spacing: 16 pt × φⁿ rounded to whole points (φ = 1.618…), so each step is
/// the golden ratio of the one before. Off-scale values snap to the nearest
/// step on a log scale.
enum Space {
    static let hair: CGFloat = 2    // 16·φ⁻⁴ ≈ 2.3 · title ↔ subtitle
    static let xxs: CGFloat = 4     // 16·φ⁻³ ≈ 3.8
    static let xs: CGFloat = 6      // 16·φ⁻² ≈ 6.1 · icon ↔ label
    static let s: CGFloat = 10      // 16·φ⁻¹ ≈ 9.9 · card gap
    static let m: CGFloat = 16      // base · screen margin, card padding
    static let l: CGFloat = 26      // 16·φ¹ ≈ 25.9 · between sections
    static let xl: CGFloat = 42     // 16·φ² ≈ 41.9
    static let xxl: CGFloat = 68    // 16·φ³ ≈ 67.8

    static let screenMargin = m
    static let cardPadding = m
    static let cardGap = s
}

/// Corner radii: one value per level. Buttons use Apple's glass styles
/// (`glassButton`), whose capsule shape comes from the system.
enum Radius {
    static let inner: CGFloat = 6
    static let control: CGFloat = 12
    static let card: CGFloat = 20
    static let panel: CGFloat = 24
}

/// Square sizes for icon tiles and round buttons. Anything the user taps on
/// its own is at least `control`, Apple's minimum touch target.
enum Size {
    static let glyph: CGFloat = 20     // radios, status glyphs
    static let tile: CGFloat = 28      // row icon tile
    static let control: CGFloat = 44   // icon buttons, touch target
    static let feature: CGFloat = 48   // leading tile of a card
}

/// Type: Apple's text-style ramp only. Legacy point sizes map to the style
/// whose default size is nearest.
enum TextScale {
    /// All-caps labels only. Mixed-case text keeps the text style's own
    /// tracking, which SF already tunes per size.
    static let capsTracking: CGFloat = 0.5

    static func style(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.75: .caption2      // 11
        case ..<12.75: .caption       // 12
        case ..<13.75: .footnote      // 13
        case ..<15.75: .subheadline   // 15
        case ..<16.5:  .callout       // 16
        case ..<18.5:  .body          // 17
        case ..<21:    .title3        // 20
        case ..<25:    .title2        // 22
        case ..<31:    .title         // 28
        default:       .largeTitle    // 34
        }
    }
}

enum AppTypography {
    static let eyebrow: Font = .caption2.weight(.semibold)
    static let secondary: Font = .subheadline
    static let body: Font = .body
    static let title: Font = .title3.weight(.semibold)
}

enum AppStroke {
    static let hairline: CGFloat = 0.5
    static let regular: CGFloat = 1
}

enum AppShadow {
    static let panelColor = Color.black.opacity(0.16)
    static let panelRadius: CGFloat = 18
    static let panelY: CGFloat = 6
}

enum AppAnimation {
    static let quick = Animation.easeOut(duration: 0.16)
    static let state = Animation.spring(response: 0.36, dampingFraction: 0.86)
}

struct AppPanelBackground: ViewModifier {
    var cornerRadius: CGFloat = Radius.panel
    var cameraSafe = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(cameraSafe ? Color(uiColor: .secondarySystemBackground) : Color(uiColor: .systemBackground))
                } else {
                    shape.fill(cameraSafe ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial))
                }
            }
            .overlay {
                shape.stroke(
                    cameraSafe
                        ? Color.white.opacity(colorScheme == .dark ? 0.22 : 0.34)
                        : Color.primary.opacity(0.10),
                    lineWidth: AppStroke.hairline
                )
            }
            .shadow(color: AppShadow.panelColor, radius: AppShadow.panelRadius, y: AppShadow.panelY)
    }
}

extension View {
    /// Apple's Liquid Glass button (iOS 26+); a bordered capsule before it.
    /// `prominent` is for the one main action on a screen or card.
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else if prominent {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }

    func appPanel(cornerRadius: CGFloat = Radius.panel, cameraSafe: Bool = false) -> some View {
        modifier(AppPanelBackground(cornerRadius: cornerRadius, cameraSafe: cameraSafe))
    }

    func minimumInteractiveSize() -> some View {
        frame(minWidth: Size.control, minHeight: Size.control)
    }
}

/// Keeps focus cleanup consistent for controls that remain mounted inside a TabView.
struct KeyboardDismissModifier<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger

    func body(content: Content) -> some View {
        content.onChange(of: trigger) { _, _ in
            KeyboardDismiss.now()
        }
    }
}

extension View {
    func dismissKeyboardWhen<Trigger: Equatable>(_ trigger: Trigger) -> some View {
        modifier(KeyboardDismissModifier(trigger: trigger))
    }
}

// MARK: - Text styles for legacy design sizes

extension View {
    /// Legacy call sites pass a design size; it picks a text style, which
    /// scales with Dynamic Type.
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        font(.system(TextScale.style(for: size), design: design, weight: weight))
    }
}
