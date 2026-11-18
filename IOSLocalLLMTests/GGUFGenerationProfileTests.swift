import XCTest
import UIKit
import CoreImage
@testable import IOSLocalLLM

final class GGUFGenerationProfileTests: XCTestCase {
    /// Opt-in integration check against separately downloaded, licensed weights.
    /// Normal source-only test runs skip this and never access the network.
    func test_nativeLFM3AudioAndSpeechWithExternalWeights() throws {
        guard let path = ProcessInfo.processInfo.environment["LFM3_NATIVE_SMOKE_DIR"] else {
            throw XCTSkip("Set LFM3_NATIVE_SMOKE_DIR to a reviewed model.gguf + mmproj.gguf pair.")
        }
        let runtime = try LlamaCppVLM(
            llmPath: path + "/model.gguf", mmprojPath: path + "/mmproj.gguf",
            nThreads: 4, contextSize: 2_048, gpuLayers: 0, enableAudio: true)
        let template: ChatTemplate = runtime.supportsVision ? .lfm3Omni : .lfm3Audio
        var text = ""
        let prompt = template.format(messages: [
            ChatMessage(role: .system, content: "Respond in text."),
            ChatMessage(role: .user, content: "Say hello."),
        ])
        let response = try runtime.generateLFM3(prompt: prompt, template: template, maxTokens: 32, sampler: .init(temperature: 0), onToken: { text += $0 })
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(response.audioSamples.isEmpty)
        let asrPrompt = template.format(messages: [
            ChatMessage(role: .system, content: "Perform ASR in English. Respond in text."),
            ChatMessage(role: .user, content: ""),
        ])
        _ = try runtime.generateLFM3(prompt: asrPrompt, audio: Array(repeating: 0, count: 8_000), template: template, maxTokens: 16, onToken: { _ in })
        var streamed = 0
        let speech = try runtime.generateLFM3(prompt: prompt, generateSpeech: true, template: template, maxTokens: 192, onToken: { _ in },
                                              onAudioChunk: { samples, _ in streamed += samples.count })
        XCTAssertFalse(speech.audioSamples.isEmpty)
        // Voice plays these chunks as they arrive; together they are the reply.
        XCTAssertEqual(streamed, speech.audioSamples.count)
        XCTAssertEqual(speech.audioSampleRate, 24_000)
        XCTAssertTrue(speech.audioSamples.allSatisfy { $0.isFinite })
        if runtime.supportsVision {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
                UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            _ = try runtime.generateLFM3(prompt: prompt, image: image, template: template, maxTokens: 16, onToken: { _ in })
            _ = try runtime.generateLFM3(prompt: prompt, audio: Array(repeating: 0, count: 8_000), image: image, template: template, maxTokens: 16, onToken: { _ in })
        }
    }

    func test_nativeLFM3ToolsWithExternalAudioWeights() throws {
        guard let path = ProcessInfo.processInfo.environment["LFM3_NATIVE_SMOKE_DIR"] else {
            throw XCTSkip("Set LFM3_NATIVE_SMOKE_DIR to reviewed Audio/Omni weights.")
        }
        let runtime = try LlamaCppVLM(llmPath: path + "/model.gguf", mmprojPath: path + "/mmproj.gguf", nThreads: 4, contextSize: 2_048, gpuLayers: 0, enableAudio: true)
        let template: ChatTemplate = runtime.supportsVision ? .lfm3Omni : .lfm3Audio
        let tool = try XCTUnwrap(LFM3ToolCodec.localTools.first { $0.name == "calculator" })
        let toolMessages = LocalAPIToolCalling.messages(from: [
            ChatMessage(role: .user, content: "Use calculator to calculate 351 times 27. Call the function; do not calculate it yourself."),
        ], tools: [tool], choice: .function("calculator"), parallelToolCalls: false, nativeLFM3: true)
        var nativeCall = ""
        _ = try runtime.generateLFM3(prompt: template.format(messages: toolMessages), template: template, maxTokens: 192, sampler: .init(temperature: 0), onToken: { nativeCall += $0 })
        XCTAssertTrue(nativeCall.contains("<function=calculator>"))
        XCTAssertEqual(ToolRunner.extractCall(from: nativeCall)?.name, "calculator",
            "closed=\(nativeCall.contains("</tool_call>")), parameter=\(nativeCall.contains("<parameter=expression>")), anyParameter=\(nativeCall.contains("<parameter=")), reasoning=\(nativeCall.contains("</think>")), bytes=\(nativeCall.utf8.count)")
    }

