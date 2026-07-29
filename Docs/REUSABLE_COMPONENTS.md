# Reusable components for local-LLM iOS apps

This catalog helps iOS developers find the parts of OnDeviceiOS that are useful
outside the full application. It lists source files, dependencies, tests, and
the work normally required to extract each subsystem.

OnDeviceiOS is MIT-licensed, but it is an app rather than a finished SDK. Start
with a small component and preserve its tests and safety behavior.

## Reuse levels

- **Extractable** — mostly Foundation-based and suitable for a Swift package
  with small access-control or naming changes.
- **Adaptable** — reusable design and implementation, but app types, UIKit
  lifecycle, persistence, or logging should be placed behind adapters.
- **Integrated** — coupled to the app service graph or native inference
  frameworks. Treat as a reference implementation or extract through a new
  protocol boundary.

## Quick selection

| You need | Start with | Level |
| --- | --- | --- |
| Correct UTF-8 token streaming | `StreamingResponseCoordinator.swift` | Extractable |
| Serialized runtime access and cancellation | `RuntimeEngine.swift` | Extractable |
| GGUF or safetensors file validation | `LocalModelFileValidator.swift` | Extractable |
| Persistent deferred indexing | `PendingIndexQueue.swift` | Extractable |
| Simple PII masking before indexing | `PIIRedactor.swift` | Extractable |
| Device/RAM model admission | `DeviceTierAdvisor.swift`, `MemoryAdvisor.swift` | Adaptable |
| Thermal, memory, and lifecycle protection | safety and residency services | Adaptable |
| Hugging Face search and downloads | model-management services | Adaptable |
| MLX text/vision generation | MLX services | Integrated |
| llama.cpp GGUF text/vision generation | llama.cpp services | Integrated |
| OpenAI/Anthropic/Ollama-compatible local routes | `LocalAPIServer.swift` | Integrated |
| Retrieval and local embeddings | RAG services | Adaptable |
| Voice turn-taking and text cleanup | voice pipeline utilities | Extractable/Adaptable |
| Local diagnostics and crash recovery | diagnostics services | Adaptable |

## Streaming and runtime primitives

### UTF-8 streaming and response coalescing — Extractable

- Source:
  [`StreamingResponseCoordinator.swift`](../CodeLens/LocalAIRuntimeFoundation/Streaming/StreamingResponseCoordinator.swift)
- Tests:
  [`LocalAIFoundationTests.swift`](../CodeLensTests/LocalAIFoundationTests.swift)
- Dependencies: Foundation and Swift concurrency.
- Useful for: incremental token output where a runtime can split a Unicode
  scalar across byte chunks; throttled/coalesced UI updates.
- Extraction note: make internal declarations public if the new package needs
  them across module boundaries.

### Serialized inference sessions — Extractable

- Source:
  [`RuntimeEngine.swift`](../CodeLens/LocalAIRuntimeFoundation/Runtime/RuntimeEngine.swift)
- Dependencies: Foundation and Swift concurrency.
- Useful for: actor-isolated model sessions, one active generation at a time,
  and explicit cancellation.
- Extraction note: the actor is small and portable. Replace the surrounding
  app request/response protocols with types owned by your package.

### Runtime configuration and errors — Extractable

- Sources:
  [`LocalAIFoundationConfig.swift`](../CodeLens/LocalAIRuntimeFoundation/Public/LocalAIFoundationConfig.swift),
  [`RuntimeError.swift`](../CodeLens/LocalAIRuntimeFoundation/Public/RuntimeError.swift),
  and
  [`LocalAITypes.swift`](../CodeLens/LocalAIRuntimeFoundation/Public/LocalAITypes.swift)
- Dependencies: primarily Foundation; some public types currently import
  UIKit.
- Useful for: generation options, runtime state, error classification, and
  normalized finish reasons.
- Extraction note: split UIKit-specific observations from portable value
  types before targeting macOS or Linux.

## Model-file validation and deferred work

### Local model validation — Extractable

- Source:
  [`LocalModelFileValidator.swift`](../CodeLens/LocalAIRuntimeFoundation/Storage/LocalModelFileValidator.swift)
