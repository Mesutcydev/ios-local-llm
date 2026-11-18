# coreai-models (OnDeviceLAS pin)

Vendored from https://github.com/apple/coreai-models.git
at revision `938d0b8943b942ce66438b94ab017c5631d1aef4`.

## Local patch

`swift/Sources/CoreAILanguageModels/LanguageModel/CoreAILanguageModel.swift`
no longer calls
`LanguageModelExecutorGenerationChannel.Response.Action.updateUsage`.

**Why:** On iPhone OS 27.0 (24A5390f) the system `FoundationModels`
framework does not export that symbol, while Xcode 27's SDK still
declares it. Linking the upstream call aborts at process load
(`dyld` / "Symbol not found") before the Core AI: LAS UI appears.

Remove this pin and return to the remote package once the device OS
and Xcode SDK export matching FoundationModels executor APIs.

## Python tooling removed

The upstream root `pyproject.toml` is not vendored. It only configured the
`python/` uv workspace member and its pytest, ruff and mypy dev pins, and
`python/` is not part of this pin (the app uses the Swift package only). The
file could not be installed from, but GitHub still flagged its `pytest==8.4.0`
pin (Dependabot alert: vulnerable tmpdir handling, fixed in 9.0.3).
