# Optional Core AI text runtime

This is the text-only subset of Apple's BSD-3-Clause `coreai-models`, pinned to
`938d0b8943b942ce66438b94ab017c5631d1aef4`. The source came from the audited
OnDeviceCoreAIStudio reference checkout. Its upstream/backport changes are
recorded in `COREAI_PIN_PATCH.md`; the full license is in `LICENSE`.

Changes in this repository:

- Package deployment remains iOS 18/macOS 15. Runtime declarations are available
  only on iOS 27, and compiled only for physical iOS devices with Core AI SDKs.
  Simulator, Catalyst, and older SDK builds expose empty modules.
- Only language models, shared runtime helpers, and the C grammar bridge are
  included. There are no model weights, compiled models, or CLI executables.
- Both tokenizer resolution paths are offline. A missing embedded tokenizer is
  an error, never an implicit Hub download.
- CLI logging is disabled; token text is removed from signposts. The unused
  logits/context export utility is excluded.
- XGrammar is pinned to `4d145cc13d878c751ebeed36af1c013074be76bc`; the bridge
  explicitly uses C++17. Its Apache-2.0 and DLPack notices are shipped with the app.

App loading must go through CodingAssistantService's memory, thermal, and
single-runtime handoff policy. Runtime generation is serialized and drained
before unload. The download library offers 15 pinned, Apache-2.0 text packs whose metadata
and embedded tokenizer configuration were checked on 26 October 2026. This
checks artifact completeness and licensing, not inference quality on every
device. Packs needing unintegrated custom kernels or unclear terms are omitted.

The current iOS single-token pipeline retains the reference's 1,024-token safety
boundary. The app caps output at 512 tokens and reserves template/context space.
Real inference performance and hardware compatibility require testing on a
supported physical device with a complete downloaded pack.
