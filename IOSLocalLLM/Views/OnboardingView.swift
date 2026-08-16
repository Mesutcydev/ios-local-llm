import SwiftUI

// MARK: - OnboardingView
// Studio-flavoured first-launch overview: editorial type, capability matrix,
// ink-on-bg "Continue" button. Three pages reachable via the next button.

struct OnboardingView: View {
    @ObservedObject private var settings = AppSettings.shared
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
            caption: "local-first vision",
            title: "Scan code\nfrom your\ncamera.",
            body: "Point your camera at any terminal or editor. Apple Vision finds text regions in real-time and FastVLM extracts the code on-device.",
            matrix: [
                ("detection", "Apple Vision · system"),
                ("vision",    "FastViT-HD encoder"),
                ("decoder",   "Qwen2-0.5B · MLX"),
                ("fallback",  "VNRecognizeTextRequest"),
            ]
        ),
        OnboardingPage(
            caption: "on-device assistant",
            title: "Ask Qwen3\nanything\nabout code.",
            body: "A 4-bit quantised Qwen3-4B model runs entirely on your device. Send captured code to the assistant for review, debugging, or refactoring.",
            matrix: [
                ("model",       "Qwen3-4B-Instruct · 4-bit"),
                ("runtime",     "MLX 0.21 · Metal · ANE"),
                ("streaming",   "token-by-token"),
                ("storage",     "sandboxed · encrypted"),
            ]
        ),
        OnboardingPage(
            caption: "text-to-image · local",
            title: "Generate\nimages\non-device.",
            body: "Type a prompt and create images entirely on your phone. Stable Diffusion and SDXL-Turbo run through MLX — quantised on-device, no cloud, no API keys.",
            matrix: [
                ("models",   "SD 1.5 · 2.1 · SDXL-Turbo"),
                ("fastest",  "SD-Turbo · 1 step"),
                ("artistic", "DreamShaper 8"),
                ("runtime",  "MLX · Metal · quantised"),
            ]
        ),
        OnboardingPage(
            caption: "no servers · no keys · no metrics",
            title: "100%\nprivate.",
            body: "All models run on-device. Your camera frames, captured code, and chat conversations never leave the phone.",
            matrix: [
                ("network",  "model download only"),
                ("analytics","none"),
                ("telemetry","none"),
                ("source",   "huggingface.co"),
            ],
            isLast: false
        ),
        OnboardingPage(
            caption: "learn & explore",
            title: "Detailed\nUser Guide\nin Settings.",
            body: "Need help? A comprehensive User Guide with instructions for every function, camera mode, voice dictation, and Mac Bridge is always available inside App Settings.",
            matrix: [
                ("location", "Settings ➔ User Guide"),
                ("screenshots", "annotated visuals"),
                ("contents",  "all menus & functions"),
                ("updates",   "local-first documentation")
            ],
            isLast: true
        ),
    ]

    var body: some View {
        ZStack {
            LiquidPinkBackdrop()

            VStack(spacing: 0) {
                // Wordmark header
                HStack {
                    KWordmark(name: "OnDevice LLM", logoAsset: "app_logo_small")
                    Spacer()
                    KMono(text: "v\(appVersion)", size: 10, color: T.ink3)
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

            // Bottom: dots + continue (hidden on the picker page —
            // it brings its own primary CTA).
            if !onPickerPage {
                VStack {
                    Spacer()
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
                            .frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: 10).fill(T.ink))
                        }
                        .buttonStyle(.plain)

                        Text("nothing leaves the device.")
                            .font(T.mono(9))
                            .tracking(0.4)
                            .foregroundColor(T.ink3)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 40)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: onPickerPage)
    }

    @ViewBuilder
    private func pageView(_ p: OnboardingPage) -> some View {
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

            Spacer().frame(height: 130)   // room for bottom nav
        }
        .padding(.horizontal, 22)
    }
}

private struct OnboardingPage {
    let caption: String
    let title: String
    let body: String
    let matrix: [(String, String)]
    var isLast: Bool = false
}
