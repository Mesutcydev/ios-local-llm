import SwiftUI

// MARK: - Blended palette

/// Per-frame RGBA-blended colors. Produced by ``VoiceOrbPaletteCache`` with
/// cheap float math (no resolution, no dictionary work) and consumed by the
/// renderer to build its gradients.
public struct VoiceOrbBlendedPalette: Sendable, Equatable {
    public var core: Color
    public var inner: Color
    public var energy: Color
    public var energySecondary: Color
    public var rim: Color
    public var glow: Color
    public var accent: Color
    public var glassHighlight: Color
    public var contactShadow: Color
}

/// Resolves every theme palette once per (theme, colorScheme) pair — Color
/// resolution needs an environment, so it must not run per frame. Frame-time
/// blending then operates on raw floats.
public struct VoiceOrbPaletteCache: Sendable {

    struct ResolvedPalette: Sendable, Equatable {
        var core: Color.Resolved
        var inner: Color.Resolved
        var energy: Color.Resolved
        var energySecondary: Color.Resolved
        var rim: Color.Resolved
        var glow: Color.Resolved
        var accent: Color.Resolved
    }

    private struct ResolvedTheme: Sendable {
        var palettes: [VoiceOrbStateKind: ResolvedPalette]
    }

    private var resolvedTheme: ResolvedTheme?
    private var resolvedThemeID: Int?
    private var resolvedScheme: ColorScheme?

    public init() {}

    /// Blends the transition palettes at `t` (0 = from, 1 = to).
    /// Rebuilds its resolution cache only when theme or appearance changes.
    public mutating func blend(
        from: VoiceOrbStateKind,
        to: VoiceOrbStateKind,
        t: Double,
        theme: VoiceAgentOrbTheme,
        colorScheme: ColorScheme
    ) -> VoiceOrbBlendedPalette {
        if resolvedScheme != colorScheme || resolvedThemeID != theme.identity {
            resolvedTheme = Self.resolve(theme: theme, colorScheme: colorScheme)
            resolvedScheme = colorScheme
            resolvedThemeID = theme.identity
        }
        guard let resolved = resolvedTheme,
              let fromPalette = resolved.palettes[from],
              let toPalette = resolved.palettes[to] else {
            return Self.fallback(theme: theme, colorScheme: colorScheme)
        }

        let t = min(max(t.isFinite ? t : 1, 0), 1)
        func mix(_ a: Color.Resolved, _ b: Color.Resolved) -> Color {
            let f = 1 - t
            return Color(
                .sRGBLinear,
                red: Double(a.linearRed * Float(f) + b.linearRed * Float(t)),
                green: Double(a.linearGreen * Float(f) + b.linearGreen * Float(t)),
                blue: Double(a.linearBlue * Float(f) + b.linearBlue * Float(t)),
                opacity: Double(a.opacity * Float(f) + b.opacity * Float(t))
            )
        }

        return VoiceOrbBlendedPalette(
            core: mix(fromPalette.core, toPalette.core),
            inner: mix(fromPalette.inner, toPalette.inner),
            energy: mix(fromPalette.energy, toPalette.energy),
            energySecondary: mix(fromPalette.energySecondary, toPalette.energySecondary),
            rim: mix(fromPalette.rim, toPalette.rim),
            glow: mix(fromPalette.glow, toPalette.glow),
            accent: mix(fromPalette.accent, toPalette.accent),
            glassHighlight: theme.glassHighlight.resolve(in: colorScheme),
            contactShadow: theme.contactShadow.resolve(in: colorScheme)
        )
    }

