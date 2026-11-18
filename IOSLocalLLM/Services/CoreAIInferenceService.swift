import Foundation

enum CoreAIInferenceError: LocalizedError, Equatable {
    case unavailable(String)
    case modelMissing
    case unsupportedCapability(String)
    case invalidImage(String)
    case generationFailed
    case emptyConversation

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .modelMissing: return "Download a Core AI pack from the Models tab first."
        case .unsupportedCapability(let capability): return "The selected Core AI model does not support \(capability)."
        case .invalidImage(let message): return message
        case .generationFailed: return "Core AI could not complete the local generation."
        case .emptyConversation: return "The request has no user message for Core AI to answer."
        }
    }
}

/// Small app-facing facade. The Core AI SDK is isolated behind this type so
/// the existing API server and safety/lifecycle code do not import SDK types.
@MainActor
final class CoreAIInferenceService {
    static let shared = CoreAIInferenceService()

    private(set) var isReady = false
    /// Assistant selection id (`coreai:…`) of the pack currently specialized.
    /// `isReady` alone is not enough: the store can point at pack B while
    /// this runtime still holds pack A.
    private(set) var loadedSelectionID: String?
    private var runtime: CoreAIRuntime?
    private var loadTask: Task<Void, Error>?
    private var loadID: UUID?
    private var unloadCount = 0
    private var isUnloading: Bool { unloadCount > 0 }

    private init() {}

    nonisolated static var availabilityReason: String? {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst) && canImport(CoreAI) && canImport(CoreAILanguageModels)
        if #available(iOS 27.0, *) { return nil }
        return "Core AI requires iOS 27 or later."
        #else
        return "Core AI requires a supported physical iOS 27 device and the Core AI SDK."
        #endif
    }


    func isLoaded(as selectionID: String) -> Bool {
        Self.isCurrentRuntime(
            loadedID: loadedSelectionID,
            ready: isReady,
            requestedID: selectionID
        )
    }

    nonisolated static func normalizedSelectionID(_ id: String) -> String {
        id.hasPrefix("coreai:") ? id : "coreai:\(id)"
    }

    nonisolated static func isCurrentRuntime(
        loadedID: String?,
        ready: Bool,
        requestedID: String
    ) -> Bool {
        ready
            && loadedID.map(normalizedSelectionID)
                == normalizedSelectionID(requestedID)
    }

    func load() async throws {
        try Task.checkCancellation()
        guard loadTask == nil, !isUnloading else { throw CoreAIInferenceError.generationFailed }
        if let reason = Self.availabilityReason {
            throw CoreAIInferenceError.unavailable(reason)
        }
        guard #available(iOS 27.0, *) else {
            throw CoreAIInferenceError.unavailable("Core AI requires iOS 27 or later.")
        }
        guard let url = CoreAIModelStore.shared.modelResourcesURL,
              let manifest = CoreAIModelStore.shared.manifest else {
            throw CoreAIInferenceError.modelMissing
        }
        guard manifest.capabilities.textGeneration else {
            throw CoreAIInferenceError.unsupportedCapability("text generation")
        }
        let selectionID = CoreAIInstalledModel.assistantSelectionID(for: manifest.id)
        if isLoaded(as: selectionID), runtime != nil {
            return
        }

        Diagnostics.shared.breadcrumb(
            "Core AI runtime load start · \(manifest.id) · v\(manifest.version) · resources=\(url.lastPathComponent)",
            category: "coreai"
        )
        await unload()
        try Task.checkCancellation()
        guard !isUnloading else { throw CancellationError() }
        let runtime = makeRuntime()
        let id = UUID()
        loadID = id
        let loading = Task { try await runtime.load(resourcesAt: url) }
        loadTask = loading
        defer { if loadID == id { loadTask = nil; loadID = nil } }
        do {
            try await withTaskCancellationHandler {
                try await loading.value
            } onCancel: { loading.cancel() }
            try Task.checkCancellation()
            guard loadID == id else { throw CancellationError() }
        } catch {
            // A failed reload must not leave the previous multi-gigabyte
            // runtime resident (and `isReady` true) while the service state
            // reports failure — memory admission and the API's readiness
            // gate would both be lying.
            if loadID == id { loadTask = nil; loadID = nil }
            runtime.cancel()
            await runtime.drain()
            Diagnostics.shared.error(
                "Core AI runtime load failed · \(manifest.id) · \(error.localizedDescription)",
                category: "coreai"
            )
            throw error
        }
        self.runtime = runtime
        loadedSelectionID = selectionID
        isReady = true
        Diagnostics.shared.breadcrumb("Core AI runtime ready · \(manifest.id)", category: "coreai")
    }

    nonisolated static func requiresVisualInput(_ message: ChatMessage) -> Bool {
        (message.imageThumbnailData != nil || !message.imageThumbnails.isEmpty)
            && (message.modelContent?.isEmpty != false)
    }

    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Double,
        thinkingEnabled: Bool?,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws {
        guard isReady, let runtime else { throw CoreAIInferenceError.modelMissing }
        if messages.contains(where: Self.requiresVisualInput) {
            throw CoreAIInferenceError.invalidImage(
                "This Core AI text pack does not accept images. Use Lens or an MLX/GGUF vision model."
            )
        }
        try await runtime.generate(
            messages: messages,
            maxTokens: maxTokens,
            temperature: temperature,
            thinkingEnabled: thinkingEnabled,
            onToken: onToken
        )
    }

    func cancel() {
        loadTask?.cancel()
        runtime?.cancel()
    }

    func unload() async {
        unloadCount += 1
        defer { unloadCount -= 1 }
        isReady = false
        loadedSelectionID = nil
        let loading = loadTask
        loadID = nil
        loading?.cancel()
        if let loading { _ = await loading.result }
        loadTask = nil
        let retiring = runtime
        retiring?.cancel()
        await retiring?.drain()
        runtime = nil
        isReady = false
        loadedSelectionID = nil
    }
}

