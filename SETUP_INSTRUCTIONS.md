# Development setup

This guide builds the source-only distribution. Model weights, compiled native
frameworks, CocoaPods, and signing profiles are not stored in Git.

## Prerequisites

- Apple-silicon Mac
- Xcode 26 or newer
- Xcode command-line tools
- Homebrew
- At least 15 GB of free space for native framework builds and package caches

Install the project tools:

```bash
brew install cmake xcodegen cocoapods
```

## Clone

The llama.cpp and whisper.cpp sources are Git submodules:

```bash
git clone --recurse-submodules https://github.com/Mesutcydev/ios-local-llm.git
cd ios-local-llm
```

If the repository was cloned without submodules:

```bash
git submodule update --init --recursive
```

## Build native frameworks

IOSLocalLLM links locally generated llama.cpp and whisper.cpp XCFrameworks.
The tracked root script builds the required slices from pinned submodules:

```bash
./scripts/build_native_frameworks.sh
```

Add `--with-catalyst` when you also need the Apple-Silicon Mac Catalyst target.
The script may apply the tracked iOS-only patch inside the generated
llama.cpp build checkout; do not commit that submodule worktree change.

Expected outputs:

```text
ThirdParty/llama.cpp/build-apple/llama.xcframework
ThirdParty/whisper.cpp/build-apple/whisper.xcframework
```

These outputs are generated files and must not be committed.

## Generate the workspace

`project.yml` is the source of truth for the Xcode project:

```bash
xcodegen generate
pod install
open IOSLocalLLM.xcworkspace
```

Open the workspace, not the `.xcodeproj`, so the ONNX Runtime pods are
available.

SwiftPM may report a conflicting `mlx-swift` identity because the project pins
the PrismML fork for one-bit model kernels while another package declares the
upstream repository transitively. This is a documented forward-compatibility
risk in [Docs/XCODE_SECURITY_SETTINGS.md](Docs/XCODE_SECURITY_SETTINGS.md), not
a missing package in the current lockfile.

## Run in Simulator

Select the `IOSLocalLLM` scheme and an iOS 18 or newer Simulator. Simulator builds
do not require a paid Apple Developer Program membership.

The source-only build starts without bundled AI weights. Features that depend
on a model become available after the user downloads a compatible model from
the app's model catalog.

## Run on a physical device

Use your own signing identity:

1. Select the IOSLocalLLM project in Xcode.
2. For the app, share extension, unit-test, and UI-test targets, select your
   development team.
3. Replace the app, extension, App Group, and CloudKit identifiers with values
   owned by your team, following [Docs/FORK_CONFIGURATION.md](Docs/FORK_CONFIGURATION.md).
4. Build and run on your device.

If you regenerate the project, make permanent identifier changes in
`project.yml`; XcodeGen overwrites manual project-file changes.

## Optional models

Models are deliberately separate from the repository.

- Use the in-app catalog for normal language, vision, and voice model
  downloads.
- `scripts/download_voice_models.sh` can stage supported voice models for
  development.
- `scripts/export_fastvlm_coreml.sh` documents an experimental FastVLM export
  path.

Read the upstream license before downloading or redistributing any model.
Apple FastVLM model weights are research-only and must not be presented as MIT
licensed or as part of this open-source distribution.

## Regenerating dependencies

After changing `project.yml` or `Podfile`:

```bash
xcodegen generate
pod install
```

Commit `project.yml`, `Podfile`, `Podfile.lock`, the generated shared Xcode
project, and shared package resolution files. Do not commit `Pods`,
`xcuserdata`, model weights, archives, signing material, or generated
frameworks.

## Tests

Run the standalone voice-orb package tests:

```bash
swift test --package-path Packages/VoiceAgentOrb
```

Run app unit tests from Xcode or with a Simulator destination:

```bash
xcodebuild test \
  -workspace IOSLocalLLM.xcworkspace \
  -scheme IOSLocalLLM \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The exact Simulator name depends on the runtimes installed on your Mac.

For the complete app test and Simulator Release compile gate, run
`./scripts/validate_app_release.sh` after completing dependency setup. It selects
an installed iPhone Simulator automatically; set `AUDIT_SIMULATOR_ID` to choose
one explicitly. Select a full Xcode installation with `DEVELOPER_DIR` if your
default toolchain is Command Line Tools.

Thermal, Jetsam, Metal-residency, and battery claims require physical-device
validation; see [Docs/VALIDATION.md](Docs/VALIDATION.md).
