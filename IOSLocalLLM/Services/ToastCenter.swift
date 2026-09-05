import SwiftUI

// MARK: - ToastCenter
// Global non-blocking notification surface for transient messages — errors,
// successes, info. Single in-flight toast at a time; new toasts replace.
//
// Usage:
//   ToastCenter.shared.error("FastVLM failed to load", detail: error.localizedDescription)
//   ToastCenter.shared.success("Model downloaded")
//   ToastCenter.shared.info("Read aloud paused")

@MainActor
final class ToastCenter: ObservableObject {

    static let shared = ToastCenter()

    @Published private(set) var current: Toast?
    /// Extra top spacing selected by the active root surface. Custom-header
    /// tabs leave a notification lane immediately below the status bar,
    /// whereas NavigationStack screens need room for the navigation bar.
    @Published private(set) var topPadding: CGFloat = 52

    private var dismissTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    func error(_ title: String, detail: String? = nil, duration: Double = 5.0) {
        show(Toast(kind: .error, title: title, detail: detail, duration: duration))
    }

    func success(_ title: String, detail: String? = nil, duration: Double = 2.5) {
        show(Toast(kind: .success, title: title, detail: detail, duration: duration))
    }

    func info(_ title: String, detail: String? = nil, duration: Double = 3.0) {
        show(Toast(kind: .info, title: title, detail: detail, duration: duration))
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        withAnimation(.easeOut(duration: 0.18)) { current = nil }
    }

    func setTopPadding(_ padding: CGFloat) {
        topPadding = padding
    }

    // MARK: - Private

    private func show(_ toast: Toast) {
        dismissTask?.cancel()
        // Kind-specific haptic. Errors get the system error notification
        // (double-tap), successes get the success cadence, info uses a
        // soft selection tap. The previous one-size-fits-all medium
        // impact made every toast feel equally urgent.
        switch toast.kind {
        case .error:   HapticManager.error()
        case .success: HapticManager.analysisComplete()
        case .info:    HapticManager.selection()
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            current = toast
        }
        dismissTask = Task { [duration = toast.duration] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled {
                await MainActor.run { self.dismiss() }
            }
        }
    }
}

// MARK: - Toast

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String?
    let duration: Double

    enum Kind { case error, success, info }
}

// MARK: - ToastOverlayView
// Mount once at the app root; consumes ToastCenter.shared.current and
// renders a Studio-styled banner anchored to the top.

struct ToastOverlayView: View {
    @ObservedObject private var center = ToastCenter.shared
    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack {
            if let toast = center.current {
                ToastBanner(toast: toast)
                    .padding(.horizontal, 14)
                    // The overlay is mounted at the window root, above every
                    // NavigationStack. The safe area clears the status bar but
                    // not the navigation bar, so an 8-point inset placed the
                    // banner directly on top of titles and toolbar buttons.
                    // Reserve one standard navigation-bar row everywhere.
                    .padding(.top, center.topPadding)
                    // Material-style focus pull on entry (slide + blur),
                    // soft dissolve on exit. AnyTransition is the older
                    // call-site for asymmetric — the protocol-based
                    // `Transition` type added in iOS 17 doesn't expose
                    // an .asymmetric helper, so we route through
                    // AnyTransition + .move/.opacity which work back to
                    // iOS 15.
                    .transition(
                        .asymmetric(
                            insertion: AnyTransition.move(edge: .top).combined(with: .opacity),
                            removal:   AnyTransition.opacity
                        )
                    )
                    .zIndex(9999)
                    .onTapGesture { center.dismiss() }
            }
            Spacer()
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: center.current)
        .allowsHitTesting(center.current != nil)
    }
}

// MARK: - ToastBanner

