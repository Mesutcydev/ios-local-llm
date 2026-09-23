# Changelog

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and intends to use semantic version tags for source releases.

## [Unreleased]

### Fixed

- The "First Light" splash variant is centred again. Its decorative aurora layers
  are wider than the screen on purpose (1.25 × width); because a `ZStack` sizes
  itself to the union of its children, those layers sized the stack inside the
  splash's `GeometryReader`, and a `GeometryReader` places its content at the
  top-leading corner — so the over-wide stack hung off the right edge and pushed
  the lens, the wordmark and the dwell beam ~55 pt right of centre. The layers
  are now pinned to the screen frame (bleed unchanged, layout centred).
- The system launch screen uses the `LaunchBackground` asset color instead of an
  empty `UIColorName`, so launching transitions into the active silver splash
  without a white flash.

- Sideload build 113 registers imported and manually-copied GGUF models in the
  installed-model registry. A standalone text `.gguf` or a complete GGUF VLM
  pair carries no `config.json` (its tokenizer and metadata are embedded), so
  the registry's hard `config.json` requirement silently rejected it: the model
  showed as ready in the Models tab but the conversation picker (which reads the
  registry as its source of truth) reported "download model first". Imported and
  HF-searched models are now registered immediately, and GGUF bundles are
  validated by magic bytes rather than filename suffix.

## [3.2.7] - 2026-09-05

### Changed

- Sideload build 112 updates llama.cpp to v0.4.0 with compatible sampler calls,
  preserving existing generation and memory policies.
- Silver eye icon and matching splash, consistent chat typography, smoother
  voice feedback, and reduced-motion Lens transitions.
- App and share-extension entitlement dictionaries remain unchanged.

### Fixed

- Sideload build 110 restores the OnDevice LLM display name and preserves the
  share extension's application-group entitlement during ad-hoc packaging.
- Imported GGUF assistants now receive their chat template, sampler
  settings, and system/tool prompts. Recurrent Gemma 3n / Gemma 4 E-series
  keep the compact 512/128 workaround; dense Gemma 4 12B/31B do not.
- MLX seed, frequency penalty, and presence penalty settings are applied.
- Local API chat/responses/messages replies report real token usage.
- Truncated replies are labeled in the chat chrome; the compact GGUF
  128-token cap is visible on the token-cap chip.
- Release-styled app builds no longer embed the unit-test bundle.
- Chat prompts no longer invite invented tool results, citations, or live
  data. Gemma templates fold the system prompt into the first user turn
  once instead of duplicating it.
- Standard GGUF assistants no longer inherit the smaller MLX-family output
  cap; Ornith continuation resumes at the correct KV-cache position.
- Speculative model prefetch now runs only after model load while charging and
  thermally nominal, reducing idle disk work and phone heat.

### Added

- In-chat streaming, approval, running-tool, citation, and image-generation
  cards. Web/file tool consent stays in the transcript.
- True Continue: tap Continue or the cut-off chip to resume the same
  assistant turn. Standard GGUFs reuse the live KV when it is still
  resident; otherwise the open assistant turn is re-prefills. No fake
  "please continue" user message.
- Standard imported GGUFs reuse matching prompt-prefix KV across turns
  instead of clearing the cache every send. Compact Gemma 3n / E-series
  still recreate context.

## [3.2.6] - 2026-07-29

### Added

- OpenSSF Scorecard analysis with public results and code-scanning upload.
- Reproducible source-release archives with SHA-256 checksums and
  GitHub/Sigstore provenance attestations.
- Release verification instructions for contributors and downstream users.

## [3.2.5] - 2026-07-29

### Added

- Open-source governance, provenance, validation, security-model, citation,
  SBOM, and coding-agent documentation.
- Reproducible root-level llama.cpp and whisper.cpp framework build tooling.
- Standalone licensing and notices for VoiceAgentOrb.

### Changed

- Repository identity standardized as `ios-local-llm`.
- Dependency lockfiles synchronized.
- Qwen3 license metadata corrected to Apache-2.0.
- Privacy and network disclosures aligned across repository and in-app text.

### Security

- Added high-confidence Clang warnings and static analyzer checks.
- Expanded responsible disclosure and repository validation guidance.

[Unreleased]: https://github.com/Mesutcydev/ios-local-llm/compare/v3.2.6...HEAD
[3.2.6]: https://github.com/Mesutcydev/ios-local-llm/releases/tag/v3.2.6
[3.2.5]: https://github.com/Mesutcydev/ios-local-llm/releases/tag/v3.2.5
