import SwiftUI

// MARK: - First-light splash
//
// The app icon is a glass eye, so launch is staged as the eye waking in a
// dark room: a aperture ring of light sweeps around the lens, the brand
// aurora (pink / teal / lavender — the LiquidPinkBackdrop palette) drifts
// behind it, and a field of faint particles rises like dust catching light.
// A hairline beam at the bottom tracks the dwell and hands off to Home.
//
// Motion notes:
//   • Everything continuous runs off one TimelineView clock; entrance
//     choreography is three staggered @State transitions (logo, wordmark,
//     beam) so the whole sequence stays interruptible and cheap.
//   • Reduce Motion skips the particle/aurora/ring clocks and the entrance
//     springs, shows the settled composition, and shortens the dwell.

struct FirstLightSplashView: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var logoIn = false
    @State private var textIn = false
    @State private var glintProgress: CGFloat = 0
    @State private var beam: CGFloat = 0
    /// The choreography must not start until the splash has actually
    /// presented a frame: heavy first-launch work (dylibs, crash reporter,
    /// first layout) can delay rendering well past `.task`/`onAppear`, which
    /// otherwise lets the whole sequence play behind the system launch
    /// screen. The probe fires on the second display refresh after this
    /// view joins a visible window.
    @State private var sequenceStarted = false

    // Brand aurora palette, shared with LiquidPinkBackdrop.
    private let pink = Color(red: 1.00, green: 0.55, blue: 0.70)
    private let teal = Color(red: 0.42, green: 0.78, blue: 0.72)
    private let lavender = Color(red: 0.72, green: 0.62, blue: 0.96)

    var body: some View {
        GeometryReader { proxy in
            let logoSize = min(proxy.size.width * 0.44, 200)

            ZStack {
                baseGradient

                if !reduceMotion {
                    // The decorative layers are deliberately wider than the
                    // screen (blooms bleed past both edges), so their frames
                    // must not be allowed to size this ZStack. GeometryReader
                    // places its content at the top-leading corner, so an
                    // over-wide ZStack hangs off the right edge and every
                    // centred sibling shifts right by half the overflow —
                    // the aurora's 1.25 × width bloom pushed the lens, the
                    // wordmark and the dwell beam 55 pt off-centre on a 6.9"
                    // phone. Pinning the layer stack to the screen keeps the
                    // bleed while the layout stays centred.
                    ZStack {
                        auroraField(in: proxy.size)
                        particleField(in: proxy.size)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }

                VStack(spacing: 0) {
                    Spacer(minLength: 20)

                    lensAssembly(logoSize: logoSize)
                        .padding(.bottom, 34)

                    wordmark

                    Spacer(minLength: 20)

                    footer
                        .padding(.bottom, 40)
                }
                .padding(.horizontal, 28)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .accessibilityHidden(true)
        .background(
            FirstFrameProbe {
                guard !sequenceStarted else { return }
                sequenceStarted = true
                Task { await runSequence() }
            }
        )
        // Fallback: if the probe somehow never draws (previews, extreme
        // launch failure), start on a generous timer so the app can never
        // strand on the splash. Eight seconds keeps it behind the probe on
        // even the slowest cold starts.
        .task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, !sequenceStarted else { return }
            sequenceStarted = true
            await runSequence()
        }
    }

    // MARK: - Background

    private var baseGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.030, green: 0.026, blue: 0.047),
                Color(red: 0.055, green: 0.043, blue: 0.086),
                Color(red: 0.028, green: 0.024, blue: 0.044)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Three heavily blurred blooms drifting on slow, incommensurate orbits
    /// so the backdrop never visibly repeats during the short dwell.
    private func auroraField(in size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSince1970
            ZStack {
                Ellipse()
                    .fill(pink.opacity(0.30))
                    .frame(width: size.width * 1.15, height: size.width * 0.9)
                    .blur(radius: 70)
                    .offset(
                        x: -size.width * 0.30 + sin(t * 0.23) * size.width * 0.08,
                        y: -size.height * 0.30 + cos(t * 0.19) * 22
                    )

                Ellipse()
                    .fill(teal.opacity(0.22))
                    .frame(width: size.width * 0.95, height: size.width * 0.75)
                    .blur(radius: 80)
                    .offset(
                        x: size.width * 0.34 + cos(t * 0.17) * size.width * 0.07,
                        y: size.height * 0.06 + sin(t * 0.29) * 26
                    )

                Ellipse()
                    .fill(lavender.opacity(0.26))
                    .frame(width: size.width * 1.25, height: size.height * 0.30)
                    .rotationEffect(.degrees(-16))
                    .blur(radius: 90)
                    .offset(
                        x: size.width * 0.10 + sin(t * 0.13) * size.width * 0.06,
                        y: size.height * 0.42 + cos(t * 0.21) * 18
                    )
            }
        }
        .allowsHitTesting(false)
    }

    /// Faint dust rising through the light. Positions come from a fixed
    /// deterministic field; the timeline only drifts and twinkles them.
    private func particleField(in size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSince1970
            Canvas { ctx, _ in
                for p in SplashDust.field {
                    let rise = (p.y - t * p.speed)
                    let wrappedY = rise - floor(rise)            // 0…1, wraps at top
                    let sway = sin(t * p.swayRate + p.phase) * 0.012
                    let x = (p.x + sway) * size.width
                    let y = wrappedY * size.height
                    let twinkle = 0.5 + 0.5 * sin(t * p.twinkleRate + p.phase)
                    let alpha = (0.10 + 0.50 * twinkle) * p.strength
                    let r = p.radius * (0.8 + 0.4 * twinkle)
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    ctx.fill(
                        Path(ellipseIn: rect),
                        with: .color(.white.opacity(alpha))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Lens assembly (logo + aperture rings + glint)

    private func lensAssembly(logoSize: CGFloat) -> some View {
        ZStack {
            // Halo behind the lens, breathing in with the entrance.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [lavender.opacity(0.55), pink.opacity(0.18), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: logoSize * 0.95
                    )
                )
                .frame(width: logoSize * 1.9, height: logoSize * 1.9)
                .blur(radius: 18)
                .opacity(logoIn ? 1 : 0)
                .scaleEffect(logoIn ? 1 : 0.6)

            if !reduceMotion {
                apertureRings(logoSize: logoSize)
            }

            Image("app_logo_small")
                .resizable()
                .scaledToFit()
                .frame(width: logoSize, height: logoSize)
                .clipShape(RoundedRectangle(cornerRadius: logoSize * 0.235, style: .continuous))
                .overlay {
                    // One slow glint sweeping the glass as the eye opens.
                    // The sweep is clipped to the lens shape and fades in/out
                    // along its path (sinusoidal envelope), so no stray slab
                    // ever appears outside the icon.
                    GeometryReader { g in
                        let w = g.size.width
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.5), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: w * 0.42)
                            .offset(x: -w * 0.55 + glintProgress * w * 1.65)
                            .opacity(sin(glintProgress * CGFloat.pi))
                            .blendMode(.screen)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: logoSize * 0.235, style: .continuous))
                }
                .shadow(color: pink.opacity(0.35), radius: 26, y: 10)
                .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
                .scaleEffect(logoIn ? 1 : 0.80)
                .blur(radius: logoIn ? 0 : 12)
                .opacity(logoIn ? 1 : 0)
        }
    }

    /// Two hairline arcs of light counter-rotating around the lens, like an
    /// aperture finding focus. Trimmed circles on an angular gradient so the
    /// arc tails fade instead of cutting.
    private func apertureRings(logoSize: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSince1970
            ZStack {
                Circle()
                    .trim(from: 0.05, to: 0.55)
                    .stroke(
                        AngularGradient(
                            colors: [.clear, .white.opacity(0.85), .clear],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: 1.3, lineCap: .round)
                    )
                    .frame(width: logoSize * 1.30, height: logoSize * 1.30)
                    .rotationEffect(.degrees(t * 42))

                Circle()
                    .trim(from: 0.60, to: 0.86)
                    .stroke(
                        AngularGradient(
                            colors: [.clear, teal.opacity(0.75), .clear],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: 1.0, lineCap: .round)
                    )
                    .frame(width: logoSize * 1.46, height: logoSize * 1.46)
                    .rotationEffect(.degrees(-t * 27))
            }
            .opacity(logoIn ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Wordmark

    private var wordmark: some View {
        VStack(spacing: 14) {
            Text("iOS Local LLM")
                .font(.system(size: 31, weight: .semibold))
                // Tracking settles from wide to tight as the name lands —
                // reads as focus being pulled, matching the lens motif.
                .tracking(textIn ? -0.6 : 7)
                .foregroundStyle(.white.opacity(0.96))

            if reduceMotion {
                caption(baseOpacity: 0.42)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSince1970
                    // A soft light sweeping across the caption, forever.
                    let sweep = (t * 0.45).truncatingRemainder(dividingBy: 1.6) - 0.3
                    caption(baseOpacity: 0.34)
                        .foregroundStyle(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.34), location: 0),
                                    .init(color: .white.opacity(0.34), location: max(0, sweep - 0.18)),
                                    .init(color: .white.opacity(0.95), location: min(1, max(0, sweep))),
                                    .init(color: .white.opacity(0.34), location: min(1, sweep + 0.18)),
                                    .init(color: .white.opacity(0.34), location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            }
        }
        .opacity(textIn ? 1 : 0)
        .offset(y: textIn ? 0 : 12)
    }

    private func caption(baseOpacity: Double) -> Text {
        Text("LOCAL AI WORKBENCH")
            .font(.caption.monospaced())
            .tracking(3.2)
            .foregroundStyle(.white.opacity(baseOpacity))
    }

    // MARK: - Footer (privacy line + dwell beam)

    private var footer: some View {
        VStack(spacing: 18) {
            Text("Private. On your device.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.45))
                .opacity(textIn ? 1 : 0)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.10))
                    .frame(width: 148, height: 2.5)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [teal, lavender, pink],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(2.5, 148 * beam), height: 2.5)
                    .shadow(color: pink.opacity(0.8), radius: 6)
            }
            .frame(width: 148, alignment: .leading)
            .opacity(textIn ? 1 : 0)
        }
    }

    // MARK: - Sequence

    private func runSequence() async {
        if reduceMotion {
            logoIn = true
            textIn = true
            beam = 1
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            onFinished()
            return
        }

        withAnimation(.spring(response: 0.72, dampingFraction: 0.76)) {
            logoIn = true
        }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }

        withAnimation(.easeOut(duration: 0.62)) {
            textIn = true
        }
        withAnimation(.timingCurve(0.25, 0.6, 0.3, 1.0, duration: 1.9)) {
            beam = 1
        }
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled else { return }

        // Single glint across the glass as the sequence resolves.
        withAnimation(.timingCurve(0.4, 0.0, 0.6, 1.0, duration: 0.95)) {
            glintProgress = 1
        }
        try? await Task.sleep(for: .milliseconds(1050))
        guard !Task.isCancelled else { return }

        onFinished()
    }
}