    func test_nativeLFM3TextToolsWithExternalWeights() throws {
        guard let path = ProcessInfo.processInfo.environment["LFM3_NATIVE_TEXT_SMOKE_DIR"] else {
            throw XCTSkip("Set LFM3_NATIVE_TEXT_SMOKE_DIR to reviewed LFM3 text weights.")
        }
        let runtime = try LlamaCppVLM(llmPath: path + "/model.gguf", nThreads: 4, contextSize: 2_048, gpuLayers: 0)
        let tool = try XCTUnwrap(LFM3ToolCodec.localTools.first { $0.name == "calculator" })
        let messages = LocalAPIToolCalling.messages(from: [
            ChatMessage(role: .user, content: "Use calculator to calculate 351 times 27. Call the function; do not calculate it yourself."),
        ], tools: [tool], choice: .function("calculator"), parallelToolCalls: false, nativeLFM3: true)
        var output = ""
        _ = try runtime.generateText(prompt: ChatTemplate.lfm3.format(messages: messages), maxTokens: 192, sampler: .init(temperature: 0), reuseContext: true, onToken: { output += $0 })
        XCTAssertTrue(output.contains("<function=calculator>"))
        XCTAssertEqual(ToolRunner.extractCall(from: output)?.name, "calculator")
    }

    // MARK: - Profile resolution

    func test_lfm3VisionUsesSingleResidencyBoundedProfile() {
        let profile = LlamaCppVLMExecutionProfile.resolve(repoID: "LiquidAI/LFM3-VL-2B-GGUF")
        XCTAssertEqual(profile.contextSize, 4_096)
        XCTAssertEqual(profile.maxOutputTokens, 256)
        XCTAssertTrue(profile.requiresSingleResidency)
    }

    /// Only a GGUF text+vision preset is shared across Assistant and Lens, and
    /// a Lens-loaded copy must cover the Assistant's 8K audio window.
    func test_lfm3OmniIsSharedGGUFWithAssistantContext() {
        XCTAssertTrue(DualRoleModelPolicy.isSharedGGUF(repoID: "LiquidAI/LFM3-Omni-2B-GGUF"))
        XCTAssertFalse(DualRoleModelPolicy.isSharedGGUF(repoID: "LiquidAI/LFM3-Audio-2B-GGUF"))
        XCTAssertFalse(DualRoleModelPolicy.isSharedGGUF(repoID: "mlx-community/Qwen3-4B-Instruct-2507-4bit"))
        XCTAssertEqual(
            LlamaCppVLMExecutionProfile.resolve(repoID: "LiquidAI/LFM3-Omni-2B-GGUF").contextSize, 8_192)
    }

