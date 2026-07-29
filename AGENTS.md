# Agent guide

This file applies to the repository root and everything below it except Git
submodules that provide their own `AGENTS.md`.

## Project identity

- Repository: **OnDeviceiOS**
- App/product names found in source: **CodeLens** and **On Device LLM**
- Purpose: a local-first Swift/SwiftUI AI workbench for iPhone and Apple
  silicon Macs
- Repository: <https://github.com/Mesutcydev/ondeviceios>
- License: MIT for original project code and documentation; third-party code,
  assets, and downloaded models keep their own licenses

Do not describe the repository as containing model weights. The public source
distribution intentionally excludes model weights, generated Core ML models,
XCFrameworks, signed apps, and installers.

## Start here

1. Read `README.md` for product scope.
2. Read `SETUP_INSTRUCTIONS.md` before building.
3. Read `CONTRIBUTING.md` before editing.
4. Read `THIRD_PARTY_NOTICES.md` before adding dependencies, models, or assets.
5. Read `Docs/AGENT_INTEGRATION.md` when changing the local API, tool calling,
   or Mac bridge.

`llms.txt` is the short machine-readable documentation index.
`codemeta.json` is the structured software metadata record.

## Repository map

| Path | Responsibility |
| --- | --- |
| `CodeLens/CodeLensApp.swift` | App entry point and service installation |
| `CodeLens/ContentView.swift` | Root application navigation |
| `CodeLens/Views/` | SwiftUI screens and reusable UI |
| `CodeLens/Services/` | Inference, model, safety, diagnostics, and bridge services |
| `CodeLens/Models/` | App data models, catalogs, settings, and shared types |
| `CodeLens/Services/Bridge/` | Local APIs, pairing, and authenticated agent channel |
| `CodeLens/LocalAIRuntimeFoundation/` | Reusable local-runtime abstractions |
| `CodeLensTests/` | Unit and policy tests |
| `Packages/VoiceAgentOrb/` | Standalone Swift package with its own tests |
| `project.yml` | Source of truth for generated Xcode project settings |
| `ThirdParty/llama.cpp/` | Upstream Git submodule |
| `ThirdParty/whisper.cpp/` | Upstream Git submodule |

## Architecture constraints

- Heavy model runtimes share a coordinated residency policy. Do not introduce
  an independent model loader that bypasses `ModelResidency`,
  `MemoryAdvisor`, or `DeviceSafetyMonitor`.
- Thermal and memory refusals are product behavior, not incidental errors.
  Preserve cancellation, unload, cooldown, and background-cleanup paths.
- Network access must remain explicit and visible to the user. Local inference
  must not silently fall back to a remote service.
- The local API is opt-in, bearer-authenticated, and intended for trusted LANs.
  It stops when the app backgrounds.
- Mac agent tools are pairing-authenticated. Keep risk levels, approval
  requirements, and protocol-version checks intact.
- Never log API keys, Hugging Face tokens, pairing credentials, prompts, model
  output, captured media, or user documents.

## Build and test

The project requires macOS and Xcode. Clone with submodules and follow
`SETUP_INSTRUCTIONS.md` for native framework generation.

Fast repository validation:

```bash
./scripts/validate_open_source.sh
swift test --package-path Packages/VoiceAgentOrb
```

App tests, after native dependencies and CocoaPods are available:

```bash
xcodebuild test \
  -workspace CodeLens.xcworkspace \
  -scheme CodeLens \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Use an installed Simulator name when the example destination is unavailable.
For focused changes, run the smallest relevant test selection first, then the
repository validator.

## Editing rules

- Prefer focused changes that follow nearby Swift and SwiftUI conventions.
- Add or update tests for behavior changes, especially memory admission,
  runtime residency, downloads, recovery, and protocol decoding.
- Make permanent project configuration changes in `project.yml`, then
  regenerate with XcodeGen. Avoid hand-editing generated project settings.
- Do not commit `Pods`, `DerivedData`, model files, generated XCFrameworks,
  signing files, credentials, or local agent memory files.
- Treat `ThirdParty/llama.cpp` and `ThirdParty/whisper.cpp` as independent
  upstream repositories. Do not absorb incidental submodule changes into an
  OnDeviceiOS commit.
- Preserve accessibility labels and identifiers. Validate visible UI changes
  with an iOS Simulator when available.

## Licensing rules

Before adding any dependency, model, dataset, voice, image, or generated
artifact:

1. Identify its exact source and version.
2. Confirm redistribution is allowed.
3. Preserve required notices and source offers.
4. Update `THIRD_PARTY_NOTICES.md` and `LICENSES/` when applicable.
5. Keep restricted model weights outside Git even when the app can download
   them at runtime.

If the license is unclear, do not add the material.

## Agent-facing surfaces

OnDeviceiOS is both agent-friendly source code and an agent-compatible local
runtime:

- OpenAI-style `GET /v1/models` and `POST /v1/chat/completions`
- OpenAI Responses compatibility at `POST /v1/responses`
- Anthropic Messages compatibility at `POST /v1/messages`
- Ollama-compatible model, chat, and generation routes under `/api`
- OpenAI/Anthropic-style tool-call decoding for supported text-chat routes
- Authenticated iPhone-to-Mac tool calls under `/v1/agent/*`

Compatibility is intentionally scoped rather than a promise of complete API
parity. Use `Docs/AGENT_INTEGRATION.md` and the implementation in
`CodeLens/Services/Bridge/LocalAPIServer.swift` as the source of truth.
