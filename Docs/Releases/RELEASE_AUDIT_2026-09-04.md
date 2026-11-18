# Release audit and implementation — 4 September 2026

Baseline: `72a0c65`. The audited changes are included in sideload build 3.2.7 (111). See
`Docs/RELEASE_VERIFICATION.md` for the separate binary packaging and signing scope.

## Implemented improvements

| Area | Change |
| --- | --- |
| Search | Request identities reject stale results/errors; cancellation stays silent; category-only browsing displays results; failed requests offer Retry. |
| Downloads | Start claims ownership synchronously. Cancellation targets the exact URLSession task. Retry waits for the old operation and cleanup; stale progress is discarded. Deletion waits for cleanup, preserves sibling variants, and reports filesystem failures. Duplicate deletion callers receive an in-progress error. Remote response bodies are no longer logged. |
| Sync | Fetch every CloudKit page before merging. Failed records/payloads abort reconciliation. Claim sync ownership before suspension and recheck opt-in throughout. Surface failed writes/deletes; retain deletion markers instead of expiring unsynced deletions. Re-read local conversations after network waits. Cloud diagnostics omit record contents and error payloads. |
| Sync controls | Settings offers an explicit opt-in, manual Sync Now, progress, last success for the session, and error/retry status. The disclosure explains uploads and that disabling sync does not delete existing cloud copies. |
| Recovery | Retry the original model; provide token/terms and storage/network guidance. Alternatives use normal discovery and compatibility checks. Recovery no longer overwrites the unrelated FastVLM selection. |
| Installation | Show format, estimated download and memory, available storage, compatibility, uncertainty, and repository/license link before confirming a download. Existing admission policies remain authoritative at load time. |
| Onboarding | Two introduction pages followed by Chat/Lens/Voice goal selection. Download only the model required for that goal; voice explains its additional speech setup. Source-only builds no longer promise bundled weights. |
| Accessibility | Semantic Dynamic Type font fallbacks, named 44-point search controls, stable Next identifier, scrolling onboarding content, and adaptive search headers at accessibility sizes. |
| Privacy wording | Local-by-default wording replaces blanket device-only claims in Settings, model setup, onboarding, and Home. The user guide lists optional network features. |
| Diagnostics | Existing export includes an explicitly unverified release checklist; product-name header is corrected. No prompt/output/media export was added. |
| Maintenance | Camera root, assistant execution policy, and model download rows moved into separate files along existing ownership boundaries. XcodeGen regenerated the project. |
| CI | Added a macOS app job that builds pinned native submodules, installs locked pods, runs app tests, and compiles Release. `scripts/validate_app_release.sh` provides the same local gate. |

## Dependencies

ONNX Runtime Objective-C and C CocoaPods were upgraded from **1.23.0 to 1.29.0**. The Podfile, lockfile, SPDX inventory, and notices agree. The official Objective-C distribution was verified before updating; the previously suggested 1.28.2 was not an available Objective-C pod version. The application disables optional POSIX telemetry before creating its ONNX environment. [Official pod versions](https://trunk.cocoapods.org/api/v1/pods/onnxruntime-objc), [1.29.0 pod specification](https://trunk.cocoapods.org/api/v1/pods/onnxruntime-objc/specs/1.29.0), [upstream release](https://github.com/microsoft/onnxruntime/releases/tag/v1.29.0).

MLX LM stays at its existing 3.31.4 resolution. The PrismML fork and native submodule revisions are preserved; their specialized kernels and protocols are not interchangeable routine upgrades. No models, assets, or runtime frameworks were added to Git. This is not an exhaustive transitive vulnerability assessment.

The new CI toolchain uses the documented Xcode 26.6 path on `macos-26`; local validation uses Xcode 27 beta. CI execution itself requires a pushed branch and has not been run remotely. [GitHub runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).

## Validation

Environment: iPhone 17 Simulator, iOS 27, Xcode 27 beta at
`/Applications/Xcode-beta.app/Contents/Developer`. Simulator identifier:
`8D051CF7-FD51-4720-A30C-D08C8DA05AEB`.

| Check | Result |
| --- | --- |
| Full app unit suite | 495 tests: 494 passed, one model-dependent skip, zero failures |
| Release-screen UI suite | Four passed: category-only search/preflight, largest-text dark search with reachable actions, largest-text onboarding/goal picker, Home |
| Voice UI suite | Four passed |
| VoiceAgentOrb package | 25 passed during the audit |
| Release Simulator build | Passed for arm64 and x86_64; final retry also passed |
| Repository checks | Hygiene validator, whitespace check, workflow YAML parsing, and SPDX JSON parsing passed |

The full test phase ran through `scripts/validate_app_release.sh`. Its final
Release compile/link completed, but debug-symbol generation exhausted local
disk space. Only this task's generated Debug products/intermediates and the
incomplete Release symbols were removed before retrying the same Release step successfully.
The initial complete Release build had already passed. No tests failed during
this final gate, and no user documents or source files were removed.

Local evidence (temporary build artifacts, not committed):

- `/tmp/codelens-final-validation.log`: final full app test run and the disk-space failure during symbol generation.
- `/tmp/codelens-release-final.log`: initial successful Release build.
- `/tmp/codelens-release-retry.log`: final Release retry after freeing disk space.
- `/tmp/codelens-release-build/Logs/Test/Test-IOSLocalLLM-2026.09.04_23-34-50-+0300.xcresult`: final test result and retained screenshot attachments.
- `/tmp/codelens-verified-screens/`: exported screenshots inspected after the final passing UI tests.

Deterministic fixtures use real views, synthetic search metadata, and no model
downloads. Visual inspection confirmed readable model names, reachable download
controls, and footers that reserve space rather than overlap scrolling content
at the largest Dynamic Type size. This does not validate inference, live Hugging
Face traffic, or live CloudKit behavior. README's Home image was refreshed from
the actual Home view with empty history; other historical screenshots are labeled.

## Remaining release evidence

A binary release still requires the physical-device matrix in `Docs/VALIDATION.md`: real model load/generate/cancel/switch/unload, background cleanup, memory pressure, thermal transitions, and battery behavior. Simulator success cannot certify these.

Additional external checks remain:

- ONNX 1.29 KittenTTS inference/audio comparison with licensed staged model artifacts. The model-dependent runtime test skips without them.
- Live CloudKit account/schema and multi-device synchronization, including conflict and offline recovery. Unit tests cover paging, errors, ownership, and opt-out but do not contact iCloud.
- Mac Catalyst build and visual checks. Locally staged llama/whisper frameworks lack Catalyst slices; the official ONNX pod XCFramework also contains iOS, Simulator, and macOS slices but no Catalyst slice. Native macOS is not a substitute for a Catalyst binary.
- Small-screen and VoiceOver manual navigation, plus broader localized-copy review. New English copy falls back through the existing localization system; translations have not been certified.
- Remote CI run on the selected runner image, and signed device/archive validation.

These are evidence gaps, not claims that the implemented paths have failed. The audit does not certify a production release or every supported device.
