import XCTest
@testable import IOSLocalLLM

// MARK: - ModelCategoryInferenceTests
//
// Pins the category inference that decides whether a model is an assistant,
// a vision/VLM, a voice, or an image-generation (diffusion) model — the logic
// behind "recognize image models at download and when downloaded" and the
// per-category headers in the Models tab.

final class ModelCategoryInferenceTests: XCTestCase {
    func test_lfm3UsesPinnedGGUFWithoutChangingDefault() throws {
        let model = try XCTUnwrap(AssistantModelCatalog.model(forID: "lfm3-1.7b-gguf"))
        XCTAssertEqual(AssistantModelCatalog.presets.first?.id, "qwen3-4b-2507")
        XCTAssertEqual(model.runtime, .llamaCpp)
        XCTAssertEqual(model.contextWindowTokens, 4_096)
        XCTAssertEqual(model.downloadRevision, "b3f2ae5d73cd3c91bf40e8ba752c648aa05dffdf")
        XCTAssertEqual(model.downloadFiles, ["LFM3-1.7B-QAD-Q4_0.gguf", "LICENSE"])
        XCTAssertTrue(model.supportsTools)
        XCTAssertTrue(model.supportsThinking)
        XCTAssertTrue(model.usesChatML)
    }

    func test_lfm3AudioAndOmniUseNonReasoningPromptsAndProjectors() throws {
        for id in ["lfm3-audio-2b-gguf", "lfm3-omni-2b-gguf"] {
            let model = try XCTUnwrap(AssistantModelCatalog.model(forID: id))
            XCTAssertTrue(model.supportsNativeAudio)
            XCTAssertTrue(model.supportsTools)
            XCTAssertFalse(model.supportsThinking)
            XCTAssertEqual(model.runtime, .llamaCpp)
            XCTAssertEqual(model.downloadFiles?.filter { $0.hasPrefix("mmproj") }.count, 1)
            let prompt = model.chatTemplate.format(messages: [ChatMessage(role: .user, content: "Hello")], enableThinking: true)
            XCTAssertTrue(prompt.hasPrefix("<|startoftext|>"))
            XCTAssertFalse(prompt.contains("<think>\n"))
            if id == "lfm3-audio-2b-gguf" {
                // The shipped Audio checkpoint has no reasoning cue at all.
                XCTAssertTrue(prompt.hasSuffix("<|im_start|>assistant\n"))
                XCTAssertFalse(prompt.contains("<think>"))
            } else {
                XCTAssertTrue(prompt.hasSuffix("<|im_start|>assistant\n<think></think>"))
            }
        }
        XCTAssertTrue(AssistantModelCatalog.model(forID: "lfm3-omni-2b-gguf")?.supportsVision == true)
        XCTAssertFalse(AssistantModelCatalog.model(forID: "lfm3-audio-2b-gguf")?.supportsVision == true)
        XCTAssertEqual(ChatTemplate.detect(for: "LiquidAI/LFM3-Audio-2B-GGUF"), .lfm3Audio)
        XCTAssertEqual(ChatTemplate.detect(for: "LiquidAI/LFM3-Omni-2B-GGUF"), .lfm3Omni)
    }

    func test_lfm3ReplaysAPIPreviousToolCallsAsNativeHistory() {
        let prompt = ChatTemplate.lfm3.format(messages: [
            ChatMessage(role: .user, content: "What is 2 + 2?"),
            ChatMessage(role: .assistant, content: "Let me check.\n\n[Previous tool calls]\ncall_id=call_1 name=calculator arguments={\"expression\":\"2+2\"}"),
            ChatMessage(role: .user, content: "[Tool result for call_id=call_1]\n4"),
            ChatMessage(role: .user, content: "Thanks"),
        ])
        XCTAssertTrue(prompt.contains(
            "<|im_start|>assistant\n<think></think>Let me check.\n\n"
            + "<tool_call>\n<function=calculator>\n"
            + "<parameter=expression>\n2+2\n</parameter>\n"
            + "</function>\n</tool_call><|im_end|>"
        ))
        XCTAssertTrue(prompt.contains(
            "<|im_start|>tool\n<tool_response>\n[Tool result for call_id=call_1]\n4\n</tool_response><|im_end|>"
        ))
        XCTAssertFalse(prompt.contains("[Previous tool calls]"))
        XCTAssertFalse(prompt.contains("call_id=call_1 name=calculator"))
    }

    func test_lfm3ClosedAssistantTurnsReplayNonReasoningCue() {        let textTemplate = ChatTemplate.lfm3
        let history = textTemplate.format(messages: [
            ChatMessage(role: .user, content: "First question"),
            ChatMessage(role: .assistant, content: "<think>hidden</think>First answer"),
            ChatMessage(role: .user, content: "Second question"),
        ])
        XCTAssertTrue(history.contains("<|im_start|>assistant\n<think></think>First answer<|im_end|>"))
        XCTAssertFalse(history.contains("hidden"))

        let audioTemplate = ChatTemplate.lfm3Audio
        let audioHistory = audioTemplate.format(messages: [
            ChatMessage(role: .user, content: "First question"),
            ChatMessage(role: .assistant, content: "First answer"),
            ChatMessage(role: .user, content: "Second question"),
        ])
        XCTAssertTrue(audioHistory.contains("<|im_start|>assistant\nFirst answer<|im_end|>"))
        XCTAssertFalse(audioHistory.contains("<think></think>First answer"))

        let omniHistory = ChatTemplate.lfm3Omni.format(messages: [
            ChatMessage(role: .user, content: "First question"),
            ChatMessage(role: .assistant, content: "First answer"),
            ChatMessage(role: .user, content: "Second question"),
        ])
        XCTAssertTrue(omniHistory.contains("<|im_start|>assistant\n<think></think>First answer<|im_end|>"))
    }

