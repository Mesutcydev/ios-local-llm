import Foundation
import Observation
import UIKit

// MARK: - LocalAIController

@MainActor
@Observable
public final class LocalAIController {
    public private(set) var activeModel: LocalModel?
    public private(set) var loadState: LoadState = .unloaded
    public private(set) var generationState: GenerationState = .idle
    public private(set) var tokenRate: Double = 0
    public private(set) var resourceStatus: ResourceStatus
    public private(set) var downloadProgress = DownloadProgress()
    public var selectedVectorStorageMode: VectorStorageMode
    public private(set) var preheatStatus: PreheatStatus = .idle

    @ObservationIgnored private let config: LocalAIFoundationConfig
    @ObservationIgnored private let session = InferenceSessionActor()
    @ObservationIgnored private let assistant = CodingAssistantService.shared

    public init(
        config: LocalAIFoundationConfig = .default,
        selectedVectorStorageMode: VectorStorageMode = .automatic
    ) {
        self.config = config
        self.selectedVectorStorageMode = selectedVectorStorageMode
        self.resourceStatus = Self.makeResourceStatus()
        self.activeModel = LocalModel(assistantModel: CodingAssistantService.shared.activeModel, config: config)
        self.loadState = Self.mapLoadState(CodingAssistantService.shared.state)
    }

    public func refreshResourceStatus() {
        resourceStatus = Self.makeResourceStatus()
        activeModel = LocalModel(assistantModel: assistant.activeModel, config: config)
        loadState = Self.mapLoadState(assistant.state)
        tokenRate = assistant.tokenRate
    }

    public func load(_ model: LocalModel? = nil) async throws {
        refreshResourceStatus()
        if let reason = DeviceSafetyMonitor.shared.stopReason {
            throw RuntimeError.modelLoadBlocked(reason: reason.detail)
        }

        if let model {
            let assistantModel = try resolveAssistantModel(model)
            await assistant.switchTo(assistantModel, persistAsDefault: false)
        } else {
            await assistant.load()
        }

        refreshResourceStatus()
        if case .failed(let message) = loadState {
            throw RuntimeError.modelLoadBlocked(reason: message)
        }
    }

    public func unloadActiveModel() async {
        await assistant.unloadAndWaitForCleanup()
        refreshResourceStatus()
    }