- Tests:
  [`LocalAIFoundationTests.swift`](../CodeLensTests/LocalAIFoundationTests.swift)
- Dependencies: Foundation.
- Useful for: checking GGUF magic bytes, validating paired VLM projector
  files, and confirming expected safetensors shards exist before loading.
- Extraction note: keep validation separate from runtime loading so corrupt or
  incomplete downloads fail early.

### Pending indexing queue — Extractable

- Source:
  [`PendingIndexQueue.swift`](../CodeLens/LocalAIRuntimeFoundation/RAG/PendingIndexQueue.swift)
- Tests:
  [`LocalAIFoundationTests.swift`](../CodeLensTests/LocalAIFoundationTests.swift)
- Dependencies: Foundation.
- Useful for: persisting RAG work that must wait for acceptable power, thermal,
  or memory conditions.
- Extraction note: inject your own policy decision and storage URL.

### PII redaction — Extractable

- Source:
  [`PIIRedactor.swift`](../CodeLens/LocalAIRuntimeFoundation/RAG/PIIRedactor.swift)
- Tests:
  [`LocalAIFoundationTests.swift`](../CodeLensTests/LocalAIFoundationTests.swift)
- Dependencies: Foundation.
- Useful for: basic masking before locally indexing text.
- Boundary: this is defensive preprocessing, not a comprehensive data-loss
  prevention system. Extend and test it for your data domain.

## Memory, thermal, and lifecycle safety kit

### Device tier and memory admission — Adaptable

- Sources:
  [`DeviceTierAdvisor.swift`](../CodeLens/Services/DeviceTierAdvisor.swift) and
  [`MemoryAdvisor.swift`](../CodeLens/Services/MemoryAdvisor.swift)
- Tests:
  [`DeviceTierAdvisorTests.swift`](../CodeLensTests/DeviceTierAdvisorTests.swift)
- Dependencies: Foundation, `os`, UIKit, and app model metadata.
- Useful for: estimating whether a model/configuration fits the current
  device, explaining refusals, and selecting conservative defaults.
- Extraction note: move device facts and model-cost estimates into protocols.
  Calibrate thresholds on physical devices; Simulator memory is not evidence
  of Jetsam safety.

### Runtime safety, residency, and lifecycle — Adaptable

- Sources:
  [`DeviceSafetyMonitor.swift`](../CodeLens/Services/DeviceSafetyMonitor.swift),
  [`ModelResidency.swift`](../CodeLens/Services/ModelResidency.swift), and
  [`LifecycleController.swift`](../CodeLens/Services/LifecycleController.swift)
- Dependencies: Foundation, UIKit/SwiftUI lifecycle notifications, `os`, and
  the app's runtime services.
- Useful for: one coordinated owner for large model allocations, thermal
  escalation, memory warnings, background cleanup, and cooldown.
- Extraction note: extract these together behind runtime unload/cancel
  protocols. Copying only admission checks without cleanup paths creates a
  false sense of safety.

## Model discovery, download, and import

### Hugging Face search and download — Adaptable

- Sources:
  [`HFSearchService.swift`](../CodeLens/Services/HFSearchService.swift),
  [`HFModelDownloadManager.swift`](../CodeLens/Services/HFModelDownloadManager.swift),
  and
  [`ModelDownloadCenter.swift`](../CodeLens/Services/ModelDownloadCenter.swift)
- Tests:
  [`HighRiskServiceTests.swift`](../CodeLensTests/HighRiskServiceTests.swift)
  and
  [`ModelCategoryInferenceTests.swift`](../CodeLensTests/ModelCategoryInferenceTests.swift)
- Dependencies: Foundation, Combine, CryptoKit, app catalog types, storage,
  admission policy, and Hugging Face HTTP APIs.
- Useful for: model discovery, resumable state, integrity checks, category
  inference, download coordination, and user-visible failure recovery.
- Extraction note: separate transport, catalog mapping, filesystem layout,
  policy admission, and UI-observable state. Do not assume a model's license
  allows redistribution.

### Local model import — Adaptable

- Source:
  [`LocalModelImportService.swift`](../CodeLens/Services/LocalModelImportService.swift)
- Dependencies: Foundation, UIKit, UniformTypeIdentifiers, SwiftUI, model
  validation, and app storage conventions.
