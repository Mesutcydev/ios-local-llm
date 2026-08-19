import XCTest
@testable import IOSLocalLLM

final class GGUFGenerationProfileTests: XCTestCase {

    // MARK: - Profile resolution

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
        XCTAssertEqual(profile.inputBudget(requestedOutputTokens: 2_048), 320)
        XCTAssertEqual(profile.clampedOutputTokens(2_048), 128)
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
            128
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
