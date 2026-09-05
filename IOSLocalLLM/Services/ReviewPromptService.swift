import Foundation
import StoreKit
import SwiftUI
import UIKit

// MARK: - ReviewPromptService
//
// Decides WHEN to ask the user to rate the app and routes the request
// through Apple's SKStoreReviewController. The native API is opaque
// (iOS may silently no-op if the quota of 3 prompts/year is met), so we
// add a single pre-prompt sheet that captures the user's mood first —
// only positive users get the native rating prompt; the rest land in a
// "send feedback" path so we don't burn quota on a 1-star event.
//
// Triggers tracked in UserDefaults:
//   • firstLaunchDate          — when the app first ran (delay anchor)
//   • meaningfulInteractions   — counter bumped on completed generations
//   • lastPromptDate           — last time we showed the pre-prompt
//   • didRequestReview         — set once user tapped "Love it"; we don't
//                                pester again from the heuristic path
//
// Eligibility (all must hold):
//   • At least 3 days since firstLaunchDate
//   • At least 5 meaningful interactions
//   • At least 30 days since lastPromptDate (or never prompted)
//   • didRequestReview is false
//
// The eligibility check is cheap so we run it on every interaction tick
// and let the call site decide whether to surface the sheet.

@MainActor
final class ReviewPromptService: ObservableObject {

    static let shared = ReviewPromptService()

    // MARK: - Published

    /// Drives the SwiftUI sheet. Views observe and present when true.
    @Published var shouldShowPrompt: Bool = false

    // MARK: - Defaults keys

    private enum Key {
        static let firstLaunchDate         = "review.firstLaunchDate"
        static let meaningfulInteractions  = "review.meaningfulInteractions"
        static let lastPromptDate          = "review.lastPromptDate"
        static let didRequestReview        = "review.didRequestReview"
        static let didOptOutForever        = "review.didOptOutForever"
    }

    // MARK: - Thresholds

    /// Defaults are intentionally conservative — we want to ask only when
    /// the user has actually used the app, not after first launch.
    private let minDaysSinceFirstLaunch: TimeInterval = 3 * 86_400
    private let minMeaningfulInteractions: Int = 5
    private let cooldownBetweenPrompts: TimeInterval = 30 * 86_400

    // MARK: - Init

    private init() {
        let d = UserDefaults.standard
        if d.object(forKey: Key.firstLaunchDate) == nil {
            d.set(Date(), forKey: Key.firstLaunchDate)
        }
    }

    // MARK: - Counters

    /// Bump on each completed assistant generation (or any other moment
    /// that represents real value delivered). Cheap — no eligibility
    /// check fires here; `evaluateAndMaybePrompt()` does that.
    func recordMeaningfulInteraction() {
        let d = UserDefaults.standard
        let next = d.integer(forKey: Key.meaningfulInteractions) + 1
        d.set(next, forKey: Key.meaningfulInteractions)
    }

