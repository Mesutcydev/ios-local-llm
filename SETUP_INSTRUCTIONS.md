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
git clone --recurse-submodules https://github.com/Mesutcydev/ondeviceios.git
cd ondeviceios
```

If the repository was cloned without submodules:

```bash
git submodule update --init --recursive
```

## Build native frameworks

CodeLens links locally generated llama.cpp and whisper.cpp XCFrameworks.
Upstream's build scripts build several Apple-platform slices and can take a
while:

```bash
(cd ThirdParty/llama.cpp && ./build-xcframework.sh)
(cd ThirdParty/whisper.cpp && ./build-xcframework.sh)
```

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
open CodeLens.xcworkspace
```

Open the workspace, not the `.xcodeproj`, so the ONNX Runtime pods are
available.

## Run in Simulator

Select the `CodeLens` scheme and an iOS 18 or newer Simulator. Simulator builds
do not require a paid Apple Developer Program membership.

The source-only build starts without bundled AI weights. Features that depend
on a model become available after the user downloads a compatible model from
the app's model catalog.

## Run on a physical device

Use your own signing identity:

1. Select the CodeLens project in Xcode.
2. For the app, share extension, unit-test, and UI-test targets, select your
   development team.
3. Change `com.codelens.CodeLens` and related identifiers to identifiers owned
   by your team.
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
  -workspace CodeLens.xcworkspace \
  -scheme CodeLens \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The exact Simulator name depends on the runtimes installed on your Mac.
