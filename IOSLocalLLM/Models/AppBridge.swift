import SwiftUI
import UIKit
import CoreImage

// MARK: - AppBridge
// Connects the Camera tab to the Assistant tab, and routes inbound
// share-extension drops into the analysis pipeline.

@MainActor
final class AppBridge: ObservableObject {
    static let shared = AppBridge()

    /// App Group identifier — must match the share extension.
    static let appGroupID = "group.com.mesutcydev.ondevicecore.shared"

    // Set by AnalysisPanelView; consumed once by CodingAssistantView
    @Published var pendingCode: PendingCode? = nil

    // Drives tab switch in ContentView. Use `requestTab(_:)` rather than
    // poking the int directly so call sites are self-documenting.
    //   0 = camera (lens), 1 = assistant, 2 = models, 3 = mac (bridge),
    //   4 = voice.
    @Published var requestedTab: Int? = nil

    /// Type-safe tab navigation. Centralises the int mapping in one place
    /// so call sites can write `AppBridge.shared.requestTab(.models)`.
    enum Tab: Int { case camera = 0, assistant = 1, models = 2, mac = 3, voice = 4 }

    enum ModelsSection: String {
        case assistant, lens, voice, image
    }

    @Published var requestedModelsSection: ModelsSection? = nil

    func requestTab(_ tab: Tab) {
        requestedTab = tab.rawValue
    }

    func requestModels(_ section: ModelsSection) {
        requestedModelsSection = section
        requestTab(.models)
    }

    /// Image dropped in from the share extension waiting to be analysed.
    @Published var pendingSharedImage: UIImage? = nil

    /// Text or URL dropped in from the share extension waiting to be sent
    /// to the assistant. Consumed by `CodingAssistantView` which prefills
    /// the composer and switches to the chat route. Lives as plain text
    /// so the assistant can decide how to frame it (raw question, URL
    /// summarisation prompt, etc.) rather than baking that policy here.
    @Published var pendingSharedText: SharedTextPayload? = nil

    struct SharedTextPayload: Equatable {
        enum Kind: String { case text, url }
        let kind: Kind
        let body: String
        /// When true the assistant view sends the prefilled prompt
        /// automatically instead of waiting for the user to tap send. Set by
        /// the "Ask OnDevice" App Intent so a Siri/Shortcuts request actually
        /// produces an answer rather than just opening the composer.
        var autoSend: Bool = false
    }

    /// Set by the "New Chat" App Intent; CodingAssistantView clears the
    /// current conversation when it drains this on appear / change.
    @Published var pendingNewChat: Bool = false

    /// Set when the user taps a conversation in Spotlight search;
    /// CodingAssistantView loads that conversation when it drains this.
    @Published var pendingOpenConversationID: UUID? = nil

    /// Open a specific stored conversation (from Spotlight) on the assistant tab.
    func openConversation(id: UUID) {
        pendingOpenConversationID = id
        requestTab(.assistant)
    }

    // MARK: - App Intent entry points
    //
    // These mirror the share-extension path (set a pending payload + flip
    // `requestedTab`) so Siri / Shortcuts reuse the exact navigation plumbing
    // the share sheet already proved out. All are @MainActor (the class is),
    // and App Intents call them inside `await MainActor.run { }`.