struct ToastBanner: View {
    let toast: Toast
    @Environment(\.koduTheme) private var T

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // SF Symbol with kind-specific symbolEffect. Errors wiggle on
            // appear (calls attention without the alarm-bell feel of a red
            // banner), successes bounce, info pulses gently.
            symbolView
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(T.mono(12, .semibold))
                    .foregroundColor(T.ink)
                    .lineLimit(2)
                if let detail = toast.detail, !detail.isEmpty {
                    Text(detail)
                        .font(T.sans(11))
                        .foregroundColor(T.ink2)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 6)

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Liquid Glass is deliberately translucent, but dense status rows
        // immediately beneath an error banner become readable through it and
        // visually collide with the toast copy. Give the notification its own
        // nearly-opaque reading surface before applying the glass treatment.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(T.surface.opacity(0.96))
        )
        .kGlass(cornerRadius: 10, fallbackFill: T.surface, fallbackStroke: T.rule)
        .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(glyphColor)
                .frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
    }

    private var symbolName: String {
        switch toast.kind {
        case .error:   return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    /// Glyph with the right symbolEffect baked in per kind. @ViewBuilder
    /// so each branch can apply a different modifier — the .wiggle and
    /// .bounce signatures take different effect types and can't be
    /// flattened to a single chain at the call site.
    @ViewBuilder
    private var symbolView: some View {
        let base = Image(systemName: symbolName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(glyphColor)
        switch toast.kind {
        case .error:
            base.symbolEffect(.wiggle, options: .nonRepeating, value: toast.id)
        case .success:
            base.symbolEffect(.bounce, options: .nonRepeating, value: toast.id)
        case .info:
            base.symbolEffect(.pulse, options: .nonRepeating, value: toast.id)
        }
    }

    private var glyphColor: Color {
        switch toast.kind {
        case .error:   return T.bad
        case .success: return T.good
        case .info:    return T.accent
        }
    }
}

// MARK: - ConfettiCenter
//
// One-shot celebratory particle burst, called for moments worth marking:
// completed downloads, first-time setup finish, etc. Lives in the toast
// file because it's another transient UI event surface — mounted at the
// app root alongside ToastOverlayView.
//
// Usage:
//   ConfettiCenter.shared.burst()
//
// Reuse-safe: each call replaces the previous burst id, and the overlay
// keys its child view on that id so the new burst kicks the animation
// from t=0 rather than continuing an in-progress one.

@MainActor
final class ConfettiCenter: ObservableObject {
    static let shared = ConfettiCenter()

    @Published var burstID: UUID?

    private var clearTask: Task<Void, Never>?
    private init() {}

    /// Fire a confetti burst. Auto-clears after ~2.5s. Subsequent calls
    /// within that window restart the animation with a fresh id.
    func burst() {
        clearTask?.cancel()
        burstID = UUID()
        clearTask = Task { [id = burstID] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    // Only clear if WE'RE still the active burst — a newer
                    // call would have already replaced burstID, and we
                    // shouldn't blow it away on a stale timer.
                    if self.burstID == id { self.burstID = nil }
                }
            }
        }
    }
}

// MARK: - ConfettiOverlayView

struct ConfettiOverlayView: View {
    @ObservedObject private var center = ConfettiCenter.shared