    private static func resolve(theme: VoiceAgentOrbTheme, colorScheme: ColorScheme) -> ResolvedTheme {
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme
        var palettes: [VoiceOrbStateKind: ResolvedPalette] = [:]
        palettes.reserveCapacity(VoiceOrbStateKind.allCases.count)
        for kind in VoiceOrbStateKind.allCases {
            let palette = theme.palette(for: kind)
            palettes[kind] = ResolvedPalette(
                core: palette.core.resolve(in: colorScheme).resolve(in: environment),
                inner: palette.inner.resolve(in: colorScheme).resolve(in: environment),
                energy: palette.energy.resolve(in: colorScheme).resolve(in: environment),
                energySecondary: palette.energySecondary.resolve(in: colorScheme).resolve(in: environment),
                rim: palette.rim.resolve(in: colorScheme).resolve(in: environment),
                glow: palette.glow.resolve(in: colorScheme).resolve(in: environment),
                accent: palette.accent.resolve(in: colorScheme).resolve(in: environment)
            )
        }
        return ResolvedTheme(palettes: palettes)
    }

    private static func fallback(theme: VoiceAgentOrbTheme, colorScheme: ColorScheme) -> VoiceOrbBlendedPalette {
        let palette = theme.idle
        return VoiceOrbBlendedPalette(
            core: palette.core.resolve(in: colorScheme),
            inner: palette.inner.resolve(in: colorScheme),
            energy: palette.energy.resolve(in: colorScheme),
            energySecondary: palette.energySecondary.resolve(in: colorScheme),
            rim: palette.rim.resolve(in: colorScheme),
            glow: palette.glow.resolve(in: colorScheme),
            accent: palette.accent.resolve(in: colorScheme),
            glassHighlight: theme.glassHighlight.resolve(in: colorScheme),
            contactShadow: theme.contactShadow.resolve(in: colorScheme)
        )
    }
}

private extension VoiceAgentOrbTheme {
    /// Identity for cache invalidation. Themes are value types compared by
    /// the view on change; a cheap identity avoids deep comparison per frame.
    var identity: Int {
        var hasher = Hasher()
        hasher.combine(self)
        return hasher.finalize()
    }
}

extension VoiceAgentOrbTheme: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(idle.core.light)
        hasher.combine(listening.energy.light)
        hasher.combine(speaking.energy.light)
        hasher.combine(thinking.energy.light)
        hasher.combine(error.energy.light)
        hasher.combine(disabled.energy.light)
    }
}

// MARK: - Renderer

/// Draws the orb into SwiftUI `Canvas` contexts.
///
/// Two surfaces are used:
/// - ``drawInterior`` — volume, energy fields, band, waves, particles, core.
///   This surface may receive the Metal refraction effect from the view.
/// - ``drawShell`` — contact shadow, atmospheric glow, glass shell, rim,
///   refraction fringe, specular highlight, progress ring.
///
/// All internal content is clipped to the orb boundary. Per-frame work is
/// bounded: fixed 72-segment field paths, fixed particle counts, a handful
/// of small gradients — no arrays of random values, no blur chains.
public enum VoiceOrbRenderer {

    // MARK: Interior surface

    public static func drawInterior(
        context: inout GraphicsContext,
        size: CGSize,
        snapshot: VoiceOrbFrameSnapshot,
        colors: VoiceOrbBlendedPalette,
        quality: VoiceOrbRenderQuality
    ) {
        let config = snapshot.config
        let alphaScale = 1 - config.dimming
        guard alphaScale > 0.01 else { return }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let orbRadius = min(size.width, size.height) * 0.31
        let scale = snapshot.breathingScale * (1 + config.shellExpansion) * (1 - 0.05 * snapshot.interruptSettle)
        let radius = orbRadius * scale
        let level = min(max(snapshot.micLevel + snapshot.outputLevel + snapshot.condensePulse * 0.3, 0), 1)

        var ctx = context

        // Internal volume: darker translucent body the energy lives in.
        let circle = Path(ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))
        let volumeGradient = Gradient(stops: [
            .init(color: colors.inner.opacity(0.92 * alphaScale), location: 0),
            .init(color: colors.inner.opacity(1.0 * alphaScale), location: 0.72),
            .init(color: colors.inner.opacity(0.96 * alphaScale), location: 1),
        ])
        ctx.fill(circle, with: .radialGradient(
            volumeGradient, center: center,
            startRadius: 0, endRadius: radius
        ))