- Useful for: security-scoped file import and copying user-provided models
  into app-owned storage.
- Extraction note: retain coordinated file access and validation; replace app
  alerts and model metadata with injected interfaces.

## Inference backends

### MLX language and vision runtime — Integrated

- Sources:
  [`CodingAssistantService.swift`](../CodeLens/Services/CodingAssistantService.swift)
  and
  [`MLXGenerationGate.swift`](../CodeLens/Services/MLXGenerationGate.swift)
- Dependencies: MLX/MLXLLM/MLXVLM packages, tokenizer/model factories, UIKit,
  safety policy, residency, app chat types, and observable UI state.
- Useful for: a production-scale reference for loading, streaming, cancelling,
  and unloading MLX language and vision models.
- Extraction strategy: first define a narrow `LocalTextRuntime` or
  `LocalVisionRuntime` protocol. Move backend-specific loading and generation
  behind it, then adapt app messages at the boundary. Preserve the generation
  gate and coordinated unload behavior.

### llama.cpp GGUF runtime — Integrated

- Sources:
  [`LlamaCppBridge.swift`](../CodeLens/Services/LlamaCpp/LlamaCppBridge.swift)
  and
  [`LlamaCppVLMService.swift`](../CodeLens/Services/LlamaCpp/LlamaCppVLMService.swift)
- Native dependency: the
  [`ThirdParty/llama.cpp`](../ThirdParty/llama.cpp) submodule and its locally
  generated XCFramework.
- Dependencies: Foundation, UIKit, CoreImage, Combine, native C APIs, app
  messages, safety policy, and residency.
- Useful for: a reference for GGUF loading, token streaming, cancellation, and
  multimodal projector handling.
- Extraction strategy: wrap the C API in a backend target, keep model-file
  validation in a portable target, and expose only `Sendable` value types to
  callers.

## Local APIs and agent tools

### OpenAI, Anthropic, and Ollama compatibility — Integrated

- Source:
  [`LocalAPIServer.swift`](../CodeLens/Services/Bridge/LocalAPIServer.swift)
- Tests:
  [`LocalAPIServerTests.swift`](../CodeLensTests/LocalAPIServerTests.swift)
- Dependencies: Network, Darwin, UIKit, app runtimes, authentication,
  serialization types, and lifecycle policy.
- Useful for: request decoding, streaming response encoding, scoped
  compatibility behavior, bearer authentication, and explicit unsupported
  option handling.
- Extraction strategy: separate the HTTP transport, protocol codecs, auth,
  model registry, and inference adapter. Start with the codecs and their tests.
  Review [Agent integration](AGENT_INTEGRATION.md) for the supported surface.

### Tool execution — Integrated

- Source:
  [`ToolRunner.swift`](../CodeLens/Services/ToolRunner.swift)
- Tests:
  [`ToolRunnerTests.swift`](../CodeLensTests/ToolRunnerTests.swift)
- Dependencies: Foundation, UIKit, app tools, approval/risk policy, and paired
  bridge state.
- Useful for: structured tool-call dispatch and a reference risk model.
- Boundary: never reuse execution dispatch without authentication, explicit
  allowlists, argument validation, risk classification, and user approval for
  consequential actions.

## Retrieval and embeddings

### Passage scoring — Extractable

- Source:
  [`EmbeddingPassageScorer.swift`](../CodeLens/Services/RAG/EmbeddingPassageScorer.swift)
- Dependencies: Foundation.
- Useful for: ranking embedded passages independently of the storage or UI
  layer.

### Knowledge base and on-device embeddings — Adaptable

- Sources:
  [`KnowledgeBaseService.swift`](../CodeLens/Services/RAG/KnowledgeBaseService.swift)
  and
  [`OnDeviceEmbedder.swift`](../CodeLens/Services/RAG/OnDeviceEmbedder.swift)
- Tests:
  [`OnDeviceEmbedderTests.swift`](../CodeLensTests/OnDeviceEmbedderTests.swift)
- Dependencies: Foundation, Combine, NaturalLanguage, app persistence, PII
  redaction, and indexing policy.
- Useful for: local document ingestion, embeddings, retrieval, and deferred
  indexing.
