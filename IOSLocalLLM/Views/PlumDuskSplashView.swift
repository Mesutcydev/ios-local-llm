import SwiftUI

struct PlumDuskSplashView: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date.now

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { context in
            SplashFrame(
                time: reduceMotion
                    ? 6.0
                    : min(7.0, context.date.timeIntervalSince(startDate))
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(true)
        .task(id: reduceMotion) {
            let duration = reduceMotion ? 1.2 : 7.0
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            onFinished()
        }
        .accessibilityHidden(true)
    }
}

private struct SplashFrame: View {
    let time: Double

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let lift = SplashMotion.animate(time, from: 3.6, to: 4.4, easing: SplashMotion.easeInOutCubic)
            let titleIn = SplashMotion.animate(time, from: 3.9, to: 4.5, easing: SplashMotion.easeOutCubic)
            let subtitleIn = SplashMotion.animate(time, from: 4.25, to: 4.85, easing: SplashMotion.easeOutCubic)
            let taglineIn = SplashMotion.animate(time, from: 5.0, to: 5.7, easing: SplashMotion.easeOutCubic)
            let eyeWidth = size.width * (620.0 / 1080.0)
            let eyeHeight = eyeWidth * 0.6
            let logoTop = size.height * CGFloat((830.0 - lift * 210.0) / 1920.0)
            let logoScale = CGFloat(1.0 - lift * 0.14)
            let glowIn = SplashMotion.animate(time, from: 0.4, to: 1.6, easing: SplashMotion.easeOutQuad)
            let glowSize = size.width * CGFloat((620.0 + sin(time * 1.3) * 40.0) / 1080.0)

            ZStack {
                SplashPalette.plum
                RadialGradient(
                    colors: [
                        SplashPalette.roseTop,
                        SplashPalette.roseMid,
                        SplashPalette.deepMid,
                        SplashPalette.plum,
                    ],
                    center: UnitPoint(x: 0.5, y: -0.08),
                    startRadius: 0,
                    endRadius: size.height * 1.08
                )

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.14), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: glowSize * 0.5
                        )
                    )
                    .frame(width: glowSize, height: glowSize)
                    .opacity(glowIn)
                    .position(x: size.width * 0.5, y: logoTop + size.height * (120.0 / 1920.0))

                AnimatedEyeMark(time: time)
                    .frame(width: eyeWidth, height: eyeHeight)
                    .scaleEffect(logoScale, anchor: .top)
                    .position(x: size.width * 0.5, y: logoTop + eyeHeight * 0.5)

                Text("iOS Local LLM")
                    .font(.system(size: size.width * (96.0 / 1080.0), weight: .semibold))
                    .tracking(-0.7)
                    .foregroundStyle(.white)
                    .opacity(titleIn)
                    .offset(y: CGFloat((1.0 - titleIn) * 13.0))
                    .position(x: size.width * 0.5, y: size.height * (1135.0 / 1920.0))

                Text("LOCAL AI WORKBENCH")
                    .font(.system(size: size.width * (40.0 / 1080.0), weight: .regular, design: .monospaced))
                    .tracking(size.width * (12.8 / 1080.0))
                    .foregroundStyle(.white.opacity(0.78))
                    .opacity(subtitleIn)
                    .offset(y: CGFloat((1.0 - subtitleIn) * 9.0))
                    .position(x: size.width * 0.5, y: size.height * (1250.0 / 1920.0))

                Text("Private. No account. No cloud.")
                    .font(.system(size: size.width * (30.0 / 1080.0), weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .opacity(taglineIn)
                    .position(x: size.width * 0.5, y: size.height * (1680.0 / 1920.0))
            }
        }
    }
}

private struct AnimatedEyeMark: View {
    let time: Double

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let draw = SplashMotion.animate(time, from: 0.15, to: 1.15, easing: SplashMotion.easeInOutCubic)
            let pop = SplashMotion.animate(time, from: 1.05, to: 1.55, easing: SplashMotion.easeOutBack)
            let look = SplashMotion.interpolate(
                time,
                times: [1.7, 2.05, 2.35, 2.65, 3.0],
                values: [0, -13, -13, 13, 0],
                easing: SplashMotion.easeInOutCubic
            )
            let fullBlink = SplashMotion.interpolate(
                time,
                times: [3.13, 3.28, 3.34, 3.52],
                values: [0, 1, 1, 0],
                easing: SplashMotion.easeInOutQuad
            )
            let halfBlink = SplashMotion.interpolate(
                time,
                times: [6.2, 6.32, 6.38, 6.52],
                values: [0, 0.55, 0.55, 0],
                easing: SplashMotion.easeInOutQuad
            )
            let blink = max(fullBlink, halfBlink)
            let idle = 1.0 + sin(time * 1.7) * 0.008