        // Everything below stays inside the glass.
        ctx.clip(to: circle)

        // Energy fields — normal blend. `.plusLighter` over stacked gradients
        // is a ProMotion hitch magnet and made the glass orb flutter.
        var fields = ctx
        fields.blendMode = .normal

        let inwardPull = config.inwardPull * (0.3 + 0.7 * snapshot.micLevel)
            + snapshot.interruptSettle * 0.5
        let wavePush = config.waveAmplitude * snapshot.outputLevel

        // Static field table — no per-frame array creation.
        for (index, field) in VoiceOrbEnergyField.all.enumerated() {
            guard index < quality.energyLayerCount else { break }
            let color: Color = switch index {
            case 0: colors.energy
            case 1: colors.energySecondary
            default: colors.accent
            }
            let fieldAlpha = field.alpha * config.energy * alphaScale
                * (1 + snapshot.condensePulse * 0.35 + snapshot.errorPulse * 0.2)

            let path = fieldPath(
                field: field,
                center: center,
                radius: radius,
                time: snapshot.time,
                level: level,
                deformation: config.deformation * (1 + snapshot.speechActivity * 0.5),
                inwardPull: inwardPull,
                wave: wavePush
            )
            let fieldGradient = Gradient(stops: [
                .init(color: color.opacity(min(fieldAlpha * 0.15, 1)), location: 0),
                .init(color: color.opacity(min(fieldAlpha * 0.75, 1)), location: 0.62),
                .init(color: color.opacity(0), location: 1),
            ])
            fields.fill(path, with: .radialGradient(
                fieldGradient, center: center,
                startRadius: 0, endRadius: radius * field.baseRadius * 1.25
            ))
        }

        // Transcribing: focused rotating band.
        if config.focusBandIntensity > 0.01, !snapshot.reducedMotion {
            let bandAngle = snapshot.rotation * 2.6
            let bandWidth = radius * 0.16
            for pass in 0..<2 {
                let widen = pass == 0 ? 1.9 : 1.0
                let alpha = config.focusBandIntensity * alphaScale * (pass == 0 ? 0.18 : 0.5)
                var arc = Path()
                arc.addArc(
                    center: center, radius: radius * 0.62,
                    startAngle: .radians(bandAngle),
                    endAngle: .radians(bandAngle + .pi * 0.55),
                    clockwise: false
                )
                fields.stroke(arc, with: .color(colors.accent.opacity(alpha)),
                              lineWidth: bandWidth * widen)
            }
        }

        // Speaking: outward waves originating from the core.
        if config.waveAmplitude > 0.01, snapshot.outputLevel > 0.01, !snapshot.reducedMotion {
            for i in 0..<3 {
                let p = fract(snapshot.time * 0.85 + Double(i) / 3)
                let ringRadius = radius * (0.28 + 0.62 * p)
                let fade = pow(1 - p, 1.6)
                let alpha = fade * snapshot.outputLevel * config.waveAmplitude * 0.5 * alphaScale
                guard alpha > 0.01 else { continue }
                let ring = Path(ellipseIn: CGRect(
                    x: center.x - ringRadius, y: center.y - ringRadius,
                    width: ringRadius * 2, height: ringRadius * 2
                ))
                fields.stroke(ring, with: .color(colors.accent.opacity(alpha)),
                              lineWidth: max(radius * 0.028 * (1 - p * 0.5), 0.5))
            }
        }

