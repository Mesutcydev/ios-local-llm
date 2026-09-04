# Validation and evidence policy

This document separates implemented safeguards from verified behavior. A code
path or a user report is not automatically a benchmark.

## Current evidence

The maintainer has confirmed manual debugging and user testing of model
management, RAM admission, memory-warning handling, and thermal-management
behavior. The repository contains the corresponding policy and lifecycle code,
but does not yet include enough shareable raw logs to claim a comprehensive
device benchmark.

Automated, repeatable checks currently include:

| Scope | Command | Environment |
| --- | --- | --- |
| Repository hygiene | `./scripts/validate_open_source.sh` | Linux or macOS |
| VoiceAgentOrb package | `swift test --package-path Packages/VoiceAgentOrb` | macOS CI |
| XcodeGen consistency | `xcodegen generate` followed by a clean diff | macOS |
| App workspace build | `xcodebuild build -workspace IOSLocalLLM.xcworkspace -scheme IOSLocalLLM -destination 'platform=iOS Simulator,name=iPhone 17'` | iPhone 17 simulator, iOS 27 |
| App tests and Release compile gate | `./scripts/validate_app_release.sh` | macOS CI or local Xcode; installed iPhone Simulator |
| App unit and UI tests | `xcodebuild test -workspace IOSLocalLLM.xcworkspace -scheme IOSLocalLLM -destination 'platform=iOS Simulator,name=iPhone 17'` | iPhone 17 simulator, iOS 27 |

On 29 July 2026, the open-source workspace built successfully and the
first-launch legal flow, onboarding, Home, Assistant, and Models screens were
manually exercised on the simulator. Assistant model preparation is
intentionally skipped on simulator builds because the simulated GPU cannot
provide valid MLX inference evidence; the real inference path remains a
physical-device validation requirement.

Do not pass `CODE_SIGNING_ALLOWED=NO` to the test command. Simulator tests are
ad-hoc signed without a paid developer account, and the Keychain-backed
pairing and credential-wipe tests require the resulting Keychain entitlement.

The release gate requires the native frameworks, XcodeGen project, and locked
CocoaPods installation described in `SETUP_INSTRUCTIONS.md`. Set
`DEVELOPER_DIR` to a full Xcode installation if Command Line Tools is selected.
`AUDIT_SIMULATOR_ID` and `AUDIT_DERIVED_DATA` optionally select the Simulator
and build directory. The script runs the full app unit/UI suite, then a generic
iOS Simulator Release build. The `app-release` CI job builds native dependencies
from pinned submodules first. Runtime tests that require staged model weights
can skip; a passing CI job does not satisfy the physical-device matrix.

Deterministic `ReleaseScreensUITests` attach screenshots of the actual search,
installation preflight, onboarding, and Home views. Search metadata is synthetic
and no model is downloaded. Attachments are retained in the test `.xcresult`.

## Required physical-device matrix

Before making a quantified reliability or performance claim, record:

| Field | Required evidence |
| --- | --- |
| Hardware | exact device model and RAM tier |
| Software | iOS, Xcode, app commit, model ID and quantization |
| Model lifecycle | load, generate, cancel, switch, unload |
| Memory pressure | admission decision, warning handling, recovery |
| Thermal | nominal/fair/serious/critical transition behavior |
| Backgrounding | generation stop and resource release |
| Duration | warm-up, run length, prompt/context/output sizes |
| Result | logs, MetricKit/signpost evidence, failures and limitations |

Simulator tests are useful for UI and deterministic logic, but are not evidence
for Jetsam limits, Metal residency, sustained thermals, or battery behavior.
Use synthetic prompts and redact tokens, device names, addresses, and user data.

## Claim language

Use “implemented” for a code path, “manually observed” for a recorded manual
test, and “validated” only when the device, commit, procedure, and outcome are
documented. Never generalize one device result to all supported hardware.
