import SwiftUI

/// Semantic, fully configurable color theme for ``VoiceAgentOrb``.
///
/// Colors are stored per ``VoiceOrbStateKind`` so the orb never hardcodes
/// state colors in the renderer. Each color has light and dark variants and
/// is resolved against the active `ColorScheme` at draw time.
public struct VoiceAgentOrbTheme: Sendable, Equatable {

    /// A color with light and dark appearance variants.
    public struct AdaptiveColor: Sendable, Equatable {
        public var light: Color
        public var dark: Color

        public init(light: Color, dark: Color) {
            self.light = light
            self.dark = dark
        }

        /// Same color in both appearances.
        public init(_ color: Color) {
            self.light = color
            self.dark = color
        }

        public init(light: Color) {
            self.light = light
            self.dark = light
        }

        public func resolve(in scheme: ColorScheme) -> Color {
            scheme == .dark ? dark : light
        }
    }

    /// Colors for one state.
    public struct Palette: Sendable, Equatable {
        /// Central intelligence core (brightest point).
        public var core: AdaptiveColor
        /// Darker internal volume tint behind the energy.
        public var inner: AdaptiveColor
        /// Primary energy field color.
        public var energy: AdaptiveColor
        /// Secondary energy field color (layered beneath/above primary).
        public var energySecondary: AdaptiveColor
        /// Glass rim / edge light color.
        public var rim: AdaptiveColor
        /// Outer atmospheric glow color.
        public var glow: AdaptiveColor
        /// Small accent color (violet flecks, refraction fringe).
        public var accent: AdaptiveColor

        public init(
            core: AdaptiveColor,
            inner: AdaptiveColor,
            energy: AdaptiveColor,
            energySecondary: AdaptiveColor,
            rim: AdaptiveColor,
            glow: AdaptiveColor,
            accent: AdaptiveColor
        ) {
            self.core = core
            self.inner = inner
            self.energy = energy
            self.energySecondary = energySecondary
            self.rim = rim
            self.glow = glow
            self.accent = accent
        }
    }

    public var idle: Palette
    public var preparing: Palette
    public var listening: Palette
    public var speechDetected: Palette
    public var transcribing: Palette
    public var thinking: Palette
    public var speaking: Palette
    public var interrupted: Palette
    public var error: Palette
    public var disabled: Palette

    /// Specular highlight and glass sheen color.
    public var glassHighlight: AdaptiveColor
    /// Contact shadow color beneath the orb.
    public var contactShadow: AdaptiveColor
    /// Optional status text label color. `nil` uses `.secondary`.
    public var labelColor: AdaptiveColor?

    public init(
        idle: Palette,
        preparing: Palette,
        listening: Palette,
        speechDetected: Palette,
        transcribing: Palette,
        thinking: Palette,
        speaking: Palette,
        interrupted: Palette,
        error: Palette,
        disabled: Palette,
        glassHighlight: AdaptiveColor,
        contactShadow: AdaptiveColor,
        labelColor: AdaptiveColor? = nil
    ) {
        self.idle = idle
        self.preparing = preparing
        self.listening = listening
        self.speechDetected = speechDetected
        self.transcribing = transcribing
        self.thinking = thinking
        self.speaking = speaking
        self.interrupted = interrupted
        self.error = error
        self.disabled = disabled
        self.glassHighlight = glassHighlight
        self.contactShadow = contactShadow
        self.labelColor = labelColor
    }

    public func palette(for kind: VoiceOrbStateKind) -> Palette {
        switch kind {
        case .idle: return idle
        case .preparing: return preparing
        case .listening: return listening
        case .speechDetected: return speechDetected
        case .transcribing: return transcribing
        case .thinking: return thinking
        case .speaking: return speaking
        case .interrupted: return interrupted
        case .error: return error
        case .disabled: return disabled
        }
    }
}

// MARK: - Default palette