    /// Call from a quiet moment in the UI (e.g. just after an assistant
    /// reply finishes streaming). If all gates pass, flips
    /// `shouldShowPrompt` so the observing view presents the sheet.
    func evaluateAndMaybePrompt() {
        guard isEligible else { return }
        // Slight delay so the prompt doesn't crash into the user's most
        // recent tap. 1s feels intentional, not random.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            guard self.isEligible else { return }
            self.shouldShowPrompt = true
        }
    }

    private var isEligible: Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: Key.didOptOutForever) { return false }
        if d.bool(forKey: Key.didRequestReview) { return false }
        let interactions = d.integer(forKey: Key.meaningfulInteractions)
        guard interactions >= minMeaningfulInteractions else { return false }
        let first = d.object(forKey: Key.firstLaunchDate) as? Date ?? Date()
        guard Date().timeIntervalSince(first) >= minDaysSinceFirstLaunch else {
            return false
        }
        if let last = d.object(forKey: Key.lastPromptDate) as? Date,
           Date().timeIntervalSince(last) < cooldownBetweenPrompts {
            return false
        }
        return true
    }

    // MARK: - Sheet outcomes

    func recordPromptShown() {
        UserDefaults.standard.set(Date(), forKey: Key.lastPromptDate)
        shouldShowPrompt = false
    }

    /// User tapped "Love it" — fire Apple's native review request. iOS
    /// decides whether to actually show it (quota-limited), but that's
    /// the right Apple-approved path.
    func userLovesIt() {
        UserDefaults.standard.set(true, forKey: Key.didRequestReview)
        recordPromptShown()
        if let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive })
            as? UIWindowScene
        {
            AppStore.requestReview(in: scene)
        }
    }

    /// User tapped "Send feedback" — open mail with a pre-filled subject.
    /// Better than burning their bad mood on a 1-star App Store review.
    func userWantsFeedback() {
        recordPromptShown()
        let app = Bundle.main.appVersionAndBuild
        let device = UIDevice.current.systemVersion
        let body = "App: \(app)\niOS: \(device)\n\n"
        let subject = "OnDevice feedback"
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = "mesutcy@gmail.com"
        comps.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        if let url = comps.url {
            UIApplication.shared.open(url)
        }
    }

    /// User tapped "Not now" — cooldown starts, may re-ask after the
    /// interval. NOT a forever opt-out.
    func userDeferred() {
        recordPromptShown()
    }

    /// User tapped "Don't ask again" — never bother them again from the
    /// heuristic path.
    func userOptedOutForever() {
        UserDefaults.standard.set(true, forKey: Key.didOptOutForever)
        recordPromptShown()
    }
}

private extension Bundle {
    var appVersionAndBuild: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

// MARK: - ReviewPromptSheet
//
// Compact mood-check sheet. Three primary actions plus a Never option
// in the secondary row. Cards intentionally use the same surface
// language as the rest of the app (rounded rect + ultra-thin material).

struct ReviewPromptSheet: View {

    @ObservedObject private var service = ReviewPromptService.shared
    @ObservedObject private var loc = LocalizationService.shared
    @Environment(\.koduTheme) private var T
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [T.accent, T.roseHi],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                Text(loc.t("Enjoying OnDevice?"))
                    .font(T.display(22, .semibold))
                    .foregroundColor(T.ink)
                    .multilineTextAlignment(.center)
                Text(
                    loc.t("A quick rating helps other people find the app. We're a tiny team — your feedback shapes what's next.")
                    + " Thanks to Jakub Antalik, creator of thinking-orbs."
                )
                    .font(T.sans(13))
                    .foregroundColor(T.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
            .padding(.horizontal, 8)

            // Primary action — "Love it"
            choiceButton(
                icon: "heart.fill",
                label: loc.t("Love it — rate on App Store"),
                fill: T.accent,
                accent: .white
            ) {
                service.userLovesIt()
                dismiss()
            }

            // Secondary — "It's OK, here's feedback"
            choiceButton(
                icon: "envelope.fill",
                label: loc.t("Send feedback instead"),
                fill: T.surface,
                accent: T.ink
            ) {
                service.userWantsFeedback()
                dismiss()
            }

            // Tertiary row — defer + never
            HStack(spacing: 14) {
                Button {
                    service.userDeferred()
                    dismiss()
                } label: {
                    Text(loc.t("Not now"))
                        .font(T.mono(11, .semibold))
                        .foregroundColor(T.ink2)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .kGlassCapsule(fallbackFill: T.surface)
                }
                .buttonStyle(.plain)

                Button {
                    service.userOptedOutForever()
                    dismiss()
                } label: {
                    Text(loc.t("Don't ask again"))
                        .font(T.mono(11, .semibold))
                        .foregroundColor(T.ink3)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule().fill(.clear)
                                .overlay(Capsule().stroke(T.rule, lineWidth: 0.5))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(T.bg)
        .interactiveDismissDisabled(false)
    }

    private func choiceButton(
        icon: String,
        label: String,
        fill: Color,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(T.sans(14, .semibold))
                Spacer()
            }
            .foregroundColor(accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(fill == T.surface ? T.rule : .clear, lineWidth: 0.5)
                    )
            )
            .shadow(color: fill == T.accent ? T.accent.opacity(0.30) : .clear,
                    radius: 10, y: 3)
        }
        .buttonStyle(.plain)
    }
}
