# OnDeviceiOS repository instructions

Read `/AGENTS.md` before editing. Use `/llms.txt` as the documentation index.

- This is a Swift/SwiftUI iOS and Mac Catalyst application for local AI.
- `project.yml` is the source of truth for generated Xcode configuration.
- Keep model loading behind `MemoryAdvisor`, `ModelResidency`, and
  `DeviceSafetyMonitor`.
- Preserve explicit network consent, bearer authentication, pairing checks,
  tool risk levels, and user-approval boundaries.
- Never add model weights, generated XCFrameworks, signing material, secrets,
  or local agent memory to Git.
- Treat `ThirdParty/llama.cpp` and `ThirdParty/whisper.cpp` as independent Git
  submodules.
- Add focused tests for model admission, residency, downloads, recovery,
  protocol decoding, or other behavior changes.
- Run `./scripts/validate_open_source.sh` before proposing a commit.
- Follow `/THIRD_PARTY_NOTICES.md` and update notices before adding external
  code, models, data, voices, or assets.

Runtime API and tool-calling behavior is documented in
`/Docs/AGENT_INTEGRATION.md`.

When adapting a component for another app, follow
`/Docs/CODING_AGENT_IMPLEMENTATION.md` and use
`/Docs/REUSABLE_COMPONENTS.md` to identify its reuse level, source, tests, and
dependencies.
