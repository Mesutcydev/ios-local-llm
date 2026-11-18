import XCTest
@testable import IOSLocalLLM

// MARK: - VoiceProfileRegistryTests
//
// Pins the four-layer resolution chain: exact match → prefix-stripped
// substring match → `_fallback`, with user overrides layered on top of
// any base. Real users load HuggingFace models with `downloaded:` /
// `imported:` / `custom:` prefixes, so the substring path is what
// makes Qwen3 variants get the right reasoning-token behavior even
// when their full repoID isn't in the catalog.

final class VoiceProfileRegistryTests: XCTestCase {

    // MARK: - Setup

    override func tearDown() {
        super.tearDown()
        // Clean up any test-installed user overrides so subsequent
        // tests start from a known state. Test IDs we touch:
        let testIDs = [
            "qwen3-4b",
            "qwen2.5-coder-1.5b",
            "downloaded:Custom/Test-Model",
        ]
        for id in testIDs {
            VoiceProfileRegistry.clearOverrides(for: id)
        }
    }

    // MARK: - Exact match

    func test_exactMatch_returnsBuiltin() {
        let p = VoiceProfileRegistry.profile(for: "qwen3-4b")
        XCTAssertEqual(p.modelId, "qwen3-4b")
        XCTAssertTrue(p.usesReasoningTokens)
        XCTAssertEqual(p.reasoningTokenPattern, .qwenThink)
        XCTAssertEqual(p.dominantLanguages, ["en", "tr"])
    }

    func test_exactMatch_noReasoning_forCoderModel() {
        let p = VoiceProfileRegistry.profile(for: "qwen2.5-coder-1.5b")
        XCTAssertFalse(p.usesReasoningTokens,
            "Coder model has no thinking tokens — stripper must be skipped")
        XCTAssertNil(p.reasoningTokenPattern)
    }

    // MARK: - Prefix-stripped substring match

    func test_downloadedPrefix_matchesByRepoIDSubstring() {
        // Real user case: load a HuggingFace Qwen3-4B variant through
        // the Download Center. The id arrives prefixed; the registry
        // strips the prefix and matches by substring.
        let p = VoiceProfileRegistry.profile(for: "downloaded:Qwen/Qwen3-4B-Instruct-MLX-4bit")
        XCTAssertTrue(p.usesReasoningTokens,
            "downloaded:Qwen3-4B-* must resolve to the qwen3-4b profile")
        XCTAssertEqual(p.reasoningTokenPattern, .qwenThink)
        // modelId in the returned profile is the FULL prefixed id so
        // overrides remain keyed by the user-visible id.
        XCTAssertEqual(p.modelId, "downloaded:Qwen/Qwen3-4B-Instruct-MLX-4bit")
    }

    func test_importedPrefix_caseInsensitiveSubstring() {
        let p = VoiceProfileRegistry.profile(for: "imported:local/qWeN3-4B-special")
        XCTAssertTrue(p.usesReasoningTokens,
            "Case-insensitive substring must match qwen3-4b regardless of case")
    }

    func test_customPrefix_unrecognizedFallsToFallback() {
        let p = VoiceProfileRegistry.profile(for: "custom:Acme/Nobody-Has-Heard-Of-This-7B")
        XCTAssertEqual(p.modelId, "custom:Acme/Nobody-Has-Heard-Of-This-7B")
        XCTAssertFalse(p.usesReasoningTokens,
            "_fallback profile does not strip reasoning tokens")
    }

    func test_longestKeyWins_qwen3VariantsPreferSpecific() {
        // A repoID containing "qwen3-1.7b" should resolve to that
        // specific profile, NOT a generic "qwen3" match (no such
        // profile exists, but the test guarantees ordering even
        // when a future shorter profile might be added).
        let p = VoiceProfileRegistry.profile(for: "downloaded:Some/Qwen3-1.7B-finetune")
        XCTAssertEqual(p.dominantLanguages, ["en", "tr"],
            "qwen3-1.7b profile should match before any shorter qwen3 alias")
        XCTAssertTrue(p.usesReasoningTokens)
    }

    func test_bonsaiFamily_usesQwenReasoningStripper() {
        let p = VoiceProfileRegistry.profile(for: "bonsai-27b-1bit")
        XCTAssertTrue(p.usesReasoningTokens)
        XCTAssertEqual(p.reasoningTokenPattern, .qwenThink)
    }

    // MARK: - User overrides

    func test_rateOverride_winsOverBuiltin() {
        let base = VoiceProfileRegistry.profile(for: "qwen3-4b")
        let baseRate = base.defaultTTSRate

        VoiceProfileRegistry.setRateOverride(0.75, for: "qwen3-4b")
        defer { VoiceProfileRegistry.setRateOverride(nil, for: "qwen3-4b") }

        let withOverride = VoiceProfileRegistry.profile(for: "qwen3-4b")
        XCTAssertEqual(withOverride.defaultTTSRate, 0.75)
        XCTAssertNotEqual(withOverride.defaultTTSRate, baseRate)
    }

