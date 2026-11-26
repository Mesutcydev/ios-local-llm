import XCTest
@testable import IOSLocalLLM

// MARK: - DeviceTierAdvisorTests
//
// Pins the device-tier classification logic. Since `DeviceTierAdvisor.current`
// reads `ProcessInfo.processInfo.physicalMemory` at runtime, we test the tier
// boundaries and the derived recommendations independently by validating the
// tier-specific outputs for each known tier.

final class DeviceTierAdvisorTests: XCTestCase {
    func testSyntheticMemoryCeilingRequiresEntitlementAndNormalPowerMode() {
        for entitled in [false, true] {
            for lowPower in [false, true] {
                let ceiling = MemoryAdvisor.resolvedProcessCeilingCandidate(
                    kernelCeiling: 4_000_000_000, entitlementCeiling: 8_000_000_000,
                    hasIncreasedMemoryEntitlement: entitled, lowPowerMode: lowPower
                )
                XCTAssertEqual(ceiling, 4_000_000_000, "a reported kernel limit always wins")
                let unreported = MemoryAdvisor.resolvedProcessCeilingCandidate(
                    kernelCeiling: 0, entitlementCeiling: 8_000_000_000,
                    hasIncreasedMemoryEntitlement: entitled, lowPowerMode: lowPower
                )
                XCTAssertEqual(unreported, entitled && !lowPower ? 8_000_000_000 : 0)
            }
        }
        XCTAssertEqual(MemoryAdvisor.resolvedProcessCeilingCandidate(
            kernelCeiling: 0, entitlementCeiling: 8_000_000_000,
            hasIncreasedMemoryEntitlement: false, lowPowerMode: false), 0)
    }


    // MARK: - Tier labels

    func test_tierLabels_areDistinct() {
        let labels = Set(DeviceTier.allCases.map(\.label))
        XCTAssertEqual(labels.count, DeviceTier.allCases.count,
                       "Every tier should have a unique label")
    }

    // MARK: - Model recommendations are non-empty

    func test_recommendedModelID_isNonEmptyForAllTiers() {
        // We can't inject physical RAM in tests, but we can validate that
        // every tier's recommendation is a non-empty, sensible string.
        // The runtime tier is whatever this device is — the recommendation
        // is always a known preset ID.
        let id = DeviceTierAdvisor.recommendedModelID
        XCTAssertFalse(id.isEmpty, "recommendedModelID must not be empty")
        // It must be one of the actual catalog presets. Validate against the
        // live catalog rather than a frozen list so this test doesn't drift
        // when the recommended flagship is refreshed (e.g. qwen3-4b → 2507).
        let known = Set(AssistantModelCatalog.presets.map(\.id))
        XCTAssertTrue(known.contains(id),
                      "\(id) is not a known preset model ID")
    }

    // MARK: - Rationale is non-empty

    func test_rationale_isNonEmpty() {
        let r = DeviceTierAdvisor.rationale
        XCTAssertFalse(r.isEmpty)
        XCTAssertTrue(r.count > 10, "Rationale should be a meaningful sentence")
    }

    // MARK: - Max tokens are in sensible range

    func test_recommendedMaxTokens_isInSensibleRange() {
        let tokens = DeviceTierAdvisor.recommendedMaxTokens
        XCTAssertGreaterThanOrEqual(tokens, 256, "Min tokens too low")
        XCTAssertLessThanOrEqual(tokens, 4096, "Max tokens too high")
    }

    // MARK: - RAM budget is positive

    func test_singleModelRAMBudget_isPositive() {
        let budget = DeviceTierAdvisor.singleModelRAMBudget
        XCTAssertGreaterThan(budget, 0)
    }

    // MARK: - Heavy features gating is consistent

    func test_shouldHideHeavyFeatures_isConsistentWithTier() {
        // On any real device the tier is .pro or .max. The flag must be
        // consistent: only .max keeps heavy features visible.
        let hide = DeviceTierAdvisor.shouldHideHeavyFeatures
        let tier = DeviceTierAdvisor.current
        if tier == .max {
            XCTAssertFalse(hide, ".max tier should NOT hide heavy features")
        } else {
            XCTAssertTrue(hide, "Non-.max tier SHOULD hide heavy features")
        }
    }

    // MARK: - Visual model recommendation

    func test_recommendedVisualModelRepoID_isNonEmpty() {
        let repo = DeviceTierAdvisor.recommendedVisualModelRepoID
        XCTAssertFalse(repo.isEmpty)
    }

    func test_visualModelFallbacks_isNonEmptyForCurrentTier() {
        let fallbacks = DeviceTierAdvisor.visualModelFallbackRepoIDs
        XCTAssertFalse(fallbacks.isEmpty)
        // All fallback IDs should be non-empty strings.
        for fb in fallbacks {
            XCTAssertFalse(fb.isEmpty)
        }
    }

