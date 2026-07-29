import SwiftUI

// MARK: - HFTokenSheet
//
// Modal for entering a Hugging Face access token. Used by the API
// Settings section in SettingsView, and by gated-model download
// failure CTAs ("This model requires a token — set one now").
//
// UX:
//   1. Multi-line SecureField + eye toggle to reveal.
//   2. Paste button — convenience for "I just copied this from
//      huggingface.co/settings/tokens".
//   3. Test — hits /api/whoami-v2 with the typed value, returns
//      username on success. Doesn't save automatically; the user
//      decides after seeing the test result.
//   4. Save — writes to Keychain via HFTokenStore.
//   5. Remove — clears any existing token (only shown when one is
//      already stored).
//
// Validation isn't required to save — users can save without
// testing if they're confident, and the download path will
// surface auth errors later via HFAuthError. The Test button is
// purely a sanity check.

struct HFTokenSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T
    @ObservedObject private var store = HFTokenStore.shared

    // MARK: - Local state

    @State private var input: String = ""
    @State private var revealed: Bool = false
    @State private var testing: Bool = false
    @State private var testResult: TestResult? = nil

    enum TestResult {
        case ok(username: String)
        case invalid
        case networkError(String)
    }

    init() {
        // Don't pre-fill the field with the existing token — Keychain
        // exposure is a security trade-off we don't want by default.
        // The masked preview is shown as a separate eyebrow instead.
        _input = State(initialValue: "")
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    headerBlock
                    inputCard
                    if let result = testResult { resultBanner(for: result) }
                    helpCard
                }
                .padding(.bottom, 32)
            }
            .background(LiquidPinkBackdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(T.sans(15))
                        .foregroundColor(T.ink2)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .font(T.sans(15, .semibold))
                        .foregroundColor(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                         ? T.ink4 : T.accent)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            KCaption(text: "API · HUGGING FACE")
            Text("Access Token")
                .font(T.display(26, .semibold))
                .tracking(-0.5)
                .foregroundColor(T.ink)
            Text("Paste a personal access token to download gated models like Gemma source weights, Llama 3, and Ministral. Generate one at huggingface.co/settings/tokens (read access is enough).")
                .font(T.sans(13))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            if let masked = store.maskedPreview {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundColor(T.good)
                    Text("Token saved · \(masked)")
                        .font(T.mono(10.5, .semibold))
                        .foregroundColor(T.good)
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 18)
    }

    // MARK: - Input card

    private var inputCard: some View {
        KSection(title: "token") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 12))
                        .foregroundColor(T.ink3)
                    Group {
                        if revealed {
                            TextField("hf_…", text: $input)
                        } else {
                            SecureField("hf_…", text: $input)
                        }
                    }
                    .font(T.mono(12))
                    .foregroundColor(T.ink)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                    Button {
                        revealed.toggle()
                        HapticManager.impact(.light)
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                            .foregroundColor(T.ink3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(T.surface2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.rule, lineWidth: 0.5))

                HStack(spacing: 8) {
                    Button {
                        if let s = UIPasteboard.general.string {
                            input = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            testResult = nil
                            HapticManager.impact(.light)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 10))
                            Text("Paste")
                                .font(T.mono(10, .semibold))
                                .tracking(0.4)
                        }
                        .foregroundColor(T.ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .kGlassCapsule(fallbackFill: T.surface)
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack(spacing: 4) {
                            if testing {
                                ProgressView().scaleEffect(0.6)
                                    .frame(width: 10, height: 10)
                            } else {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 10))
                            }
                            Text("Test")
                                .font(T.mono(10, .semibold))
                                .tracking(0.4)
                        }
                        .foregroundColor(T.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(T.accentSoft))
                        .overlay(Capsule().stroke(T.accent.opacity(0.4), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)
                    .opacity(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)

                    Spacer()

                    if store.hasToken {
                        Button(role: .destructive) {
                            store.clear()
                            input = ""
                            testResult = nil
                            HapticManager.impact(.medium)
                        } label: {
                            Text("Remove")
                                .font(T.mono(10, .semibold))
                                .tracking(0.4)
                                .foregroundColor(T.bad)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(T.bad.opacity(0.10)))
                                .overlay(Capsule().stroke(T.bad.opacity(0.30), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Action result banner

    @ViewBuilder
    private func resultBanner(for result: TestResult) -> some View {
        let (tint, icon, title, detail): (Color, String, String, String) = {
            switch result {
            case .ok(let name):
                return (T.good, "checkmark.seal.fill", "Token valid",
                        "Signed in as @\(name) on huggingface.co.")
            case .invalid:
                return (T.bad, "xmark.octagon.fill", "Token rejected",
                        "huggingface.co returned 401. Check that you copied the full token, including the hf_ prefix.")
            case .networkError(let detail):
                return (T.warn, "wifi.exclamationmark", "Couldn't verify token",
                        detail)
            }
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(tint)
                Text(title.uppercased())
                    .font(T.mono(10, .semibold))
                    .tracking(0.5)
                    .foregroundColor(tint)
            }
            Text(detail)
                .font(T.sans(11.5))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.35), lineWidth: 0.5))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - Help

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            KCaption(text: "WHY DO I NEED THIS?")
            Text("Hugging Face requires a token for repositories where the publisher gates access — typically because the model has a license that requires you to accept terms. Examples: official google/gemma-* mirrors, meta-llama/* models, mistralai/Ministral-*.")
                .font(T.sans(11.5))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Most iOS Local LLM defaults (mlx-community/*, ggml-org/*) are open and don't need a token. Set one only if you want to download from gated repos.")
                .font(T.sans(11.5))
                .foregroundColor(T.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
    }

    // MARK: - Actions

    private func save() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let saved = store.save(trimmed)
        HapticManager.notification(saved ? .success : .error)
        if saved {
            ToastCenter.shared.success("HF token saved")
            dismiss()
        } else {
            ToastCenter.shared.error("Couldn't save token",
                                      detail: "Keychain write failed. Try again or restart the app.")
        }
    }

    private func runTest() async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        testing = true
        testResult = nil
        defer { testing = false }
        if let username = await store.validate(trimmed) {
            testResult = .ok(username: username)
            HapticManager.notification(.success)
        } else {
            // Best-effort: distinguish "invalid token" from "network error".
            // /api/whoami-v2 returns nil for both; we treat any failure as
            // invalid token since the network path is the same as a fresh
            // search and would have surfaced separately if down.
            testResult = .invalid
            HapticManager.notification(.error)
        }
    }
}
