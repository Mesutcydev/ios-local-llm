# OnDeviceiOS

OnDeviceiOS is the open-source home of CodeLens, a local-first AI workbench for
iPhone and Apple silicon Macs. It
runs language, vision, speech, and image-generation models on the user's
device, with no account or telemetry required.

The app was previously distributed through the App Store. This repository is
now the canonical source distribution. There is currently no official
pre-built binary or App Store release.

## Highlights

- On-device chat and code assistance with MLX models
- Live camera and image analysis
- Local voice activity detection, transcription, and speech synthesis
- Local OpenAI-compatible API server and Mac bridge
- Model discovery and downloads from Hugging Face
- iPhone and Apple-silicon Mac Catalyst targets

## Project status

CodeLens is usable but is a large, evolving application. Some features require
recent Apple hardware, optional model downloads, or native frameworks that
must be built locally. Contributions that improve first-run setup, tests,
accessibility, and documentation are especially welcome.

## Requirements

- macOS with Apple silicon
- Xcode 26 or newer
- iOS 18 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [CocoaPods](https://cocoapods.org/)
- CMake

An Apple Developer Program membership is not required for Simulator builds.
Running on a physical device uses your own signing identity and bundle
identifier.

## Build

Clone the repository and its native dependencies:

```bash
git clone --recurse-submodules https://github.com/Mesutcydev/ondeviceios.git
cd ondeviceios
```

Install project tools if needed:

```bash
brew install xcodegen cocoapods cmake
```

Build the native inference frameworks:

```bash
(cd ThirdParty/llama.cpp && ./build-xcframework.sh)
(cd ThirdParty/whisper.cpp && ./build-xcframework.sh)
```

Generate the Xcode project and install CocoaPods:

```bash
xcodegen generate
pod install
open CodeLens.xcworkspace
```

Select the `CodeLens` scheme and an iOS Simulator. For a physical device,
change the bundle identifiers and select your own development team in Xcode.
See [SETUP_INSTRUCTIONS.md](SETUP_INSTRUCTIONS.md) for details and optional
model setup.

## Models and large files

No AI model weights, compiled Core ML models, generated XCFrameworks, or app
installers are distributed in this repository. They are intentionally ignored
because they are large and often have terms different from the CodeLens
license.

CodeLens downloads supported models only after a user chooses them. Always
review a model's license before downloading or redistributing it. In
particular, Apple FastVLM weights use a research-only license and are not part
of this open-source distribution.

## Privacy

Inference and user data are local by default. Network access is used for
explicit actions such as searching for or downloading models, optional web
search, and communication with a paired local bridge. Review
[PRIVACY_POLICY.md](PRIVACY_POLICY.md) and the app's privacy manifest before
shipping a modified build.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a change. Please use
GitHub Issues for reproducible bugs and focused feature proposals. Security
reports should follow [SECURITY.md](SECURITY.md).

## License

Original CodeLens code and documentation are available under the
[MIT License](LICENSE). Third-party code, data, models, and dependencies remain
under their respective terms; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The CodeLens name and logos
are not licensed as trademarks; see [TRADEMARKS.md](TRADEMARKS.md).
