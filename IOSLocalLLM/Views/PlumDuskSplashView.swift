import SwiftUI

struct PlumDuskSplashView: View {
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        GeometryReader { proxy in
            let logoSize = min(proxy.size.width * 0.48, 220)

            ZStack {
                Color(white: 0.88)
                RadialGradient(
                    colors: [Color(white: 0.98), Color(white: 0.88), Color(white: 0.72)],
                    center: UnitPoint(x: 0.5, y: 0.35),
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.85
                )

                VStack(spacing: 0) {
                    Spacer(minLength: 24)

                    Image("app_logo_small")
                        .resizable()
                        .scaledToFit()
                        .frame(width: logoSize, height: logoSize)
                        .clipShape(RoundedRectangle(cornerRadius: logoSize * 0.12))
                        .shadow(color: .black.opacity(0.14), radius: 24, y: 12)
                        .scaleEffect(reduceMotion || revealed ? 1 : 0.96)
                        .padding(.bottom, 28)

                    Text("iOS Local LLM")
                        .font(.title.weight(.semibold))
                        .tracking(-0.7)
                        .foregroundStyle(Color(white: 0.12))
                        .padding(.bottom, 12)

                    Text("LOCAL AI WORKBENCH")
                        .font(.caption.monospaced())
                        .tracking(2.4)
                        .foregroundStyle(Color(white: 0.36))

                    Spacer(minLength: 24)

                    Text("Private. On your device.")
                        .font(.footnote)
                        .foregroundStyle(Color(white: 0.36))
                        .padding(.bottom, 36)
                }
                .padding(.horizontal, 24)
                .multilineTextAlignment(.center)
                .opacity(reduceMotion || revealed ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .task {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.65)) {
                revealed = true
            }
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.6 : 1.8))
            guard !Task.isCancelled else { return }
            onFinished()
        }
        .accessibilityHidden(true)
    }
}
