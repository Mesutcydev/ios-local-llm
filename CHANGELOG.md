# Changelog

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and intends to use semantic version tags for source releases.

## [3.5.6] - Build 162

- Assistant restores its runtime-status row while editing an empty conversation,
  keeping model setup reachable after the empty-state controls disappear.
- Voice layout clamps its minimum height during initial and transient small
  layouts, avoiding a negative frame size.

- Model downloads keep the selected revision for file listings, size checks,
  retries and transfers. An unavailable pinned revision now reports an error
  instead of silently downloading a different revision.
- Curated GGUF assistants load their specified model and audio projector files,
  even when older quantizations share the folder. Imported models retain their
  existing file selection behavior.
- Downloads check that every required file is published before transferring
  weights, preventing incomplete packages from being reported as ready.

## [3.5.5] - Build 161

- llama.cpp updated to b12662. On iPhone, Metal work is split into shorter
  command buffers, so long ternary Bonsai GGUF graphs no longer hit the GPU
  timeout. The build also runs Ternary Bonsai 2 / 2.5 `Q2_0` files (Hadamard
  activations, b11556+). Rebuild `llama.xcframework` after pulling.
- Ternary Bonsai 2.5 27B added for Mac (2-bit `Q2_0` GGUF, 7.7 GB, text
  only). It is too large for the iPhone app memory limit. On Mac, large GGUFs
  now run every layer on the GPU; iPhones keep the 12-layer cap above 3 GiB.
- The Mac (Catalyst) build links again. ONNX Runtime has no Mac Catalyst
  build, so KittenTTS, Paradee and Supertonic voices are unavailable on Mac
  (the Podfile leaves it out of the Mac link). Pods share the app's iOS 18
  floor, the camera's multitasking call is iPad/iPhone only, and the
  Catalyst llama slice links `libvendor-hash.a` (llama.cpp b12662+).
- Mac follows Mac conventions: Return sends a chat message (Shift or Option
  + Return adds a line). Home, Models, HF search, the voice picker, the image
  model note, the unsupported-device cards and the Core AI import error say
  "Mac" instead of "iPhone". The ONNX voices are marked iPhone/iPad-only and
  stop offering a download that could not run; the voice picker and Voice
  settings no longer list them as selectable engines.

## [3.5.4] - Build 160

- Settings shows a card for Token: Local AI & Code Studio under the category
  list; tapping it opens the App Store listing. The subtitle is in all 15
  languages. App Store Connect closed 3.5.3, so this build uses 3.5.4.

## [3.5.3] - Build 159

- Models tab rebuilt. My Models shows storage used and free, which model
  Assistant, Lens and Voice use, and one grouped list of installed models
  (Core AI packs included). Search and filters appear from six models up.
- Discover shows the top three per category with See all, and every row has a
  one-tap Get button with progress in place; image rows keep the parental PIN
  gate. Edge mode and Guided setup moved into the ••• menu.
- Model pages follow the App Store layout: name and size, one main action,
  an info list (size, memory fit, devices, runtime, repository) and an actions
  list. The app-wide "Smart handling" card is gone (it lives in Settings).
- Recommended setups are a grouped list that warns about low storage or
  memory; KittenTTS Mini resolves to the real model; Kokoro's size reads
  ~330 MB, its real download.
- Downloads uses a standard title bar; sizes use one number format.
- Settings is one grouped list with sentence-case labels and native switches;
  Lens notices stay dark over the camera; Home and Voice use one tile size.
- New interface text in all 15 languages, and "Get" uses App Store wording.

### Build 158

- Buttons use Apple's Liquid Glass styles (`glassButton`): prominent glass for
  a screen's main action, glass for secondary ones, system capsule shapes.
- One layout scale: spacing is 16 pt × φⁿ, text uses Apple's text styles and
  follows Text Size, radii and tile sizes come from four values each. Screens
  share a 16 pt edge and a 10 pt gap between cards.
  `scripts/audit_ui_metrics.py` keeps new code on the scale.
- The "Running tool" and "Image generated" toasts are gone (the chat already
  shows both), and toasts no longer overlap the conversation or Lens controls.
- A finished reply switches to its formatted version without a cross-fade.
- During image generation the assistant no longer offers Load, and the
  progress card drops its stale status line.