    // MARK: - MemoryAdvisor load-spike headroom (high-RAM crash fix)

    func test_loadSpikeMultiplier_isAtLeastValidatedValue() {
        // loadSpikeMultiplier is the single weights->peak factor used by
        // callers that start from RAW weight bytes (e.g. LensInferenceLoop's
        // VLM sizing). 1.4x previously produced EXC_RESOURCE on load, so it
        // must stay >= 1.6x. NOTE: it is applied exactly ONCE on that path and
        // is NOT used by safetyBlocker — estimatedFootprint already returns a
        // peak, and the gate adds a fixed reserve instead of multiplying again.
        XCTAssertGreaterThanOrEqual(MemoryAdvisor.loadSpikeMultiplier, 1.6,
            "Weights->peak factor must stay >= 1.6x or high-RAM models OOM on load")
    }

    func test_footprintFactors_doNotCompoundToDoubleCount() {
        // Regression guard for the "everything reports ~2.5x the RAM it needs"
        // bug: a downloaded model was sized at on-disk x workingSetOverhead in
        // estimatedFootprint and then multiplied AGAIN by the spike factor in
        // the gate. The gate now adds loadHeadroomReserve (a fixed byte amount,
        // not a multiplier), and the on-disk factor stays a single modest value.
        XCTAssertLessThanOrEqual(MemoryAdvisor.workingSetOverhead, 1.4,
            "On-disk->peak factor must stay modest; it is the ONLY multiplier on the downloaded path")
        XCTAssertGreaterThanOrEqual(MemoryAdvisor.workingSetOverhead, 1.0)
        // A fixed reserve, not a fraction of model size — keep it bounded so it
        // neither over-blocks small models nor vanishes for large ones.
        XCTAssertGreaterThan(MemoryAdvisor.loadHeadroomReserve, 0)
        XCTAssertLessThanOrEqual(MemoryAdvisor.loadHeadroomReserve, 1_500_000_000)
    }

    func test_highMemoryIPhoneProcessCeiling_keepsReserved12GBBudget() {
        let totalRAM: Int64 = 12_260_000_000
        let optimisticEntitledEstimate: Int64 = 9_230_000_000

        XCTAssertEqual(
            MemoryAdvisor.clampedProcessCeiling(
                candidate: optimisticEntitledEstimate,
                totalRAM: totalRAM,
                isPhone: true
            ),
            MemoryAdvisor.maximumHighMemoryIPhoneProcessCeiling,
            "A 12 GB iPhone should admit larger models while retaining several GB for iOS"
        )
    }

    func test_standardIPhoneProcessCeiling_staysConservative() {
        XCTAssertEqual(
            MemoryAdvisor.clampedProcessCeiling(
                candidate: 7_000_000_000,
                totalRAM: 8_000_000_000,
                isPhone: true
            ),
            MemoryAdvisor.maximumIPhoneProcessCeiling
        )
    }

    func test_ornithEnvelopeFitsOnlyHighMemoryIPhoneTier() {
        let ornithRequired: Int64 = 7_800_000_000
        let highMemoryCeiling = MemoryAdvisor.clampedProcessCeiling(
            candidate: 9_230_000_000,
            totalRAM: 12_260_000_000,
            isPhone: true
        )
        let standardCeiling = MemoryAdvisor.clampedProcessCeiling(
            candidate: 7_000_000_000,
            totalRAM: 8_000_000_000,
            isPhone: true
        )

        XCTAssertGreaterThan(highMemoryCeiling, ornithRequired)
        XCTAssertLessThan(standardCeiling, ornithRequired)
    }

    func test_nonPhoneProcessCeiling_keepsScalableEstimate() {
        let totalRAM: Int64 = 12_260_000_000
        let candidate: Int64 = 9_230_000_000

        XCTAssertEqual(
            MemoryAdvisor.clampedProcessCeiling(
                candidate: candidate,
                totalRAM: totalRAM,
                isPhone: false
            ),
            candidate,
            "High-memory iPad and Mac targets should retain their scalable ceiling"
        )
    }

    func test_gemmaPhasePeakDoesNotAddNonOverlappingLoadAndInference() {
        let weights: UInt64 = 3_200_000_000
        let activations: UInt64 = 1_200_000_000
        // Load peak: 3.2 GB × 1.6 = 5.12 GB.
        // Inference peak: 3.2 GB + 1.2 GB = 4.4 GB.
        // They do not coexist, so the envelope is 5.12 GB, not 6.32 GB.
        let gemmaPeak = LensInferenceLoop.phaseAwarePeakBytes(
            weightBytes: weights,
            activationReserveBytes: activations
        )
        XCTAssertEqual(gemmaPeak, 5_120_000_000)
        XCTAssertEqual(
            LensInferenceLoop.requiredLoadBytes(peakBytes: gemmaPeak),
            5_620_000_000
        )
    }