// MARK: - Deterministic dust field

/// Fixed pseudo-random particle layout (hashed indices, no RNG state) so the
/// field is identical on every launch and costs nothing to allocate.
private struct SplashDust {
    let x: CGFloat          // 0…1 horizontal anchor
    let y: CGFloat          // 0…1 vertical start
    let radius: CGFloat     // pt
    let speed: CGFloat      // fraction of screen height per second
    let phase: CGFloat      // radians, decorrelates twinkle/sway
    let swayRate: CGFloat
    let twinkleRate: CGFloat
    let strength: CGFloat   // 0…1 alpha ceiling

    private static func hash(_ n: Int) -> CGFloat {
        var x = UInt64(bitPattern: Int64(n &* 2654435761 &+ 1013904223))
        x ^= x >> 13
        x &*= 0x5DEECE66D
        x ^= x >> 17
        return CGFloat(x & 0xFFFF) / CGFloat(0xFFFF)
    }

    static let field: [SplashDust] = (0 ..< 44).map { i in
        SplashDust(
            x: hash(i * 7 + 1),
            y: hash(i * 7 + 2),
            radius: 0.7 + hash(i * 7 + 3) * 1.5,
            speed: 0.010 + hash(i * 7 + 4) * 0.030,
            phase: hash(i * 7 + 5) * .pi * 2,
            swayRate: 0.4 + hash(i * 7 + 6) * 0.8,
            twinkleRate: 1.1 + hash(i * 7 + 7) * 1.9,
            strength: 0.35 + hash(i * 7 + 8) * 0.65
        )
    }
}

#Preview {
    FirstLightSplashView(onFinished: {})
}

// MARK: - First-frame probe

/// Zero-size UIView that reports once its window has presented two display
/// refreshes with this view attached — i.e. the splash is genuinely on
/// screen. Used to start the choreography only when it can be seen.
private struct FirstFrameProbe: UIViewRepresentable {
    let onRendered: () -> Void

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(onRendered: onRendered)
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        private let onRendered: () -> Void
        private var fired = false

        init(onRendered: @escaping () -> Void) {
            self.onRendered = onRendered
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            contentMode = .redraw
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // Zero-size backgrounds are skipped by the render pass; force a
            // real draw so draw(_:) fires during the app's first committed
            // frame — the same render pass that dismisses the system launch
            // screen. didMoveToWindow/CADisplayLink both fire earlier, while
            // the launch image is still covering the UI.
            isOpaque = false
            setNeedsDisplay()
        }

        override func draw(_ rect: CGRect) {
            guard !fired else { return }
            fired = true
            // Let this render pass commit (and the launch screen drop)
            // before the choreography clock starts.
            DispatchQueue.main.async { [onRendered] in onRendered() }
        }
    }
}
