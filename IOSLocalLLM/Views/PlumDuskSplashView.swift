import SwiftUI

/// Uses the same artwork as the home-screen icon. Keep startup brief and let
/// SwiftUI render the entrance once instead of redrawing a decorative timeline.
struct PlumDuskSplashView: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color("LaunchBackground")
                RadialGradient(
                    colors: [.white.opacity(0.75), .clear],
                    center: UnitPoint(x: 0.5, y: 0.35),
                    startRadius: 20,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.7
                )

                VStack(spacing: 24) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: min(proxy.size.width * 0.46, 200))
                        .clipShape(RoundedRectangle(cornerRadius: min(proxy.size.width * 0.046, 20)))
                        .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
                        .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Text("OnDevice Core")
                            .font(.system(.largeTitle, design: .default, weight: .semibold))
                            .tracking(-0.7)
                            .foregroundStyle(Color(white: 0.16))
                        Text("LOCAL AI STUDIO")
                            .font(.system(.caption, design: .monospaced, weight: .medium))
                            .tracking(3)
                            .foregroundStyle(Color(white: 0.38))
                    }
                    .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .opacity(isVisible ? 1 : 0)
                .offset(y: reduceMotion || isVisible ? 0 : 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .task {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) {
                isVisible = true
            }
            do { try await Task.sleep(for: .seconds(reduceMotion ? 0.4 : 1.2)) }
            catch { return }
            onFinished()
        }
    }
}