- The Analyze button sits on the generated image; Lens hides its scan frame
  behind the camera-unavailable and paused panels.
- Model lists: Get buttons keep their width, and "Suggested · best fit first"
  is a description line rather than a second header.
- Build 157 (a SenseNova model test) was reverted; 3.5.3 otherwise matches
  3.5.2.

## [3.5.2] - Build 155

- "Clean up partial downloads" no longer deletes a paused download or its
  resume data.
- A chat turn is saved when it is sent and again when the app goes to the
  background, so a reply cut short by the system keeps the prompt.
- A chat history file that cannot be read (for example while the device is
  locked) is left in place and loaded again later instead of being set aside
  as corrupt.
- Onboarding asks before a model download starts on cellular data, and a
  model marked "won't fit" can no longer be chosen there.
- Image generation stops before decoding when it is cancelled or the app goes
  to the background. A model disabled after repeated failed runs can be
  re-enabled with Try Again.
- Reset App Data also deletes the iCloud copies of conversations when sync is
  on, or marks them for deletion at the next sync when iCloud is unreachable.
- Local API: a streamed reply cut off by the response deadline reports a
  truncated finish reason instead of a normal stop.
- Lens shows why a caption was paused instead of "Analysis complete", and
  ignores the late result of a cancelled caption. Photos picked from the
  library are decoded downsized, off the main thread.
- Importing a model folder keeps its full name and removes a half-copied
  folder when the import fails.
- Resuming a partly downloaded file is no longer refused for disk space it
  does not need.
- Switching or clearing a chat stops the reply in progress, and stopped
  replies stay marked after the chat is reopened.
- Voice answers appear in the transcript as they are spoken: the text reveals
  one sentence at a time, the box keeps the current sentence in view, and the
  highlight fills word by word. Replies no longer repeat sentences in the
  transcript, and replaying a reply shows it once.
- A voice reply's highlight no longer freezes when refined timing arrives
  during playback, and it clears when the reply finishes.
- Downloads can be paused and resumed. Pause keeps every downloaded file;
  cancelling a download now asks first, because it deletes them.
- A download that was running when the app was terminated continues on the
  next launch, and attaches to a transfer the system is still running instead
  of starting the same file twice.
- Downloading a GGUF repository from search fetches one quantization (4-bit
  preferred) and its projector instead of every variant, and the size shown
  before downloading counts only those files. Loading a folder that holds
  several quantizations picks the same file every time.
- GGUF chat models are accepted in search results; search results in Models
  use the compatibility verdict and pre-download sheet.
- SmolVLM2 downloads only its Q8 model and projector (about 520 MB, as
  listed) rather than all four files in the repository.
- Curated MLX and vision catalog entries are pinned to reviewed revisions,
  falling back to the default branch if a pinned commit disappears upstream.
- Choosing an assistant model that is not installed starts a normal Models
  download instead of fetching it invisibly while it loads.
- Importing a model from Files moves the picked copy into place instead of
  copying it a second time.
- A build without bundled vision weights no longer creates an empty model
  folder; Lens shows the selected model's name and says when it is not
  installed.
- Remove the separate Download Center screen (Settings now opens Models),
  the download Live Activity that had no widget to display it, the FastVLM
  repository setting, and the "Clone your voice" placeholder.
- Voice shows a loading indicator instead of "No voices match" while voices
  load. Settings labels and Home shortcuts use consistent capitalization.
- Turning an iPhone to landscape while typing in Assistant keeps the message
  field above the keyboard; the model status row steps aside there so the
  whole composer fits.
- Voice conversations recover from stalled playback, audio-route changes,
  phone calls and backgrounding, and no longer start a model download.
- Model memory admission trusts the kernel's per-app limit, records measured
  load peaks, and sizes context from free memory; replies can run to 8K
  tokens with one automatic continuation.

## [3.5.1] - Build 148

- Keep Private Cloud Compute opt-in: standard builds use the local-only
  entitlements; `FM_PCC` and the PCC entitlement file are enabled explicitly
  after the managed capability is verified.
- Remove restricted research model artifacts from the app bundle and require
  the local image-safety classifier for Release builds.
- Rewrite camera, photo, microphone and local-network usage descriptions to
  match Lens, voice conversations, the Mac Bridge and the Local API Server;
  advertise the `_localllm._tcp` Bonjour service.