    func test_gemmaMLXProfileBoundsCacheAndGeneration() {
        let profile = MLXVLMExecutionProfile.resolve(
            repoID: "local/imported-model",
            architecture: "gemma3"
        )
        XCTAssertEqual(profile.cacheLimitBytes, 0)
        XCTAssertNil(
            profile.maxOutputTokens,
            "The rotating 512-token KV cache bounds memory; answer length follows the caller and thermal advisor"
        )
        XCTAssertEqual(profile.maxKVSize, 512)
        XCTAssertEqual(profile.kvBits, 4)
        XCTAssertTrue(profile.requiresSingleResidency)
    }

    func test_bonsai27AssistantProfileBoundsTextWithoutDisablingChat() throws {
        let model = try XCTUnwrap(
            AssistantModelCatalog.model(forID: "bonsai-27b-1bit")
        )
        let profile = MLXAssistantExecutionProfile.resolve(repoID: model.repoID)

        XCTAssertEqual(profile.maxContextTokens, 2_048)
        XCTAssertNil(
            profile.maxOutputTokens,
            "The rotating 2K KV cache bounds memory on its own; a fixed output cap truncated every Bonsai 27B reply mid-sentence"
        )
        XCTAssertEqual(profile.maxKVSize, 2_048)
        XCTAssertEqual(profile.kvBits, 4)
        XCTAssertEqual(profile.prefillStepSize, 128)
        XCTAssertEqual(profile.cacheLimitBytes, 0)
        XCTAssertEqual(
            profile.inputBudget(
                modelContextWindowTokens: 32_768,
                deviceContextCap: 8_192,
                requestedOutputTokens: 2_048
            ),
            1_536,
            "Uncapped output must not shrink the prompt budget below the rotating-cache reserve"
        )
        XCTAssertLessThanOrEqual(
            model.approxRAMBytes + MemoryAdvisor.loadHeadroomReserve,
            MemoryAdvisor.maximumIPhoneProcessCeiling,
            "The bounded text role should remain admissible on a high-memory iPhone"
        )
    }

    func test_ornithAssistantProfileBoundsKVForHighMemoryIPhone() {
        let profile = MLXAssistantExecutionProfile.resolve(
            repoID: "mlx-community/Ornith-1.0-9B-4bit"
        )

        XCTAssertEqual(profile.maxContextTokens, 4_096)
        XCTAssertNil(
            profile.maxOutputTokens,
            "The rotating 4K KV cache bounds memory; answer length follows the user's response-length setting"
        )
        XCTAssertEqual(profile.maxKVSize, 4_096)
        XCTAssertEqual(profile.kvBits, 4)
        XCTAssertEqual(profile.prefillStepSize, 128)
        XCTAssertEqual(profile.cacheLimitBytes, 0)
    }

    func test_dottedQwen35AssistantProfileBoundsMemoryWithoutTruncatingReplies() {
        let profile = MLXAssistantExecutionProfile.resolve(
            repoID: "local/MLX-Qwen3.5-9B-Claude-Reasoning-Distilled-v2-4bit"
        )

        XCTAssertEqual(profile.maxContextTokens, 2_048)
        XCTAssertNil(
            profile.maxOutputTokens,
            "Reasoning and visible answer tokens must follow the user's response-length setting"
        )
        XCTAssertEqual(profile.maxKVSize, 2_048)
        XCTAssertEqual(profile.kvBits, 4)
        XCTAssertEqual(profile.prefillStepSize, 128)
        XCTAssertEqual(profile.cacheLimitBytes, 0)
        XCTAssertEqual(
            profile.inputBudget(
                modelContextWindowTokens: 32_768,
                deviceContextCap: 8_192,
                requestedOutputTokens: 2_048
            ),
            1_536,
            "A rotating cache must retain meaningful prompt history even when the response allowance is 2K"
        )
    }

