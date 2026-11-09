# Changelog

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and intends to use semantic version tags for source releases.

## [Unreleased]

### Security

- Stopping the local API server now closes every open client connection, not
  only the listener.
- The local API caps concurrent connections and pre-authentication header
  size, rejects unparsable `Content-Length` values, and closes the connection
  after rejecting a chunked upload.
- Model output and user prompts are no longer written to runtime logs on
  tool-parse failures or Lens requests.
- Copied API keys stay on the device and expire from the pasteboard.
- Web page fetches enforce the size cap while streaming, and the URL safety
  check covers all of `fe80::/10`.

### Fixed

- An unreadable conversation history file is preserved instead of being
  overwritten by the next save.
- The manual thermal reset can no longer override a critical thermal state.
- Backgrounding cancels GGUF vision inference.
- `/mac` and `/m` only trigger Mac context when used as whole commands.
- Bridge token frames are valid JSON for tabs and control characters.
- Web fetches appear in the network activity indicator.

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