            ZStack {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.969, green: 0.937, blue: 0.957))
                        .overlay(Circle().stroke(SplashPalette.plum.opacity(0.18), lineWidth: 1.5))
                        .frame(width: size.width * 0.36, height: size.width * 0.36)
                        .position(
                            x: size.width * CGFloat((100.0 + look * 0.25) / 200.0),
                            y: size.height * (58.0 / 120.0)
                        )

                    Circle()
                        .fill(Color(red: 0.125, green: 0.012, blue: 0.059))
                        .frame(width: size.width * 0.17, height: size.width * 0.17)
                        .position(
                            x: size.width * CGFloat((100.0 + look * 1.25) / 200.0),
                            y: size.height * (58.0 / 120.0)
                        )

                    Circle()
                        .fill(.white)
                        .frame(width: size.width * 0.045, height: size.width * 0.045)
                        .position(
                            x: size.width * CGFloat((93.0 + look * 1.25) / 200.0),
                            y: size.height * (51.0 / 120.0)
                        )
                }
                .scaleEffect(CGFloat(pop))
                .clipShape(EyeLidShape(blink: blink))

                EyeLidShape(blink: blink)
                    .trim(from: 0, to: CGFloat(draw))
                    .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            .scaleEffect(CGFloat(idle))
        }
    }
}

private struct EyeLidShape: Shape {
    var blink: Double

    var animatableData: Double {
        get { blink }
        set { blink = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let topY = -8.0 + (58.0 + 8.0) * blink
        let bottomY = 128.0 + (58.0 - 128.0) * blink
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.width * CGFloat(x / 200.0), y: rect.height * CGFloat(y / 120.0))
        }

        var path = Path()
        path.move(to: point(12, 58))
        path.addQuadCurve(to: point(188, 58), control: point(100, topY))
        path.addQuadCurve(to: point(12, 58), control: point(100, bottomY))
        return path
    }
}

private enum SplashMotion {
    static func animate(
        _ time: Double,
        from start: Double,
        to end: Double,
        easing: (Double) -> Double
    ) -> Double {
        easing(min(1, max(0, (time - start) / (end - start))))
    }

    static func interpolate(
        _ time: Double,
        times: [Double],
        values: [Double],
        easing: (Double) -> Double
    ) -> Double {
        guard let firstTime = times.first, let firstValue = values.first else { return 0 }
        if time <= firstTime { return firstValue }
        guard let lastTime = times.last, let lastValue = values.last, time < lastTime else {
            return values.last ?? 0
        }

        for index in 0..<(times.count - 1) where time <= times[index + 1] {
            let progress = (time - times[index]) / (times[index + 1] - times[index])
            let eased = easing(progress)
            return values[index] + (values[index + 1] - values[index]) * eased
        }
        return lastValue
    }

    static func easeInOutCubic(_ value: Double) -> Double {
        value < 0.5 ? 4 * value * value * value : 1 - pow(-2 * value + 2, 3) / 2
    }

    static func easeOutCubic(_ value: Double) -> Double { 1 - pow(1 - value, 3) }
    static func easeOutQuad(_ value: Double) -> Double { 1 - (1 - value) * (1 - value) }
    static func easeInOutQuad(_ value: Double) -> Double {
        value < 0.5 ? 2 * value * value : 1 - pow(-2 * value + 2, 2) / 2
    }

    static func easeOutBack(_ value: Double) -> Double {
        let c1 = 1.70158
        let c3 = c1 + 1
        return 1 + c3 * pow(value - 1, 3) + c1 * pow(value - 1, 2)
    }
}

private enum SplashPalette {
    static let roseTop = Color(red: 0.886, green: 0.227, blue: 0.612)
    static let roseMid = Color(red: 0.769, green: 0.122, blue: 0.494)
    static let deepMid = Color(red: 0.635, green: 0.071, blue: 0.400)
    static let plum = Color(red: 0.486, green: 0.043, blue: 0.306)
}