    func test_qwen35InputBudget_keepsImmediateFollowUpContext() {
        let profile = MLXAssistantExecutionProfile.resolve(
            repoID: "local/MLX-Qwen3.5-4B-Claude-Reasoning-Distilled-6bit"
        )
        let messages = [
            ChatMessage(role: .system, content: String(repeating: "instruction ", count: 80)),
            ChatMessage(role: .user, content: "Can you apply the attached protocol?"),
            ChatMessage(
                role: .assistant,
                content: String(repeating: "analysis ", count: 250)
                    + "\nWould you like me to apply the first step?"
            ),
            ChatMessage(role: .user, content: "Yes"),
        ]
        let budget = profile.inputBudget(
            modelContextWindowTokens: 32_768,
            deviceContextCap: 8_192,
            requestedOutputTokens: 2_048
        )
        let trimmed = CodingAssistantService.trimToInputBudget(
            messages,
            maxTokens: budget
        )

        XCTAssertEqual(trimmed.last?.content, "Yes")
        XCTAssertTrue(trimmed.contains {
            $0.role == .user
                && $0.content == "Can you apply the attached protocol?"
        })
        XCTAssertTrue(trimmed.contains {
            $0.role == .assistant
                && $0.content.contains("Would you like me to apply the first step?")
        })
    }

    func test_inputTrimming_keepsPriorVisibleRequestWhenGroundingIsTooLarge() {
        let priorRequest = "Need important parts summarized as a short list."
        let messages = [
            ChatMessage(
                role: .system,
                content: String(repeating: "instruction ", count: 240)
            ),
            ChatMessage(
                role: .user,
                content: priorRequest,
                modelContent: "[ATTACHED APPLE STYLE GUIDE]\n"
                    + String(repeating: "source material ", count: 2_000)
                    + "\n\(priorRequest)"
            ),
            ChatMessage(
                role: .assistant,
                content: String(repeating: "summary detail ", count: 800)
                    + "\nWould you like examples for particular rules?"
            ),
            ChatMessage(role: .user, content: "Have you summarized all?"),
        ]

        let trimmed = CodingAssistantService.trimToInputBudget(
            messages,
            maxTokens: 1_536
        )

        let retainedPriorRequest = trimmed.first {
            $0.role == .user && $0.content == priorRequest
        }
        XCTAssertNotNil(retainedPriorRequest)
        XCTAssertNil(
            retainedPriorRequest?.modelContent,
            "When the attachment no longer fits, retain its visible request as the follow-up antecedent"
        )
        XCTAssertTrue(trimmed.contains {
            $0.role == .assistant
                && $0.content.hasSuffix("Would you like examples for particular rules?")
        })
        XCTAssertEqual(trimmed.last?.content, "Have you summarized all?")
    }

    func test_inputTrimming_preservesTailOfLongPriorAssistantReply() {
        let messages = [
            ChatMessage(role: .system, content: String(repeating: "instruction ", count: 80)),
            ChatMessage(role: .user, content: "Can you apply the attached protocol?"),
            ChatMessage(
                role: .assistant,
                content: String(repeating: "analysis ", count: 500)
                    + "\nWould you like me to apply the first step?"
            ),
            ChatMessage(role: .user, content: "Yes"),
        ]

        let trimmed = CodingAssistantService.trimToInputBudget(
            messages,
            maxTokens: 512
        )

        XCTAssertEqual(trimmed.last?.content, "Yes")
        XCTAssertTrue(trimmed.contains {
            $0.role == .assistant
                && $0.content.hasPrefix("…\n")
                && $0.content.hasSuffix("Would you like me to apply the first step?")
        })
    }

    @MainActor
    func test_perModelSettings_persistByCanonicalRepositoryAndResetToDefaults() throws {
        let suiteName = "AssistantModelSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "profiles"
        let profile = AssistantModelGenerationSettings(
            maxTokens: 1_024,
            temperature: 0.25,
            topP: 0.9,
            topK: 40,
            minP: 0.05,
            repetitionPenalty: 1.1,
            thinkingEnabled: true
        )

        let store = AssistantModelSettingsStore(
            defaults: defaults,
            storageKey: storageKey
        )
        XCTAssertNil(store.settings(for: "mlx-community/Qwen3-4B-4bit"))

        store.save(
            profile,
            for: " MLX-COMMUNITY/Qwen3-4B-4bit ",
            supportsThinking: true
        )

        let reloaded = AssistantModelSettingsStore(
            defaults: defaults,
            storageKey: storageKey
        )
        XCTAssertEqual(
            reloaded.settings(for: "mlx-community/qwen3-4b-4bit"),
            profile
        )

        reloaded.reset(repositoryID: "MLX-COMMUNITY/QWEN3-4B-4BIT")
        XCTAssertNil(
            AssistantModelSettingsStore(
                defaults: defaults,
                storageKey: storageKey
            ).settings(for: "mlx-community/qwen3-4b-4bit")
        )
    }

    @MainActor
    func test_perModelSettings_clampUnsupportedThinkingAndUnsafeValues() throws {
        let suiteName = "AssistantModelSettingsClampTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AssistantModelSettingsStore(
            defaults: defaults,
            storageKey: "profiles"
        )

