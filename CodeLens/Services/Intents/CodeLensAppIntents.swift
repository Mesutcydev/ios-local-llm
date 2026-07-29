import AppIntents
import Foundation

// MARK: - CodeLens App Intents
//
// Siri / Shortcuts / Spotlight entry points. These intentionally open the app
// (`openAppWhenRun = true`) and hand off through `AppBridge` — the same
// pending-payload + tab-request plumbing the share extension already uses — so
// the heavy on-device MLX / llama.cpp inference runs in the foreground process
// where the Metal command queue is actually permitted (see MLXGenerationGate's
// foreground latch). A truly headless "answer in Shortcuts" intent is provided
// separately, backed by Apple's Foundation Models which the OS can run without
// our process being frontmost.
//
// App Intents are auto-discovered by the system from any type conforming to
// `AppIntent` in the app target — no registration needed.

// MARK: Ask

struct AskCodeLensIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask CodeLens"
    static var description = IntentDescription(
        "Ask the on-device assistant a question. Opens CodeLens and answers locally — nothing leaves your device."
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask?")
    var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AppBridge.shared.askAssistant(prompt, autoSend: true)
        return .result()
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Ask CodeLens \(\.$prompt)")
    }
}

// MARK: Quick Ask (headless, Apple Foundation Models)

/// Returns an answer directly into Siri / Shortcuts WITHOUT launching the app,
/// using Apple's on-device system model. This is the headless counterpart to
/// `AskCodeLensIntent`: instant, private, zero-download. Falls back with a
/// clear error when Apple Intelligence isn't available (older OS / device /
/// toggle off), nudging the user to the app-opening "Ask CodeLens" instead.
struct QuickAskCodeLensIntent: AppIntent {
    static var title: LocalizedStringResource = "Quick Ask CodeLens"
    static var description = IntentDescription(
        "Get a fast on-device answer from the built-in system model — no app launch, fully private."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask?")
    var prompt: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard AppleFoundationModel.isAvailable else {
            let reason = AppleFoundationModel.unavailableReason
                ?? "The on-device system model isn't available."
            throw AppleFoundationModel.AppleFMError.unavailable(
                "\(reason) Try \"Ask CodeLens\" to use a downloaded model instead."
            )
        }
        let answer = try await AppleFoundationModel.answer(
            to: prompt,
            instructions: "You are a concise, helpful on-device assistant. Answer directly."
        )
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Quick ask CodeLens \(\.$prompt)")
    }
}

// MARK: New chat

struct NewChatIntent: AppIntent {
    static var title: LocalizedStringResource = "New CodeLens Chat"
    static var description = IntentDescription("Start a fresh conversation with the on-device assistant.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppBridge.shared.startNewChat()
        return .result()
    }
}

// MARK: Live caption

struct LiveCaptionIntent: AppIntent {
    static var title: LocalizedStringResource = "Caption What I'm Looking At"
    static var description = IntentDescription("Open the live camera caption — a local vision model describes the scene.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppBridge.shared.startLiveCaption()
        return .result()
    }
}

// MARK: Voice

struct VoiceChatIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to CodeLens"
    static var description = IntentDescription("Open hands-free voice conversation with the on-device assistant.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppBridge.shared.startVoiceChat()
        return .result()
    }
}

// MARK: - Shortcuts provider
//
// Surfaces the ZERO-INPUT intents as Siri phrases / App Shortcuts. Every phrase
// contains `\(.applicationName)` so Siri can disambiguate it to this app.
//
// IMPORTANT: AskCodeLensIntent and QuickAskCodeLensIntent are intentionally NOT
// listed here. App Shortcuts must be runnable from the phrase alone — Siri
// can't reliably capture an arbitrary free-text question from a spoken phrase,
// and exposing a required-parameter intent as an App Shortcut without supplying
// the value triggers App Store rejection ITMS-90626 ("Invalid Siri Support —
// no example phrase…"). Those two intents remain fully available in the
// Shortcuts app, where the user fills in the prompt field.

struct CodeLensShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: VoiceChatIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start a voice chat with \(.applicationName)",
            ],
            shortTitle: "Voice",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: LiveCaptionIntent(),
            phrases: [
                "Caption with \(.applicationName)",
                "Describe what I'm looking at with \(.applicationName)",
            ],
            shortTitle: "Caption",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: NewChatIntent(),
            phrases: [
                "Start a new chat in \(.applicationName)",
                "New \(.applicationName) chat",
            ],
            shortTitle: "New Chat",
            systemImageName: "square.and.pencil"
        )
    }
}