@MainActor
private protocol CoreAIRuntime: AnyObject {
    func load(resourcesAt url: URL) async throws
    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Double,
        thinkingEnabled: Bool?,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws
    func cancel()
    func drain() async
}

#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst) && canImport(CoreAI) && canImport(FoundationModels) && canImport(CoreAILanguageModels)
import FoundationModels
import CoreAILanguageModels

@available(iOS 27.0, *)
private final class CoreAIAvailableRuntime: CoreAIRuntime {
    private var model: CoreAILanguageModel?
    private var task: Task<Void, Error>?

    func load(resourcesAt url: URL) async throws {
        model = try await CoreAILanguageModel(resourcesAt: url)
    }

    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Double,
        thinkingEnabled: Bool?,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard task == nil else { throw CoreAIInferenceError.generationFailed }
        guard let model else { throw CoreAIInferenceError.modelMissing }
        guard let plan = CoreAIConversationPlanner.plan(messages: messages) else {
            throw CoreAIInferenceError.emptyConversation
        }

        var entries: [Transcript.Entry] = []
        if !plan.system.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: plan.system))],
                toolDefinitions: []
            )))
        }
        for turn in plan.history {
            switch turn {
            case .user(let text):
                entries.append(.prompt(Transcript.Prompt(
                    segments: [.text(Transcript.TextSegment(content: text))]
                )))
            case .assistant(let text):
                entries.append(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [.text(Transcript.TextSegment(content: text))]
                )))
            case .tool(let id, let name, let content):
                entries.append(.toolOutput(Transcript.ToolOutput(
                    id: id,
                    toolName: name,
                    segments: [.text(Transcript.TextSegment(content: content))]
                )))
            }
        }

        let session = LanguageModelSession(
            model: model.withThinkingEnabled(thinkingEnabled),
            transcript: Transcript(entries: entries)
        )
        let transcriptCountBefore = session.transcript.count

        // The stream only stops through task cancellation (this SDK build
        // has no `stopResponding`), so the generation runs in a tracked
        // child task that `cancel()` can actually reach.
        let generation = Task<Void, Error> {
            var previous = ""
            for try await snapshot in session.streamResponse(
                to: plan.latestUser,
                options: FoundationModels.GenerationOptions(
                    temperature: temperature,
                    maximumResponseTokens: maxTokens
                )
            ) {
                try Task.checkCancellation()
                let full = snapshot.content
                let delta = ApplePrivateCloud.streamDelta(previous: previous, full: full)
                previous = full
                if !delta.isEmpty { onToken(delta) }
            }
        }
        task = generation
        defer { task = nil }
        try await withTaskCancellationHandler {
            try await generation.value
        } onCancel: {
            generation.cancel()
        }

        // Models whose tokenizer carries tool-call special tokens have the
        // `<tool_call>` markup routed by the executor into transcript
        // `ToolCall` entries — it never appears in the streamed text. Re-
        // encode those calls as Hermes envelopes so the shared HTTP parser
        // can return them to API clients, matching how the MLX path
        // re-encodes native tool-call events.
        var envelopes = ""
        for entry in session.transcript.dropFirst(transcriptCountBefore) {
            guard case .toolCalls(let calls) = entry else { continue }
            for call in calls {
                envelopes += Self.hermesEnvelope(
                    id: call.id,
                    name: call.toolName,
                    argumentsJSON: call.arguments.jsonString
                )
            }
        }
        if !envelopes.isEmpty {
            Diagnostics.shared.breadcrumb(
                "Core AI surfaced tool calls from the session transcript · \(envelopes.count) characters",
                category: "coreai"
            )
            onToken(envelopes)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func drain() async {
        if let task { _ = await task.result }
    }

    private static func hermesEnvelope(
        id: String,
        name: String,
        argumentsJSON: String
    ) -> String {
        let arguments = (try? JSONSerialization.jsonObject(
            with: Data(argumentsJSON.utf8)
        )) as? [String: Any] ?? [:]
        // Include the model-supplied call id when it round-trips; the
        // server parser generates a stable id otherwise.
        let payload: [String: Any] = [
            "id": id,
            "name": name,
            "arguments": arguments
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ),
              let json = String(data: data, encoding: .utf8) else {
            return "<tool_call>{\"name\":\"\(name)\",\"arguments\":{}}</tool_call>"
        }
        return "<tool_call>\(json)</tool_call>"
    }
}
#endif

private final class CoreAIUnavailableRuntime: CoreAIRuntime {
    func load(resourcesAt url: URL) async throws {
        throw CoreAIInferenceError.unavailable("Build this target with the Xcode 27 SDK to use Core AI.")
    }

    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Double,
        thinkingEnabled: Bool?,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws {
        throw CoreAIInferenceError.unavailable("Core AI is unavailable in this build.")
    }

    func cancel() {}
    func drain() async {}
}

private extension CoreAIInferenceService {
    func makeRuntime() -> CoreAIRuntime {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst) && canImport(CoreAI) && canImport(FoundationModels) && canImport(CoreAILanguageModels)
        if #available(iOS 27.0, *) { return CoreAIAvailableRuntime() }
        #endif
        return CoreAIUnavailableRuntime()
    }
}