        store.save(
            AssistantModelGenerationSettings(
                maxTokens: 99_999,
                temperature: 4,
                topP: -1,
                topK: 500,
                minP: 2,
                repetitionPenalty: 4,
                thinkingEnabled: true
            ),
            for: "local/plain-model",
            supportsThinking: false
        )

        let saved = try XCTUnwrap(store.settings(for: "local/plain-model"))
        XCTAssertEqual(saved.maxTokens, 4_096)
        XCTAssertEqual(saved.temperature, 1.5)
        XCTAssertEqual(saved.topP, 0.05)
        XCTAssertEqual(saved.topK, 100)
        XCTAssertEqual(saved.minP, 0.5)
        XCTAssertEqual(saved.repetitionPenalty, 1.3)
        XCTAssertFalse(saved.thinkingEnabled)
    }

    func test_enabledMLXLowMemoryPolicyUsesTokenAILimitAndNoCache() {
        let policy = MLXLowMemoryPolicy.resolve(
            enabled: true,
            physicalMemoryBytes: 8_000_000_000,
            processCeilingBytes: 6_200_000_000
        )

        XCTAssertEqual(policy.memoryLimitBytes, 5_920_000_000)
        XCTAssertEqual(policy.cacheLimitBytes, 0)
    }

    func test_MLXLowMemoryPolicyNeverExceedsProcessCeiling() {
        let policy = MLXLowMemoryPolicy.resolve(
            enabled: true,
            physicalMemoryBytes: 12_000_000_000,
            processCeilingBytes: 8_500_000_000
        )

        XCTAssertEqual(policy.memoryLimitBytes, 8_500_000_000)
        XCTAssertEqual(policy.cacheLimitBytes, 0)
    }

    func test_disabledMLXLowMemoryPolicyLeavesAllocatorUntouched() {
        let policy = MLXLowMemoryPolicy.resolve(
            enabled: false,
            physicalMemoryBytes: 8_000_000_000,
            processCeilingBytes: 6_200_000_000
        )

        XCTAssertNil(policy.memoryLimitBytes)
        XCTAssertNil(policy.cacheLimitBytes)
    }

    func test_MLXHardCeilingMessageExplainsGGUFOnlyPaging() {
        let message = MemoryAdvisor.hardCeilingMessage(
            neededBytes: 6_600_000_000,
            ceilingBytes: 6_200_000_000,
            runtime: .mlx,
            lowMemoryEnabled: true
        )

        XCTAssertTrue(message.contains("needs ~6.6 GB"))
        XCTAssertTrue(message.contains("cannot page MLX weights"))
        XCTAssertTrue(message.contains("GGUF quantization"))
        XCTAssertTrue(MemoryAdvisor.isHardCapacityFailure(message))
    }

    func test_normalHardCeilingMessageDoesNotClaimPagingIsEnabled() {
        let message = MemoryAdvisor.hardCeilingMessage(
            neededBytes: 6_600_000_000,
            ceilingBytes: 6_200_000_000,
            runtime: .mlx,
            lowMemoryEnabled: false
        )

        XCTAssertTrue(message.contains("too large for this device"))
        XCTAssertFalse(message.contains("storage-backed paging"))
        XCTAssertTrue(MemoryAdvisor.isHardCapacityFailure(message))
    }

    func test_transientLoadFailureRemainsRetryable() {
        XCTAssertFalse(
            MemoryAdvisor.isHardCapacityFailure(
                "Not enough memory right now. Close other apps, then retry."
            )
        )
    }

    func test_tightFitKeepsPositiveReserveAndRejectsOversizedFootprint() {
        let available: Int64 = 4_000_000_000
        XCTAssertGreaterThan(MemoryAdvisor.edgeHeadroomReserve, 0)
        XCTAssertLessThan(MemoryAdvisor.edgeHeadroomReserve, MemoryAdvisor.loadHeadroomReserve)
        XCTAssertGreaterThan(
            MemoryAdvisor.requiredLoadMemory(footprint: available + 1, reserve: MemoryAdvisor.edgeHeadroomReserve),
            available
        )
        XCTAssertLessThanOrEqual(
            MemoryAdvisor.requiredLoadMemory(footprint: 3_800_000_000, reserve: MemoryAdvisor.edgeHeadroomReserve),
            available
        )
        XCTAssertGreaterThan(
            MemoryAdvisor.requiredLoadMemory(footprint: 3_800_000_000, reserve: MemoryAdvisor.loadHeadroomReserve),
            available
        )
    }

    func test_unknownAndOverflowingFootprintsCannotBypassAdmission() {
        XCTAssertEqual(
            MemoryAdvisor.requiredLoadMemory(footprint: 0, reserve: MemoryAdvisor.edgeHeadroomReserve),
            MemoryAdvisor.unknownFootprintFloor + MemoryAdvisor.edgeHeadroomReserve
        )
        XCTAssertEqual(
            MemoryAdvisor.requiredLoadMemory(footprint: Int64.max, reserve: MemoryAdvisor.edgeHeadroomReserve),
            Int64.max
        )
    }

    func test_dualRoleRuntimeIsSharedOnlyWhenVisionEnvelopeFits() {
        XCTAssertFalse(
            DualRoleModelPolicy.shouldShareRuntime(
                isDualRole: true,
                selectionsMatch: true,
                requiredVisionBytes: 8_700_000_000,
                availableBytes: 6_080_000_000
            ),
            "Matching picker selections must not force an unsafe VLM runtime onto Assistant"
        )
        XCTAssertTrue(
            DualRoleModelPolicy.shouldShareRuntime(
                isDualRole: true,
                selectionsMatch: true,
                requiredVisionBytes: 5_100_000_000,
                availableBytes: 6_080_000_000
            )
        )
        XCTAssertFalse(
            DualRoleModelPolicy.shouldShareRuntime(
                isDualRole: true,
                selectionsMatch: false,
                requiredVisionBytes: 5_100_000_000,
                availableBytes: 6_080_000_000
            ),
            "Different Assistant and Lens selections should keep independent runtimes"
        )
    }

    func test_bonsai27VisionEnvelopeStillExceedsIPhoneCeiling() {
        let visionPeak = LensInferenceLoop.phaseAwarePeakBytes(
            weightBytes: 5_130_000_000,
            activationReserveBytes: 800_000_000
        )
        let required = LensInferenceLoop.requiredLoadBytes(peakBytes: visionPeak)

        XCTAssertGreaterThan(
            required,
            UInt64(MemoryAdvisor.maximumIPhoneProcessCeiling)
        )
    }

    func test_gemmaGGUFProfileUsesLensSizedContext() {
        let profile = LlamaCppVLMExecutionProfile.resolve(
            repoID: "ggml-org/gemma-3-4b-it-GGUF"
        )
        XCTAssertEqual(profile.contextSize, 1_024)
        XCTAssertNil(
            profile.maxOutputTokens,
            "The preallocated 1K context bounds memory; answer length follows the caller and thermal advisor"
        )
        XCTAssertTrue(profile.requiresSingleResidency)
    }

    @MainActor
    func test_curatedGemmaIsCompleteGGUFPairNotWholeRepository() {
        let gemma = ModelDownloadCenter.shared.models.first {
            $0.id == "ggml-org/gemma-3-4b-it-GGUF"
        }
        XCTAssertEqual(gemma?.runtime, .llamaCpp)
        XCTAssertEqual(
            gemma?.downloader?.fileAllowlist,
            ["gemma-3-4b-it-Q4_K_M.gguf", "mmproj-model-f16.gguf"]
        )
    }

    @MainActor
    func test_legacyGemmaSelectionMigratesToBoundedGGUFBackend() {
        let legacy = "mlx-community/gemma-3-4b-it-4bit"
        let migrated = LocalModelRegistry.storedVisionSelectionID(legacy)

        XCTAssertEqual(migrated, "ggml-org/gemma-3-4b-it-GGUF")
        XCTAssertEqual(
            LocalModelRegistry.visionRuntime(
                forStoredSelectionID: legacy,
                catalog: ModelDownloadCenter.shared.models
            ),
            .llamaCpp
        )
    }

    func test_unknownFootprintFloor_isConservative() {
        // An unsized model must fail safe: assume at least 3.5 GB so a large
        // custom/imported model can't slip through the gate as "fits".
        XCTAssertGreaterThanOrEqual(MemoryAdvisor.unknownFootprintFloor, 3_500_000_000,
            "Unknown-footprint floor must stay high enough to block unsized large models")
    }

    func test_estimatedFootprint_knownPresets() {
        // Hand-tuned built-in footprints — pin them so a careless edit to the
        // table is caught (the gate's correctness depends on these).
        XCTAssertEqual(MemoryAdvisor.estimatedFootprint(for: "qwen3-8b"), 6_500_000_000)
        XCTAssertEqual(MemoryAdvisor.estimatedFootprint(for: "qwen3-4b"), 3_800_000_000)
        XCTAssertEqual(MemoryAdvisor.estimatedFootprint(for: "qwen3-1.7b"), 1_500_000_000)
    }

    func test_verdict_unknownModel_fitsComfortably() {
        // Unknown footprint (== 0) must not be treated as huge — it returns
        // fits (the per-process ceiling in safetyBlocker is the real backstop).
        XCTAssertFalse(MemoryAdvisor.verdict(for: "totally/unknown-model-xyz").isBlocking)
    }

    func test_verdict_oversizedStack_isBlocking() {
        // Stacking many copies of the largest model far exceeds any device's
        // 70%-of-physical budget, so the verdict must block regardless of the
        // test host's RAM.
        let huge = Array(repeating: "qwen3-8b", count: 20)
        XCTAssertTrue(MemoryAdvisor.verdict(for: "qwen3-8b", alreadyLoaded: huge).isBlocking,
                      "20x 8B models must exceed budget and block")
    }

    func test_normalGGUFModeKeepsSmallModelsFullyAccelerated() {
        let policy = GGUFLoadPolicy.resolve(
            fileBytes: 2 * 1_024 * 1_024 * 1_024,
            pagingEnabled: false
        )

        XCTAssertEqual(policy.gpuLayers, 999)
        XCTAssertFalse(policy.storageBacked)
        XCTAssertGreaterThan(policy.minimumAvailableBytes, 2_000_000_000)
    }

    func test_normalGGUFModeBoundsMetalOffloadForLargeModels() {
        let policy = GGUFLoadPolicy.resolve(
            fileBytes: 8 * 1_024 * 1_024 * 1_024,
            pagingEnabled: false
        )

        #if targetEnvironment(macCatalyst)
        // Mac keeps all layers on Metal; the partial-offload cap is iOS-only.
        XCTAssertEqual(policy.gpuLayers, 999)
        #else
        XCTAssertEqual(policy.gpuLayers, 12)
        #endif
        XCTAssertFalse(policy.storageBacked)
    }

    func test_storageBackedGGUFModeUsesFixedHeadroomAndNoMetalLayers() {
        let policy = GGUFLoadPolicy.resolve(
            fileBytes: 18 * 1_024 * 1_024 * 1_024,
            pagingEnabled: true
        )

        XCTAssertEqual(policy.gpuLayers, 0)
        XCTAssertTrue(policy.storageBacked)
        XCTAssertEqual(
            policy.minimumAvailableBytes,
            GGUFLoadPolicy.storageBackedHeadroom
        )
    }
}

