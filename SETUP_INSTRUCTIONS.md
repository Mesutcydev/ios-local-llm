# Development setup

This guide builds the source-only distribution. Model weights, compiled native
frameworks, CocoaPods, and signing profiles are not stored in Git.

## Prerequisites

- Apple-silicon Mac
- Xcode 27.1 or newer (required for native iPhone Duo layout and vertical bars)
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
The pinned llama.cpp revision includes LFM3 text, vision, Audio, and Omni support and accepts
iOS slices directly; no source patch is required. Rebuild llama.xcframework
after updating the submodule; an older generated binary cannot load LFM3.

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

Both workspaces include SwiftPM mirrors that route transitive upstream
`mlx-swift` references to the pinned PrismML fork used for one-bit model kernels.
Keep these mappings and `Package.resolved` together when upgrading MLX packages;
see [Docs/XCODE_SECURITY_SETTINGS.md](Docs/XCODE_SECURITY_SETTINGS.md).

## Run in Simulator

When several Xcode versions are installed, select Xcode 27.1 or newer in
Xcode Settings → Locations, or prefix build commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` when that is the
27.1 installation. An iOS 27.1 SDK build enables iPhone Duo's full display and
vertical system bars; changing the deployment target alone does not. See
[Duo validation](Docs/IPHONE_DUO.md) for the resizing and fold checks.

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

Before a Release build, prepare the small local image safety classifier using
[the pinned conversion instructions](Docs/IMAGE_CONTENT_SAFETY.md). Debug builds
without it refuse image generation; other features remain available. Release
builds fail when the classifier is missing, so an unchecked image generator
cannot be distributed accidentally.

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

## LFM3 voice and tool support

Download LFM3 Audio 2B or LFM3 Omni 2B from Models, then select it in
Assistant or the Voice conversation model menu. Voice mode sends bounded
16 kHz microphone audio to that model and plays its native 24 kHz speech
when voice answers are enabled. Omni also accepts images in Assistant/Lens.
These checkpoints do not use thinking mode. The app keeps its existing
microphone permissions, local live transcript, thermal and residency policy.
Video and realtime WebSocket audio are outside this integration.

LFM3 native XML function calls are supported in chat, Voice, and the existing
OpenAI/Anthropic/Ollama tool routes. The same tool allowlists and approval
requirements apply. No tools execute merely because they appear in reasoning.

An optional unit integration test accepts a separately reviewed GGUF model
and projector pair through `LFM3_NATIVE_SMOKE_DIR` (`model.gguf`,
`mmproj.gguf`). Source-only test runs skip it and never download weights.
