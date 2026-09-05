# CoreAI Studio: competitor comparison and product audit

Research date: 5 September 2026. Scope: official competitor descriptions/repositories, current upstream release notes, and targeted local source inspection. This is not a hands-on competitor benchmark, App Store popularity ranking, or complete security review. No application code, dependencies, or model downloads were changed.

## Product conclusion

The app already has substantial breadth: local chat, camera/vision, conversational voice, image generation, documents/RAG, model import/downloads, benchmarking, quality evaluation, model comparison, Shortcuts, and a paired Mac tool channel. The strongest next investment is making those capabilities feel like one reliable product. Adding another top-level feature before fixing onboarding, grounding visibility, and conversation behavior would increase complexity faster than usefulness.

Positioning proposal: **A private AI studio on your iPhone: talk, see, create, and work with your files.** Describe optional external execution separately and accurately. “Best” should be demonstrated through completion rates, responsiveness, recoverability, and device-specific quality—not model counts or unsupported claims about competitors.

## Three competitive benchmarks

I selected these three because they offer complementary, directly relevant benchmarks: open model flexibility, guided Apple integration, and phone-to-desktop continuity. This is a judgment about comparison value, not an assertion that independent testing established an absolute top three. Fullmoon and other minimalist apps remain useful secondary references.

| Competitor | Verified offering | Lesson for CoreAI Studio |
| --- | --- | --- |
| **PocketPal AI** | Official repository documents GGUF import/Hugging Face discovery, local TTS, configurable Pals, tools, benchmarks, and editing/regeneration. | Make reusable assistants easy to configure; treat model evaluation as part of selection, not an isolated utility. |
| **Private LLM** | Official site provides device/use-case model selection and Siri/Shortcuts workflows across Apple devices. | Guide people to a suitable model and useful task before exposing technical configuration. |
| **Locally by LM Studio** | App Store listing describes on-device MLX chat and image analysis. LM Studio documents LM Link for encrypted access to models on another machine. | Keep mobile interaction simple and make the execution device explicit. Remote access to a home computer is distinct from inference on the iPhone. |