    func test_lfm3NativeToolInstructionsAndResponsesKeepTheirRoles() {
        let prompt = ChatTemplate.lfm3.format(messages: [
            ChatMessage(role: .system, content: ToolRunner.systemPromptAddendum),
            ChatMessage(role: .user, content: "What time is it?"),
            ChatMessage(role: .tool, content: "12:30"),
        ])
        XCTAssertTrue(prompt.contains("<tools>"))
        // The released template's tool_to_json key order and separators.
        XCTAssertTrue(prompt.contains(#"{"name": "calculator", "description": "Evaluate an arithmetic expression.", "parameters": "#))
        XCTAssertFalse(prompt.contains("PARAMETER_NAME"))
        XCTAssertFalse(prompt.contains("emit a fenced"))
        XCTAssertTrue(prompt.contains("<|im_start|>tool\n<tool_response>\n12:30\n</tool_response>"))
    }

    func test_lfm3ThinkingTemplateDoesNotSendQwenCommands() {
        let template = ChatTemplate.detect(for: "LiquidAI/LFM3-1.7B-GGUF")
        let messages = [ChatMessage(role: .user, content: "Hello")]
        let thinking = template.format(messages: messages, enableThinking: true)
        let direct = template.format(messages: messages, enableThinking: false)
        XCTAssertEqual(thinking, "<|startoftext|><|im_start|>user\nHello<|im_end|>\n<|im_start|>assistant\n<think>")
        XCTAssertEqual(direct, "<|startoftext|><|im_start|>user\nHello<|im_end|>\n<|im_start|>assistant\n<think></think>")
        XCTAssertFalse(thinking.contains("/think"))
        XCTAssertFalse(direct.contains("/no_think"))
        XCTAssertEqual(ChatTemplate.detect(for: "mlx-community/Qwen3-4B-4bit"), .chatML)
        XCTAssertEqual(ChatTemplate.detect(for: "mlx-community/Llama-3.2-3B-Instruct-4bit"), .llama3)
    }

    func test_lfm3VisionMarkerAndContinuationKeepOneBOS() {
        let template = ChatTemplate.lfm3
        let messages = [
            ChatMessage(role: .user, content: "<__media__>\nDescribe this image."),
            ChatMessage(role: .assistant, content: "A red"),
        ]
        let prompt = template.format(messages: messages, leaveLastAssistantOpen: true)
        XCTAssertTrue(prompt.hasPrefix("<|startoftext|><|im_start|>user\n<__media__>"))
        // The continuation replays the cue the reply was generated after.
        XCTAssertTrue(prompt.hasSuffix("<|im_start|>assistant\n<think></think>A red"))
        XCTAssertEqual(prompt.components(separatedBy: "<|startoftext|>").count, 2)
        let midReasoning = template.format(messages: [
            ChatMessage(role: .user, content: "Why?"),
            ChatMessage(role: .assistant, content: "Because"),
        ], enableThinking: true, leaveLastAssistantOpen: true)
        XCTAssertTrue(midReasoning.hasSuffix("<|im_start|>assistant\n<think>Because"))
    }

    func test_lfm3ToolStepsAfterTheUserKeepReasoningAndCue() {
        // Chat feeds tool results as user-role "TOOL RESULT:" turns; LFM3
        // renders them as tool turns, so the call step stays in the current turn.
        let chat = ChatTemplate.lfm3.format(messages: [
            ChatMessage(role: .user, content: "Weather?"),
            ChatMessage(role: .assistant, content: "plan it</think><tool_call>\n<function=web_search>\n<parameter=query>\nweather\n</parameter>\n</function>\n</tool_call>"),
            ChatMessage(role: .user, content: "TOOL RESULT: web_search\n\nSunny"),
        ], enableThinking: true)
        XCTAssertTrue(chat.contains("<|im_start|>assistant\n<think>plan it</think><tool_call>"))
        XCTAssertTrue(chat.contains("<|im_start|>tool\n<tool_response>\nTOOL RESULT: web_search"))
        XCTAssertTrue(chat.hasSuffix("<|im_start|>assistant\n<think>"))

        let voice = ChatTemplate.lfm3Omni.format(messages: [
            ChatMessage(role: .user, content: "Time?"),
            ChatMessage(role: .assistant, content: "<tool_call>\n<function=datetime>\n</function>\n</tool_call>"),
            ChatMessage(role: .tool, content: "12:30"),
        ])
        XCTAssertTrue(voice.contains("<|im_start|>assistant\n<think></think><tool_call>"))
    }

    func test_lfm3ReplaysChatToolCallBeforeItsResult() throws {
        // Chat removes the call turn from the transcript and keeps the call on the result.
        var result = ChatMessage(role: .user, content: "TOOL RESULT: web_search\n\nSunny")
        result.toolCallJSON = try XCTUnwrap(ToolCall(name: "web_search", args: ["query": "weather"]).json)
        let messages = [ChatMessage(role: .user, content: "Weather?"), result]
        XCTAssertTrue(ChatTemplate.lfm3.format(messages: messages).contains(
            "<|im_start|>user\nWeather?<|im_end|>\n"
            + "<|im_start|>assistant\n<think></think><tool_call>\n<function=web_search>\n"
            + "<parameter=query>\nweather\n</parameter>\n</function>\n</tool_call><|im_end|>\n"
            + "<|im_start|>tool\n<tool_response>\nTOOL RESULT: web_search"))
        XCTAssertFalse(ChatTemplate.chatML.format(messages: messages).contains("<tool_call>"))
        // Voice and the API keep their own call turn; never duplicate it.
        let voice = ChatTemplate.lfm3Omni.format(messages: [
            messages[0], ChatMessage(role: .assistant, content: "<tool_call>\n</tool_call>"), result,
        ])
        XCTAssertEqual(voice.components(separatedBy: "<tool_call>").count, 2)
    }

    func test_lfm3NativePromptSplitsAtCueAndKeepsMediaInUserTurn() throws {
        let template = ChatTemplate.lfm3Omni
        let afterTool = template.format(messages: [
            ChatMessage(role: .user, content: "What time is it?"),
            ChatMessage(role: .assistant, content: "<tool_call>\n<function=datetime>\n</function>\n</tool_call>"),
            ChatMessage(role: .tool, content: "12:30"),
        ])
        let split = try XCTUnwrap(LlamaCppVLM.splitLFM3Prompt(afterTool, template: template, mediaMarkers: "\n<__media__>"))
        XCTAssertEqual(split.cue, "<|im_start|>assistant\n<think></think>")
        XCTAssertTrue(split.body.contains("<|im_start|>user\nWhat time is it?\n<__media__><|im_end|>"))
        XCTAssertTrue(split.body.hasSuffix("<tool_response>\n12:30\n</tool_response><|im_end|>\n"))

        let resumed = template.format(messages: [
            ChatMessage(role: .user, content: "Tell me a story"),
            ChatMessage(role: .assistant, content: "Once upon"),
        ], leaveLastAssistantOpen: true)
        let continued = try XCTUnwrap(LlamaCppVLM.splitLFM3Prompt(resumed, template: template, mediaMarkers: ""))
        XCTAssertEqual(continued.cue, "<|im_start|>assistant\n<think></think>Once upon")
        XCTAssertTrue(continued.body.hasSuffix("Tell me a story<|im_end|>\n"))
    }

    @MainActor
    func test_lfm3CatalogDownloadsOnlyOneQuantizationAndProjector() throws {
        let catalog = ModelDownloadCenter.shared.models
        let text = try XCTUnwrap(catalog.first { $0.id == "lfm3-1.7b-gguf" })
        XCTAssertEqual(text.runtime, .llamaCpp)
        XCTAssertEqual(text.downloader?.branch, "b3f2ae5d73cd3c91bf40e8ba752c648aa05dffdf")
        XCTAssertEqual(text.downloader?.fileAllowlist, ["LFM3-1.7B-QAD-Q4_0.gguf", "LICENSE"])
        let vision = try XCTUnwrap(catalog.first { $0.id == "LiquidAI/LFM3-VL-2B-GGUF" })
        XCTAssertEqual(vision.category, .vlm)
        XCTAssertEqual(vision.runtime, .llamaCpp)
        XCTAssertEqual(vision.downloader?.branch, "7c3b4a43c9023e80bf234fec5e826a3365c8dda8")
        XCTAssertEqual(vision.downloader?.fileAllowlist, [
            "LFM3-VL-2B-QAD-Q4_0.gguf", "mmproj-LFM3-VL-2B-Q8_0.gguf", "LICENSE",
        ])
        XCTAssertTrue(vision.capabilities.contains(.vision))
    }

    func test_importedGGUFVLMTailDirectoryIsRecognized() throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = "local_LFM3-VL-import-test-\(UUID().uuidString)"
        let dir = docs.appendingPathComponent("HFModels").appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data([0x47, 0x47, 0x55, 0x46]) + Data(repeating: 1, count: 60)
        try bytes.write(to: dir.appendingPathComponent("LFM3-VL-2B-QAD-Q4_0.gguf"))
        try bytes.write(to: dir.appendingPathComponent("mmproj-LFM3-VL-2B-Q8_0.gguf"))

        let found = LlamaCppVLMService.stagedDirectory(for: "local/\(folder)")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.lastPathComponent, folder)
        XCTAssertEqual(found?.resolvingSymlinksInPath().path, dir.resolvingSymlinksInPath().path)
    }