    /// Live captions send one small tile instead of the 1080×1920 frame.
    @MainActor
    func test_liveCaptionFrameIsCappedTo512LongSide() {
        let frame = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 1080, height: 1920))
        let live = AnalysisService.liveSized(frame)
        XCTAssertEqual(live.extent.height, 512, accuracy: 0.5)
        XCTAssertEqual(live.extent.width, 288, accuracy: 0.5)
        let small = frame.cropped(to: CGRect(x: 0, y: 0, width: 300, height: 400))
        XCTAssertEqual(AnalysisService.liveSized(small).extent, small.extent)
    }

    func test_recurrentGemma4ByRepoID_getsCompactProfile() {
        let profile = GGUFGenerationProfile.resolve(
            repoID: "local_gemma-4-e4b-it-Q4_K_M",
            displayName: "gemma-4-e4b-it-Q4_K_M"
        )
        XCTAssertEqual(profile, .compact)
    }

    func test_recurrentGemma4ByDisplayName_getsCompactProfile() {
        let profile = GGUFGenerationProfile.resolve(
            repoID: "local_import-2",
            displayName: "Gemma4 E4B instruct"
        )
        XCTAssertEqual(profile, .compact)
    }

    func test_qwenImport_getsStandardProfile() {
        // Regression: the compact Gemma workaround previously applied to
        // every imported GGUF, truncating Qwen replies to ~128 tokens
        // mid-sentence.
        let profile = GGUFGenerationProfile.resolve(
            repoID: "local_Qwen3.8-9B-Q4_K_M",
            displayName: "local_Qwen3.8-9B-Q4_K_M"
        )
        XCTAssertEqual(profile, .standard)
    }

    func test_llamaAndGemma3Imports_getStandardProfile() {
        XCTAssertEqual(
            GGUFGenerationProfile.resolve(
                repoID: "local_Llama-3.2-3B-Q4_K_M",
                displayName: "local_Llama-3.2-3B-Q4_K_M"
            ),
            .standard
        )
        // Gemma 3 is NOT the recurrent family that needs the workaround.
        XCTAssertEqual(
            GGUFGenerationProfile.resolve(
                repoID: "ggml-org/gemma-3-4b-it-GGUF",
                displayName: "Gemma 3 4B IT (Q4_K_M GGUF)"
            ),
            .standard
        )
    }

    func test_recurrentGemma3n_getsCompactProfile() {
        // Gemma 3n uses the same recurrent (MatFormer) architecture and needs
        // the same bounded-context workaround as Gemma 4 E-series.
        XCTAssertEqual(
            GGUFGenerationProfile.resolve(
                repoID: "ggml-org/gemma-3n-E2B-it-GGUF",
                displayName: "Gemma 3n E2B IT (Q4_K_M GGUF)"
            ),
            .compact
        )
        XCTAssertEqual(
            GGUFGenerationProfile.resolve(
                repoID: "local_gemma3n-e4b-it-q4_k_m",
                displayName: "local_gemma3n-e4b-it-q4_k_m"
            ),
            .compact
        )
    }

    func test_denseGemma4Imports_getStandardProfile() {
        // 12B / 31B Gemma 4 are not the recurrent E-series that abort on a
        // 4K context. Applying the compact 128-token cap to them would
        // silently truncate every reply.
        XCTAssertEqual(
            GGUFGenerationProfile.resolve(
                repoID: "bartowski/gemma-4-12B-it-Q4_K_M",
                displayName: "gemma-4-12B-it-Q4_K_M"
            ),
            .standard
        )
        XCTAssertEqual(
            GGUFGenerationProfile.resolve(
                repoID: "local_gemma-4-31B-it",
                displayName: "Gemma 4 31B"
            ),
            .standard
        )
    }

    // MARK: - Budgets

    func test_compactProfile_keepsBoundedBudgets() {
        let profile = GGUFGenerationProfile.compact
        XCTAssertEqual(profile.contextTokens, 512)
        XCTAssertEqual(profile.inputBudget(requestedOutputTokens: 2_048), 240)
        XCTAssertEqual(profile.clampedOutputTokens(2_048), 448)
        // Prompt budget + the bridge's half-window reply reserve fit in 512.
        XCTAssertLessThanOrEqual(240 + profile.contextTokens / 2, profile.contextTokens)
    }

    func test_standardProfile_allowsFullUserOutputSetting() {
        let profile = GGUFGenerationProfile.standard
        XCTAssertEqual(profile.contextTokens, 4_096)
        XCTAssertEqual(profile.clampedOutputTokens(2_048), 2_048)
    }

    func test_standardInputBudget_reservesRequestedOutput() {
        let profile = GGUFGenerationProfile.standard
        // Default 2048-token reply setting: prompt gets the other half.
        XCTAssertEqual(profile.inputBudget(requestedOutputTokens: 2_048), 2_032)
        // Output reserve never exceeds half the window.
        XCTAssertEqual(profile.inputBudget(requestedOutputTokens: 8_192), 2_032)
        // Small requests leave more room for the prompt.
        XCTAssertEqual(profile.inputBudget(requestedOutputTokens: 512), 3_568)
    }

    func test_outputTokenCap_compactWinsOverUserSetting() {
        XCTAssertEqual(
            GGUFGenerationProfile.outputTokenCap(
                isGGUF: true,
                profile: .compact,
                requested: 2_048,
                thermalCap: 4_096
            ),
            448
        )
    }

    func test_outputTokenCap_standardHonorsThermalCap() {
        XCTAssertEqual(
            GGUFGenerationProfile.outputTokenCap(
                isGGUF: true,
                profile: .standard,
                requested: 2_048,
                thermalCap: 512
            ),
            512
        )
    }

    func test_outputTokenCap_nonGGUFIgnoresProfile() {
        XCTAssertEqual(
            GGUFGenerationProfile.outputTokenCap(
                isGGUF: false,
                profile: .compact,
                requested: 2_048,
                thermalCap: 4_096
            ),
            2_048
        )
    }

    // MARK: - Runtime messages / prompt

    func test_standardProfile_keepsSystemAndToolInstructions() {
        let messages = [
            ChatMessage(role: .system, content: "You are a coding assistant. Use tools."),
            ChatMessage(role: .user, content: "List files"),
        ]
        let kept = GGUFGenerationProfile.standard.messagesForRuntime(messages)
        XCTAssertEqual(kept.map(\.role), [.system, .user])
        XCTAssertEqual(kept.first?.content, "You are a coding assistant. Use tools.")
    }

    func test_compactProfile_dropsPersonaButKeepsConversationMemory() {
        let messages = [
            ChatMessage(role: .system, content: "You are a coding assistant. Use tools."),
            ChatMessage(role: .system, content: "[CONVERSATION MEMORY]\nUser likes Swift."),
            ChatMessage(role: .user, content: "Hi"),
        ]
        let kept = GGUFGenerationProfile.compact.messagesForRuntime(messages)
        XCTAssertEqual(kept.map(\.role), [.user, .user])
        XCTAssertTrue(kept[0].content.hasPrefix("[CONVERSATION MEMORY]"))
        XCTAssertEqual(kept[1].content, "Hi")
    }

    func test_standardQwenPrompt_usesChatMLAndGenerationCue() {
        let messages = [
            ChatMessage(role: .system, content: "Be brief."),
            ChatMessage(role: .user, content: "Hello"),
        ]
        let prompt = GGUFGenerationProfile.standard.prompt(
            from: messages,
            template: .chatML,
            enableThinking: false
        )
        XCTAssertTrue(prompt.contains("<|im_start|>system\nBe brief.<|im_end|>"))
        XCTAssertTrue(prompt.contains("<|im_start|>user\nHello<|im_end|>"))
        XCTAssertTrue(prompt.hasSuffix("<|im_start|>assistant\n /no_think"))
        XCTAssertFalse(prompt.contains("user: Hello"))
    }

    func test_compactPrompt_usesPlainRolesAndAssistantCue() {
        let messages = [
            ChatMessage(role: .system, content: "Ignore this persona."),
            ChatMessage(role: .user, content: "Hello"),
        ]
        let prompt = GGUFGenerationProfile.compact.prompt(
            from: messages,
            template: .gemma,
            enableThinking: false
        )
        XCTAssertTrue(prompt.hasSuffix("user: Hello\n\nassistant:"))
        XCTAssertTrue(prompt.contains(CodingAssistantService.compactGroundingPrompt))
        XCTAssertFalse(prompt.contains("<start_of_turn>"))
        XCTAssertFalse(prompt.contains("Ignore this persona."))
    }

    func test_standardQwenPrompt_keepsToolInstructions() {
        let system = "Be brief." + ToolRunner.systemPromptAddendum
        let messages = [
            ChatMessage(role: .system, content: system),
            ChatMessage(role: .user, content: "What is 2+2 and search if needed"),
        ]
        let kept = GGUFGenerationProfile.standard.messagesForRuntime(messages)
        XCTAssertTrue(kept.contains { $0.content.contains("web_search") })
        XCTAssertTrue(kept.contains { $0.content.contains("file_read") })
        let prompt = GGUFGenerationProfile.standard.prompt(
            from: kept,
            template: .chatML,
            enableThinking: false
        )
        XCTAssertTrue(prompt.contains("```tool"))
        XCTAssertTrue(prompt.contains("web_search"))
        XCTAssertTrue(prompt.contains("file_read"))
        XCTAssertTrue(prompt.contains("calculator"))
        XCTAssertTrue(prompt.contains("Do not invent a tool result"))
    }

    func test_compactPrompt_stillOmitsToolAddendum() {
        let messages = [
            ChatMessage(role: .system, content: "Be brief." + ToolRunner.systemPromptAddendum),
            ChatMessage(role: .user, content: "Hi"),
        ]
        let prompt = GGUFGenerationProfile.compact.prompt(
            from: messages,
            template: .gemma,
            enableThinking: false
        )
        XCTAssertFalse(prompt.contains("web_search"))
        XCTAssertFalse(prompt.contains("```tool"))
    }

    func test_continuationPrompt_leavesLastAssistantOpen() {
        let messages = [
            ChatMessage(role: .system, content: "Be brief."),
            ChatMessage(role: .user, content: "Write a story"),
            ChatMessage(role: .assistant, content: "Once upon a time"),
        ]
        let prompt = GGUFGenerationProfile.standard.prompt(
            from: messages,
            template: .chatML,
            enableThinking: false,
            leaveLastAssistantOpen: true
        )
        XCTAssertTrue(prompt.hasSuffix("<|im_start|>assistant\nOnce upon a time"))
        XCTAssertFalse(prompt.hasSuffix("<|im_start|>assistant\n /no_think"))
        XCTAssertFalse(prompt.contains("Please continue from where you left off"))
    }

    func test_compactContinuationPrompt_doesNotAddSecondAssistantCue() {
        let messages = [
            ChatMessage(role: .user, content: "Write a story"),
            ChatMessage(role: .assistant, content: "Once upon"),
        ]
        let prompt = GGUFGenerationProfile.compact.prompt(
            from: messages,
            template: .gemma,
            enableThinking: false,
            leaveLastAssistantOpen: true
        )
        XCTAssertTrue(prompt.hasSuffix("assistant: Once upon"))
        XCTAssertFalse(prompt.hasSuffix("assistant: Once upon\n\nassistant:"))
    }

    func test_prefixCache_reusesSharedTokens() {
        XCTAssertEqual(GGUFPrefixCache.commonPrefixLength([1, 2, 3, 4], [1, 2, 9]), 2)
        XCTAssertEqual(
            GGUFPrefixCache.reuseOffset(cached: [1, 2, 3], next: [1, 2, 3, 4, 5], reuseContext: true),
            3
        )
        XCTAssertEqual(
            GGUFPrefixCache.reuseOffset(cached: [1, 2, 3], next: [1, 2, 3, 4], reuseContext: false),
            0
        )
        XCTAssertEqual(
            GGUFPrefixCache.reuseOffset(cached: [9, 8], next: [1, 2], reuseContext: true),
            0
        )
    }

    func test_continuationStartsAfterCachedSequence() {
        XCTAssertEqual(
            GGUFPrefixCache.continuationDecodePosition(
                cachedTokenCount: 120,
                generatedSinceResume: 0
            ),
            120
        )
        XCTAssertEqual(
            GGUFPrefixCache.continuationDecodePosition(
                cachedTokenCount: 120,
                generatedSinceResume: 3
            ),
            123
        )
    }

    func test_continuationLimitLeavesContextSentinelSpace() {
        XCTAssertEqual(
            GGUFPrefixCache.continuationLimit(
                contextSize: 512,
                cachedTokenCount: 400,
                requested: 256
            ),
            111
        )
        XCTAssertEqual(
            GGUFPrefixCache.continuationLimit(
                contextSize: 512,
                cachedTokenCount: 511,
                requested: 256
            ),
            0
        )
    }

    func test_mlXProfileDoesNotCapGGUFOutput() {
        XCTAssertEqual(
            AssistantGenerationBudget.maxTokens(
                runtime: .llamaCpp,
                requested: 2_048,
                thermalCap: 4_096,
                backendCap: 256
            ),
            2_048
        )
        XCTAssertEqual(
            AssistantGenerationBudget.maxTokens(
                runtime: .mlx,
                requested: 2_048,
                thermalCap: 4_096,
                backendCap: 256
            ),
            256
        )
    }

    func test_ornithUsesQwen35PromptContract() {
        XCTAssertEqual(
            ChatTemplate.detect(for: "local_Ornith-1.5-9B-Q5_K_M").format,
            ChatTemplate.qwen35.format
        )
    }

    func test_prefetchPolicyRequiresChargingAndNominalThermalState() {
        XCTAssertTrue(
            ModelResidency.allowsBackgroundPrefetch(
                thermalState: .nominal,
                isCharging: true,
                lowPowerMode: false
            )
        )
        XCTAssertFalse(
            ModelResidency.allowsBackgroundPrefetch(
                thermalState: .nominal,
                isCharging: false,
                lowPowerMode: false
            )
        )
        XCTAssertFalse(
            ModelResidency.allowsBackgroundPrefetch(
                thermalState: .serious,
                isCharging: true,
                lowPowerMode: false
            )
        )
    }

    func test_samplerSpec_preservesUserSettings() {
        let spec = LlamaCppVLM.GGUFSamplerSpec(
            temperature: 0.2,
            topP: 0.8,
            topK: 40,
            repetitionPenalty: 1.1,
            seed: 7
        )
        XCTAssertEqual(spec.temperature, 0.2)
        XCTAssertEqual(spec.topP, 0.8)
        XCTAssertEqual(spec.topK, 40)
        XCTAssertEqual(spec.repetitionPenalty, 1.1)
        XCTAssertEqual(spec.seed, 7)
    }
}