    var body: some View {
        ZStack {
            if let id = center.burstID {
                ConfettiBurstView(seed: id)
                    .id(id)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - ConfettiBurstView
//
// A single burst's worth of particles. 36 confetti pieces spawn from the
// top half of the screen with randomised colour (rose / peach / accent),
// fall under simulated gravity with horizontal drift, and rotate as they
// go. The whole thing renders in a TimelineView so we avoid the cost of
// 36 separate @State animations.

private struct ConfettiBurstView: View {
    let seed: UUID
    @Environment(\.koduTheme) private var T

    private struct Particle {
        let x0: CGFloat            // horizontal start (unit space 0...1)
        let y0: CGFloat            // vertical start (unit space, negative = above screen)
        let drift: CGFloat         // horizontal drift over the fall
        let rotation0: Double      // initial rotation in degrees
        let rotationRate: Double   // degrees/sec
        let size: CGFloat
        let aspect: CGFloat
        let hue: Int               // 0 = roseHi, 1 = accent, 2 = peach
        let duration: Double       // total flight time
        let delay: Double          // staggered start
    }

    private let particles: [Particle]

    init(seed: UUID) {
        self.seed = seed
        // Deterministic RNG seeded by the burst id so the layout is
        // consistent within one burst (a re-render mid-flight produces
        // the same particles), but different across bursts.
        var rng = SystemRandomNumberGenerator()
        var arr: [Particle] = []
        arr.reserveCapacity(36)
        for _ in 0..<36 {
            arr.append(Particle(
                x0: CGFloat.random(in: 0.05...0.95, using: &rng),
                y0: CGFloat.random(in: (-0.20)...(-0.02), using: &rng),
                drift: CGFloat.random(in: -0.18...0.18, using: &rng),
                rotation0: Double.random(in: 0...360, using: &rng),
                rotationRate: Double.random(in: -180...180, using: &rng),
                size: CGFloat.random(in: 6...11, using: &rng),
                aspect: CGFloat.random(in: 0.5...1.6, using: &rng),
                hue: Int.random(in: 0...2, using: &rng),
                duration: Double.random(in: 1.4...2.2, using: &rng),
                delay: Double.random(in: 0...0.25, using: &rng)
            ))
        }
        self.particles = arr
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                // Seconds since the view appeared, derived from the
                // timeline's date and an @State origin set on first tick.
                // Using TimelineView avoids 36 separate spring/keyframe
                // animations and keeps the simulation closed-form.
                Canvas { ctx, size in
                    let now = context.date.timeIntervalSinceReferenceDate
                    if Self.origin < 0 { Self.origin = now }
                    let elapsed = now - Self.origin
                    for p in particles {
                        let t = (elapsed - p.delay) / p.duration
                        guard t >= 0 else { continue }
                        // Allow t > 1 to drift offscreen; we just clamp at
                        // 1.2 to bound the rotation accumulation and avoid
                        // unbounded angle math.
                        let tt = min(t, 1.2)
                        // Quadratic ease-in vertical (gravity), linear
                        // horizontal drift. y goes from y0 → 1.15
                        // (well past the bottom), x from x0 → x0+drift.
                        let progress = tt * tt
                        let yUnit = p.y0 + (1.15 - p.y0) * CGFloat(progress)
                        let xUnit = p.x0 + p.drift * CGFloat(tt)
                        let x = xUnit * size.width
                        let y = yUnit * size.height
                        let rot = p.rotation0 + p.rotationRate * tt
                        let rect = CGRect(
                            x: -p.size / 2,
                            y: -(p.size * p.aspect) / 2,
                            width: p.size,
                            height: p.size * p.aspect
                        )
                        // Fade out in the last third of the flight so
                        // particles don't pop off-screen at full opacity.
                        let alpha = tt < 0.75 ? 1.0 : max(0, 1 - (tt - 0.75) / 0.45)

                        var copy = ctx
                        copy.translateBy(x: x, y: y)
                        copy.rotate(by: .degrees(rot))
                        copy.opacity = alpha
                        copy.fill(
                            Path(roundedRect: rect, cornerSize: CGSize(width: 1.5, height: 1.5)),
                            with: .color(color(for: p.hue))
                        )
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    /// Frame-zero origin captured the first time the canvas ticks. Static
    /// because Canvas + TimelineView can't easily hold per-instance @State
    /// across redraws without re-rendering the whole tree. Reset on each
    /// new view (each `id:` change rebuilds the struct).
    private static var origin: TimeInterval = -1

    private func color(for hue: Int) -> Color {
        switch hue {
        case 0:  return T.roseHi
        case 1:  return T.accent
        default: return Color(red: 1.0, green: 0.78, blue: 0.67)   // peach
        }
    }
}