- Extraction note: define document-store and embedder protocols, then compose
  the portable scorer, redactor, and pending queue around them.

## Voice pipeline utilities

Several small voice utilities are useful without adopting the whole speech
stack:

| Component | Source | Level |
| --- | --- | --- |
| Bounded audio buffering | [`AudioQueue.swift`](../CodeLens/Services/Voice/Pipeline/AudioQueue.swift) | Extractable |
| Local language detection | [`LanguageDetector.swift`](../CodeLens/Services/Voice/Pipeline/LanguageDetector.swift) | Adaptable (`NaturalLanguage`) |
| Remove reasoning tags from spoken output | [`ReasoningStripper.swift`](../CodeLens/Services/Voice/Pipeline/ReasoningStripper.swift) | Extractable |
| Semantic speech chunking | [`SemanticChunker.swift`](../CodeLens/Services/Voice/Pipeline/SemanticChunker.swift) | Extractable |
| Text sanitizing/chunking | [`TextChunker.swift`](../CodeLens/Services/Voice/TextChunker.swift) | Extractable |
| End-of-turn estimation | [`EndOfTurnEstimator.swift`](../CodeLens/Services/Voice/Listening/EndOfTurnEstimator.swift) | Extractable |
| Turn-end state machine | [`TurnEndpointer.swift`](../CodeLens/Services/Voice/Listening/TurnEndpointer.swift) | Extractable |
| Core ML voice activity detection | [`VoiceActivityDetector.swift`](../CodeLens/Services/Voice/Listening/VoiceActivityDetector.swift) | Adaptable |

Matching tests are named after these components in
[`CodeLensTests`](../CodeLensTests). Model artifacts are deliberately excluded
from the repository and retain their own licenses.

## Diagnostics and recovery

### Diagnostics, crash reporting, and system status — Adaptable

- Sources:
  [`Diagnostics.swift`](../CodeLens/Services/Diagnostics/Diagnostics.swift),
  [`CrashReporter.swift`](../CodeLens/Services/Diagnostics/CrashReporter.swift),
  and
  [`SystemStatusService.swift`](../CodeLens/Services/SystemStatusService.swift)
- Tests:
  [`DiagnosticsTests.swift`](../CodeLensTests/DiagnosticsTests.swift)
- Dependencies: Foundation, Darwin, Metal, UIKit, `os`, and app settings.
- Useful for: privacy-conscious local diagnostics, detecting previous
  abnormal termination, and exposing hardware/runtime status.
- Extraction note: use an allowlist for recorded fields and verify that
  prompts, outputs, credentials, documents, and captured media cannot enter
  logs.

## Suggested extraction order

1. Copy one Extractable component and its matching tests into a new Swift
   package.
2. Replace app-specific types with value types owned by that package.
3. Add protocols for device facts, storage, runtime cancellation, and unload
   behavior before moving an Adaptable subsystem.
4. Test cancellation, backgrounding, memory pressure, corrupt files, partial
   downloads, and thermal refusal—not only successful generation.
5. Integrate one inference backend last, behind a narrow runtime interface.
6. Profile and user-test on the oldest physical device you support.

The
[`LocalAIRuntimeFoundation README`](../CodeLens/LocalAIRuntimeFoundation/README.md)
describes the closest existing boundary to a future standalone runtime
package.

## Give a component to a coding agent

Use the
[coding-agent implementation handoff](CODING_AGENT_IMPLEMENTATION.md) when you
want an agent to port one of these components into another app. It includes a
copy-paste prompt, required discovery and licensing checks, instructions for
each reuse level, physical-device validation requirements, and a definition
of done.

## Licensing when reusing code

Original OnDeviceiOS code is available under the
[MIT License](../LICENSE). Keep the copyright and permission notice with
copied or substantial portions of the code.

The MIT license does not automatically cover:

- `llama.cpp`, `whisper.cpp`, or other third-party dependencies;
- model weights, tokenizers, datasets, voices, or generated assets;
- Apple sample code and research-only assets;
- the CodeLens name or logos as trademarks.

Review [Third-party notices](../THIRD_PARTY_NOTICES.md),
[`LICENSES`](../LICENSES), and each model card before distribution.