    @MainActor
    func test_curatedAssistantDoesNotTreatAnotherGGUFVariantAsInstalled() throws {
        let folder = "curated-gguf-test-\(UUID().uuidString)"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("LLMModels").appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let magic = Data("GGUF".utf8)
        try magic.write(to: dir.appendingPathComponent("another-Q4_K_M.gguf"))
        var model = AssistantModel(
            id: folder, repoID: "test/\(folder)", displayName: "Test", subtitle: "",
            approxRAMBytes: 1, tags: [], contextWindowTokens: 4096,
            downloadFiles: ["selected-Q2_0.gguf"], runtime: .llamaCpp
        )
        XCTAssertNil(CodingAssistantService.preStagedDirectory(for: model))
        XCTAssertFalse(CodingAssistantService.isInstalled(model))
        try magic.write(to: dir.appendingPathComponent("selected-Q2_0.gguf"))
        XCTAssertEqual(CodingAssistantService.preStagedDirectory(for: model)?.lastPathComponent, folder)
        XCTAssertTrue(CodingAssistantService.isInstalled(model))
        model.downloadFiles = nil
        try FileManager.default.removeItem(at: dir.appendingPathComponent("selected-Q2_0.gguf"))
        XCTAssertTrue(CodingAssistantService.isInstalled(model), "Generic imports still accept their valid GGUF")
    }

    func test_explicitConversationSwitchPreservesItsLoadTarget() {
        let savedDefault = AssistantModel(
            id: "downloaded:MercuriusDream/Nanbeige4.2-3B-mlx-4bit",
            repoID: "MercuriusDream/Nanbeige4.2-3B-mlx-4bit",
            displayName: "Nanbeige 3B",
            subtitle: "4-bit",
            approxRAMBytes: 3_000_000_000,
            tags: [],
            contextWindowTokens: 4_096
        )
        let conversationSelection = AssistantModel(
            id: "downloaded:Jackrong/MLX-Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-4bit",
            repoID: "Jackrong/MLX-Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-4bit",
            displayName: "Qwen3.5 9B",
            subtitle: "4-bit",
            approxRAMBytes: 6_500_000_000,
            tags: [],
            contextWindowTokens: 4_096
        )

        let resolved = CodingAssistantService.loadTarget(
            activeModel: conversationSelection,
            savedDefault: savedDefault,
            reselectFromSettings: false
        )

        XCTAssertEqual(resolved.id, conversationSelection.id)
        XCTAssertNotEqual(resolved.id, savedDefault.id)
    }