public extension VoiceAgentOrbTheme {
    /// The default theme. Dark variants are slightly brighter and more
    /// saturated so the orb keeps its presence on dark backgrounds.
    static let `default` = VoiceAgentOrbTheme(
        idle: Palette(
            core: AdaptiveColor(light: Color(red: 0.98, green: 0.99, blue: 1.00),
                                dark: Color(red: 0.95, green: 0.97, blue: 1.00)),
            inner: AdaptiveColor(light: Color(red: 0.78, green: 0.82, blue: 0.88),
                                 dark: Color(red: 0.16, green: 0.18, blue: 0.24)),
            energy: AdaptiveColor(light: Color(red: 0.62, green: 0.70, blue: 0.84),
                                  dark: Color(red: 0.55, green: 0.64, blue: 0.82)),
            energySecondary: AdaptiveColor(light: Color(red: 0.84, green: 0.87, blue: 0.92),
                                           dark: Color(red: 0.42, green: 0.48, blue: 0.62)),
            rim: AdaptiveColor(light: Color(red: 0.90, green: 0.93, blue: 0.98),
                               dark: Color(red: 0.70, green: 0.76, blue: 0.88)),
            glow: AdaptiveColor(light: Color(red: 0.72, green: 0.80, blue: 0.95),
                                dark: Color(red: 0.45, green: 0.56, blue: 0.80)),
            accent: AdaptiveColor(light: Color(red: 0.70, green: 0.78, blue: 0.95),
                                  dark: Color(red: 0.60, green: 0.68, blue: 0.92))
        ),
        preparing: Palette(
            core: AdaptiveColor(light: Color(red: 0.93, green: 0.97, blue: 1.00),
                                dark: Color(red: 0.90, green: 0.95, blue: 1.00)),
            inner: AdaptiveColor(light: Color(red: 0.74, green: 0.80, blue: 0.88),
                                 dark: Color(red: 0.15, green: 0.19, blue: 0.26)),
            energy: AdaptiveColor(light: Color(red: 0.45, green: 0.66, blue: 0.95),
                                  dark: Color(red: 0.40, green: 0.62, blue: 0.98)),
            energySecondary: AdaptiveColor(light: Color(red: 0.70, green: 0.82, blue: 0.98),
                                           dark: Color(red: 0.36, green: 0.52, blue: 0.85)),
            rim: AdaptiveColor(light: Color(red: 0.80, green: 0.89, blue: 1.00),
                               dark: Color(red: 0.62, green: 0.74, blue: 0.95)),
            glow: AdaptiveColor(light: Color(red: 0.55, green: 0.74, blue: 0.98),
                                dark: Color(red: 0.38, green: 0.58, blue: 0.92)),
            accent: AdaptiveColor(light: Color(red: 0.62, green: 0.76, blue: 0.98),
                                  dark: Color(red: 0.52, green: 0.68, blue: 0.98))
        ),
        listening: Palette(
            core: AdaptiveColor(light: Color(red: 0.85, green: 0.98, blue: 1.00),
                                dark: Color(red: 0.82, green: 0.97, blue: 1.00)),
            inner: AdaptiveColor(light: Color(red: 0.58, green: 0.78, blue: 0.92),
                                 dark: Color(red: 0.08, green: 0.22, blue: 0.32)),
            energy: AdaptiveColor(light: Color(red: 0.10, green: 0.72, blue: 0.95),
                                  dark: Color(red: 0.12, green: 0.78, blue: 1.00)),
            energySecondary: AdaptiveColor(light: Color(red: 0.20, green: 0.45, blue: 0.98),
                                           dark: Color(red: 0.22, green: 0.50, blue: 1.00)),
            rim: AdaptiveColor(light: Color(red: 0.55, green: 0.88, blue: 1.00),
                               dark: Color(red: 0.45, green: 0.85, blue: 1.00)),
            glow: AdaptiveColor(light: Color(red: 0.30, green: 0.76, blue: 0.98),
                                dark: Color(red: 0.20, green: 0.66, blue: 0.98)),
            accent: AdaptiveColor(light: Color(red: 0.40, green: 0.60, blue: 1.00),
                                  dark: Color(red: 0.36, green: 0.58, blue: 1.00))
        ),
        speechDetected: Palette(
            core: AdaptiveColor(light: Color(red: 0.88, green: 0.96, blue: 1.00),
                                dark: Color(red: 0.86, green: 0.95, blue: 1.00)),
            inner: AdaptiveColor(light: Color(red: 0.55, green: 0.70, blue: 0.94),
                                 dark: Color(red: 0.10, green: 0.18, blue: 0.34)),
            energy: AdaptiveColor(light: Color(red: 0.20, green: 0.55, blue: 1.00),
                                  dark: Color(red: 0.24, green: 0.60, blue: 1.00)),
            energySecondary: AdaptiveColor(light: Color(red: 0.42, green: 0.45, blue: 0.98),
                                           dark: Color(red: 0.48, green: 0.50, blue: 1.00)),
            rim: AdaptiveColor(light: Color(red: 0.58, green: 0.78, blue: 1.00),
                               dark: Color(red: 0.52, green: 0.74, blue: 1.00)),
            glow: AdaptiveColor(light: Color(red: 0.38, green: 0.62, blue: 1.00),
                                dark: Color(red: 0.32, green: 0.55, blue: 0.98)),
            accent: AdaptiveColor(light: Color(red: 0.62, green: 0.45, blue: 0.98),
                                  dark: Color(red: 0.68, green: 0.52, blue: 1.00))
        ),
        transcribing: Palette(
            core: AdaptiveColor(light: Color(red: 0.92, green: 0.92, blue: 1.00),
                                dark: Color(red: 0.90, green: 0.90, blue: 1.00)),
            inner: AdaptiveColor(light: Color(red: 0.62, green: 0.58, blue: 0.90),
                                 dark: Color(red: 0.14, green: 0.13, blue: 0.32)),
            energy: AdaptiveColor(light: Color(red: 0.40, green: 0.42, blue: 0.98),
                                  dark: Color(red: 0.46, green: 0.48, blue: 1.00)),
            energySecondary: AdaptiveColor(light: Color(red: 0.55, green: 0.35, blue: 0.95),
                                           dark: Color(red: 0.62, green: 0.42, blue: 0.98)),
            rim: AdaptiveColor(light: Color(red: 0.70, green: 0.68, blue: 1.00),
                               dark: Color(red: 0.62, green: 0.60, blue: 0.98)),
            glow: AdaptiveColor(light: Color(red: 0.52, green: 0.50, blue: 0.98),
                                dark: Color(red: 0.45, green: 0.44, blue: 0.95)),
            accent: AdaptiveColor(light: Color(red: 0.60, green: 0.48, blue: 0.98),
                                  dark: Color(red: 0.66, green: 0.55, blue: 1.00))
        ),
        thinking: Palette(
            core: AdaptiveColor(light: Color(red: 0.95, green: 0.90, blue: 1.00),
                                dark: Color(red: 0.94, green: 0.88, blue: 1.00)),
            inner: AdaptiveColor(light: Color(red: 0.62, green: 0.50, blue: 0.86),
                                 dark: Color(red: 0.17, green: 0.11, blue: 0.32)),
            energy: AdaptiveColor(light: Color(red: 0.55, green: 0.35, blue: 0.95),
                                  dark: Color(red: 0.62, green: 0.42, blue: 1.00)),
            energySecondary: AdaptiveColor(light: Color(red: 0.38, green: 0.28, blue: 0.82),
                                           dark: Color(red: 0.44, green: 0.32, blue: 0.90)),
            rim: AdaptiveColor(light: Color(red: 0.74, green: 0.62, blue: 0.98),
                               dark: Color(red: 0.66, green: 0.55, blue: 0.98)),
            glow: AdaptiveColor(light: Color(red: 0.60, green: 0.44, blue: 0.95),
                                dark: Color(red: 0.52, green: 0.38, blue: 0.92)),
            accent: AdaptiveColor(light: Color(red: 0.85, green: 0.40, blue: 0.85),
                                  dark: Color(red: 0.88, green: 0.48, blue: 0.90))
        ),
        speaking: Palette(
            core: AdaptiveColor(light: Color(red: 0.92, green: 1.00, blue: 0.99),
                                dark: Color(red: 0.90, green: 1.00, blue: 0.98)),
            inner: AdaptiveColor(light: Color(red: 0.50, green: 0.80, blue: 0.82),
                                 dark: Color(red: 0.07, green: 0.24, blue: 0.26)),
            energy: AdaptiveColor(light: Color(red: 0.10, green: 0.82, blue: 0.82),
                                  dark: Color(red: 0.14, green: 0.88, blue: 0.88)),
            energySecondary: AdaptiveColor(light: Color(red: 0.20, green: 0.70, blue: 0.95),
                                           dark: Color(red: 0.24, green: 0.76, blue: 0.98)),
            rim: AdaptiveColor(light: Color(red: 0.60, green: 0.92, blue: 0.92),
                               dark: Color(red: 0.52, green: 0.90, blue: 0.90)),
            glow: AdaptiveColor(light: Color(red: 0.35, green: 0.85, blue: 0.85),
                                dark: Color(red: 0.25, green: 0.78, blue: 0.80)),
            accent: AdaptiveColor(light: Color(red: 0.85, green: 0.98, blue: 0.96),
                                  dark: Color(red: 0.80, green: 0.98, blue: 0.95))
        ),
        interrupted: Palette(
            core: AdaptiveColor(light: Color(red: 1.00, green: 0.94, blue: 0.85),
                                dark: Color(red: 1.00, green: 0.92, blue: 0.82)),
            inner: AdaptiveColor(light: Color(red: 0.85, green: 0.68, blue: 0.45),
                                 dark: Color(red: 0.30, green: 0.20, blue: 0.10)),
            energy: AdaptiveColor(light: Color(red: 0.98, green: 0.68, blue: 0.25),
                                  dark: Color(red: 1.00, green: 0.72, blue: 0.30)),
            energySecondary: AdaptiveColor(light: Color(red: 0.92, green: 0.55, blue: 0.20),
                                           dark: Color(red: 0.95, green: 0.60, blue: 0.24)),
            rim: AdaptiveColor(light: Color(red: 1.00, green: 0.82, blue: 0.55),
                               dark: Color(red: 0.98, green: 0.78, blue: 0.50)),
            glow: AdaptiveColor(light: Color(red: 0.95, green: 0.70, blue: 0.35),
                                dark: Color(red: 0.90, green: 0.62, blue: 0.28)),
            accent: AdaptiveColor(light: Color(red: 1.00, green: 0.80, blue: 0.50),
                                  dark: Color(red: 1.00, green: 0.78, blue: 0.46))
        ),
        error: Palette(
            core: AdaptiveColor(light: Color(red: 1.00, green: 0.88, blue: 0.86),
                                dark: Color(red: 1.00, green: 0.86, blue: 0.84)),
            inner: AdaptiveColor(light: Color(red: 0.80, green: 0.52, blue: 0.50),
                                 dark: Color(red: 0.28, green: 0.12, blue: 0.12)),
            energy: AdaptiveColor(light: Color(red: 0.85, green: 0.38, blue: 0.36),
                                  dark: Color(red: 0.88, green: 0.42, blue: 0.40)),
            energySecondary: AdaptiveColor(light: Color(red: 0.72, green: 0.30, blue: 0.30),
                                           dark: Color(red: 0.76, green: 0.34, blue: 0.34)),
            rim: AdaptiveColor(light: Color(red: 0.92, green: 0.60, blue: 0.58),
                               dark: Color(red: 0.88, green: 0.55, blue: 0.52)),
            glow: AdaptiveColor(light: Color(red: 0.85, green: 0.45, blue: 0.42),
                                dark: Color(red: 0.78, green: 0.38, blue: 0.36)),
            accent: AdaptiveColor(light: Color(red: 0.95, green: 0.62, blue: 0.58),
                                  dark: Color(red: 0.92, green: 0.58, blue: 0.55))
        ),
        disabled: Palette(
            core: AdaptiveColor(light: Color(red: 0.90, green: 0.90, blue: 0.92),
                                dark: Color(red: 0.72, green: 0.72, blue: 0.75)),
            inner: AdaptiveColor(light: Color(red: 0.70, green: 0.70, blue: 0.73),
                                 dark: Color(red: 0.18, green: 0.18, blue: 0.20)),
            energy: AdaptiveColor(light: Color(red: 0.60, green: 0.60, blue: 0.64),
                                  dark: Color(red: 0.48, green: 0.48, blue: 0.52)),
            energySecondary: AdaptiveColor(light: Color(red: 0.68, green: 0.68, blue: 0.71),
                                           dark: Color(red: 0.40, green: 0.40, blue: 0.44)),
            rim: AdaptiveColor(light: Color(red: 0.78, green: 0.78, blue: 0.80),
                               dark: Color(red: 0.55, green: 0.55, blue: 0.58)),
            glow: AdaptiveColor(light: Color(red: 0.66, green: 0.66, blue: 0.70),
                                dark: Color(red: 0.42, green: 0.42, blue: 0.46)),
            accent: AdaptiveColor(light: Color(red: 0.70, green: 0.70, blue: 0.73),
                                  dark: Color(red: 0.52, green: 0.52, blue: 0.55))
        ),
        glassHighlight: AdaptiveColor(light: Color(white: 1.0), dark: Color(white: 1.0)),
        contactShadow: AdaptiveColor(light: Color(red: 0.20, green: 0.24, blue: 0.34),
                                     dark: Color(red: 0.0, green: 0.0, blue: 0.0))
    )
}