Sources: [PocketPal repository](https://github.com/a-ghorbani/pocketpal-ai), [Private LLM](https://privatellm.app/en), [Locally App Store listing](https://apps.apple.com/us/app/locally-ai-by-lm-studio/id6741426692), [LM Link mobile announcement](https://lmstudio.ai/blog/locally-lm-link).

Vendor performance/quantization superiority claims were not accepted as benchmark evidence. An unlisted competitor capability is unknown, not proven absent. No competitor output quality, thermal behavior, or animation smoothness was personally tested.

## What already exists here—and what needs improvement

| Area | Existing source | Recommended delta |
| --- | --- | --- |
| Model choice | Model catalog, device tier/memory admission, recommended combinations | Explain suitability per task and current device; separate “downloaded,” “loadable,” and “validated.” |
| Evaluation | BenchmarkService, QualityEvalView, CompareView, VisualModelComparisonView | Correct measurement ordering, record runtime/configuration provenance, and link results from model details. Do not build a duplicate benchmark feature. |
| Reusable assistants | Persona.swift, memory and sampler stores | Extend a persona into an optional task preset binding model preference, voice, document scope, and tool policy. |
| Apple integration | IOSLocalLLMAppIntents.swift, share extension, SpotlightIndexer | Expose a small Shortcuts gallery and explain which actions open the app versus use the system model. |
| Documents | KnowledgeBaseService, FileAttachmentService, KnowledgeBaseView | Add stable source references and excerpt inspection, document scope per chat, indexing status, and dependable cancellation. |
| Desktop | Pairing-authenticated Mac bridge | Improve connection explanation and capability discovery. Do not advertise the existing tool bridge as equivalent to LM Link's remote inference without implementing and verifying that route. |
| Voice | Separate orb, karaoke, and controls presentation models | Follow the spoken phrase, pause idle polling, and display understandable listening/preparing/speaking/error states. |
| Lens and image generation | CameraRootView, LensTaskPanel, AnalysisPanelView, image studio | Preserve successful camera capture; connect its results to ongoing tasks and saved artifacts rather than adding another camera mode. |

## Additional source-backed findings

These extend the [earlier UI/CodeLens audit](UI_PERFORMANCE_CODELENS_AUDIT_2026-09-05.md), whose parser, scrolling, unfinished-code, voice-follow, and Reduce Motion findings remain relevant.

### P1: Clearing the knowledge base can be undone by an in-flight import

`Services/RAG/KnowledgeBaseService.swift:76–146` starts detached embedding work, awaits it, then appends and persists the result. Neither `clear()` nor `wipeFromDisk()` invalidates that pending operation. `WipeAllDataService.swift:79` calls the latter. If reset occurs during embedding, the completed import can recreate the index afterward. This is a source-backed interleaving, not an on-device reproduction.

Fix: retain cancellable import jobs and a reset generation counter. Check cancellation/generation before committing. Use job counts rather than one Boolean for multiple imports. Acceptance: pause an import, wipe, release the import; memory and disk stay empty and no success toast appears.

### P2: The knowledge-base limit does not bound the completed result

`KnowledgeBaseService.swift:85` checks only the existing count, then permits up to 400 new chunks. At 4,999 chunks, a 400-chunk import can exceed the stated 5,000 ceiling. Concurrent imports can each pass the initial check while the actor is suspended.

Fix: reserve capacity or clamp/reject at commit, report truncation explicitly, and test overlapping imports near the limit. Maintain the existing per-document limits and safety policy.

### P2: Onboarding describes the old product and makes overbroad privacy claims

`Views/OnboardingView.swift:24–95` leads with scanning code and a fixed Qwen3/MLX setup, includes five explanatory pages before the picker, and says network use is model-download-only. This app now has broader model/runtime choices and explicit web, sync, bridge, and Apple Private Cloud paths.

`Views/HomeView.swift:111–145` similarly hardcodes replies staying on the iPhone and an on-device header, independently of the selected execution location. This is a presentation inconsistency; it does not establish unauthorized network transmission.

Fix: derive execution wording from the same source used for actual routing. Replace the tutorial with: choose a task, review the recommended download, try a useful prompt. Keep privacy readable: local by default; optional network features identified at the point of use. Test every execution route and idle/loading state.

### P2: Benchmark callbacks do not form an ordered measurement pipeline

`Services/BenchmarkService.swift:198–239` launches independent Tasks for token updates and completion. Completion snapshots the metrics without explicitly draining outstanding token tasks. Actor isolation protects individual calls but does not make this multi-step pipeline atomic or guarantee finalization happens after all updates. Throughput samples are added per callback despite the documented one-per-second intent; an unused `lastSampleTime` remains.

Some backends emit text chunks/deltas (`CodingAssistantService.swift:2344,2607,2810`), so incrementing once per callback is not a comparable tokenizer token count. The result already calls this approximate; it should not become a cross-backend accuracy claim.

Fix: one ordered event consumer, explicit completion barrier, real usage counts when available, clearly labeled estimates otherwise, time-based sampling, and immutable per-run generation options. Test burst delivery immediately followed by completion, cancellation, and two different chunking patterns for identical output.

### Performance candidate: document retrieval and persistence occupy the main actor

`KnowledgeBaseService` is main-actor isolated. Retrieval embeds the query, scores every chunk, and sorts the full candidate set synchronously; JSON encoding and file writes in `persist()` are also synchronous. `CodingAssistantView.swift:3288` calls retrieval before adding the user's message to the UI. At larger indexes this can increase perceived send latency. The import embedding loop itself already runs off-main—retain that improvement.

Fix: snapshot-backed retrieval/index actor, bounded top-k selection, serialized persistence, and immediate visible send/preparing feedback. Profile 100, 1,000, and 5,000 chunks before choosing a new database or vector index. Do not add a dependency merely to optimize a small corpus.

### Performance/logic candidate: every conversation save rebuilds all Spotlight entries

`Models/ConversationStore.swift:167` invokes `SpotlightIndexer.reindexAll`; `Services/SpotlightIndexer.swift:18` deletes the whole domain before reinserting every conversation. Single-item index and remove helpers already exist. Repeated saves create avoidable work and a temporary empty-search interval; overlapping delete/reinsert completion order deserves a regression test.

Fix: update only changed IDs, delete only removed IDs, and reserve full rebuilds for migration/repair. Profile large histories. Separately assess whole-history JSON load/save cost; do not assert that Task creation alone guarantees off-main execution or migrate storage without evidence.

## Simplification plan that preserves the design

Keep the present five tabs during the first iteration. A navigation rewrite would create migration work before the underlying friction is resolved.

1. **Home becomes a useful starting point.** One task entry, Resume recent work, and concise readiness. Remove duplicate voice entry points from the hero/quick-action combination. Keep Lens and Voice directly accessible.
2. **Use one model-selection sheet.** First show recommended and installed models suitable for the current task; put all models and expert filters behind an expansion. Persist the user's explicit choice.
3. **Put technical controls under Advanced.** Preserve quantization, context, samplers, backend, and residency details, but normal users choose intent and a understandable speed/quality preference. Never silently switch model identity or execution location.
4. **Use one status vocabulary.** Downloading → validating → loading → ready → generating → stopped/error. Provide one relevant recovery action and expandable details.
5. **Keep the visual identity.** Retain glass, palette, and spatial arrangement; standardize body/secondary/code/control styles, fix Dynamic Type fallback differences, and reduce decorative motion during reading.
6. **Make model changes explainable.** “Using your selected model,” “Needs download,” and “Cannot fit right now” are more useful than backend labels on every surface. Preserve thermal/memory refusal behavior.

## Highest-value additions or extensions

| Priority | Proposal | Concrete user benefit | Scope and acceptance |
| --- | --- | --- | --- |
| Next | **Offline readiness card** | Know which tasks will work before a flight or without service | Read-only status for chat, vision, transcription, speech, and images; distinguish installed assets from successful validation. Downloads remain explicit. |
| Next | **Document source inspector** | Verify an answer against its evidence | Persist document/chunk IDs with the answer; open the cited excerpt. Show when no source supports the answer. Filename-only citations are insufficient for duplicate names. |
| Next | **Unified task presets** | Start “Study these notes” or “Explain this image” without configuring four systems | Extend Persona rather than add a competing preset store. Bind optional model/voice/document scope; require fresh approval for consequential tools. |
| Next | **Actionable model fit** | Choose confidently without learning parameter counts | Combine existing safety checks with local benchmark evidence; label estimates separately and invalidate measurements after runtime/configuration changes. |
| Later | **Task workspace and artifact shelf** | Keep a chat, its pictures, documents, and generated results together | Build on conversations/history first; reference existing assets rather than duplicate bytes. Verify export and deletion across all linked assets. |
| Later | **Shortcuts examples** | Reuse the assistant from everyday iOS workflows | Curated summarize/rewrite/explain entry points using existing intents. Keep foreground requirements explicit. |
| Later | **Optional desktop model access** | Use a larger model on a paired Mac | Separate inference capability from tool execution; authenticate, show destination, and fail explicitly if disconnected. No silent cloud fallback. |

Do not prioritize a public persona marketplace, automatic benchmark uploads, multiple simultaneous heavy agents, speculative decoding by default, or video generation simply to extend the feature list. Each adds significant trust, memory, or UX costs. A manual sequential model comparison already exists and respects the device better.

## Code cleaning

Use the current CoreAI implementations when adopting Desktop CodeLens's file boundaries: extract CameraRootView from ContentView, execution-policy types from CodingAssistantService, and download rows from ModelsManagerView. The sibling mostly separates functionality already present here. Do not replace newer CoreAI safety, consent, and diagnostics behavior with older sibling code.

Next, isolate the block tokenizer, chat follow policy, and a typed generation event stream. Unify presentation of runtime errors while preserving backend-specific recovery. Remove misleading historical comments (including the knowledge-base claim that no competitor has local RAG), unused benchmark state, and duplicate terminology only after checking call sites. File length alone is not a runtime performance defect.

## New llama.cpp and Meta model releases

**llama.cpp v0.4.0 was released on 4 September 2026.** Relevant changes include on-demand tensor reading, load-memory work, KV restore improvements, new model support, and multimodal API changes. State/session versions changed. These warrant a controlled integration evaluation; they are not proof of faster iPhone inference. [Official v0.4.0 release](https://github.com/ggml-org/llama.cpp/releases/tag/v0.4.0).

The newer **b10819 pre-release**, shown on 5 September, includes a Metal early-return memory-leak fix. Treat this as a specific patch candidate, distinct from the stable tag. [Official release listing](https://github.com/ggml-org/llama.cpp/releases).

The app's SBOM records llama.cpp `7ef790f90a4772eadd6966815f6d3ae7d93c7e03`. The source folder has no Git metadata, so that record is not proof of the exact current checkout or linked binary. Local source lacks the searched Muse Glimmer architecture registration and new lazy-mode API. Establish a reproducible source/binary fingerprint before upgrading.

Upgrade evaluation: pin an exact revision; check the iOS build patch and Swift C/mtmd calls; rebuild native frameworks; test saved-state compatibility, UTF-8 streaming, chat templates, tool output, image preprocessing, cancellation/unload, and pressure recovery. Compare cold load, first token, sustained decode, peak memory, and thermal behavior on the same physical devices/models. Keep rollback artifacts outside Git. Server-only features do not automatically reach this native app.

**Meta's new downloadable local model is Muse Glimmer 30B, released 10 August 2026, rather than a newly verified Llama-branded release.** Meta describes it as an Apache-2.0 open model aimed at Mac/PC agent workflows with a 24–32 GB memory envelope. Evaluate it for desktop use first. [Meta announcement](https://research.meta.ai/blog/introducing-muse-glimmer-open-agentic-model).

The official GGUF card lists a 16.8 GB text model, an additional 1.4 GB perception encoder, minimum llama.cpp build b10353, and model-specific template/stop-token requirements. That is not a sensible default iPhone download; runtime support alone does not establish device suitability. [Official GGUF card](https://huggingface.co/meta-models/Muse-Glimmer-30B-GGUF).

Meta also announced **Muse Spark 1.3 on 2 September**, available through Muse Code and its model API; that announcement does not establish downloadable iPhone weights. [Official announcement](https://research.meta.ai/blog/introducing-muse-spark-1-3). The research index lists **Muse Voice Transcribe on 1 September**, but its detailed page could not be retrieved, so no local integration recommendation is made. [Meta research index](https://research.meta.ai/).

## Delivery sequence and proof

1. Correct reset/import races, privacy wording, Markdown fidelity, and scroll ownership; add focused regression tests.
2. Repair benchmark ordering, measure the existing app, and record runtime/configuration provenance.
3. Simplify onboarding and model selection; improve voice follow and idle work.
4. Add readiness, source inspection, and task presets on existing foundations.
5. Evaluate the pinned llama.cpp update and desktop-only large models independently of UI changes.

Usability validation: ask a new user to start a local chat, understand what must download, use voice, inspect a document source, recover from an interrupted reply, and remove imported data. Record success and steps rather than assume fewer screens are always better.

Performance validation: use the same model, prompt, output limit, temperature, runtime revision, thermal starting state, and device. Record cold/warm first-token latency, stream frame hitches, cancellation-to-idle time, memory peaks, and idle energy. Speed claims require real-device measurements; Simulator tests validate interaction and layout.

Known validation limitation: the previous app build was blocked by CoreAI module resolution and the ONNX XCFramework copy phase. The earlier 25 passing VoiceAgentOrb tests are useful baseline evidence, not validation of this audit's proposed changes. This audit performed source/web research only.