    func test_normalLoadStillUsesSavedDefault() {
        let savedDefault = AssistantModel(
            id: "downloaded:MercuriusDream/Nanbeige4.2-3B-mlx-4bit",
            repoID: "MercuriusDream/Nanbeige4.2-3B-mlx-4bit",
            displayName: "Nanbeige 3B",
            subtitle: "4-bit",
            approxRAMBytes: 3_000_000_000,
            tags: [],
            contextWindowTokens: 4_096
        )
        let currentSelection = AssistantModel(
            id: "downloaded:Jackrong/MLX-Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-4bit",
            repoID: "Jackrong/MLX-Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-4bit",
            displayName: "Qwen3.5 9B",
            subtitle: "4-bit",
            approxRAMBytes: 6_500_000_000,
            tags: [],
            contextWindowTokens: 4_096
        )

        let resolved = CodingAssistantService.loadTarget(
            activeModel: currentSelection,
            savedDefault: savedDefault,
            reselectFromSettings: true
        )

        XCTAssertEqual(resolved.id, savedDefault.id)
    }

    @MainActor
    func test_installedRegistryModelIsReconciledIntoModelsTabSource() throws {
        let repoID = "Jackrong/test-\(UUID().uuidString)"
        let directory = ModelStoragePaths.modelRoots[1]
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            ModelDownloadCenter.shared.unregisterCustom(repoID: repoID)
        }
        try Data(#"{"architectures":["Qwen3ForCausalLM"]}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        try Data(#"{"model_max_length":4096}"#.utf8)
            .write(to: directory.appendingPathComponent("tokenizer_config.json"))
        try Data([0x01])
            .write(to: directory.appendingPathComponent("model.safetensors"))

        let record = try XCTUnwrap(
            InstalledModelRegistry.validateDirectory(directory, repoID: repoID)
        )
        XCTAssertTrue(record.validationState.isActivatable)

        ModelDownloadCenter.shared.reconcileInstalledRegistry(records: [record])

        let installed = ModelDownloadCenter.shared.models.first {
            $0.sourceRepoID.caseInsensitiveCompare(repoID) == .orderedSame
        }
        XCTAssertNotNil(installed)
        XCTAssertTrue(installed?.isReady == true)
        XCTAssertEqual(installed?.category, .assistant)
    }

    @MainActor
    func test_installedRegistryAcceptsStandaloneGGUFWithoutConfigJSON() throws {
        // A GGUF text model embeds its tokenizer and metadata, so it ships
        // WITHOUT config.json / tokenizer.json. The installed registry must
        // admit it as a llamaCpp activatable model; otherwise the model shows
        // as ready in the catalog but the conversation picker (registry-backed)
        // reports "download model first".
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        // Minimal GGUF: the 4 magic bytes are all LocalModelFileValidator
        // checks to confirm a file is a real GGUF.
        try Data([0x47, 0x47, 0x55, 0x46])
            .write(to: directory.appendingPathComponent("model.Q4_K_M.gguf"))

        let record = try XCTUnwrap(
            InstalledModelRegistry.validateDirectory(directory, repoID: "local/Qwen3-4B-Q4")
        )
        XCTAssertEqual(record.engine, .llamaCpp)
        XCTAssertTrue(record.validationState.isActivatable)
    }


    private func cat(_ repo: String, pipeline: String? = nil, tags: [String] = []) -> DownloadableModel.Category {
        LocalModelRegistry.category(repoID: repo, pipelineTag: pipeline, tags: tags)
    }

    // MARK: Pipeline tags are authoritative

    func test_textToImagePipeline_isImageGen() {
        XCTAssertEqual(cat("some/repo", pipeline: "text-to-image"), .imageGen)
        XCTAssertEqual(cat("some/repo", pipeline: "image-to-image"), .imageGen)
        XCTAssertEqual(cat("some/repo", pipeline: "unconditional-image-generation"), .imageGen)
    }

    func test_visionPipeline_isVLM() {
        XCTAssertEqual(cat("some/repo", pipeline: "image-text-to-text"), .vlm)
        XCTAssertEqual(cat("some/repo", pipeline: "image-to-text"), .vlm)
        XCTAssertEqual(cat("some/repo", pipeline: "visual-question-answering"), .vlm)
    }

    func test_speechPipeline_isVoice() {
        XCTAssertEqual(cat("some/repo", pipeline: "text-to-speech"), .voice)
        XCTAssertEqual(cat("some/repo", pipeline: "automatic-speech-recognition"), .voice)
    }

    // MARK: Keyword / tag fallback when pipeline is missing

    func test_diffusionKeywords_isImageGen() {
        XCTAssertEqual(cat("stabilityai/stable-diffusion-2-1-base"), .imageGen)
        XCTAssertEqual(cat("stabilityai/sdxl-turbo"), .imageGen)
        XCTAssertEqual(cat("black-forest-labs/FLUX.1-schnell"), .imageGen)
    }

    func test_diffusersTag_isImageGen() {
        XCTAssertEqual(cat("anyorg/anymodel", tags: ["diffusers"]), .imageGen)
    }

    func test_visionKeywords_isVLM() {
        XCTAssertEqual(cat("Qwen/Qwen2.5-VL-3B-Instruct"), .vlm)
        XCTAssertEqual(cat("HuggingFaceTB/SmolVLM-Instruct"), .vlm)
    }

    func test_voiceKeywords_isVoice() {
        XCTAssertEqual(cat("openai/whisper-base"), .voice)
        XCTAssertEqual(cat("KittenML/kitten-tts"), .voice)
    }

    func test_plainLLM_isAssistant() {
        XCTAssertEqual(cat("Qwen/Qwen2.5-Coder-1.5B-Instruct"), .assistant)
        XCTAssertEqual(cat("meta-llama/Llama-3.2-1B-Instruct"), .assistant)
    }