- Allow landscape orientations (`UIRequiresFullScreen` is now off) and keep the
  legacy `codelens` URL scheme so existing links still open the app.
- Bound the Local API: cap concurrent connections and the size of requests
  that have not presented a valid key.
- Catalogue the Live mode, voice-catalog and speech labels in all 15 languages
  and stop the localization audit from flagging SF Symbol names.
- Fix the first-run legal documents: wrapped lines now join into paragraphs,
  `**bold**`/`_italic_` render instead of showing markers, web links are
  tappable, and the "read to the end" gate no longer unlocks while the document
  is still at the top. Consent sheets get an explicit Close button instead of a
  checkmark; copy now says "OnDevice LLM", "license" and "By continuing".
- Fix assistant answers running together: headings, paragraphs, bulleted and
  numbered lists, quotes and tables are now laid out as separate blocks instead
  of being flattened into one line by `Text`.
- Web-search answers: the model is asked for a heading, a short direct answer
  and bulleted sections with [n] citations; when it cites nothing, the sources
  card lists every fetched source and a trailing "Sources:" line is dropped; the
  Web Search card subtitle reads "N sources · names" instead of the internal
  context marker.
- Onboarding: skip is shown on both information pages with a 44 pt target, the
  model picker has a "Not now" button, "Recommended" follows the pre-selected
  device-tier model, and decorative elements are hidden from VoiceOver.
- Accessibility: directional chevrons mirror in right-to-left languages,
  fixed-size text in Code mode, Diagnostics, activity cards and voice views now
  scales with Dynamic Type, "AI" keeps its capitals, small captions start at
  10 pt, and the light-theme green/amber and OLED accent reach 4.5:1 contrast.
- Update MLX dependencies: mlx-swift-lm 3.32.3 with the matching PrismML
  mlx-swift fork revision (upstream 0.32.3 plus the 1-bit kernels),
  swift-transformers 1.3.5 and swift-jinja 2.5.2. FastVLM adopts the new
  `LanguageModel.prepare(_:cache:state:prefill:)` requirement.

## [3.4] - App Store candidate

- Add LFM3 1.7B text, LFM3 VL 2B, LFM3 Audio 2B, and LFM3 Omni 2B GGUF
  presets with pinned revisions, file allowlists, and verified projectors.
- Run LFM3 Audio/Omni voice turns natively: bounded 16 kHz microphone input,
  text or interleaved 24 kHz speech output, and the existing residency,
  thermal, cancellation, and approval policies.
- Decode native LFM3 `<tool_call>` functions in chat, Voice, and the local API
  routes, rejecting incomplete, unknown, duplicate, mistyped, or reasoning-only
  calls before execution.
- Add the QAD LFM3 VL checkpoint, its matching Q8 projector, the publisher's
  low-temperature vision prompt, and a single-residency 4K Lens profile.
  Assistant image turns now fall back across installed VLMs when the selected
  visual model cannot load. Reloading after image grounding preserves the
  conversation model instead of restoring the saved default.
- Discover complete GGUF vision pairs directly under HFModels/GGUFModels, so imported LFM3 VL works even when its catalog category is wrong.
- Recognize imported GGUF VLM pairs in `HFModels/local_<name>`; imported LFM3 VL no longer appears missing or asks for a re-download.
- Prefer LFM3 VL/Omni over SmolVLM for Assistant image grounding, preserve the
  conversation model across vision handoffs, and offer an in-place LFM3 VL
  download when no vision model is installed.
- Accept the optional prompt on native `describe_image` calls, load the selected
  vision model on demand, and fall back to another installed VLM when Lens is
  still using Apple Vision OCR.
- Keep image-generation install guidance visible before the parental lock so a
  locked, uninstalled model still returns an actionable download message.

## [3.3.4] - Release candidate

- Add optional Core AI text inference on supported physical iOS 27 devices,
  with coordinated model residency, memory admission and thermal cancellation.
- Add 15 pinned text packs to the download library, with license links,
  validated installation, cancellation, installed-model selection and storage totals.
- Preserve iOS 18, MLX, GGUF and Simulator support.
- Harden document import limits, knowledge-base cleanup, web fetch limits and
  address validation; improve cancellation during model switching.
- Translate the primary Core AI library controls into the 15 app languages.

## [3.3.3] - TestFlight candidate