// MARK: - Model limit maximization (measured peaks, memory-sized context)

final class ModelLimitSizingTests: XCTestCase {
    func test_measuredPeak_exactReplacesEstimateBoundOnlyLowersIt() {
        // Lifetime peak rose during the run → exact peak (raises or lowers).
        let exact = MemoryAdvisor.updatedMeasurement(
            [:], baseline: 500, peakBefore: 1_000, peakAfter: 5_500)
        XCTAssertEqual(exact["exact"], 5_000)
        // Peak did not rise → only an upper bound; keeps the smallest.
        let bound = MemoryAdvisor.updatedMeasurement(
            ["bound": 4_000], baseline: 1_000, peakBefore: 9_000, peakAfter: 9_000)
        XCTAssertEqual(bound["bound"], 4_000)

        let gb: Int64 = 1_000_000_000
        // Exact peak above the estimate raises it (with margin).
        XCTAssertEqual(MemoryAdvisor.footprint(staticEstimate: 4 * gb, measurement: ["exact": 5 * gb]),
                       5_500_000_000)
        // A bound never raises an estimate.
        XCTAssertEqual(MemoryAdvisor.footprint(staticEstimate: 4 * gb, measurement: ["bound": 6 * gb]), 4 * gb)
        // Lowering stops at 75% of the estimate.
        XCTAssertEqual(MemoryAdvisor.footprint(staticEstimate: 8 * gb, measurement: ["exact": 1 * gb]), 6 * gb)
        // No measurement: estimate unchanged.
        XCTAssertEqual(MemoryAdvisor.footprint(staticEstimate: 3 * gb, measurement: [:]), 3 * gb)
    }