    /// Prefill the assistant composer with `prompt`; when `autoSend` is true
    /// the view fires it immediately once the app is foreground.
    func askAssistant(_ prompt: String, autoSend: Bool) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { requestTab(.assistant); return }
        pendingSharedText = SharedTextPayload(kind: .text, body: trimmed, autoSend: autoSend)
        requestTab(.assistant)
    }

    /// Start a fresh conversation on the assistant tab.
    func startNewChat() {
        pendingNewChat = true
        requestTab(.assistant)
    }

    /// Jump to the live-caption camera tab.
    func startLiveCaption() { requestTab(.camera) }

    /// Jump to the hands-free voice tab.
    func startVoiceChat() { requestTab(.voice) }

    struct PendingCode: Equatable {
        let code: String
        let source: String
        let prefillPrompt: String
    }

    func sendToAssistant(code: String, source: String = "Camera OCR", image: UIImage? = nil) {
        if let image {
            ToolBridge.shared.lastImage = image
        }
        let prompt = """
        I captured the following code via \(source). Please review it:

        ```
        \(code)
        ```
        """
        pendingCode = PendingCode(code: code, source: source, prefillPrompt: prompt)
        requestedTab = 1
    }

    func consume() -> PendingCode? {
        defer { pendingCode = nil }
        return pendingCode
    }

    // MARK: - Share-extension inbound

    /// Handles `ondevice-core://share?...` URLs from the share extension.
    /// Supports four payload shapes:
    ///   • `file=<jpg>`     — staged image, routes to camera/lens tab
    ///   • `textfile=<txt>` — long text staged to a file, routes to assistant
    ///   • `text=<...>`     — short text inlined in the query
    ///   • `url=<...>`      — URL inlined in the query, routes to assistant
    /// The text/URL paths land in `pendingSharedText` and switch to the
    /// assistant tab so CodingAssistantView can prefill the composer.
    func handleIncomingURL(_ url: URL) {
        guard url.scheme == "ondevice-core", url.host == "share" else { return }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems
        else { return }
        let lookup = Dictionary(items.compactMap { item -> (String, String)? in
            guard let v = item.value else { return nil }
            return (item.name, v)
        }, uniquingKeysWith: { first, _ in first })

        if let file = lookup["file"] {
            handleIncomingImage(filename: file)
            return
        }
        if let textfile = lookup["textfile"] {
            handleIncomingTextFile(filename: textfile)
            return
        }
        if let text = lookup["text"] {
            handleIncomingText(text, kind: .text)
            return
        }
        if let urlString = lookup["url"] {
            handleIncomingText(urlString, kind: .url)
            return
        }
    }

    /// `ondevice-core://share?file=…` is a PUBLIC custom URL scheme — any app or web
    /// page can invoke it. The filename must be a single safe path component so
    /// a value like "../../Documents/conversations.json" can't escape the
    /// staging dir and give an out-of-app caller arbitrary read/delete in our
    /// container. `nonisolated` — pure string check with no actor state.
    nonisolated static func isSafeShareFilename(_ name: String) -> Bool {
        !name.isEmpty
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("..")
            && !name.hasPrefix(".")
            && (name as NSString).pathComponents.count == 1
    }

    /// Resolves `filename` inside `subdir` of the App Group container, rejecting
    /// traversal. Returns nil (and toasts) on misconfig or an unsafe name.
    private func stagedShareURL(subdir: String, filename: String) -> URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else {
            ToastCenter.shared.error("Share extension misconfigured",
                                      detail: "App Group container not found.")
            return nil
        }
        guard Self.isSafeShareFilename(filename) else {
            ToastCenter.shared.error("Invalid shared file")
            return nil
        }
        let dir = containerURL.appendingPathComponent(subdir, isDirectory: true)
        let url = dir.appendingPathComponent(filename)
        // Defense in depth: the resolved path must still live inside `dir`.
        guard url.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path + "/") else {
            ToastCenter.shared.error("Invalid shared file")
            return nil
        }
        return url
    }

    private func handleIncomingImage(filename: String) {
        guard let stagedURL = stagedShareURL(subdir: "SharedImages", filename: filename) else { return }
        // Single-use: remove the staged file on EVERY exit path (incl. decode
        // failure) so corrupt/oversized shares don't leak files into the
        // container (a disk + privacy residue).
        defer { try? FileManager.default.removeItem(at: stagedURL) }

        guard let data = try? Data(contentsOf: stagedURL),
              let image = UIImage(data: data) else {
            ToastCenter.shared.error("Couldn't open shared image")
            return
        }
        pendingSharedImage = image
        ToolBridge.shared.lastImage = image
        requestedTab = Tab.camera.rawValue
        ToastCenter.shared.info("Shared image received")
    }

    private func handleIncomingTextFile(filename: String) {
        guard let stagedURL = stagedShareURL(subdir: "SharedText", filename: filename) else { return }
        defer { try? FileManager.default.removeItem(at: stagedURL) }

        // Cap the read so a malicious/huge shared .txt can't be slurped whole
        // into memory and dumped into the composer. Read up to the cap via a
        // FileHandle, not Data(contentsOf:) of the entire file. String(decoding:)
        // is lossy so a UTF-8 sequence split by the byte cap degrades to U+FFFD
        // rather than failing the whole import.
        let maxBytes = 512 * 1024
        guard let fh = try? FileHandle(forReadingFrom: stagedURL) else {
            ToastCenter.shared.error("Couldn't open shared text")
            return
        }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: maxBytes + 1)) ?? Data()
        let truncated = data.count > maxBytes
        let text = String(decoding: data.prefix(maxBytes), as: UTF8.self)
        if truncated {
            ToastCenter.shared.info("Shared text was long",
                                    detail: "Only the first part was added to the composer.")
        }
        handleIncomingText(text, kind: .text)
    }

    private func handleIncomingText(_ raw: String, kind: SharedTextPayload.Kind) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingSharedText = SharedTextPayload(kind: kind, body: trimmed)
        requestedTab = Tab.assistant.rawValue
        let detail = trimmed.count > 60
            ? String(trimmed.prefix(60)) + "…"
            : trimmed
        ToastCenter.shared.info(
            kind == .url ? "Shared link received" : "Shared text received",
            detail: detail
        )
    }
}
