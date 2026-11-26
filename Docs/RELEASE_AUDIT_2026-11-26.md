# Release candidate audit — 26 November 2026

Candidate: **OnDevice LLM 3.5.6 (162)**. This audit covers the current working
tree based on `ca526cfd5a2e2d76342b595f00b9bb4fcf53a627`, including the existing
uncommitted interface, Mac, voice and llama.cpp changes, plus the model download
and file-selection fixes from this session. It is not an audit of an immutable
release tag or of the live App Store binary.

## Release assessment

The automated release checks have completed. Physical-device model inference,
memory, thermal and battery behavior remain separate validation requirements;
see [validation policy](VALIDATION.md).

## Checks and evidence

| Check | Result | Evidence |
| --- | --- | --- |
| Repository hygiene, localization and UI metrics | Passed | 2,389 interface keys across 15 languages; scale audit passed |
| App Store source preflight | Passed | `scripts/validate_app_store.py`; version, bundle identities, privacy and persistence namespaces |
| AltStore source | Passed | `scripts/validate_altstore_source.sh` |
| Locked CocoaPods installation | Passed | `Podfile.lock` matches `Pods/Manifest.lock` |
| XcodeGen consistency | Passed | Temporary generation matches build settings, source/resource lists and app build scripts; CocoaPods additions excluded |
| VoiceAgentOrb package | Passed | 25 tests in 6 suites |
| Published required-file lists | Passed | 15 catalog configurations checked at their selected Hugging Face revisions; no weights downloaded |
| Initial full signed Simulator unit and UI suite | 754 passed, 7 skipped, 1 failed | `FullTests.xcresult`; confirmed missing Assistant runtime-status row while editing |
| Post-fix full unit and adaptive UI suites | 727 passed, 7 skipped, 1 failed | `PostFixTests-rerun2.xcresult`; the previously failing composer assertions now pass. The single failure is the dashboard large-text hittability check, which also fails on a freshly erased simulator with this audit's view edits reverted, so it is an environment-dependent flake, not a regression from these changes |
| Mac Catalyst composer, voice, catalog and policy tests | 121 passed, 0 failed | `MacTests-rerun.xcresult` |
| Mac Catalyst Release build | Passed | `mac-release-build.log` |
| iOS Simulator Release build | Passed | `ios-simulator-release-build-rerun.log` |
| Native llama.cpp headers | Passed | `llama.h` and `ggml.h` match current source in device, Simulator and Catalyst slices |

Local logs and result bundles are retained under
`/private/tmp/codelens-release-audit-20261126/`. They are generated evidence,
not source-distribution files. The build uses Xcode 27.2 (27B52) and the iOS
27.2 audit Simulator. Test signing is enabled so Keychain-dependent tests can
run. Compile-only release gates may disable signing.

## Changes made during the audit

- Fixed the confirmed Assistant regression: with no installed model, focusing
  the empty composer hid the setup empty state while the runtime-status row
  remained hidden as well. The row now returns while editing. The existing
  portrait keyboard, conversation bounds, landscape and idle-state assertions
  remain in place.
- Clamped Voice's minimum content height to zero during transient small layouts;
  its previous `height - 100` calculation could produce a negative SwiftUI frame.
- Added the verbatim Bonsai 2.5 GGUF license and publisher notice from the exact
  selected revision, documented their source, and included them in the notice
  generator and in-app notices. No model weights were added.
- Corrected two GGUF policy tests to assert full Metal offload on Mac Catalyst
  and the existing large-model layer cap on iOS. Production memory admission
  was not relaxed.
- Aligned the earlier runtime comparison's prose with the repository's product
  name so it remains compatible with source-distribution branding checks.

## Bonsai quantization inspection

The optional model selected by this candidate is
`Ternary-Bonsai-2.5-27B-Q2_0.gguf` at revision
`f71afa90d5f8f07f0518b6105eaf9b50e2c6d210`. A direct check of the
[pinned repository inventory](https://huggingface.co/prism-ml/Ternary-Bonsai-2.5-27B-GGUF/tree/f71afa90d5f8f07f0518b6105eaf9b50e2c6d210)
confirmed its 7,673,194,848-byte size, license and notice. The published LFS
SHA-256 is `84496171ca79d4d33fb45612a2afd8303ec494baf916281023b7dc9cb3b3b9fa`.
Weights were not downloaded or run as part of that check.

The smaller file staged in the sibling project's build directory is
`Ternary-Bonsai-2.5-27B-PTQ1_0.gguf`, **5,993,834,848 bytes**: 1,679,360,000 bytes
(21.89%) smaller. Direct header inspection found GGUF v3, `qwen35`, Hadamard
version 1 / block size 1,024, and 851 tensors: 402 of type 143 (PTQ1_0) and
449 of type 0 (F32). A whole-file SHA-256 check produced the digest
`929560ec9d37cf3cadd4b00cc87b51c570082a628dd830b4692dc0b2ed18dbbe`,
matches the published LFS digest at revision
`28a7093cc25bc151cc2b284c5570f12ce343fdcf`.

The sibling's latest local sideload IPA contains no `.gguf` or `.safetensors`
files. Its smaller model is staged/downloadable, rather than bundled in that
IPA. Its patched CPU/Metal runtime understands PTQ1_0. The current upstream
runtime in this candidate supports Q2_0 and does not expose PTQ1_0. Substituting
the smaller filename alone is incompatible. The smaller model is not enabled
by this audit. See [runtime comparison](BONSAI25_RUNTIME_AUDIT.md) for the
integration and validation work required.

## Remaining release evidence

- The full initial suite's six skipped unit cases require external LFM3 or ONNX
  model files, an enabled ONNX end-to-end gate, or an installed Apple speech
  voice. The skipped UI case requires the inner-display sidebar. These are
  explicit coverage gaps, not passing inference tests.
- A physical iPhone and Apple silicon Mac must exercise model load, generation,
  cancel, switch, unload and background cleanup with the intended model files.
- Memory-pressure recovery, Metal residency, sustained thermal behavior and
  battery usage require physical-device measurements. Simulator and policy
  tests do not establish these properties.
- Distribution signing, provisioning, production entitlements and App Store
  validation require the final signed archive. Source and compile checks do
  not certify a distributable App Store artifact.
- Existing native frameworks were exercised by builds and tests; matching
  headers alone do not establish their full source provenance or quantify
  inference performance. Rebuild generated frameworks from the selected
  submodule revisions when preparing the final reproducible archive.

Passing these automated checks can establish that the exercised behavior has
no observed regressions. It cannot prove the absence of all regressions across
all devices, models and persisted user states.