### Interface and model library

- Adapt the simplified OnDevice Core AI Studio design with quieter surfaces,
  clearer navigation, and a redesigned Models page.
- Separate downloaded models from discovery, keep import/download/storage
  actions accessible, and move model actions into focused detail sheets.
- Refine the assistant composer with a dedicated message/action row, quieter
  model and attachment controls, and layouts for larger text.

### Localization

- Bundle complete interface catalogs for all 15 supported app languages,
  including native SwiftUI controls, model metadata, and the share extension.
- Apply the selected locale and Arabic layout direction throughout the app
  without replacing the view tree or discarding drafts.
- Add an offline localization audit for missing keys and interpolation tokens.

## [3.3.2] - TestFlight candidate

### Local API

- Replace the Studio Mac shortcut with a Local API Server tile that opens the
  server workspace directly, with an explicit Done action to return Home.
- Add a dedicated API workspace using the app's Studio theme, with explicit
  start, stop, and restart actions and separate listener/model readiness.
- Load installed local models without implicit downloads; offer model cleanup
  and keep cloud targets out of the API model picker.
- Show pinned HTTPS setup recipes for OpenAI, Anthropic, and Ollama clients,
  safely quote shell values, and document the eight supported routes.
- Confirm API key rotation, hide revealed keys on navigation/backgrounding,
  and use the device-only clipboard for credentials and setup commands.
- Validate port changes and persist them before restarting an enabled server.

### iPhone Duo and accessibility

- Keep the native sidebar reveal control available on Home, Models, and Voices.
- Remove redundant zero-state model counters and reflow role controls for
  larger text and narrow windows.
- Reserve a separate composer row above the keyboard so chat content stays
  clear of the editor through folding and resizing.
- Expand custom model and dashboard actions to 44-point minimum touch targets.
- Strengthen secondary and metadata text colors in light and dark appearances.
- Show explicit model setup for missing weights and prepare only installed
  models automatically, with accurate idle and preparing explanations.

### Release preparation

- Bump the app and share extension together to 3.3.2 (123).
- Prepare localized release notes and promotional copy for all six existing
  App Store languages, plus TestFlight testing instructions.

## [3.3.1] - App Store candidate

### Performance

- Convert only the requested page in the history pagination API;
  keep the existing fast path for short transcripts.
- Serialize model-storage scans, coalesce pending requests, and publish only
  the latest totals when they change.
- Avoid publishing unchanged model readiness on tab/foreground refreshes;
  still detect models removed from disk.
- Create the paired Lens services once per navigation shell and observe their
  live updates in the Lens screen.

### Accessibility

- Give the Image Generation options control a 44-point tap target.
- Keep PIN-form regression-test scrolling above the numeric keyboard.

### Release preparation

- Bump app and share-extension versions together to 3.3.1 (120).
- Update citation and source-inventory version metadata together.
- Prepare six premium iPhone and six iPad screenshots for each existing
  App Store language: Arabic, English (U.S.), Greek, Portuguese (Portugal),
  Romanian, and Russian. iPad previews show the app's compatibility mode.
- Localize What's New and promotional text for all six listings.

## [3.3] - Unreleased App Store candidate

### Fixed

- Preserve the existing App Store identity, shared storage, CloudKit container,
  and credential namespaces when upgrading from the existing App Store 3.2.4 release.
- Save Share extension content in an App Group inbox and import it after setup.
- Keep legal actions reachable with large text and expose document read states
  to accessibility; add Turkish safety and download-screen translations.
- Resolve MLX dependencies through the pinned one-bit fork in both workspaces.
- Await Spotlight removal during data reset and report failures.
- Shorten startup animation and respect Reduced Motion and VoiceOver.
- Remove the custom rating pre-prompt and retain memory/thermal checks for
  smaller-margin model loads.
- Check image prompts and generated images locally before preview or sharing;
  preserve the separate parental PIN and add a keyboard dismissal control.
- Clarify optional web/iCloud handling and local content-check limitations.

### Release preparation

- Prepare replacement build 118 for the existing App Store Connect 3.3 draft;
  the submitted build remains unchanged until the replacement is verified.
- Validate app/extension identities, versions, entitlements, privacy manifests,
  dependency notices, and excluded research artifacts in source and bundles.

## Earlier unreleased sideload fixes

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
