import SwiftUI

// MARK: - OnboardingView
// Studio-flavoured first-launch overview: editorial type, capability matrix,
// ink-on-bg "Continue" button. Three pages reachable via the next button.

struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var page = 0
    @Environment(\.koduTheme) private var T

    // Picker tab index is one past the informational pages. Both the
    // bottom nav and the page-dots use this to switch behavior — the
    // picker has its own bottom CTA bar so we hide the parent one on
    // that page.
    private var pickerIndex: Int { pages.count }
    private var totalTabs: Int { pages.count + 1 }
    private var onPickerPage: Bool { page == pickerIndex }
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            caption: "start with what you need",
            title: "Your AI.\nOn your device.",
            body: "Chat, understand images, or talk hands-free. Choose a model to get started; you can add more capabilities later.",
            matrix: [
                ("Chat", "Ask questions, write, and work with code"),
                ("Lens", "Understand a photo or camera view"),
                ("Voice", "Talk with your assistant"),
            ]
        ),
        OnboardingPage(
            caption: "local by default",
            title: "You choose\nwhen to connect.",
            body: "Downloaded models run locally. Model downloads, optional web search, private-cloud models, and paired-device tools use the network when you choose those features.",
            matrix: [
                ("Account", "No account required for local models"),
                ("Downloads", "Review size and license before installing"),
                ("Help", "User Guide in Settings"),
            ]
        ),
    ]

    var body: some View {
        ZStack {
            LiquidPinkBackdrop()

            VStack(spacing: 0) {
                // Wordmark header
                HStack {
                    if !dynamicTypeSize.isAccessibilitySize {
                    KWordmark(name: "OnDevice LLM", logoAsset: "app_logo_small")
                    Spacer()
                    KMono(text: "v\(appVersion)", size: 10, color: T.ink3)
                    }
                    if dynamicTypeSize.isAccessibilitySize { Spacer() }
                    if page < pages.count - 1 {
                        Button {
                            settings.hasSeenOnboarding = true
                        } label: {
                            Text("skip")
                                .font(T.mono(11))
                                .foregroundColor(T.ink3)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 12)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { idx, p in
                        pageView(p).tag(idx)
                    }
                    // Picker is the final page. Its own CTA bar lives
                    // inside the view; the parent nav hides itself
                    // when this page is active.
                    OnboardingModelPickerView {
                        settings.hasSeenOnboarding = true
                    }
                    .tag(pickerIndex)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Bottom: dots + continue (hidden on the picker page —
            // it brings its own primary CTA).
            if !onPickerPage {
                VStack(spacing: 14) {
                        HStack(spacing: 6) {
                            ForEach(0..<totalTabs, id: \.self) { i in
                                Capsule()
                                    .fill(i == page ? T.ink : T.ink4)
                                    .frame(width: i == page ? 18 : 5, height: 5)
                                    .animation(.spring(duration: 0.3), value: page)
                            }
                        }

                        Button {
                            withAnimation { page += 1 }
                        } label: {
                            HStack {
                                Text("next")
                                    .font(T.mono(14, .semibold))
                                    .tracking(0.3)
                                Spacer()
                                Text("→")
                                    .font(T.mono(11))
                                    .foregroundColor(T.ink4)
                            }
                            .foregroundColor(T.bg)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(minHeight: 50)
                            .background(RoundedRectangle(cornerRadius: 10).fill(T.ink))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("onboarding.next")
                        .accessibilityLabel("Next")

                        if !dynamicTypeSize.isAccessibilitySize {
                        Text("local by default. network features are optional.")
                            .font(T.mono(9))
                            .tracking(0.4)
                            .foregroundColor(T.ink3)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .background(T.bg)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: onPickerPage)
    }

    @ViewBuilder
    private func pageView(_ p: OnboardingPage) -> some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Spacer().frame(height: 12)

            // Hero
            VStack(alignment: .leading, spacing: 8) {
                KCaption(text: p.caption, color: T.ink2)
                Text(p.title)
                    .font(T.display(38, .semibold))
                    .tracking(-1.4)
                    .foregroundColor(T.ink)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text(p.body)
                    .font(T.sans(14))
                    .foregroundColor(T.ink2)
                    .padding(.top, 4)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            // Capability matrix
            VStack(spacing: 0) {
                ForEach(Array(p.matrix.enumerated()), id: \.offset) { i, row in
                    if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                    HStack {
                        KMono(text: row.0, size: 11, color: T.ink3)
                            .frame(width: 100, alignment: .leading)
                        KMono(text: row.1, size: 11, color: T.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                }
            }
            .kGlass(cornerRadius: 8, fallbackFill: T.surface)

            Spacer().frame(height: 16)   // room for bottom nav
        }
        .padding(.horizontal, 22)
        }
    }
}

private struct OnboardingPage {
    let caption: String
    let title: String
    let body: String
    let matrix: [(String, String)]
    var isLast: Bool = false
}