    // MARK: Image-gen must not be misread as a vision (VLM) model

    func test_imageGenDoesNotCollideWithVision() {
        // A diffusion repo must land in imageGen, never vlm — the bug this fixes.
        XCTAssertNotEqual(cat("stabilityai/stable-diffusion-2-1-base"), .vlm)
        XCTAssertNotEqual(cat("stabilityai/stable-diffusion-2-1-base"), .assistant)
    }

    // MARK: Role mapping stays consistent

    func test_roleMapping() {
        XCTAssertEqual(LocalModelRegistry.role(for: .assistant), .assistant)
        XCTAssertEqual(LocalModelRegistry.role(for: .vlm), .vision)
        XCTAssertEqual(LocalModelRegistry.role(for: .voice), .voice)
        XCTAssertEqual(LocalModelRegistry.role(for: .imageGen), .image)
    }

    // MARK: - Capability inference (Tools / Coder / Fast / Multilingual pills)

    func test_inferred_supportsTools_addsToolsPill() {
        let caps = ModelCapability.inferred(repoID: "mlx-community/Qwen3-4B-4bit",
                                            supportsTools: true)
        XCTAssertTrue(caps.contains(.tools))
    }

    func test_inferred_withoutTools_omitsToolsPill() {
        let caps = ModelCapability.inferred(repoID: "mlx-community/Llama-3.2-1B-Instruct-4bit",
                                            supportsTools: false)
        XCTAssertFalse(caps.contains(.tools))
    }