        // Fine interior particles.
        if config.particleVisibility > 0.01, quality.particleCount > 0, !snapshot.reducedMotion {
            for i in 0..<quality.particleCount {
                let unit = VoiceOrbParticles.position(
                    index: i, count: quality.particleCount,
                    t: snapshot.time, energy: config.energy
                )
                let point = CGPoint(
                    x: center.x + (unit.x - 0.5) * 2 * radius * 0.92,
                    y: center.y + (unit.y - 0.5) * 2 * radius * 0.92
                )
                let twinkle = 0.6 + 0.4 * sin(snapshot.time * (0.6 + Double(i % 5) * 0.13) + Double(i) * 1.7)
                let particleAlpha = config.particleVisibility * 0.5 * twinkle * alphaScale
                let pr = max(VoiceOrbParticles.radius(index: i) * radius * 2 * (0.8 + 0.4 * level), 0.4)
                let dot = Path(ellipseIn: CGRect(
                    x: point.x - pr, y: point.y - pr, width: pr * 2, height: pr * 2
                ))
                fields.fill(dot, with: .color(colors.core.opacity(min(particleAlpha, 1))))
            }
        }

        // Central intelligence core.
        let condense = snapshot.condensePulse
        let coreRadius = radius
            * (0.30 + 0.08 * level)
            * (1 - 0.22 * condense)
            * (1 + 0.05 * snapshot.errorPulse)
        let coreBrightness = min(
            config.coreBrightness
                * (1 + 0.45 * snapshot.outputLevel + 0.5 * condense)
                * (1 + 0.30 * snapshot.loadingProgress)
                + snapshot.errorPulse * 0.25,
            1
        ) * alphaScale
        if coreRadius > 1, coreBrightness > 0.01 {
            let coreGradient = Gradient(stops: [
                .init(color: colors.core.opacity(min(coreBrightness, 1)), location: 0),
                .init(color: colors.core.opacity(coreBrightness * 0.55), location: 0.45),
                .init(color: colors.energy.opacity(coreBrightness * 0.25), location: 0.75),
                .init(color: colors.energy.opacity(0), location: 1),
            ])
            let coreRect = CGRect(
                x: center.x - coreRadius, y: center.y - coreRadius,
                width: coreRadius * 2, height: coreRadius * 2
            )
            fields.fill(Path(ellipseIn: coreRect), with: .radialGradient(
                coreGradient, center: center, startRadius: 0, endRadius: coreRadius
            ))
        }

        // Error: one brief, restrained warm pulse (single decay, no flashing).
        if snapshot.errorPulse > 0.01 {
            let pulseGradient = Gradient(stops: [
                .init(color: colors.energy.opacity(snapshot.errorPulse * 0.30 * alphaScale), location: 0),
                .init(color: colors.energy.opacity(0), location: 1),
            ])
            fields.fill(circle, with: .radialGradient(
                pulseGradient, center: center, startRadius: 0, endRadius: radius
            ))
        }