    func test_kvShape_qwen3AndHybridConfigs() throws {
        let qwen3 = try XCTUnwrap(KVCacheShape(config: [
            "num_hidden_layers": 36, "num_attention_heads": 32,
            "num_key_value_heads": 8, "head_dim": 128, "hidden_size": 2560,
        ]))
        XCTAssertEqual(qwen3, KVCacheShape(attentionLayers: 36, kvHeads: 8, headDim: 128))
        // 36 × 8 × 128 × 2 = 73,728 elements/token; fp16 2 B, 8-bit 1.0625 B.
        XCTAssertEqual(qwen3.bytesPerToken(kvBits: nil), 147_456)
        XCTAssertEqual(qwen3.bytesPerToken(kvBits: 8), 78_336)
        XCTAssertEqual(qwen3.bytesPerToken(kvBits: 4), 41_472)

        let hybrid = try XCTUnwrap(KVCacheShape(config: ["text_config": [
            "num_hidden_layers": 8, "num_attention_heads": 16, "num_key_value_heads": 4,
            "head_dim": 256,
            "layer_types": ["linear_attention", "linear_attention", "linear_attention", "full_attention",
                            "linear_attention", "linear_attention", "linear_attention", "full_attention"],
        ] as [String: Any]]))
        XCTAssertEqual(hybrid.attentionLayers, 2)
        let interval = try XCTUnwrap(KVCacheShape(config: [
            "num_hidden_layers": 48, "num_attention_heads": 16, "head_dim": 128, "full_attention_interval": 4,
        ]))
        XCTAssertEqual(interval.attentionLayers, 12)
        XCTAssertEqual(interval.kvHeads, 16)
        XCTAssertNil(KVCacheShape(config: ["hidden_size": 1024]))
    }

