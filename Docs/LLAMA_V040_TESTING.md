# llama.cpp v0.4.0 testing

Updated on 5 September 2026 on `codex/llama-v0.4.0-testing`.

- Previous revision: `7ef790f90a4772eadd6966815f6d3ae7d93c7e03`.
- Testing revision: `5266f24da75dc449bd56cbed7addb9c8e4a6a73e` ([v0.4.0](https://github.com/ggml-org/llama.cpp/releases/tag/v0.4.0)).
- License remains MIT; upstream notices remain in the submodule.
- The release source pins this revision for sideload build 3.2.7 (112).

## Integration changes

The native build script uses upstream's `ios-sim ios-device` arguments. The old iOS-only patch is removed. Both text-generation repetition-sampler calls now supply the vocabulary size required by the new C API.

Generation settings, context budgets, model residency, cancellation, and thermal/memory admission policies are unchanged. The existing `penalty_last_n = -1` is intentionally preserved: both the previous and new native implementations clamp it to zero. Correcting that pre-existing behavior would change sampling and is outside this compatibility update.

## Device acceptance checks

Validation: native iPhone and Simulator framework builds, Simulator app compilation, an unsigned iPhone app build, 27 GGUF generation-profile tests, and 3 inference policy tests passed. Release preparation aligns CITATION, SPDX metadata, and the changelog with version 3.2.7.

Before treating this as the new stable runtime, use the same installed models and settings as the previous build:

1. Run a familiar text GGUF for several turns; check streaming, Stop, Continue, and a fresh conversation.
2. Switch between GGUF and MLX, then unload and reload. Check that old runtimes release memory.
3. Run an existing vision GGUF with its matching projector through Lens.
4. Run a voice conversation using GGUF, interrupt speech, and start another turn.
5. Background during generation, return, and verify recovery. Check memory and thermal behavior on a physical iPhone.

Simulator compilation and policy tests cannot establish model quality, Metal stability, peak RAM, or battery behavior. No model weights were downloaded for this update.

## Local rollback

The previous generated framework is preserved at `ThirdParty/llama.cpp/build-apple-backup-7ef790f/llama.xcframework` on this machine (ignored by Git).

Rollback requires restoring the old submodule revision **and** the previous framework together, removing the two newly added vocabulary-size arguments in `LlamaCppBridge.swift`, and restoring the previous native build script/patch and dependency metadata. Preserve the separate chat/voice/Lens edits. Do not use a repository-wide reset.

After rollback, clean the app build to avoid using cached headers or binaries from the other revision. If rebuilding rather than using the backup, the old revision needs the old iOS-only patch. The new generated framework contains iOS device and Simulator slices; build the optional Catalyst slice before testing on Mac Catalyst.