        // Specular highlight near the upper edge (contained by the clip).
        let specWidth = radius * 0.95
        let specHeight = radius * 0.34
        let specCenter = CGPoint(x: center.x - radius * 0.12, y: center.y - radius * 0.58)
        let specAlpha = 0.5 * alphaScale * (0.6 + 0.4 * config.rimIntensity)
        let specGradient = Gradient(stops: [
            .init(color: colors.glassHighlight.opacity(specAlpha), location: 0),
            .init(color: colors.glassHighlight.opacity(0), location: 1),
        ])
        ctx.fill(Path(ellipseIn: CGRect(
            x: specCenter.x - specWidth / 2, y: specCenter.y - specHeight / 2,
            width: specWidth, height: specHeight
        )), with: .radialGradient(
            specGradient, center: specCenter, startRadius: 0, endRadius: specWidth / 2
        ))
    }

    // MARK: Shell surface

    public static func drawShell(
        context: inout GraphicsContext,
        size: CGSize,
        snapshot: VoiceOrbFrameSnapshot,
        colors: VoiceOrbBlendedPalette,
        quality: VoiceOrbRenderQuality
    ) {
        let config = snapshot.config
        let alphaScale = 1 - config.dimming

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let orbRadius = min(size.width, size.height) * 0.31
        let scale = snapshot.breathingScale * (1 + config.shellExpansion) * (1 - 0.05 * snapshot.interruptSettle)
        let radius = orbRadius * scale

        let ctx = context

        // Contact shadow: restrained, beneath the orb.
        let shadowAlpha = 0.30 * (1 - 0.35 * config.glow) * alphaScale
        if shadowAlpha > 0.01, quality != .reduced {
            let shadowCenter = CGPoint(x: center.x, y: center.y + radius * 1.22)
            let shadowGradient = Gradient(stops: [
                .init(color: colors.contactShadow.opacity(shadowAlpha), location: 0),
                .init(color: colors.contactShadow.opacity(0), location: 1),
            ])
            ctx.fill(Path(ellipseIn: CGRect(
                x: shadowCenter.x - radius * 0.62, y: shadowCenter.y - radius * 0.10,
                width: radius * 1.24, height: radius * 0.20
            )), with: .radialGradient(
                shadowGradient, center: shadowCenter, startRadius: 0, endRadius: radius * 0.62
            ))
        }

        // Atmospheric glow.
        let energyLevel = max(snapshot.micLevel, snapshot.outputLevel)
        let glowAlpha = config.glow * quality.glowMultiplier
            * (0.55 + 0.45 * energyLevel) * alphaScale
        if glowAlpha > 0.01 {
            let glowRadius = radius * (1.30 + 0.18 * config.glow + 0.06 * energyLevel)
            let glowGradient = Gradient(stops: [
                .init(color: colors.glow.opacity(min(glowAlpha, 1)), location: 0),
                .init(color: colors.glow.opacity(glowAlpha * 0.45), location: 0.55),
                .init(color: colors.glow.opacity(0), location: 1),
            ])
            ctx.fill(Path(ellipseIn: CGRect(
                x: center.x - glowRadius, y: center.y - glowRadius,
                width: glowRadius * 2, height: glowRadius * 2
            )), with: .radialGradient(
                glowGradient, center: center, startRadius: radius * 0.55, endRadius: glowRadius
            ))
        }

        guard alphaScale > 0.01 else { return }

        // Glass shell body sheen.
        let sheenGradient = Gradient(stops: [
            .init(color: colors.glassHighlight.opacity(0.14 * alphaScale), location: 0),
            .init(color: colors.glassHighlight.opacity(0.02 * alphaScale), location: 0.5),
            .init(color: colors.glassHighlight.opacity(0), location: 1),
        ])
        let circle = Path(ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))
        ctx.fill(circle, with: .linearGradient(
            sheenGradient,
            startPoint: CGPoint(x: center.x - radius * 0.5, y: center.y - radius),
            endPoint: CGPoint(x: center.x + radius * 0.3, y: center.y + radius)
        ))

        // Rim light: soft edge glow whose brightness tracks speech/energy.
        let rimAlpha = min(
            config.rimIntensity * (0.55 + 0.45 * energyLevel)
                * (1 + 0.6 * snapshot.speechActivity + 0.5 * snapshot.errorPulse)
                * alphaScale,
            1
        )
        if rimAlpha > 0.01 {
            let rimGradient = Gradient(stops: [
                .init(color: colors.rim.opacity(rimAlpha * 0.55), location: 0),
                .init(color: colors.rim.opacity(rimAlpha * 0.9), location: 0.82),
                .init(color: colors.rim.opacity(0), location: 1),
            ])
            ctx.stroke(circle, with: .radialGradient(
                rimGradient, center: center,
                startRadius: radius * 0.75, endRadius: radius * 1.02
            ), lineWidth: max(radius * 0.05, 1.5))
        }

        // Edge refraction: faint chromatic fringe, opposite offsets.
        if quality != .reduced {
            let fringe = ctx
            let fringeAlpha = 0.30 * alphaScale * (0.4 + 0.6 * config.rimIntensity)
            var coolArc = Path()
            coolArc.addArc(center: CGPoint(x: center.x - 1.3, y: center.y - 1.3),
                           radius: radius - 0.8,
                           startAngle: .radians(.pi * 1.05), endAngle: .radians(.pi * 1.55),
                           clockwise: false)
            fringe.stroke(coolArc, with: .color(colors.accent.opacity(fringeAlpha)),
                          lineWidth: 1.4)
            var warmArc = Path()
            warmArc.addArc(center: CGPoint(x: center.x + 1.3, y: center.y + 1.3),
                           radius: radius - 0.8,
                           startAngle: .radians(.pi * 0.05), endAngle: .radians(.pi * 0.55),
                           clockwise: false)
            fringe.stroke(warmArc, with: .color(colors.energySecondary.opacity(fringeAlpha * 0.8)),
                          lineWidth: 1.4)
        }

        // Crisp glass edge.
        let edgeAlpha = (0.35 + 0.35 * config.rimIntensity) * alphaScale
        let edgeGradient = Gradient(stops: [
            .init(color: colors.glassHighlight.opacity(edgeAlpha), location: 0),
            .init(color: colors.rim.opacity(edgeAlpha * 0.35), location: 0.5),
            .init(color: colors.rim.opacity(edgeAlpha * 0.15), location: 1),
        ])
        ctx.stroke(circle, with: .linearGradient(
            edgeGradient,
            startPoint: CGPoint(x: center.x, y: center.y - radius),
            endPoint: CGPoint(x: center.x, y: center.y + radius)
        ), lineWidth: max(min(size.width, size.height) * 0.006, 1))

        // Preparing: light travelling around the circumference + progress.
        if config.progressGlow > 0.01 {
            let spin = snapshot.reducedMotion ? 0.0 : snapshot.time * 0.9
            let travelGradient = Gradient(stops: [
                .init(color: colors.rim.opacity(0), location: 0),
                .init(color: colors.rim.opacity(0.65 * config.progressGlow * alphaScale), location: 0.12),
                .init(color: colors.rim.opacity(0), location: 0.28),
                .init(color: colors.rim.opacity(0), location: 1),
            ])
            ctx.stroke(circle, with: .conicGradient(
                travelGradient, center: center, angle: .radians(spin)
            ), lineWidth: max(radius * 0.035, 2))

            // Integrated progress arc along the surface (never a spinner).
            let progress = snapshot.loadingProgress
            if progress > 0.005 {
                var arc = Path()
                arc.addArc(center: center, radius: radius * 0.985,
                           startAngle: .radians(-.pi / 2),
                           endAngle: .radians(-.pi / 2 + 2 * .pi * progress),
                           clockwise: false)
                ctx.stroke(arc, with: .color(colors.core.opacity(0.85 * alphaScale)),
                           style: StrokeStyle(lineWidth: max(radius * 0.02, 1.5), lineCap: .round))
            }
        }
    }

    // MARK: Field geometry

    /// Closed polar curve for an energy field. Fixed 72 segments; the path
    /// is built by appending (no intermediate point arrays).
    private static func fieldPath(
        field: VoiceOrbEnergyField,
        center: CGPoint,
        radius: Double,
        time: Double,
        level: Double,
        deformation: Double,
        inwardPull: Double,
        wave: Double
    ) -> Path {
        let steps = 72
        let fieldRotation = time * field.rotationSpeed
        let baseR = radius * field.baseRadius

        var path = Path()
        for i in 0...steps {
            let theta = 2 * Double.pi * Double(i) / Double(steps) + fieldRotation
            let offset = field.radiusOffset(
                theta: theta, t: time,
                level: level, deformation: deformation,
                inwardPull: inwardPull, wave: wave
            )
            let r = baseR * (1 + offset)
            let point = CGPoint(
                x: center.x + r * cos(theta),
                y: center.y + r * sin(theta)
            )
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    private static func fract(_ x: Double) -> Double { x - x.rounded(.down) }
}
