# OnDevice LLM — local AI studio audit and competitive comparison

**Audit date:** 5 September 2026. **Source baseline:** `53727c22b5f77c6931491c42758de2d6b7aa9217`, including the six uncommitted chat/voice/Lens polish files already present in this task. Runtime source pin: llama.cpp `7ef790f90a4772eadd6966815f6d3ae7d93c7e03` (27 July 2026).

**Recommendation:** improve correctness, response readability, and the path from choosing a task to getting a useful result before adding more engines. The app already has a broad studio foundation. Its strongest opportunity is to make that breadth dependable and easy to use.

**Maintainer constraint:** preserve the currently functioning model-running paths. This audit makes no changes to loaders, inference, runtime pins, memory admission, or generation defaults. Future UI work must keep those paths intact. Any runtime experiment belongs in a separate branch with the current pin retained for rollback and existing-model regression evidence before adoption.

This is an engineering and product audit, not a claim that one app is fastest. Competitor features were checked against developer documentation, repositories, and US App Store listings. Competitor apps were not installed or benchmarked. Our code was inspected directly; repository screenshots were reviewed for visual direction, with the older Assistant screenshot treated as historical. No physical-device latency, thermal, battery, or model-quality comparisons were performed. “Implemented” below does not mean validated for every model or iPhone. See [validation policy](VALIDATION.md).

## Three comparison targets

These are three strong, directly relevant benchmarks, not an objectively established worldwide ranking. Selection favors overlap with local iOS inference, established distribution, and complementary strengths:

| App | Why it belongs in this comparison | Evidence snapshot |
| --- | --- | --- |
| **PocketPal AI** | Flexible GGUF workflows, personal assistants, and public benchmarking | [Repository](https://github.com/a-ghorbani/pocketpal-ai); [iOS listing](https://apps.apple.com/us/app/pocketpal-ai/id6502579498), v1.17.2, 28 August |
| **Private LLM** | Curated models and integration into Apple workflows | [Developer site](https://privatellm.app/en); [FAQ](https://privatellm.app/en/faq); [iOS listing](https://apps.apple.com/us/app/private-llm-local-ai-chat/id6448106860) |
| **Locally AI by LM Studio** | Native multimodal assistant and desktop continuity | [Developer site](https://locallyai.app/); [iOS listing](https://apps.apple.com/us/app/locally-ai-by-lm-studio/id6741426692), 1.64.0, 11 August; [LM Link documentation](https://lmstudio.ai/docs/lmlink/lmlink-in-locally) |

Google AI Edge Gallery is also relevant to a future task-based multimodal review. This table deliberately concentrates on three general-purpose local assistant competitors. Store versions and prices are snapshots, not promises about availability in every country.

## GitHub-style differences table

**Legend:** ✅ implemented here / documented by competitor; ◐ partial or materially scoped; **NV** not verified in reviewed sources; ❌ explicitly excluded by the cited source. NV must not be turned into “does not have it.”

Competitor column references apply to the cells in that column: **P1** [PocketPal repository](https://github.com/a-ghorbani/pocketpal-ai), **P2** [PocketPal iOS release notes](https://apps.apple.com/us/app/pocketpal-ai/id6502579498); **R1** [Private LLM](https://privatellm.app/en), **R2** [FAQ](https://privatellm.app/en/faq), **R3** [iOS listing](https://apps.apple.com/us/app/private-llm-local-ai-chat/id6448106860); **L1** [Locally](https://locallyai.app/), **L2** [iOS listing](https://apps.apple.com/us/app/locally-ai-by-lm-studio/id6741426692), **L3** [LM Link](https://lmstudio.ai/docs/lmlink/lmlink-in-locally). Our evidence is indexed immediately after the table.

| Capability | OnDevice LLM — current source | PocketPal AI (P1/P2) | Private LLM (R1/R2/R3) | Locally AI (L1/L2/L3) |
| --- | --- | --- | --- | --- |
| Local text chat after setup | ✅ MLX, GGUF, supported Apple system routes | ✅ GGUF | ✅ Curated text models | ✅ MLX; Apple system support |
| User-selected model discovery/import | ✅ Hugging Face and local model workflows; compatibility gates | ✅ Hugging Face GGUF/import | ◐ Curated catalog; arbitrary HF imports excluded | ◐ Catalog verified; arbitrary import NV |
| Image understanding | ✅ Photos and Lens | ✅ Vision models | ❌ Text inference only | ✅ Vision models |
| Dedicated live camera workflow | ✅ Capture, ask, translate, scan, solve | NV | ❌ Text-only scope | NV |
| Voice | ✅ STT, VAD, streamed speech, interrupt, transcripts | ✅ Neural streaming TTS; full hands-free parity NV | Hands-free mode NV | ✅ Local conversation mode |
| Local image generation | ✅ Diffusion service and UI; hardware-dependent | NV | ❌ Text-only scope | NV |
| Documents / retrieval | ✅ Local KB and file grounding; citation UX needs work | Persistent document RAG NV | ❌ FAQ explicitly excludes document reading/RAG | Persistent document RAG NV |
| Personas / reusable instructions | ✅ Personas, snippets, model profiles | ✅ Pals | ✅ System prompts | ✅ System prompts |
| Benchmarks / model comparison | ✅ Benchmark, Compare, quality-eval surfaces; correctness caveats below | ✅ Benchmarking / leaderboard | Built-in comparison NV | Built-in comparison NV |
| Siri / Shortcuts | ✅ Foreground downloaded-model actions; headless Apple Quick Ask | ✅ Shortcuts | ✅ Siri, Shortcuts, x-callback-url | ✅ Siri, Shortcuts, system controls |
| Remote computer use | ✅ Paired Mac tools; distinct from remote-model hosting | ✅ Compatible remote servers | NV | ✅ LM Studio via LM Link |
| Phone as authenticated API server | ✅ Opt-in LAN API, scoped compatibility | NV | NV | NV |
| Web access during chat | ✅ Explicit optional web tools | ✅ Optional search with own key | ◐ Shortcuts can supply external content | NV |
| Chat organization | ✅ Search, export, saved model, context memory; pin/folders not found | ✅ Pin and Markdown export | Organization parity NV | Organization parity NV |
| Speculative decoding in iOS UI | Not found in app-owned Swift paths | ◐ Experimental draft-model pairing | NV | NV |
| Distribution / entry cost | MIT source; sideload workflow; no current official App Store binary per README | Free listing | $4.99 US listing; one-time purchase | Free listing |

Our implementation evidence:

- Chat and models: [CodingAssistantService](../IOSLocalLLM/Services/CodingAssistantService.swift), [LocalModelRegistry](../IOSLocalLLM/Models/ModelCatalogTypes.swift#L441), [HFSearchView](../IOSLocalLLM/Views/HFSearchView.swift).
- Lens and voice: [LensTaskPanel](../IOSLocalLLM/Views/LensTaskPanel.swift), [VoiceConversationService](../IOSLocalLLM/Services/VoiceConversationService.swift), [VoiceConversationView](../IOSLocalLLM/Views/VoiceConversationView.swift).
- Generation and documents: [ImageGenerationService](../IOSLocalLLM/Services/ImageGenerationService.swift), [KnowledgeBaseService](../IOSLocalLLM/Services/RAG/KnowledgeBaseService.swift).
- Studio tools: [BenchmarkService](../IOSLocalLLM/Services/BenchmarkService.swift), [CompareView](../IOSLocalLLM/Views/CompareView.swift), [ModelQualityEval](../IOSLocalLLM/Services/ModelQualityEval.swift), [Persona](../IOSLocalLLM/Models/Persona.swift).
- Integration and history: [App Intents](../IOSLocalLLM/Services/Intents/IOSLocalLLMAppIntents.swift), [agent integration](AGENT_INTEGRATION.md), [ConversationStore](../IOSLocalLLM/Models/ConversationStore.swift), [README](../README.md).

The defensible advantage is **breadth in one local studio**, especially combining camera tasks, document grounding, image generation, and authenticated integration. It is not yet defensible to claim better speed, model quality, reliability, or accessibility than all three. Private LLM's comparative quantization/speed language is vendor marketing; this audit does not adopt it as an independent benchmark. Locally's offline mode and its internet/account-dependent LM Link mode must also be distinguished.

## Findings that should drive the next work

Priority: **P1** correctness/trust before expanding; **P2** high-value UX/performance; **P3** planned extension. “Code-confirmed” means the current control flow or representation establishes the issue; it is not a claim of device reproduction. Performance candidates require measurement.

| ID | Priority / evidence | Finding and concrete effect | Recommended change and acceptance gate |
| --- | --- | --- | --- |
| A01 | P1 · code-confirmed | **The full wipe misses the KB.** `WipeAllDataService.wipeAll()` deletes several Documents roots and defaults, but not `Application Support/KnowledgeBase/index.json` or its in-memory contents. The UI action is titled “Wipe all on-device data.” | Inventory every durable store and coordinate cancellation, memory reset, disk deletion, and receipts. Test a synthetic KB through wipe + relaunch; do not run destructive checks on user data. Audit custom personas and singleton caches in the same pass. |
| A02 | P1 · code-confirmed | **Benchmarks can record failures as successful runs.** `runSingle` supplies `onComplete` but no `onError`, although generation failures call `onError` then `onComplete(0)`. Its throwing continuation never takes a failure path. | Use one completion outcome carrying success/failure/cancel; failed prompts must not enter comparable history. Inject a failing backend and verify the failure UI and absence of a result row. |
| A03 | P1 · code-confirmed | **Benchmark settings are not controlled.** The service temporarily writes global `assistantMaxTokens`; generation prioritizes a saved per-model `maxTokens`. Other sampling, thinking and JSON preferences also remain effective. | Pass per-call settings via existing overrides, snapshot model/runtime/config at start, and preserve user settings. Verify identical effective configuration with and without a saved profile; distinguish warm and cold runs. |
| A04 | P1 · code-confirmed interleaving | **KB import can undo Clear.** `addDocument` awaits detached embedding, then appends and persists without an operation generation check; `clear()` does not invalidate in-flight imports. The total-chunk limit is checked before, not enforced on commit. | Cancel/invalidate imports when clearing and check the remaining budget atomically before append. Tests: pause embedding, clear, resume; parallel imports near the 5,000-chunk ceiling. No cleared data may return. |
| A05 | P1 · code-confirmed copy mismatch | **Home makes an unconditional local-processing promise.** `heroSubtitle` says replies stay on the iPhone without checking `activeExecutionLocation`; the assistant supports explicit Private Cloud selection. Any model download can also make the unloaded assistant appear to be preparing. | Derive status and privacy copy from the selected execution route and selected model's download. Test local, private cloud, unavailable, and unrelated voice-model download states. Preserve explicit network consent. |
| A06 | P2 · reproduced from current function | **Response-length selection does not round-trip.** Normal writes 1,024, but `nearest(1024)` returns Detailed. Detailed writes 2,048, but maps back to Full. | Make preset mapping internally consistent. Require `nearest(preset.maxTokens) == preset` for every preset and document the rule for custom values. |
| A07 | P2 · code-confirmed | **Completion can steal the reading position.** `followedGenerationAtBottom` is captured at generation start; completion forces a bottom scroll even if the reader subsequently moved up. Tool approval insertions also scroll unconditionally. | Track current following intent and user scroll gestures; only follow while opted in. Test scrolling upward during generation, tool requests, completion, keyboard changes, and tapping Jump to latest. |
| A08 | P2 · code-confirmed layout difference | **Streaming still changes presentation at completion.** Streaming uses plain `Text`; completed output switches to parsed text/code/math/thinking blocks. Matching body sizes fixes one jump, not raw fences, lists, tables, or block reflow. | Keep completed blocks stable and parse only a bounded evolving tail at a controlled cadence. Preserve the live-selection crash workaround. Test long code, incomplete fences, Unicode, thinking tags, and cancellation without a layout-wide animation. |
| A09 | P2 · performance candidate | **A character bucket is not a time throttle.** Every chunk still schedules main-actor work and modifies the parent messages array; the 24-character bucket only reduces scroll callbacks. `String.count` also traverses text. | Coalesce display updates, isolate the active response, and flush promptly on completion/cancel. Measure chunk bursts and growing transcripts before choosing a cadence; never throttle the inference engine itself. |
| A10 | P2 · code-confirmed extra work; impact unmeasured | **Every tab switch rescans model state and storage.** `refreshAllStates()` reconciles, checks models, invalidates footprint caches, and launches a detached size walk. Walks have no stored task or revision guard, so older totals can publish after newer ones. | Prefer completion/deletion/import events; retain a fallback reconciliation. Coalesce scans, reject stale results, and keep footprint invalidation tied to actual file changes. Stress 20 quick tab changes during a synthetic download/delete. |
| A11 | P2 · concurrency/performance risk | **Conversation persistence lacks explicit serialization.** Snapshotting is present, but `ConversationStore` has no actor isolation or serial writer; debounced persistence, retry and synchronous `flush()` share encoder/file state. Loading reads the full JSON; paging helpers have no app callers. | Give UI state an explicit actor and disk writes a serial revisioned owner. Do not merely wrap each write in another detached task. Test save/flush/wipe ordering and profile a large history before changing storage format. |
| A12 | P2 · code-confirmed behavior | **Follow speech scrolls to the end of all text, not the spoken phrase.** The transcript has a single body and bottom anchor; auto-scroll ignores the active range's screen location. The previous fix makes resume immediate but does not solve phrase tracking. | Anchor stable phrases or track the active text range. Long responses must keep the spoken phrase visible, preserve manual reading, and resume at speech position. |
| A13 | P2 · performance candidate | **Voice still has continuous display work.** The Metal orb requests native 60/120 Hz in normal mode, 30 in reduced quality, and 15 with Reduce Motion. Karaoke has an unpaused 12 Hz timeline whenever text exists. GPU cost relative to inference is unmeasured. | Measure actual Metal/energy cost while listening, thinking, speaking, paused, and transcript-only. Pause static karaoke updates; adapt orb cadence to power/thermal/rendering state without losing interrupt feedback. Preserve the existing isolated observation boundaries. |
| A14 | P2 · design/accessibility candidate | **Voice action semantics need a state audit.** The orb advertises a button trait; its parent gesture does nothing in several phases, including paused and failed. Small transcript controls and state-driven focus changes need VoiceOver checks. | Use explicit state-specific accessible actions and hints. Test start, interrupt, pause/resume and retry with VoiceOver; keep the existing control dock visible at accessibility sizes. Do not claim a VoiceOver defect from the trait alone. |
| A15 | P2 · code-confirmed limitation | **KB retrieval is English-default and citations lose location.** The service creates the default English embedder, exposes document names rather than source ranges/pages, and scores/sorts the whole index on MainActor. Long input is clipped to a configured limit. | Show indexing coverage and language, preserve document/chunk provenance, offer tappable excerpts, and move measured costly retrieval off-main. Test Turkish + English documents, missing answers, duplicate filenames, and truncation disclosure. |
| A16 | P2 · code-confirmed incomplete feature | **Logprob support emits placeholders.** MLX emits `logprob: 0` despite comments promising a no-op when unavailable. The present chat handler discards these values, so this is not evidence of a currently visible confidence score. Consumers would interpret zero as probability 1. | Emit explicit unavailable metadata or no tokens; gate UI by backend capability. Test unsupported backends and never substitute invented confidence values. Remove dormant controls if there is no supported consumer. |
| A17 | P2 · design opportunity | **The composer disappears during generation.** Its safe-area inset is removed and Stop remains in the toolbar. Users cannot prepare a follow-up in that composer while reading. Photo/file actions also appear both in the plus menu and alongside it. | Keep a compact stable composer with reachable Stop; allow drafting without accidentally submitting twice. Consolidate attachment actions if testing confirms discoverability. Verify one-handed use, keyboard, long output, and accessibility sizes. |
| A18 | P2 · maintenance finding | **UI orchestration is concentrated in very large files.** CodingAssistantView is 6,108 lines, ModelsManagerView 4,079, SettingsView 1,893, and CodingAssistantService 2,485 at this baseline. Line count alone does not establish a performance problem. | Extract response rendering, scroll policy, turn/tool orchestration, and model-selection presentation along existing boundaries. Extend LocalModelRegistry rather than inventing another catalog. Add behavior tests before moving logic. |
| A19 | P3 · code-confirmed feature gap | **Image generation lacks a reusable run record in its UI.** Service accepts a seed but the screen supplies none; it presents the current image and ShareLink, without a visible seed/history workflow. | Save image + prompt + negative prompt + model revision + actual seed/steps/size as an opt-in local run record. Add reuse/variation and clear-history actions. Same configuration should be replayable within the backend's determinism limits. |
| A20 | P2 · command-confirmed | **Repository validation is red.** The validator expects 3.2.7; CITATION.cff declares 3.2.6. | Align release metadata deliberately and rerun the validator; do not suppress the check. Keep release evidence distinct from physical-device performance evidence. |

### Source anchors for findings

| Findings | Inspected implementation |
| --- | --- |
| A01, A04 | [WipeAllDataService](../IOSLocalLLM/Services/WipeAllDataService.swift#L26), [KB import/clear](../IOSLocalLLM/Services/RAG/KnowledgeBaseService.swift#L76), [KB persistence](../IOSLocalLLM/Services/RAG/KnowledgeBaseService.swift#L213), [wipe UI](../IOSLocalLLM/Views/SettingsView.swift#L1367) |
| A02, A03 | [Benchmark runSingle](../IOSLocalLLM/Services/BenchmarkService.swift#L146), [generation error contract](../IOSLocalLLM/Services/CodingAssistantService.swift#L1086), [settings precedence](../IOSLocalLLM/Services/CodingAssistantService.swift#L1262) |
| A05, A06 | [Home state/copy](../IOSLocalLLM/Views/HomeView.swift#L91), [ResponseLength](../IOSLocalLLM/Views/SettingsView.swift#L1675), [picker binding](../IOSLocalLLM/Views/SettingsView.swift#L1061) |
| A07–A09, A17 | [scroll observers](../IOSLocalLLM/Views/CodingAssistantView.swift#L388), [composer/completion](../IOSLocalLLM/Views/CodingAssistantView.swift#L470), [per-chunk updates](../IOSLocalLLM/Views/CodingAssistantView.swift#L3309), [Markdown renderer](../IOSLocalLLM/Views/CodingAssistantView.swift#L5432), [composer](../IOSLocalLLM/Views/AssistantChatComponents.swift#L3) |
| A10, A11 | [tab refresh](../IOSLocalLLM/ContentView.swift#L74), [model refresh/storage](../IOSLocalLLM/Services/ModelDownloadCenter.swift#L1016), [history writes](../IOSLocalLLM/Models/ConversationStore.swift#L141) |
| A12–A14 | [transcript](../IOSLocalLLM/Views/Voice/KaraokeTranscriptView.swift#L175), [isolated containers](../IOSLocalLLM/Views/Voice/VoiceIsolatedContainers.swift), [Metal view cadence](../IOSLocalLLM/Views/Voice/VoiceActivityOrb.swift#L152) |
| A15, A16 | [KB retrieval](../IOSLocalLLM/Services/RAG/KnowledgeBaseService.swift#L141), [embedder language](../IOSLocalLLM/Services/RAG/OnDeviceEmbedder.swift#L23), [placeholder logprobs](../IOSLocalLLM/Services/CodingAssistantService.swift#L1724), [discarding chat handler](../IOSLocalLLM/Views/CodingAssistantView.swift#L3294) |
| A19, A20 | [image UI](../IOSLocalLLM/Views/ImageGenerationView.swift#L9), [seed generation](../IOSLocalLLM/Services/ImageGenerationService.swift#L561), [CITATION](../CITATION.cff#L12), [validator](../scripts/validate_open_source.sh) |

## Competitor-inspired product plan

The existing glass surfaces, restrained accent, dark Lens, and orb identity should remain. Simplification means fewer decisions before a useful result and consistent behavior across existing screens.

| Order | Work package | Competitive inspiration | Definition of done |
| --- | --- | --- | --- |
| 1 | **Trust and measurement** — A01–A06, A16, A20 | A private studio needs credible controls and benchmarks | Wipe/import interleavings pass; settings round-trip; benchmark failures/configuration are truthful; unsupported capabilities say unavailable; validation passes. |
| 2 | **A stable conversation surface** — A07–A09, A12, A17 | Readability and continuity matter more than another model badge | Smooth streaming, preserved reading position, stable composer, correctly followed speech; synthetic long-answer UI tests and physical-device traces. |
| 3 | **One model-selection experience** | Combine flexible discovery with curated recommendations | Reuse current onboarding goal picker and registry. Offer “Fast / Balanced / Best quality for this device” backed by explicit evidence, plus Advanced. Use identical ready/downloading/unsupported states in chat, voice and Lens. |
| 4 | **Reusable task profiles** | Pals and existing system-prompt workflows | Extend Persona rather than add a parallel feature: optional model, voice, document scope and sampling profile. Share a local configuration file without credentials, private memory, or bundled weights. Preserve current consent/approval policy. |
| 5 | **Document workspaces** | Turn our existing retrieval into a daily-use advantage | Named document collections, source excerpts, indexing coverage/language and per-chat selection; chat pins/search. Do not confuse retrieved evidence with model-generated citations. |
| 6 | **Voice and Lens task continuity** | Native multimodal interaction | Offer “Continue in chat” with capture/source provenance and editable transcript. Voice shows listening/thinking/preparing/speaking, active route, and an immediate interrupt. Lens keeps a stable frame/result and reachable follow-up/retake. |
| 7 | **An image studio loop** — A19 | Make generation useful beyond a one-off preview | Local run history, seed reuse, variants and share. Honor deletion, safety limits and model licenses. |
| 8 | **Power efficiency and advanced decoding** — A10, A11, A13 | Benchmark-led optimization; PocketPal's experimental decoding is a research lead | First measure and reduce redundant UI/I/O work. Only trial a draft model after joint residency admission, acceptance-rate measurement, and energy/latency comparison show a benefit. |

Do not start with a marketplace, autonomous background agent, universal “run any model” promise, new top-level tab, or two simultaneously loaded models. They increase support and memory costs before the core workflows are reliable. Source availability, backend architecture support, quantization/projector compatibility, license, and live device fit are separate checks.

For model discovery, retain an expert path while making the first successful answer easy. For returning users, prioritize the recent conversation and ready model. Keep existing advanced tools accessible through progressive disclosure rather than deleting functionality. Settings already has a grouped entry screen; improve its consistency instead of proposing that grouping as new work.

## The new Llama / llama.cpp release

**Yes: llama.cpp v0.4.0 is now the latest release**, published **4 September 2026 at 19:56:47 UTC**. The GitHub release points to commit `5266f24` and associated nightly `b10809`. This was checked through the live release page and GitHub API; an older search result still showed b10516, illustrating why the release endpoint matters. This repository's **source** pin remains the July commit above; the loaded binary's embedded version was not inspected. [Official release](https://github.com/ggml-org/llama.cpp/releases/tag/v0.4.0).

Relevant changes include lazy tensor reading, reduced load-time RAM peaks, Metal allocation/leak fixes, Metal 4 tensor support on newer chips, Gemma 4 vision fixes, and new model architectures. Session/state versions and multimodal APIs also change. These are upgrade candidates, not proof of faster iPhone inference. Server/web-UI features do not automatically upgrade this app's custom Swift API or SwiftUI screens. [Release details](https://github.com/ggml-org/llama.cpp/releases/tag/v0.4.0).

| Upgrade step | What to verify |
| --- | --- |
| Pin and inspect | Use an isolated upgrade branch; review the full July-pin-to-release diff, not only v0.3-to-v0.4 notes. Preserve submodule boundaries and required licenses. |
| Rebuild native artifacts | Follow SETUP_INSTRUCTIONS and the tracked framework scripts. Recheck local patches and regenerate every required slice; do not substitute a desktop binary. |
| Audit bridge compatibility | Inspect `Services/LlamaCpp/LlamaCppBridge.swift` and sibling VLM service against changed mtmd/context structures. Rebuild dependent code and invalidate any incompatible state caches if used. |
| Test existing models first | Text GGUF, vision + projector, Unicode/tokenization, tool decoding, cancellation, context limits, unload/reload and background cleanup. Then test newly supported architectures. |
| Measure on device | Compare old/new pins with identical model files, prompts and settings: cold/warm load, TTFT, decode, physical footprint, thermal state and energy. Keep a rollback pin. |

If “Llama” meant **Meta's model family**, that is different. The reviewed [official Llama repository](https://github.com/meta-llama/llama-models/blob/main/README.md) and [Scout model card](https://huggingface.co/meta-llama/Llama-4-Scout-17B-16E) still establish Llama 4 as the relevant released family; no newer downloadable Llama generation was verified in this audit. Scout has 109B total parameters despite 17B active per token. Naive 4-bit weights alone would be roughly 54.5 GB before overhead, so active-parameter counts must not be used as iPhone memory estimates.

Meta also announced **Muse Spark 1.3 on 2 September 2026**, delivered through Muse Code and Meta Model API. That announcement does not provide evidence of downloadable iOS-local weights; do not add it as an offline model. [Meta announcement](https://research.meta.ai/blog/introducing-muse-spark-1-3).

## Verification and follow-through

Completed for this audit:

- Inspected the current worktree, core subsystem boundaries, model/runtime pin, and the cited UI/service paths. Earlier uncommitted polish is preserved; this audit adds a report, not another runtime rewrite.
- Executed the actual extracted `ResponseLength` enum using Swift. Output: `Short: 512 -> Short`, `Normal: 1024 -> Detailed`, `Detailed: 2048 -> Full`, `Full: 4096 -> Full`.
- Reran repository validation: **fails** with `CITATION.cff does not declare version 3.2.7`.
- Checked primary competitor sources and the live llama.cpp release endpoint. Unverified competitor features remain NV.

The prior task's Simulator build and five voice UI tests concern the preceding typography/follow-control changes. They do not validate the findings above or establish competitor superiority. The earlier [release audit](RELEASE_AUDIT_2026-09-04.md) is historical evidence, not a fresh run of every test.

Required implementation evidence for the next phase:

| Area | Test / measurement |
| --- | --- |
| Logic | Response preset round-trip; benchmark error/config isolation; KB clear/import races and chunk budget; serialized save/flush/wipe ordering; execution-route copy. |
| UI | Long streaming prose/code/tables; user scroll during completion; large text; dark/light; Reduce Motion; VoiceOver; stopped/retried generation; retained drafts. |
| Local models | Representative MLX and GGUF text/vision models, current versus upgraded runtime, known projector/config pairs. Use the physical-device matrix in VALIDATION.md. |
| Performance | Release build, exact device/OS/model hash and settings; warm-up then repeated comparable runs; median and p95 TTFT/latency, sustained decode, `phys_footprint`, dropped frames, thermal and battery evidence. RSS is not the full GPU/Jetsam footprint. |
| Comparisons | Run shared supported models/settings where possible. If quantizations or engines cannot match, report a separate “best available setup” experiment. Blind-score fixed tasks; never infer answer quality from tokens/sec alone. |

Success should be expressed as users completing chat, voice, Lens and document tasks reliably, with measured responsiveness and truthful state. Capability count alone is insufficient.