    func test_inferred_coderRepo_addsCoderPill() {
        let caps = ModelCapability.inferred(repoID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit")
        XCTAssertTrue(caps.contains(.coder))
    }

    func test_inferred_codeTag_addsCoderPill() {
        let caps = ModelCapability.inferred(repoID: "some/model", tags: ["code"])
        XCTAssertTrue(caps.contains(.coder))
    }

    func test_inferred_fastTag_addsFastPill() {
        XCTAssertTrue(ModelCapability.inferred(repoID: "some/model", tags: ["fast"]).contains(.fast))
        XCTAssertTrue(ModelCapability.inferred(repoID: "some/model", tags: ["light"]).contains(.fast))
    }

    func test_inferred_multilingualFamilies() {
        XCTAssertTrue(ModelCapability.inferred(repoID: "Qwen/Qwen3-4B").contains(.multilingual))
        XCTAssertTrue(ModelCapability.inferred(repoID: "prism-ml/Bonsai-27B-mlx-1bit").contains(.multilingual))
        XCTAssertTrue(ModelCapability.inferred(repoID: "google/gemma-2-2b-it").contains(.multilingual))
    }

    func test_bonsaiCatalog_containsAllPublishedMLXVariants() {
        let bonsai = AssistantModelCatalog.presets.filter { $0.repoID.lowercased().contains("bonsai") }
        XCTAssertEqual(bonsai.count, 9)
        XCTAssertEqual(Set(bonsai.map(\.id)), [
            "bonsai-2.5-27b-ternary-gguf",
            "bonsai-27b-1bit", "bonsai-27b-ternary",
            "bonsai-8b-1bit", "bonsai-8b-ternary",
            "bonsai-4b-1bit", "bonsai-4b-ternary",
            "bonsai-1.7b-1bit", "bonsai-1.7b-ternary",
        ])
        XCTAssertTrue(bonsai.allSatisfy { $0.downloadSizeBytes != nil })
        XCTAssertTrue(bonsai.allSatisfy { $0.supportsThinking })
    }

    func test_ternaryBonsai25_isAMacOnlyStockLlamaCppQ2_0Preset() throws {
        let model = try XCTUnwrap(AssistantModelCatalog.model(forID: "bonsai-2.5-27b-ternary-gguf"))
        XCTAssertEqual(model.runtime, .llamaCpp)
        XCTAssertEqual(model.platformCompatibility, .macOnly)
        XCTAssertEqual(model.downloadRevision, "f71afa90d5f8f07f0518b6105eaf9b50e2c6d210")
        // Q2_0 is the only packing stock llama.cpp loads; PTQ1_0/PQ2_0 need PrismML's fork.
        XCTAssertEqual(model.downloadFiles, ["Ternary-Bonsai-2.5-27B-Q2_0.gguf", "LICENSE", "NOTICE.txt"])
        XCTAssertFalse(model.supportsVision)
        XCTAssertTrue(model.supportsThinking)
        XCTAssertTrue(model.supportsTools)
        XCTAssertEqual(ChatTemplate.detect(for: model.repoID), .qwen35)
    }

    func test_ornithIsAFirstClassHighMemoryAssistantPreset() throws {
        let ornith = try XCTUnwrap(
            AssistantModelCatalog.model(forID: "ornith-1.0-9b-4bit")
        )
        XCTAssertEqual(ornith.repoID, "mlx-community/Ornith-1.0-9B-4bit")
        XCTAssertEqual(ornith.platformCompatibility, .highMemoryMobileAndMac)
        XCTAssertEqual(ornith.contextWindowTokens, 4_096)
        XCTAssertLessThanOrEqual(
            ornith.approxRAMBytes + MemoryAdvisor.loadHeadroomReserve,
            MemoryAdvisor.maximumHighMemoryIPhoneProcessCeiling
        )
    }

    func test_bonsaiMetadata_resolvesVendorFamilyAndTemplates() {
        XCTAssertEqual(ModelVendor.infer(from: "prism-ml/Bonsai-27B-mlx-1bit"), .prism)
        XCTAssertEqual(ModelFamily.inferID(from: "prism-ml/Ternary-Bonsai-8B-mlx-2bit"), "bonsai")
        XCTAssertEqual(ModelFamily.displayName(forID: "bonsai"), "Bonsai")
        XCTAssertEqual(ChatTemplate.detect(for: "prism-ml/Bonsai-27B-mlx-1bit").format, "qwen35")
        XCTAssertEqual(ChatTemplate.detect(for: "prism-ml/Bonsai-4B-mlx-1bit").format, "chatml")
    }

    func test_chatTemplateUsesModelContextWithoutExposingItAsDisplayText() {
        let message = ChatMessage(
            role: .user,
            content: "Summarize this.",
            modelContent: "[FILE]\nSource text\nSummarize this."
        )

        let prompt = ChatTemplate.chatML.format(messages: [message])

        XCTAssertTrue(prompt.contains("[FILE]\nSource text\nSummarize this."))
        XCTAssertEqual(message.content, "Summarize this.")
    }

    func test_gemmaTemplate_foldsSystemIntoFirstUserTurnOnce() {
        let messages = [
            ChatMessage(role: .system, content: "Be brief."),
            ChatMessage(role: .user, content: "Hello"),
        ]
        let prompt = ChatTemplate.gemma.format(messages: messages)
        XCTAssertTrue(prompt.contains("<start_of_turn>user\nBe brief.\n\nHello<end_of_turn>"))
        XCTAssertEqual(prompt.components(separatedBy: "Be brief.").count - 1, 1)
        XCTAssertFalse(prompt.contains("System: Be brief."))
        XCTAssertTrue(prompt.hasSuffix("<start_of_turn>model\n"))
    }

    func test_chatMLTemplate_keepsDedicatedSystemTurn() {
        let messages = [
            ChatMessage(role: .system, content: "Be brief."),
            ChatMessage(role: .user, content: "Hello"),
        ]
        let prompt = ChatTemplate.chatML.format(messages: messages)
        XCTAssertTrue(prompt.contains("<|im_start|>system\nBe brief.<|im_end|>"))
        XCTAssertTrue(prompt.contains("<|im_start|>user\nHello<|im_end|>"))
        XCTAssertFalse(prompt.contains("Be brief.\n\nHello"))
    }

    func test_chatMLTemplate_leaveLastAssistantOpen_skipsGenerationCue() {
        let messages = [
            ChatMessage(role: .user, content: "Write a story"),
            ChatMessage(role: .assistant, content: "Once upon a time"),
        ]
        let open = ChatTemplate.chatML.format(
            messages: messages,
            leaveLastAssistantOpen: true
        )
        XCTAssertEqual(open, "<|im_start|>user\nWrite a story<|im_end|>\n<|im_start|>assistant\nOnce upon a time")
        let closed = ChatTemplate.chatML.format(messages: messages)
        XCTAssertTrue(closed.contains("<|im_end|>\n<|im_start|>assistant\n /no_think"))
    }

    func test_assistantOutputSanitizer_removesKnownQwenBoundaryLeaks() {
        XCTAssertEqual(
            AssistantOutputSanitizer.clean("\nassistant: off.\n\n### Result\n**Done**"),
            "### Result\n**Done**"
        )
        XCTAssertEqual(
            AssistantOutputSanitizer.clean(".\n\nThis is the answer."),
            "This is the answer."
        )
    }

    func test_assistantOutputSanitizer_preservesNormalAnswerText() {
        let answer = "Assistant: configure the setting to off.\n\nThen retry."
        XCTAssertEqual(AssistantOutputSanitizer.clean(answer), answer)
    }

    func test_assistantMarkdown_preservesSingleLineBreaks() {
        let source = AssistantOutputSanitizer.preservingLineBreaksForMarkdown(
            "Whether it's:\nSolving a problem\nCalculations\n\nDone"
        )
        XCTAssertEqual(
            source,
            "Whether it's:  \nSolving a problem  \nCalculations\n\nDone"
        )

        let rendered = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full)
        )
        XCTAssertTrue(
            String(rendered?.characters ?? AttributedString().characters)
                .hasPrefix("Whether it's:\nSolving a problem\nCalculations")
        )
    }

    func test_assistantMarkdown_repairsRunTogetherProseBoundaries() {
        let source = AssistantOutputSanitizer.preservingLineBreaksForMarkdown(
            "Please provide:Your name (full name)Any other detail.Ask again"
        )

        XCTAssertEqual(
            source,
            "Please provide:  \nYour name (full name)  \nAny other detail.\n\nAsk again"
        )
    }

    func test_assistantMarkdown_repairsRunTogetherHeadingsFromLocalModels() {
        let source = AssistantOutputSanitizer.preservingLineBreaksForMarkdown(
            "Document Title: OpusJakePurpose: A workflowDraft Removals — instructionsSubmit Them For MeKeep Me Gone"
        )

        XCTAssertEqual(
            source,
            "Document Title: OpusJake  \nPurpose: A workflow  \nDraft Removals — instructions  \nSubmit Them For Me  \nKeep Me Gone"
        )
    }

    func test_assistantMarkdown_repairsImageDescriptionLabels() {
        let source = AssistantOutputSanitizer.preservingLineBreaksForMarkdown(
            "Image DescriptionThis appears to be a listing.What's Visible:Product: Apple Mac Studio M4 MaxModel number: MU963Chip: 14-core CPU / 32-core GPUMemory: 36GB RAMStorage: 512GB SSDPricing:Original price: EGP 320,600Current price: EGP 153,950 (52% off)Stock Status: 1 item in stockWebsite Elements:Instagram iconNavigation menu: Home.Note: No reviews yet.——The image shows an online store."
        )

        XCTAssertFalse(source.contains("DescriptionThis"))
        XCTAssertFalse(source.contains("MaxModel"))
        XCTAssertFalse(source.contains("MU963Chip"))
        XCTAssertFalse(source.contains("GPUMemory"))
        XCTAssertFalse(source.contains("RAMStorage"))
        XCTAssertFalse(source.contains("SSDPricing"))
        XCTAssertFalse(source.contains("stockWebsite"))
        XCTAssertTrue(source.contains("Description  \nThis"))
        XCTAssertTrue(source.contains("RAM  \nStorage"))
        XCTAssertTrue(source.contains("yet.\n\n—The image"))
    }

    /// Regression: `Text` drops Markdown block structure, so headings,
    /// paragraphs and list items ran together ("Trench WarfareWhat it was").
    func test_assistantMarkdownBlocks_keepHeadingsParagraphsAndListsApart() {
        let blocks = AssistantMarkdownBlocks.parse(
            AssistantOutputSanitizer.preservingLineBreaksForMarkdown(
                "## Trench Warfare\n### What it was\nIt was the main style.\n\n### How it worked\n- **Trenches**: Long channels.\n- **Barbed wire**: Fences.\n\n1. First\n2. Second\n   - nested"
            )
        )
        XCTAssertEqual(blocks.map(\.kind), [
            .header(2), .header(3), .paragraph, .header(3),
            .listItem(ordered: false, ordinal: 1, depth: 1),
            .listItem(ordered: false, ordinal: 2, depth: 1),
            .listItem(ordered: true, ordinal: 1, depth: 1),
            .listItem(ordered: true, ordinal: 2, depth: 1),
            .listItem(ordered: false, ordinal: 1, depth: 2),
        ])
        XCTAssertEqual(blocks.map { String($0.text.characters) }, [
            "Trench Warfare", "What it was", "It was the main style.", "How it worked",
            "Trenches: Long channels.", "Barbed wire: Fences.", "First", "Second", "nested",
        ])
    }

    func test_assistantMarkdownBlocks_keepSoftBreaksAndTableRows() {
        let plain = AssistantMarkdownBlocks.parse(
            AssistantOutputSanitizer.preservingLineBreaksForMarkdown("One.\nTwo.\n\nThree.")
        )
        XCTAssertEqual(plain.map { String($0.text.characters) }, ["One.\nTwo.", "Three."])

        let table = AssistantMarkdownBlocks.parse("| Name | Year |\n|---|---|\n| Verdun | 1916 |")
        XCTAssertEqual(table.map { String($0.text.characters) }, ["Name  |  Year", "Verdun  |  1916"])
    }

    func test_imageGroundingSanitizer_removesCrossModelControlTokens() {
        let raw = """
        <|im_start|>assistant
        Assistant: The image shows a magnetic phone holder.<end_of_utterance>
        It includes a product listing.<|im_end|>
        """

        XCTAssertEqual(
            ImageGroundingSanitizer.clean(raw),
            "The image shows a magnetic phone holder.\nIt includes a product listing."
        )
    }

    func test_bonsai27_isTheOnlyDualTextAndVisionBonsaiFamily() throws {
        let binary27 = try XCTUnwrap(AssistantModelCatalog.model(forID: "bonsai-27b-1bit"))
        let ternary27 = try XCTUnwrap(AssistantModelCatalog.model(forID: "bonsai-27b-ternary"))
        let smaller = AssistantModelCatalog.presets.filter {
            $0.id.hasPrefix("bonsai-") && !$0.id.contains("27b")
        }

        XCTAssertTrue(binary27.capabilities.contains(.vision))
        XCTAssertTrue(ternary27.capabilities.contains(.vision))
        XCTAssertTrue(DualRoleModelPolicy.isTextAndVision(repoID: binary27.repoID))
        XCTAssertTrue(DualRoleModelPolicy.isTextAndVision(repoID: ternary27.repoID))
        XCTAssertTrue(smaller.allSatisfy { !$0.capabilities.contains(.vision) })
        XCTAssertTrue(smaller.allSatisfy {
            !DualRoleModelPolicy.isTextAndVision(repoID: $0.repoID)
        })
    }

    @MainActor
    func test_bonsai27_downloadEntry_keepsOnePackageForBothCatalogRoles() throws {
        let model = try XCTUnwrap(ModelDownloadCenter.shared.models.first {
            $0.id == "bonsai-27b-1bit"
        })
        XCTAssertEqual(model.sourceRepoID, "prism-ml/Bonsai-27B-mlx-1bit")
        XCTAssertTrue(model.supportsCategory(.assistant))
        XCTAssertTrue(model.supportsCategory(.vlm))
    }

    func test_bonsaiCatalog_declaresPublishedPlatformCompatibility() throws {
        let binary27 = try XCTUnwrap(AssistantModelCatalog.model(forID: "bonsai-27b-1bit"))
        let ternary27 = try XCTUnwrap(AssistantModelCatalog.model(forID: "bonsai-27b-ternary"))
        let smaller = AssistantModelCatalog.presets.filter {
            $0.id.hasPrefix("bonsai-") && !$0.id.contains("27b")
        }

        XCTAssertEqual(binary27.platformCompatibility, .highMemoryMobileAndMac)
        XCTAssertEqual(ternary27.platformCompatibility, .macOnly)
        XCTAssertTrue(smaller.allSatisfy { $0.platformCompatibility == .mobileAndMac })

        #if os(macOS) || targetEnvironment(macCatalyst)
        XCTAssertTrue(ModelPlatformCompatibility.macOnly.supportsCurrentPlatform)
        XCTAssertFalse(ModelPlatformCompatibility.iosOnly.supportsCurrentPlatform)
        #else
        XCTAssertFalse(ModelPlatformCompatibility.macOnly.supportsCurrentPlatform)
        XCTAssertTrue(ModelPlatformCompatibility.iosOnly.supportsCurrentPlatform)
        #endif
    }

    /// The ONNX voices (KittenTTS, Paradee, Supertonic) need ONNX Runtime,
    /// which ships no Mac Catalyst slice. They must say so instead of being
    /// offered as a download that can only fail after the bytes arrive.
    @MainActor
    func test_onnxVoiceModels_declareIOSOnlyPlatformCompatibility() throws {
        let ids = [
            "tts.kitten.micro.0_8", "tts.kitten.nano.0_8.int8", "tts.kitten.mini.0_8",
            "paradee-8m", "supertonic-3",
        ]
        for id in ids {
            let model = try XCTUnwrap(ModelDownloadCenter.shared.models.first { $0.id == id }, id)
            XCTAssertEqual(model.platformCompatibility, .iosOnly, id)
            XCTAssertEqual(model.supportedVoiceEngine?.isSupportedOnThisPlatform,
                           model.platformCompatibility?.supportsCurrentPlatform, id)
        }
        // Kokoro is Core ML, so it keeps running on every platform.
        let kokoro = try XCTUnwrap(ModelDownloadCenter.shared.models.first { $0.id == "kokoro-82m" })
        XCTAssertNil(kokoro.platformCompatibility)
    }

    func test_inferred_plainRepo_noFalsePositives() {
        // A bare non-coder, non-multilingual repo with no tools should get
        // no inferred capability pills at all.
        let caps = ModelCapability.inferred(repoID: "meta-llama/Llama-3.2-1B-Instruct")
        XCTAssertTrue(caps.isEmpty, "Expected no inferred pills, got \(caps)")
    }

    func test_displayCapabilities_surfacesToolsForToolModel() {
        // The default flagship supports tools → the picker row should show
        // the Tools pill without the preset literal listing it.
        let flagship = AssistantModelCatalog.presets.first { $0.supportsTools }
        let model = try? XCTUnwrap(flagship)
        XCTAssertTrue(model?.displayCapabilities.contains(.tools) ?? false)
    }

    func test_displayCapabilities_orderingStatusBeforeCapabilityBeforeGated() {
        // Synthetic model carrying a status, a capability, and gated — the
        // ordering contract: status → capability markers → gated last.
        let m = AssistantModel(
            id: "t", repoID: "Qwen/Qwen2.5-Coder-7B", displayName: "t", subtitle: "t",
            approxRAMBytes: 0, tags: ["fast"], contextWindowTokens: 0,
            capabilities: [.best, .gated, .vision], supportsTools: true
        )
        let order = m.displayCapabilities
        let idxBest = order.firstIndex(of: .best)
        let idxVision = order.firstIndex(of: .vision)
        let idxGated = order.firstIndex(of: .gated)
        XCTAssertNotNil(idxBest); XCTAssertNotNil(idxVision); XCTAssertNotNil(idxGated)
        XCTAssertLessThan(idxBest!, idxVision!)   // status before capability
        XCTAssertLessThan(idxVision!, idxGated!)  // capability before gated
        // Inferred markers present too.
        XCTAssertTrue(order.contains(.tools))
        XCTAssertTrue(order.contains(.coder))
        XCTAssertTrue(order.contains(.fast))
    }

    func test_allCapabilities_haveLabelAndSymbol() {
        for cap in ModelCapability.allCases {
            XCTAssertFalse(cap.label.isEmpty, "\(cap) missing label")
            XCTAssertFalse(cap.symbol.isEmpty, "\(cap) missing symbol")
        }
    }
}