    func test_legacyPrefixOverride_survivesUpgradeAndReset() {
        let legacy = "com.mesutcydev.ioslocalllm.voice.profile.qwen3-4b.rate"
        UserDefaults.standard.set(0.66, forKey: legacy)
        defer { UserDefaults.standard.removeObject(forKey: legacy) }

        XCTAssertEqual(VoiceProfileRegistry.profile(for: "qwen3-4b").defaultTTSRate, 0.66)
        XCTAssertNil(UserDefaults.standard.object(forKey: legacy), "moved to the current key")
        VoiceProfileRegistry.clearOverrides(for: "qwen3-4b")
        XCTAssertEqual(VoiceProfileRegistry.profile(for: "qwen3-4b").defaultTTSRate, 0.5,
            "a reset must not resurrect the legacy value")
    }

    func test_clearOverrides_returnsToBaseline() {
        VoiceProfileRegistry.setRateOverride(0.42, for: "qwen3-4b")
        VoiceProfileRegistry.setPitchOverride(1.5, for: "qwen3-4b")
        VoiceProfileRegistry.clearOverrides(for: "qwen3-4b")

        let p = VoiceProfileRegistry.profile(for: "qwen3-4b")
        XCTAssertEqual(p.defaultTTSRate, 0.5,
            "After clearOverrides, rate falls back to the built-in default")
        XCTAssertEqual(p.defaultTTSPitch, 1.0)
    }

    func test_chunkingStrategyOverride_persistsAcrossLookups() {
        VoiceProfileRegistry.setChunkingStrategyOverride(.clause, for: "qwen3-4b")
        defer { VoiceProfileRegistry.setChunkingStrategyOverride(nil, for: "qwen3-4b") }

        let p = VoiceProfileRegistry.profile(for: "qwen3-4b")
        XCTAssertEqual(p.chunkingStrategy, .clause)
    }

    func test_overridesAreKeyedByFullModelId_notSubstringMatch() {
        // A user override for the FULL downloaded id should NOT
        // apply when looking up the bare preset key, and vice versa.
        let downloadedID = "downloaded:Custom/Test-Model"
        VoiceProfileRegistry.setRateOverride(0.65, for: downloadedID)
        defer { VoiceProfileRegistry.setRateOverride(nil, for: downloadedID) }

        let downloaded = VoiceProfileRegistry.profile(for: downloadedID)
        XCTAssertEqual(downloaded.defaultTTSRate, 0.65)

        let preset = VoiceProfileRegistry.profile(for: "qwen3-4b")
        XCTAssertEqual(preset.defaultTTSRate, 0.5,
            "Override on a different id must not leak across ids")
    }

    // MARK: - Structural fields unaffected by overrides

    func test_overrides_doNotChangeReasoningField() {
        // The registry deliberately keeps `usesReasoningTokens` and
        // `dominantLanguages` immutable from the user side — those
        // are model-architecture facts, not preferences. Verify
        // that any override path can't somehow flip them.
        VoiceProfileRegistry.setRateOverride(0.9, for: "qwen3-4b")
        defer { VoiceProfileRegistry.setRateOverride(nil, for: "qwen3-4b") }

        let p = VoiceProfileRegistry.profile(for: "qwen3-4b")
        XCTAssertTrue(p.usesReasoningTokens)
        XCTAssertEqual(p.dominantLanguages, ["en", "tr"])
    }
}

// MARK: - VoiceConversationService.sanitizedHistory
//
// Voice turns can end without a reply (barge-in, thermal refusal, model
// still loading). The history sent to the model must not carry empty
// assistant turns or back-to-back user turns — strict-alternation chat
// templates reject them and the model starts answering with nothing.
final class VoiceConversationHistoryTests: XCTestCase {

    func test_sanitizedHistory_dropsEmptyRepliesAndMergesUserTurns() {
        let history: [ChatMessage] = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "first"),
            ChatMessage(role: .assistant, content: "  ", isStreaming: true),
            ChatMessage(role: .user, content: "second"),
            ChatMessage(role: .assistant, content: "partial", wasInterrupted: true),
            ChatMessage(role: .user, content: "third"),
        ]
        let out = VoiceConversationService.sanitizedHistory(history)
        XCTAssertEqual(out.map(\.role), [.system, .user, .assistant, .user])
        XCTAssertEqual(out[1].content, "first\nsecond")
        XCTAssertEqual(out[2].content, "partial")
        XCTAssertEqual(out[3].content, "third")
    }

    func test_sanitizedHistory_keepsToolTurns() {
        let history: [ChatMessage] = [
            ChatMessage(role: .user, content: "weather?"),
            ChatMessage(role: .assistant, content: "<tool_call>"),
            ChatMessage(role: .tool, content: "sunny"),
        ]
        XCTAssertEqual(VoiceConversationService.sanitizedHistory(history).count, 3)
    }
}