    func test_sizedProfile_followsMemoryWithinCaps() {
        let shape = KVCacheShape(attentionLayers: 36, kvHeads: 8, headDim: 128)
        let base = MLXAssistantExecutionProfile.resolve(repoID: "mlx-community/Qwen3-4B-4bit")
        // Plenty of memory: full cap at 8-bit.
        let roomy = base.sized(shape: shape, headroomBytes: 3_000_000_000, contextCap: 16_384)
        XCTAssertEqual(roomy.maxContextTokens, 16_384)
        XCTAssertEqual(roomy.kvBits, 8)
        XCTAssertNil(roomy.maxKVSize)
        // Tight: 8-bit can't reach the cap → 4-bit, window from memory.
        let tight = base.sized(shape: shape, headroomBytes: 400_000_000, contextCap: 16_384)
        XCTAssertEqual(tight.kvBits, 4)
        XCTAssertEqual(tight.maxContextTokens, 9_472)  // 400 MB / 41,472 B → 9,645 → 256-aligned
        // No memory left: never below the 2K floor.
        XCTAssertEqual(base.sized(shape: shape, headroomBytes: -5, contextCap: 16_384).maxContextTokens, 2_048)
        // Unknown shape: profile unchanged.
        XCTAssertEqual(base.sized(shape: nil, headroomBytes: 9_000_000_000, contextCap: 16_384), base)

        // Rotating profile: window grows with memory but never below its own.
        let qwen35 = MLXAssistantExecutionProfile.resolve(repoID: "local/MLX-Qwen3.5-4B-4bit")
        let hybrid = KVCacheShape(attentionLayers: 8, kvHeads: 4, headDim: 256)
        let grown = qwen35.sized(shape: hybrid, headroomBytes: 1_000_000_000, contextCap: 16_384)
        XCTAssertEqual(grown.maxContextTokens, 16_384)
        XCTAssertEqual(grown.maxKVSize, 16_384)
        XCTAssertEqual(qwen35.sized(shape: hybrid, headroomBytes: 0, contextCap: 16_384).maxKVSize, 2_048)
    }

    func test_outputCap_growingCacheKeepsHalfTheWindow() {
        let growing = MLXAssistantExecutionProfile.resolve(repoID: "mlx-community/Qwen3-4B-4bit")
        XCTAssertEqual(growing.outputCap(contextLimit: 4_096), 2_048)
        XCTAssertEqual(
            growing.inputBudget(modelContextWindowTokens: 32_768, deviceContextCap: 4_096,
                                requestedOutputTokens: 8_192),
            1_792)
        let rotating = MLXAssistantExecutionProfile.resolve(repoID: "mlx-community/Ornith-1.0-9B-4bit")
        XCTAssertNil(rotating.outputCap(contextLimit: 4_096), "a rotating window doesn't grow with the reply")
    }

    func test_ggufContext_sizedFromBudgetWithinFloorAndTrainedLength() {
        // 1 MB/token, 6 GB budget → 6,000 → 5,888; under the 16K cap.
        XCTAssertEqual(LlamaCppVLM.kvSizedContext(perTokenBytes: 1_000_000, kvBudgetBytes: 6_000_000_000,
                                                  floor: 4_096, ceiling: 16_384, trainedContext: 32_768), 5_888)
        XCTAssertEqual(LlamaCppVLM.kvSizedContext(perTokenBytes: 1_000, kvBudgetBytes: 6_000_000_000,
                                                  floor: 4_096, ceiling: 16_384, trainedContext: 8_192), 8_192)
        XCTAssertEqual(LlamaCppVLM.kvSizedContext(perTokenBytes: 1_000_000, kvBudgetBytes: 0,
                                                  floor: 4_096, ceiling: 16_384, trainedContext: 32_768), 4_096)
    }

    func test_pccInputBudget_longReplySettingKeepsPromptRoom() {
        XCTAssertEqual(ApplePrivateCloud.inputBudget(contextSize: 4_096, maximumResponseTokens: 8_192), 1_536)
    }
}