    public func generate(
        messages: [ChatMessage],
        options: GenerationOptions = .default
    ) -> AsyncThrowingStream<TokenEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: RuntimeError.noActiveModel)
                    return
                }
                do {
                    try await self.session.run {
                        try Task.checkCancellation()
                        await MainActor.run {
                            self.generationState = .generating
                            self.refreshResourceStatus()
                        }

                        continuation.yield(.started)
                        if options.toolMode != .disabled {
                            continuation.yield(.warning(
                                "Tool mode is a host-app feature; this facade streams model text and leaves tool execution to CodeLens."
                            ))
                        }

                        let sampler = SamplerConfig(
                            temperature: options.temperature,
                            topP: options.topP,
                            topK: nil,
                            minP: nil,
                            repetitionPenalty: options.repetitionPenalty,
                            frequencyPenalty: nil,
                            presencePenalty: nil,
                            seed: options.seed
                        )
                        let forceNoThinking = options.thinkingMode == .disabled

                        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                            let completion = SingleFire {
                                done.resume()
                            }
                            Task { @MainActor [weak self] in
                                guard let self else {
                                    completion.fire()
                                    return
                                }
                                self.assistant.generate(
                                    messages: messages,
                                    maxTokensOverride: options.maxTokens,
                                    temperatureOverride: options.temperature,
                                    topPOverride: options.topP,
                                    samplerConfig: sampler,
                                    jsonMode: options.jsonMode,
                                    forceNoThinking: forceNoThinking,
                                    onToken: { token in
                                        continuation.yield(.token(token))
                                    },
                                    onComplete: { rate in
                                        continuation.yield(.usage(
                                            tokensPerSecond: rate,
                                            inputTokens: nil,
                                            outputTokens: nil
                                        ))
                                        Task { @MainActor [weak self] in
                                            self?.tokenRate = rate
                                        }
                                        completion.fire()
                                    }
                                )
                            }
                        }

                        await MainActor.run {
                            self.generationState = .idle
                            self.refreshResourceStatus()
                        }
                        continuation.yield(.completed)
                        continuation.finish()
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        self.generationState = .idle
                        self.refreshResourceStatus()
                    }
                    continuation.finish(throwing: RuntimeError.generationCancelled)
                } catch is InferenceSessionActor.Cancelled {
                    await MainActor.run {
                        self.generationState = .idle
                        self.refreshResourceStatus()
                    }
                    continuation.finish(throwing: RuntimeError.generationCancelled)
                } catch {
                    await MainActor.run {
                        self.generationState = .failed(error.localizedDescription)
                        self.refreshResourceStatus()
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task { @MainActor [weak self] in
                    self?.cancelGeneration()
                }
            }
        }
    }

    public func describeImage(
        _ image: PlatformImage,
        prompt: String = "Describe what's in this image. Be concise.",
        options: GenerationOptions = .default
    ) -> AsyncThrowingStream<TokenEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: RuntimeError.noActiveModel)
                    return
                }
                do {
                    try await self.session.run {
                        try Task.checkCancellation()
                        guard let target = await MainActor.run(body: { self.selectedVisionTarget() }) else {
                            throw RuntimeError.unsupportedOperation(
                                "The default FastVLM UIImage path is not exposed through LocalAIController yet."
                            )
                        }

                        continuation.yield(.started)
                        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                            let completion = SingleFire {
                                done.resume()
                            }
                            Task { @MainActor in
                                do {
                                    switch target.runtime {
                                    case .llamaCpp:
                                        if LlamaCppVLMService.shared.activeRepoID != target.repoID {
                                            throw RuntimeError.modelNotLoaded(target.repoID)
                                        }
                                        LlamaCppVLMService.shared.describe(
                                            image: image,
                                            prompt: prompt,
                                            maxTokens: options.maxTokens,
                                            onToken: { continuation.yield(.token($0)) },
                                            onComplete: { rate in
                                                continuation.yield(.usage(
                                                    tokensPerSecond: rate,
                                                    inputTokens: nil,
                                                    outputTokens: nil
                                                ))
                                                completion.fire()
                                            }
                                        )
                                    case .mlx:
                                        if MLXVisionService.shared.activeRepoID != target.repoID {
                                            throw RuntimeError.modelNotLoaded(target.repoID)
                                        }
                                        MLXVisionService.shared.describe(
                                            image: image,
                                            prompt: prompt,
                                            maxTokens: options.maxTokens,
                                            onToken: { continuation.yield(.token($0)) },
                                            onComplete: { rate in
                                                continuation.yield(.usage(
                                                    tokensPerSecond: rate,
                                                    inputTokens: nil,
                                                    outputTokens: nil
                                                ))
                                                completion.fire()
                                            }
                                        )
                                    }
                                } catch {
                                    done.resume(throwing: error)
                                }
                            }
                        }
                        continuation.yield(.completed)
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task { @MainActor [weak self] in
                    self?.cancelGeneration()
                }
            }
        }
    }

    public func preheat(_ target: PreheatTarget) async {
        preheatStatus = .preparing(target)
        switch target {
        case .text(let modelID):
            do {
                if let model = localAssistantModel(id: modelID) {
                    try await load(model)
                } else {
                    try await load()
                }
                preheatStatus = .ready(target)
            } catch {
                preheatStatus = .failed(error.localizedDescription)
            }

        case .vision(let modelID):
            let runtime = LocalModelRegistry.visionRuntime(
                forStoredSelectionID: modelID,
                catalog: ModelDownloadCenter.shared.models
            )
            let repoID = LocalModelRegistry.persistedVisionRepoID(for: modelID)
            switch runtime {
            case .llamaCpp:
                await LlamaCppVLMService.shared.switchTo(repoID: repoID)
            case .mlx:
                await MLXVisionService.shared.switchTo(repoID: repoID)
            }
            preheatStatus = .ready(target)
        }
    }

    public func preheatVLM(modelID: String) async {
        await preheat(.vision(modelID: modelID))
    }

    /// Fetches the repo's Hugging Face metadata and runs the app's on-device
    /// compatibility verdict — same gate the download UI uses.
    public func scanRepo(_ repoID: String) async throws -> CompatibilityResult {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)") else {
            throw RuntimeError.underlying("Invalid repo id: \(repoID)")
        }
        var request = URLRequest(url: url)
        request.setValue("CodeLens iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        HFTokenStore.authorize(&request)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RuntimeError.underlying("Hugging Face has no readable metadata for \(repoID).")
        }
        let summary = HFModelSummary(json: json)
        return CompatibilityResult(repoID: repoID, verdict: OnDeviceCompatibility.verdict(for: summary))
    }

    /// Starts (or resumes) the download for a model already in the catalog.
    /// Custom HF repos must be registered via the search flow first.
    public func download(repoID: String) async throws {
        guard let model = ModelDownloadCenter.shared.models.first(where: { $0.id == repoID }) else {
            throw RuntimeError.underlying("No catalog entry for \(repoID). Add it from Hugging Face search first.")
        }
        model.start()
    }

    @discardableResult
    public func importModel(from url: URL) async throws -> String {
        try await LocalModelImportService.shared.importModel(from: url)
    }

    public func deleteModel(id: String) async throws {
        let center = ModelDownloadCenter.shared
        guard let model = center.models.first(where: { $0.id == id }) else {
            throw RuntimeError.underlying("No installed model with id \(id).")
        }
        // ponytail: handleDeletion is the app's canonical path (resets active
        // selections, unloads weights, unregisters). It reports file-delete
        // failures via ToastCenter rather than throwing — keeping that here
        // avoids duplicating resetActiveSelections just to re-throw.
        center.handleDeletion(of: model)
    }

    public func cancelGeneration() {
        generationState = .cancelling
        assistant.stopGeneration()
        MLXVisionService.shared.cancelCurrentInference()
        LlamaCppVLMService.shared.cancelCurrentInference()
        Task {
            await session.cancelAll()
            await MainActor.run {
                self.generationState = .idle
                self.refreshResourceStatus()
            }
        }
    }

    private func selectedVisionTarget() -> (runtime: ModelRuntime, repoID: String)? {
        let stored = AppSettings.shared.cameraVisualModelID
        let selectionID = LocalModelRegistry.storedVisionSelectionID(stored)
        guard !LocalModelRegistry.isDefaultVisionSelection(selectionID) else { return nil }
        let runtime = LocalModelRegistry.visionRuntime(
            forStoredSelectionID: stored,
            catalog: ModelDownloadCenter.shared.models
        )
        return (runtime, LocalModelRegistry.persistedVisionRepoID(for: selectionID))
    }

    private func resolveAssistantModel(_ model: LocalModel) throws -> AssistantModel {
        guard model.runtime == .mlx else {
            throw RuntimeError.unsupportedOperation(
                "Text generation through \(model.runtime.label) is not wired behind LocalAIController yet."
            )
        }
        if let preset = AssistantModelCatalog.presets.first(where: {
            $0.id == model.id || $0.repoID == model.repoID
        }) {
            return preset
        }
        return AssistantModel(
            id: model.id,
            repoID: model.repoID,
            displayName: model.displayName,
            subtitle: "custom · MLX",
            approxRAMBytes: model.approxRAMBytes,
            tags: [],
            contextWindowTokens: model.contextWindowTokens,
            capabilities: model.capabilities,
            supportsTools: model.capabilities.contains(.tools),
            runtime: model.runtime
        )
    }

    private func localAssistantModel(id: String) -> LocalModel? {
        AssistantModelCatalog.presets
            .first(where: { $0.id == id || $0.repoID == id })
            .map { LocalModel(assistantModel: $0, config: config) }
    }

    private static func mapLoadState(_ state: CodingAssistantService.ServiceState) -> LoadState {
        switch state {
        case .unloaded:
            return .unloaded
        case .loading(let message):
            return .loading(message)
        case .ready, .generating:
            return .ready
        case .failed(let message):
            return .failed(message)
        }
    }

    private static func makeResourceStatus() -> ResourceStatus {
        let safety = DeviceSafetyMonitor.shared
        return ResourceStatus(
            availableMemoryBytes: MemoryAdvisor.availableMemoryForModel,
            physFootprintBytes: MemoryAdvisor.physFootprint,
            thermalStateDescription: String(describing: safety.effectiveThermalState),
            isLowPowerModeEnabled: safety.lowPowerMode,
            shouldStopHeavyWork: safety.shouldStopHeavyWork
        )
    }
}

private final class SingleFire: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let body: @Sendable () -> Void

    init(_ body: @escaping @Sendable () -> Void) {
        self.body = body
    }

    func fire() {
        lock.lock()
        let shouldFire = !fired
        fired = true
        lock.unlock()
        if shouldFire {
            body()
        }
    }
}