@MainActor
final class HFSearchReleaseTests: XCTestCase {
    private func response(_ name: String) -> (Data, URLResponse) {
        (Data("[{\"id\":\"test/\(name)\"}]".utf8),
         HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200,
                         httpVersion: nil, headerFields: nil)!)
    }

    func testOlderResponseCannotReplaceNewerResults() async {
        var pending: [String: CheckedContinuation<(Data, URLResponse), Error>] = [:]
        let service = HFSearchService { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!.first { $0.name == "search" }!.value!
            return try await withCheckedThrowingContinuation { pending[query] = $0 }
        }
        let first = Task { await service.search(query: "old") }
        while pending["old"] == nil { await Task.yield() }
        let second = Task { await service.search(query: "new") }
        while pending["new"] == nil { await Task.yield() }
        pending.removeValue(forKey: "new")!.resume(returning: response("new"))
        await second.value
        pending.removeValue(forKey: "old")!.resume(returning: response("old"))
        await first.value
        XCTAssertEqual(service.results.map(\.id), ["test/new"])
        XCTAssertEqual(service.lastQuery, "new")
        XCTAssertFalse(service.isSearching)
    }

    func testOlderFailureDoesNotStopNewerSearch() async {
        var pending: [String: CheckedContinuation<(Data, URLResponse), Error>] = [:]
        let service = HFSearchService { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!.first { $0.name == "search" }!.value!
            return try await withCheckedThrowingContinuation { pending[query] = $0 }
        }
        let first = Task { await service.search(query: "old") }
        while pending["old"] == nil { await Task.yield() }
        let second = Task { await service.search(query: "new") }
        while pending["new"] == nil { await Task.yield() }
        pending.removeValue(forKey: "old")!.resume(throwing: URLError(.timedOut))
        await first.value
        XCTAssertTrue(service.isSearching)
        XCTAssertNil(service.lastError)
        pending.removeValue(forKey: "new")!.resume(returning: response("new"))
        await second.value
        XCTAssertEqual(service.results.map(\.id), ["test/new"])
        XCTAssertFalse(service.isSearching)
    }

    func testClearingQueryInvalidatesPendingResponse() async {
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        let service = HFSearchService { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        let first = Task { await service.search(query: "old") }
        while pending == nil { await Task.yield() }
        await service.search(query: "  ")
        XCTAssertFalse(service.isSearching)
        pending!.resume(returning: response("old"))
        await first.value
        XCTAssertTrue(service.results.isEmpty)
        XCTAssertNil(service.lastError)
    }

    func testCancellationDoesNotShowSearchFailure() async {
        let service = HFSearchService { _ in throw URLError(.cancelled) }
        await service.search(query: "test")
        XCTAssertNil(service.lastError)
        XCTAssertFalse(service.isSearching)
    }

    func testFilterOnlySearchReturnsModels() async {
        let service = HFSearchService { _ in self.response("model") }
        await service.search(query: "", filter: .mlx)
        XCTAssertEqual(service.results.map(\.id), ["test/model"])
    }
}
