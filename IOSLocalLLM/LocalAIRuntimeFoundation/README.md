# LocalAIRuntimeFoundation

This directory is the beginning of a reusable boundary for local AI runtimes.
It contains public configuration/types, streaming primitives, file validation,
and small RAG utilities.

It is **not currently a standalone Swift package**. The files are compiled as
part of the iOS Local LLM app target, and several public-facing types still refer to
app services or UIKit. Use
[the reusable-component catalog](../../Docs/REUSABLE_COMPONENTS.md) to choose
portable pieces and understand their dependencies.

## Contents

| Directory | Responsibility | Portability |
| --- | --- | --- |
| `Public/` | Configuration, request/response types, controller, and normalized errors | Mixed; configuration and errors are easiest to extract |
| `Runtime/` | Runtime protocols and actor-isolated session primitive | Session actor is portable; protocols use app types |
| `Streaming/` | Incremental UTF-8 decoding and coalesced response delivery | Highly portable |
| `Storage/` | GGUF, VLM-pair, and safetensors validation | Highly portable |
| `RAG/` | PII redaction and persistent pending-index queue | Highly portable |

## Best first extractions

For a new local-LLM iOS app, start with:

1. `Streaming/StreamingResponseCoordinator.swift`
2. `Storage/LocalModelFileValidator.swift`
3. `Runtime/RuntimeEngine.swift` for its inference-session actor
4. `RAG/PendingIndexQueue.swift`
5. `RAG/PIIRedactor.swift`

Their behavior is exercised by
[`IOSLocalLLMTests/LocalAIFoundationTests.swift`](../../IOSLocalLLMTests/LocalAIFoundationTests.swift).
Move the relevant tests with the implementation.

## Before turning this directory into a package

- Replace references to `CodingAssistantService`, app chat models, and
  singleton state with injected protocols.
- Split UIKit-specific observations from Foundation-only value types.
- Make package-facing declarations explicitly `public` and `Sendable` where
  concurrency requires it.
- Keep runtime implementations in separate targets so an app can choose MLX,
  llama.cpp, or another backend without linking all of them.
- Preserve cancellation, file validation, memory admission, thermal refusal,
  and unload semantics at the integration boundary.

The full runtime and safety relationships are documented in
[`ARCHITECTURE.md`](../../ARCHITECTURE.md).
