# CodeLens / OnDevice LLM (App id 6770114399) — App Store Connect Builds Changelog

_Generated 2026-11-19 from live `asc builds list` + `asc builds test-notes list` (en-US "What to Test" notes)._

- **191 build uploads on record**, unique build numbers 1–159. ASC retains ~90 days of full detail: September builds **99–115 have aged out** (gap below). All recorded builds are **VALID**.
- Skipped build numbers (never existed): 41, 62, 130.
- Upload dates are the latest upload of each build number (re-uploads superseded earlier ones). Interim builds without an en-US note were uploads that were never beta-distributed with test notes.


## 2026-06

### Build 1 — uploaded 2026-06-19

_No en-US test note on record._

### Build 2 — uploaded 2026-06-19

This build fixes on-device model loading and the Models download flow. Everything still runs fully on-device — no account, nothing leaves your iPhone.

FIXED

• On-device models load again under memory pressure. A system-wide low-memory warning from other apps no longer unloads your chat or vision model mid-use — the "iOS reported a memory-pressure spike / Load failed" loop is gone.
• Tapping Download in Models now starts the download for every catalog model (Qwen3-VL and others). The button no longer appears to do nothing.
• Vision models that ship as GGUF (e.g. SmolVLM) resolve their weights reliably, including when files sit in a subfolder.

NEW

• A downloads pill in the Models header shows how many downloads are active — tap it to open a Downloads page with live progress and cancel/retry.
• Haptic feedback the moment a download starts.

What to test: download Qwen3-VL 4B from Models, run the assistant (including a web search, then Continue), and switch between chat and vision models while other apps are open in the background.

### Build 3 — uploaded 2026-06-23

This build fixes on-device model loading and the Models download flow. Everything still runs fully on-device — no account, nothing leaves your iPhone.

FIXED

• On-device models load again under memory pressure. A system-wide low-memory warning from other apps no longer unloads your chat or vision model mid-use — the "iOS reported a memory-pressure spike / Load failed" loop is gone.
• Tapping Download in Models now starts the download for every catalog model (Qwen3-VL and others). The button no longer appears to do nothing.
• Vision models that ship as GGUF (e.g. SmolVLM) resolve their weights reliably, including when files sit in a subfolder.
• Fixed a Lens crash: if the camera vision model can't load, the app now keeps running instead of closing.
• After a low-memory event, models reload as soon as memory frees up instead of being blocked for ~20 seconds.
• Chained tool calls (e.g. a follow-up web search) are no longer occasionally dropped.

NEW …

### Build 4 — uploaded 2026-06-23

This build adds a fresh look and fixes model loading. Everything still runs fully on-device — no account, nothing leaves your iPhone.

NEW

• New default theme — clean, native iOS look with a System Blue accent. Your previous accent color is kept; all colors (Rose, Blue, Violet, Emerald, Amber, Graphite, Teal, Indigo, Coral, Magenta) are still in Settings → Appearance.
• OLED dark mode — a true-black, high-contrast dark theme (easy on the eyes and on battery). Pick it under Settings → Appearance (Light · Dark · OLED).
• The Lens setup card is now readable and shows live download progress while the vision model installs, so it never looks stuck.

FIXED …

### Build 5 — uploaded 2026-06-23

This build polishes the chat experience, themes the Models page, and improves voice. Everything still runs fully on-device — no account, nothing leaves your iPhone.

NEW

• Chat history is now one tap away — a History button sits right in the chat toolbar (it used to be buried in a menu). The "more" menu is also tidied up, with power-user tools grouped under "Advanced".
• The Models page now follows your selected accent color, so the whole app matches your theme.

FIXED

• KittenTTS voices: fixed audio that could come out as a synthetic buzz instead of speech (the model's audio output is now read at its true precision).

ALSO IN RECENT BUILDS

• New default "System" theme (clean native iOS blue) plus an OLED true-black dark mode — Settings → Appearance.
• Qwen3-4B "tokenizer.json missing" self-repairs; assistant shows a one-tap "Repair & retry".
• On-device models load reliably under memory pressure; downloads start reliably with live progress. …

### Build 6 — uploaded 2026-06-23

This build adds on-device error analysis and polishes chat, theming, and voice. Everything still runs fully on-device — no account, nothing leaves your iPhone.

NEW

• On-device error analysis — the app can now use your selected local model to diagnose itself. In Settings → Diagnostics, tap "Analyze with on-device AI" for a plain-English read on crashes, memory, and recent errors with concrete fixes. You can also run it from chat: ⋯ menu → "Diagnose app errors", then ask follow-up questions. Runs entirely on-device.
• Chat history is one tap away — a History button in the chat toolbar (it used to be buried in a menu). The ⋯ menu is tidied, with power-user tools under "Advanced".
• The Models page now follows your selected accent color.

FIXED

• KittenTTS voices: fixed audio that could come out as a synthetic buzz instead of speech.

ALSO IN RECENT BUILDS

• New default "System" theme (native iOS blue) plus an OLED true-black dark mode — Settings → Appearance.
• Qwen3-4B "tokenizer.json missing" self-repairs; assistant shows a one-tap "Repair & retry". …

### Build 7 — uploaded 2026-06-24

A refreshed, more professional look — plus on-device error analysis. Everything still runs fully on-device; nothing leaves your iPhone.

NEW

• New default theme "Onyx" — a clean, near-black professional look (ChatGPT-style: restrained, neutral, color reserved for status). Prefer color? System (blue), Rose, Teal, and the rest are still in Settings → Appearance, alongside OLED dark mode.
• Calmer, more refined UI — neutral section labels, flat near-black buttons, and a neutral chat hero, so the app reads more like a pro tool.
• On-device error analysis — Settings → Diagnostics → "Analyze with on-device AI", or chat ⋯ → "Diagnose app errors", for a local diagnosis of crashes/memory/errors with fixes.

FIXED

• Conversation titles no longer show raw "think>…" from thinking models — titles are clean, and existing ones are tidied automatically.

What to test: open the app and check the new Onyx look (Settings → Appearance to try other accents + OLED); start a chat and confirm the title reads cleanly; tap the History (clock) button in chat.

### Build 8 — uploaded 2026-06-24

Cleaner, more native Settings — on top of the new professional look. Everything still runs fully on-device; nothing leaves your iPhone.

NEW

• Settings menus redesigned to look simpler and more native — the system font throughout (no more monospaced "techy" labels) and consistent, Settings-app-style rows across Appearance, Voice, and Models & AI.
• "Onyx" professional theme is the default — a clean, near-black ChatGPT-style look. Other accents (System blue, Rose, Teal, …) and OLED dark mode are in Settings → Appearance.

FIXED

• Conversation titles no longer show raw "think>…" from thinking models (existing ones are tidied automatically).

ALSO RECENT

• On-device error analysis (Settings → Diagnostics, or chat ⋯ → "Diagnose app errors").
• Chat history is one tap away (clock button in the chat toolbar).

What to test: open Settings → Appearance / Voice / Models & AI and confirm the rows read cleanly in the system font; check the Onyx look and try other accents + OLED.

### Build 9 — uploaded 2026-06-30

_No en-US test note on record._


## 2026-07

### Build 10 — uploaded 2026-07-09

_No en-US test note on record._

### Build 11 — uploaded 2026-07-09

_No en-US test note on record._

### Build 12 — uploaded 2026-07-09

More stable, private, and dependable on-device AI.

NEW
• SmolVLM2 GGUF frame processing is fixed for on-device Lens captures.
• Safer Wipe All Data — clears saved API keys, Hugging Face token, and Mac Bridge pairings from Keychain.
• Stronger Mac Bridge pairing protection and safer web page fetching.
• Conversation saves now report failures instead of failing silently.
• iCloud sync entitlement and clearer sync error reporting.

VOICE
• KittenTTS speaks with less lag between sentences.
• Apple System Voice prefers Enhanced/Premium voices and avoids the Bluetooth “zombie” route after voice chat.
• Kokoro float16 audio decoding fixed (download Kokoro from Models → Catalog to enable).

LENS
• Fixed a camera vision-encoder crash (SIGSEGV) on newer iPhones by keeping Core ML off the GPU path.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 13 — uploaded 2026-07-09

More stable, private, and dependable on-device AI.

NEW
• Safer Wipe All Data — clears saved API keys, Hugging Face token, and Mac Bridge pairings from Keychain.
• Stronger Mac Bridge pairing protection and safer web page fetching.
• Conversation saves now report failures instead of failing silently.
• iCloud sync entitlement and clearer sync error reporting.

VOICE
• Apple System Voice prefers Enhanced/Premium voices and drops the Bluetooth 8 kHz “zombie” route while speaking.
• KittenTTS speaks with less lag between sentences.
• Kokoro recovers from a prior ANE crash after cooldown / app update (download from Models → Catalog).

LENS
• Ask retries a stuck vision model instead of looping “could not process this frame”.
• Clearer heat / memory errors when Qwen3-VL can’t run a frame.
• Fixed a camera vision-encoder crash (SIGSEGV) on newer iPhones.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 14 — uploaded 2026-07-09

_No en-US test note on record._

### Build 15 — uploaded 2026-07-09

More stable, private, and dependable on-device AI.

VOICE
• Apple System Voice now switches to true .playback (mic off) while speaking — fixes the remaining “zombie” synthetic sound in voice chat.
• Test audio uses the same clean playback path; Bluetooth prefers A2DP.

LENS
• Ask retries a stuck vision model instead of looping “could not process this frame”.
• Gemma 3 now runs through a memory-bounded llama.cpp/mtmd Q4 route instead of the crash-prone high-peak MLX path.
• Visual models route by an explicit runtime contract, with per-family memory, context, cache, and token policies.
• Diagnostics now capture VLM allocator peak and process footprint to make device-specific failures actionable.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 16 — uploaded 2026-07-09

More stable, private, and dependable on-device AI.

VOICE
• Apple System Voice now switches to true .playback (mic off) while speaking — fixes the remaining “zombie” synthetic sound in voice chat.
• Test audio uses the same clean playback path; Bluetooth prefers A2DP.

LENS
• Fixes the unclean-exit crash caused by switching Gemma/Qwen while a Lens inference was still finishing.
• Model loads, inference, cancellation, and GPU cache cleanup are now serialized across Lens, Assistant, FastVLM, and Image Generation.
• Existing Gemma MLX selections automatically migrate to the supported memory-bounded llama.cpp/mtmd Q4 route.
• GGUF and MLX visual-model fallbacks stay on their correct runtimes instead of stacking incompatible loaders in memory.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 17 — uploaded 2026-07-10

More stable, private, and dependable on-device AI.

VOICE
• Apple System Voice now renders to PCM and plays through CodeLens’s controlled audio engine, bypassing the stale Apple/HFP output route behind the persistent “zombie” sound.
• Test audio and voice-chat replies now use the same high-quality playback path.

LENS
• Assistant, Lens, and Voice keep only one large native model resident at a time; changing tabs, modes, or models drains the previous runtime before loading the next.
• Fixes the unclean-exit crash caused by switching Gemma/Qwen while Lens inference was still finishing.
• Model loads, inference, cancellation, and GPU cache cleanup are serialized across MLX, llama.cpp, FastVLM, and Image Generation.
• Existing Gemma MLX selections automatically migrate to the supported memory-bounded llama.cpp/mtmd Q4 route.
• GGUF and MLX visual-model fallbacks stay on their correct runtimes instead of stacking incompatible loaders in memory.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 18 — uploaded 2026-07-10

More stable, private, and dependable on-device AI.

MEMORY
• Fixed the RAM check that under-reported available memory on high-RAM iPhones (12 GB Pro Max), so larger models that comfortably fit now load instead of being wrongly refused.
• "Not enough memory" messages now reflect the real live headroom the app can use.

VOICE
• Fixed the robotic/synthetic voice: the Apple novelty and Eloquence voices are no longer picked by mistake. The app now selects a natural same-language voice (and self-heals older robotic selections).
• Tip: download an Enhanced or Premium voice in Settings → Accessibility → Spoken Content → Voices for the best quality.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 19 — uploaded 2026-07-10

A brand-new look, built on Apple's Liquid Glass design.

DESIGN
• The whole app has been redesigned with Apple's Liquid Glass — cards, buttons, and the tab bar are now real translucent glass that refracts what's behind it.
• New ambient backgrounds in light and dark themes give every screen gentle depth. OLED mode stays true black to save battery.
• The Lens caption panel now floats as frosted glass over the live camera.
• Every accent color palette works with the new glass surfaces.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 20 — uploaded 2026-07-10

A brand-new look, built on Apple's Liquid Glass design.

DESIGN
• The whole app has been redesigned with Apple's Liquid Glass — cards, buttons, and the tab bar are now real translucent glass that refracts what's behind it.
• New ambient backgrounds in light and dark themes give every screen gentle depth. OLED mode stays true black to save battery.
• The Lens caption panel now floats as frosted glass over the live camera.
• Every accent color palette works with the new glass surfaces.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 21 — uploaded 2026-07-10

A brand-new look, built on Apple's Liquid Glass design.

DESIGN
• The whole app has been redesigned with Apple's Liquid Glass — cards, buttons, and the tab bar are now real translucent glass that refracts what's behind it.
• New ambient backgrounds in light and dark themes give every screen gentle depth. OLED mode stays true black to save battery.
• The Lens caption panel now floats as frosted glass over the live camera.
• Every accent color palette works with the new glass surfaces.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 22 — uploaded 2026-07-10

A brand-new look, built on Apple's Liquid Glass design.

DESIGN
• The whole app has been redesigned with Apple's Liquid Glass — cards, buttons, and the tab bar are now real translucent glass that refracts what's behind it.
• New ambient backgrounds in light and dark themes give every screen gentle depth. OLED mode stays true black to save battery.
• The Lens caption panel now floats as frosted glass over the live camera.
• Every accent color palette works with the new glass surfaces.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 23 — uploaded 2026-07-10

A brand-new look, built on Apple's Liquid Glass design.

DESIGN
• The whole app has been redesigned with Apple's Liquid Glass — cards, buttons, and the tab bar are now real translucent glass that refracts what's behind it.
• New ambient backgrounds in light and dark themes give every screen gentle depth. OLED mode stays true black to save battery.
• The Lens caption panel now floats as frosted glass over the live camera.
• Every accent color palette works with the new glass surfaces.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 24 — uploaded 2026-07-10

A brand-new look, built on Apple's Liquid Glass design.

DESIGN
• The whole app has been redesigned with Apple's Liquid Glass — cards, buttons, and the tab bar are now real translucent glass that refracts what's behind it.
• New ambient backgrounds in light and dark themes give every screen gentle depth. OLED mode stays true black to save battery.
• The Lens caption panel now floats as frosted glass over the live camera.
• Every accent color palette works with the new glass surfaces.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 25 — uploaded 2026-07-11

Refined clear Liquid Glass transparency, lighter hairline edge lighting, and a more translucent primary action.

### Build 26 — uploaded 2026-07-11

A brand-new look, built on Apple's Liquid Glass design.

DESIGN
• The whole app has been redesigned with Apple's Liquid Glass — cards, buttons, and the tab bar are now real translucent glass that refracts what's behind it.
• New ambient backgrounds in light and dark themes give every screen gentle depth. OLED mode stays true black to save battery.
• The Lens caption panel now floats as frosted glass over the live camera.
• Every accent color palette works with the new glass surfaces.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 27 — uploaded 2026-07-11

A refined look, built on Apple's Liquid Glass design.

DESIGN
• Clear, highly refractive Liquid Glass now has crisp, adaptive edges in both light and dark appearances.
• The app now uses a restrained black Onyx accent throughout light, dark, and OLED modes.
• Accent color choices are temporarily hidden for a simpler, more consistent interface.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 28 — uploaded 2026-07-11

A brighter dark appearance, built around Apple's native Liquid Glass.

DESIGN
• Dark mode now uses a lighter graphite canvas for improved depth and readability.
• Glass surfaces show more transparency and refraction as content scrolls behind them.
• Neutral ambient highlights make the glass effect easier to see without adding color.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 29 — uploaded 2026-07-11

A brighter dark appearance, built around Apple's native Liquid Glass.

DESIGN
• Dark mode now uses a lighter graphite canvas for improved depth and readability.
• Glass surfaces show more transparency and refraction as content scrolls behind them.
• Neutral ambient highlights make the glass effect easier to see without adding color.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 30 — uploaded 2026-07-11

A brighter dark appearance, built around Apple's native Liquid Glass.

DESIGN
• Dark mode now uses a lighter graphite canvas for improved depth and readability.
• Glass surfaces show more transparency and refraction as content scrolls behind them.
• Neutral ambient highlights make the glass effect easier to see without adding color.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 31 — uploaded 2026-07-12

A brighter dark appearance, built around Apple's native Liquid Glass.

DESIGN
• Dark mode now uses a lighter graphite canvas for improved depth and readability.
• Glass surfaces show more transparency and refraction as content scrolls behind them.
• Neutral ambient highlights make the glass effect easier to see without adding color.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 32 — uploaded 2026-07-12

_No en-US test note on record._

### Build 33 — uploaded 2026-07-12

A refined light and dark appearance, built with Apple's native Liquid Glass.

DESIGN
• Cards and controls now use the adaptive system glass material in both appearances.
• Removed painted glass tints, shine gradients, and decorative background washes.
• Standard dark mode now uses Apple's neutral system canvas with no graphite color cast.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 34 — uploaded 2026-07-12

A refined light and dark appearance, built with Apple's native Liquid Glass.

DESIGN
• Cards and controls now use the adaptive system glass material in both appearances.
• Removed painted glass tints, shine gradients, and decorative background washes.
• Standard dark mode now uses Apple's neutral system canvas with no graphite color cast.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 35 — uploaded 2026-07-12

_No en-US test note on record._

### Build 36 — uploaded 2026-07-12

A refined light and dark appearance, built with Apple's native Liquid Glass.

DESIGN
• Cards and controls now use the adaptive system glass material in both appearances.
• Removed painted glass tints, shine gradients, and decorative background washes.
• Standard dark mode now uses Apple's neutral system canvas with no graphite color cast.

Everything still runs entirely on your device — no account, no servers, nothing ever leaves your iPhone.

### Build 37 — uploaded 2026-07-12

_No en-US test note on record._

### Build 38 — uploaded 2026-07-12

_No en-US test note on record._

### Build 39 — uploaded 2026-07-12

_No en-US test note on record._

### Build 40 — uploaded 2026-07-12

_No en-US test note on record._

### Build 42 — uploaded 2026-07-12

_No en-US test note on record._

### Build 43 — uploaded 2026-07-14

_No en-US test note on record._

### Build 44 — uploaded 2026-07-14

_No en-US test note on record._

### Build 45 — uploaded 2026-07-15

_No en-US test note on record._

### Build 46 — uploaded 2026-07-15

Stability update for on-device Bonsai models.

• Fixed the Bonsai 1-bit quantization crash during model loading.
• Prevented out-of-memory terminations when Bonsai 27B is used in Lens on iPhone.
• Added safer device-specific memory limits and a graceful smaller-model recommendation when a model cannot run safely.
• Expanded diagnostics with process ceiling, footprint, and kernel memory readings.

Everything continues to run entirely on your device — no account, no servers.

### Build 47 — uploaded 2026-07-15

Smarter on-device model switching for Assistant and Lens.

• Fixed the Bonsai 1-bit quantization crash during model loading.
• Bonsai 27B now stays available as a memory-bounded text assistant on supported iPhones.
• Lens automatically uses a smaller installed vision model when a selected model's image runtime cannot fit safely.
• Assistant and Lens selections are independent, and switching tabs releases the previous runtime before loading the next one.
• Prevented hidden tabs from reloading models and causing repeated memory failures.

Everything continues to run entirely on your device — no account, no servers.

### Build 48 — uploaded 2026-07-15

Smarter on-device model switching for Assistant and Lens.

• Fixed the Bonsai 1-bit quantization crash during model loading.
• Bonsai 27B now stays available as a memory-bounded text assistant on supported iPhones.
• Lens automatically uses a smaller installed vision model when a selected model's image runtime cannot fit safely.
• Assistant and Lens selections are independent, and switching tabs releases the previous runtime before loading the next one.
• Prevented hidden tabs from reloading models and causing repeated memory failures.

Everything continues to run entirely on your device — no account, no servers.

### Build 49 — uploaded 2026-07-15

Smarter on-device model switching for Assistant and Lens.

• Fixed the Bonsai 1-bit quantization crash during model loading.
• Bonsai 27B now stays available as a memory-bounded text assistant on supported iPhones.
• Lens automatically uses a smaller installed vision model when a selected model's image runtime cannot fit safely.
• Assistant and Lens selections are independent, and switching tabs releases the previous runtime before loading the next one.
• Prevented hidden tabs from reloading models and causing repeated memory failures.

Everything continues to run entirely on your device — no account, no servers.

### Build 50 — uploaded 2026-07-16

Better chats, safer model downloads, and simpler storage management.

• Polished the Assistant composer and empty-chat experience.
• Added custom questions in Lens for supported on-device vision models.
• Reorganized Models by Assistant, Lens, Voice, and Image.
• Added a unified Downloads Center with clear progress and recent completions.
• Blocks models that definitely cannot run safely on the current device.
• Warns before large downloads and adds a guided “choose models to keep” cleanup.
• Improved cache cleanup to remove interrupted-download data.
• Added a preview for the upcoming OnDevice: AI Image Studio.

Everything continues to run entirely on your device — no account, no servers.

### Build 51 — uploaded 2026-07-16

_No en-US test note on record._

### Build 52 — uploaded 2026-07-16

_No en-US test note on record._

### Build 53 — uploaded 2026-07-16

Lens now feels more at home on iPhone.

NEW
• A redesigned Liquid Glass Lens experience keeps the camera front and center.
• A compact model picker makes on-device readiness easier to understand.
• Ask, Translate, Scan, and Solve now have clearer modes and subtle visual accents.
• New capture, scanning, and result animations provide better processing feedback.
• Lens answers are easier to read, with improved hierarchy and streamlined actions.
• Accessibility improvements include larger controls, Dynamic Type, VoiceOver labels, Reduce Motion, and increased-contrast support.

Everything continues to run entirely on your device — no account, no servers.

### Build 54 — uploaded 2026-07-17

_No en-US test note on record._

### Build 55 — uploaded 2026-07-17

Lens now feels more at home on iPhone.

NEW
• A redesigned Liquid Glass Lens experience keeps the camera front and center.
• A compact model picker makes on-device readiness easier to understand.
• Ask, Translate, Scan, and Solve now have clearer modes and subtle visual accents.
• New capture, scanning, and result animations provide better processing feedback.
• Lens answers are easier to read, with improved hierarchy and streamlined actions.
• Accessibility improvements include larger controls, Dynamic Type, VoiceOver labels, Reduce Motion, and increased-contrast support.
• Added support for the Bonsai 8B and 27B EXT series for more capable on-device assistance.

Everything continues to run entirely on your device — no account, no servers.

### Build 56 — uploaded 2026-07-17

Lens now feels more at home on iPhone.

NEW
• A redesigned Liquid Glass Lens experience keeps the camera front and center.
• A compact model picker makes on-device readiness easier to understand.
• Ask, Translate, Scan, and Solve now have clearer modes and subtle visual accents.
• New capture, scanning, and result animations provide better processing feedback.
• Lens answers are easier to read, with improved hierarchy and streamlined actions.
• Accessibility improvements include larger controls, Dynamic Type, VoiceOver labels, Reduce Motion, and increased-contrast support.
• Added support for the Bonsai 8B and 27B EXT series for more capable on-device assistance.

Everything continues to run entirely on your device — no account, no servers.

### Build 57 — uploaded 2026-07-17

Lens now feels more at home on iPhone.

NEW
• A redesigned Liquid Glass Lens experience keeps the camera front and center.
• A compact model picker makes on-device readiness easier to understand.
• Ask, Translate, Scan, and Solve now have clearer modes and subtle visual accents.
• New capture, scanning, and result animations provide better processing feedback.
• Lens answers are easier to read, with improved hierarchy and streamlined actions.
• Accessibility improvements include larger controls, Dynamic Type, VoiceOver labels, Reduce Motion, and increased-contrast support.
• Added support for the Bonsai 8B and 27B EXT series for more capable on-device assistance.

Everything continues to run entirely on your device — no account, no servers.

### Build 58 — uploaded 2026-07-17

Voice model runtime test build.

NEW
• Added native on-device ONNX inference for KittenTTS Micro 0.8, Nano 0.8 INT8, and Mini 0.8.
• Added pinned, validated model downloads with eight English voices and 24 kHz audio output.
• Added Select & Test so a model is marked ready only after it produces playable audio.
• Fixed voice-engine and Kitten variant selection surviving a cold restart.
• Moved future runtime integrations below working downloadable models.

This build passed simulator inference and playback tests. Physical-iPhone runtime validation is pending TestFlight testing.

### Build 59 — uploaded 2026-07-17

_No en-US test note on record._

### Build 60 — uploaded 2026-07-17

_No en-US test note on record._

### Build 61 — uploaded 2026-07-17

_No en-US test note on record._

### Build 63 — uploaded 2026-07-17

_No en-US test note on record._

### Build 64 — uploaded 2026-07-17

Voice Mode conversation loop + orb animation fixes.

• Mic now reliably resumes after the first spoken reply (no more stuck “Listening”).
• Orb speaking/listening reactivity restored across Glass, Nebula, and Core themes.
• Speech-detected animation fires when you start talking.
• Smoother speaking levels between TTS chunks; hitch recovery no longer freezes the orb in reduced mode.

Please retest Voice Mode: two full turns, all orb themes, Test audio, Bluetooth if available.

### Build 65 — uploaded 2026-07-17

Voice Mode fixes — multi-turn chat, karaoke, and Glass orb polish.

• Mic reliably resumes after the first spoken reply (hard restart if soft resume fails).
• Karaoke highlighting advances with speech again (player-clock fallback + phrase interpolation).
• Glass orb uses full-quality rendering with stronger listening/thinking/speaking motion.
• Second-turn LLM generation no longer silently drops while the first decode is still draining.

Please retest: 2–3 full voice turns, karaoke follow-along, Glass theme.

### Build 66 — uploaded 2026-07-18

Voice Mode — smoother orb, accurate karaoke, and three new presence themes.

• Orb animation lag fixed: removed per-token and mic-rate view invalidation that starved the render loop, and rebalanced Nebula rendering for ProMotion displays.
• Karaoke stays locked to the voice: highlighting no longer jumps ahead of the audio, repeated phrases highlight the correct span, and the transcript no longer shifts font as words are spoken.
• New orb themes: Waveform (equalizer bars), Aurora (flowing light ribbons), and Orbit (satellite rings) — pick them in Voice Settings.
• All themes hold a 30 FPS budget with cheaper sRGB rendering.

Please retest: full voice turns on device, karaoke follow-along, and the new themes.

### Build 67 — uploaded 2026-07-18

New app icon, Voice Mode audio fixes, and native-feel motion.

• New default app icon (Neon eye) — the previous pink icon is still available: Settings → Appearance → app icon → Classic.
• Fixed sped-up / word-skipping voice playback: the audio graph no longer reconnects between sentence chunks (that re-rated queued audio and caused dropouts), and mixed engine sample rates are now converted instead of reconnected mid-speech.
• Karaoke no longer jumps letters, words, or sentences: each spoken chunk is anchored to its real playback position on the audio clock, so the highlight tracks the voice even when on-device synthesis lags behind.
• Native-feel animations: Waveform, Aurora, Orbit, and Core now render at full ProMotion rate, Nebula at 60 FPS, and level smoothing is frame-rate independent.

Please retest: the new icon and the Classic switch in Settings, long voice replies on device (listen for speed shifts and skips), karaoke follow-along, and orb motion across themes.

### Build 68 — uploaded 2026-07-20

_No en-US test note on record._

### Build 69 — uploaded 2026-07-21

Voice Mode animation and stability update.

• Core is now the lightweight default orb.
• Display-synchronised animation removes flutter on standard and ProMotion iPhones.
• Audio-reactive motion is smoother across listening, thinking, speaking, interruption, and idle states.
• Fixed Glass orb frame-update warnings and VoiceOver duplication during state changes.

Please test multi-turn Voice Mode conversations, interruption while speaking, Reduce Motion, and orb smoothness on iPhone 15, 16, and 17 models.

### Build 70 — uploaded 2026-07-22

Voice Mode orb update.

• Replaced the legacy fluttering orbs with a native SwiftUI implementation of thinking-orbs.
• Added smooth, state-driven motion for listening, thinking, speaking, interruption, and idle states.
• Added creator attribution in Voice settings and the review prompt.

Thanks to Jakub Antalik, creator of thinking-orbs.

Please test multi-turn Voice Mode conversations, interruption while speaking, Reduce Motion, and orb smoothness on iPhone 15, 16, and 17 models.

### Build 71 — uploaded 2026-07-22

Voice Mode orb performance hotfix.

• Fixed reduced rendering mode incorrectly freezing the orb.
• Removed frame-queue buildup that caused stuttering and uneven motion.
• Restored microphone and playback responsiveness while listening and speaking.
• Batched dot rendering to substantially reduce per-frame work.

Thanks to Jakub Antalik, creator of thinking-orbs.

Please test listening and speaking responsiveness, multi-turn conversations, interruption, Reduce Motion, and orb smoothness.

### Build 72 — uploaded 2026-07-23

Please focus testing on the new Local API Server:

• Enable the server, change its port, restart it, and confirm all displayed LAN URLs are reachable from another computer.
• Connect from Linux using the provided curl examples.
• Test OpenAI-compatible GET /v1/models and POST /v1/chat/completions with both streaming and non-streaming requests.
• Test Ollama-compatible GET /api/tags, POST /api/chat, and POST /api/generate with streaming and non-streaming requests.
• Verify missing or incorrect bearer keys are rejected, then rotate the key and confirm the old key stops working.
• Confirm only the currently loaded Assistant model is advertised and accepted.
• Try an unknown model, malformed JSON, unsupported tools/images, a busy model, and disconnecting during generation.
• Background and reopen the app; confirm the server stops in the background and restores when foregrounded if enabled.
• Confirm the existing Mac Bridge pairing, inference, and QR flow still work.

Please include the client used, iPhone model, iOS version, model name, and server error text with any report.

### Build 73 — uploaded 2026-07-23

Please focus testing on the new Local API Server:

• Enable the server, change its port, restart it, and confirm all displayed LAN URLs are reachable from another computer.
• Connect from Linux using the provided curl examples.
• Test OpenAI-compatible GET /v1/models and POST /v1/chat/completions with both streaming and non-streaming requests.
• Test Ollama-compatible GET /api/tags, POST /api/chat, and POST /api/generate with streaming and non-streaming requests.
• Verify missing or incorrect bearer keys are rejected, then rotate the key and confirm the old key stops working.
• Confirm only the currently loaded Assistant model is advertised and accepted.
• Try an unknown model, malformed JSON, unsupported tools/images, a busy model, and disconnecting during generation.
• Background and reopen the app; confirm the server stops in the background and restores when foregrounded if enabled.
• Confirm the existing Mac Bridge pairing, inference, and QR flow still work.

Please include the client used, iPhone model, iOS version, model name, and server error text with any report.

### Build 74 — uploaded 2026-07-23

Please focus testing on the new Local API Server:

• Enable the server, change its port, restart it, and confirm all displayed LAN URLs are reachable from another computer.
• Connect from Linux using the provided curl examples.
• Test OpenAI-compatible GET /v1/models and POST /v1/chat/completions with both streaming and non-streaming requests.
• Test Ollama-compatible GET /api/tags, POST /api/chat, and POST /api/generate with streaming and non-streaming requests.
• Verify missing or incorrect bearer keys are rejected, then rotate the key and confirm the old key stops working.
• Confirm only the currently loaded Assistant model is advertised and accepted.
• Try an unknown model, malformed JSON, unsupported tools/images, a busy model, and disconnecting during generation.
• Background and reopen the app; confirm the server stops in the background and restores when foregrounded if enabled.
• Confirm the existing Mac Bridge pairing, inference, and QR flow still work.

Please include the client used, iPhone model, iOS version, model name, and server error text with any report.

### Build 75 — uploaded 2026-07-23

Please focus testing on the new Local API Server:

• Enable the server, change its port, restart it, and confirm all displayed LAN URLs are reachable from another computer.
• Connect from Linux using the provided curl examples.
• Test OpenAI-compatible GET /v1/models and POST /v1/chat/completions with both streaming and non-streaming requests.
• Test Ollama-compatible GET /api/tags, POST /api/chat, and POST /api/generate with streaming and non-streaming requests.
• Verify missing or incorrect bearer keys are rejected, then rotate the key and confirm the old key stops working.
• Confirm only the currently loaded Assistant model is advertised and accepted.
• Try an unknown model, malformed JSON, unsupported tools/images, a busy model, and disconnecting during generation.
• Background and reopen the app; confirm the server stops in the background and restores when foregrounded if enabled.
• Confirm the existing Mac Bridge pairing, inference, and QR flow still work.

Please include the client used, iPhone model, iOS version, model name, and server error text with any report.

### Build 76 — uploaded 2026-07-24

Please focus testing on the new Local API Server:

• Enable the server, change its port, restart it, and confirm all displayed LAN URLs are reachable from another computer.
• Connect from Linux using the provided curl examples.
• Test OpenAI-compatible GET /v1/models and POST /v1/chat/completions with both streaming and non-streaming requests.
• Test Ollama-compatible GET /api/tags, POST /api/chat, and POST /api/generate with streaming and non-streaming requests.
• Verify missing or incorrect bearer keys are rejected, then rotate the key and confirm the old key stops working.
• Confirm only the currently loaded Assistant model is advertised and accepted.
• Try an unknown model, malformed JSON, unsupported tools/images, a busy model, and disconnecting during generation.
• Background and reopen the app; confirm the server stops in the background and restores when foregrounded if enabled.
• Confirm the existing Mac Bridge pairing, inference, and QR flow still work.

Please include the client used, iPhone model, iOS version, model name, and server error text with any report.

### Build 77 — uploaded 2026-07-24

Please focus testing on the new Local API Server: …

### Build 78 — uploaded 2026-07-24

Please focus testing on Nanbeige 4.2 support and Assistant notifications:

• Download or select a Nanbeige 4.2 MLX model and confirm it loads without an “unsupported model type: nanbeige” error.
• Start several Assistant conversations and verify generation is coherent and stable.
• Trigger success, warning, and model-loading notifications on the Assistant screen.
• Confirm notifications appear below the navigation header and do not cover the Assistant title or selected model name.
• Check the same notification layout in portrait and landscape and with larger Dynamic Type sizes.
• Regression-test voice playback and confirm audio remains smooth.

Please include the device model, OS version, exact Nanbeige repository name, and any displayed error text with your report.

### Build 79 — uploaded 2026-07-24

Please focus testing on the Local API server:

• Enable the Local API server from Home → Mac and confirm its default port is 11434.
• Change the Local API port, tap Apply, and confirm the active server URL and saved port update immediately.
• Confirm the Mac pairing bridge remains clearly labeled as TLS on port 8443 and is not presented as the Local API URL.
• Send OpenAI-compatible requests to both /v1/chat/completions and /v1/responses.
• Verify /v1/responses works with input_text content in both streaming and non-streaming modes.
• Verify requests containing an empty "tools": [] array are accepted. Non-empty tool calls remain unsupported.

Please include the device model, OS version, endpoint, request body, response status, and any displayed error text with your report.

### Build 80 — uploaded 2026-07-25

Please focus testing on storage-backed large GGUF models:

• Import a text GGUF model that would normally be tight or too large for the device.
• In Models → Smart handling, enable Storage-backed large models.
• Load the imported GGUF and confirm it reaches Ready instead of showing the normal full-model memory warning.
• Send a short prompt and confirm generation begins and completes. Slower loading and token generation are expected.
• While generating, switch apps briefly and return; confirm CodeLens remains responsive and the device does not terminate the app.
• Disable Storage-backed large models, reload a small GGUF, and confirm normal accelerated loading still works.
• Confirm MLX models such as Ornith are unaffected by this option; this build supports storage-backed paging for imported GGUF only.

Please include the iPhone model, iOS version, GGUF filename and quantization, file size, load time, token speed, peak memory if available, and any displayed error text.

### Build 81 — uploaded 2026-07-25

Please focus testing on the Local API Server with Hermes Agent or another OpenAI-compatible tool client:

• Enable the Local API Server and connect to the displayed /v1 URL using its API key.
• Send a /v1/chat/completions request containing one or more function tools. Confirm the request is accepted instead of returning “Tool calling is not supported.”
• Confirm non-streaming responses return assistant tool_calls with stable IDs, JSON-string arguments, and finish_reason “tool_calls.”
• Repeat with stream=true and confirm tool-call deltas complete successfully.
• Execute the requested tool client-side, then send the assistant tool_calls and role=tool result back. Confirm the model continues the conversation.
• With Hermes Agent, confirm message content arrays such as [{"type":"text","text":"..."}] are accepted for user, assistant, and tool messages.
• Confirm parallel tool calls and tool_choice auto, required, none, and named-function modes behave correctly.

Please include the model, client name/version, streaming setting, request error text, and response JSON if anything fails.

### Build 82 — uploaded 2026-07-25

Please focus on tool calling and long conversations:

IN-APP TOOL CALLING
• Ask “What’s the weather in Asyut tomorrow?” with Web Access enabled. Approve access if prompted.
• Confirm raw JSON/tool syntax is not shown as the final answer.
• Confirm the search starts promptly and ends with a normal human-language weather response.
• The assistant must not say it is still waiting after the tool result arrives.
• Repeat with calculator, date/time, Knowledge Base, and a two-tool chained request.

LOCAL API SERVER
• Test OpenAI /v1/chat/completions with Hermes Agent, both streaming and non-streaming.
• Execute the returned function client-side, send its result back with the same tool-call ID, and confirm the next response answers naturally.
• Test Anthropic /v1/messages using tool_use and tool_result blocks.
• Test Ollama /api/chat using tools and role=tool results.
• Confirm tool calls return quickly after their JSON arguments are complete.
• Confirm ordinary requests without tools still stream normally. …

### Build 83 — uploaded 2026-07-25

Please focus on model loading, local API selection, and Qwen output:

MODEL RELOAD CONTROLS
• Load an assistant model, leave/background the app until iOS unloads it, then return to the same conversation.
• Confirm the marked “Not loaded” status row shows a Load button and reloads the selected model without leaving the conversation.
• Confirm the empty-conversation card also offers Load and Choose.

LOCAL API SERVER
• Open Mac Bridge → Local API Server with the selected model unloaded.
• Confirm Load reloads the current model.
• Tap the (…) model button and confirm the picker lists only assistant models already downloaded on this device.
• Select a different downloaded model and confirm it becomes ready for OpenAI, Anthropic, and Ollama requests.
• Confirm models that have not been downloaded do not appear. …

### Build 84 — uploaded 2026-07-25

Please focus on Hermes tool calling, cancellation, and device heat:

HERMES TOOL CALLING
• Connect Hermes to the OpenAI-compatible Local API and start a prompt that requires a tool.
• Confirm a valid tool call returns to Hermes and Hermes continues with a normal human-language answer.
• Try a prompt that does not need a tool while tools are available. Confirm text starts streaming instead of waiting for the whole answer.

STOP AND DISCONNECT
• While a tool request is generating, press Stop in Hermes.
• Confirm on-device generation stops promptly and a new request can start without force-closing CodeLens.
• Repeat by closing/disconnecting Hermes during generation.

HEAT AND RUNAWAY REQUESTS
• Confirm tool selection cannot run indefinitely. It is limited to 256 output tokens and a 90-second deadline.
• If the model cannot create a valid tool call, confirm Hermes receives a readable timeout response instead of looping.
• Watch whether the phone cools normally after Stop or timeout. …

### Build 85 — uploaded 2026-07-25

Please focus on Hermes tool calling, cancellation, and device heat:

HERMES TOOL CALLING
• Connect Hermes to the OpenAI-compatible Local API and start a prompt that requires a tool.
• Confirm a valid tool call returns to Hermes and Hermes continues with a normal human-language answer.
• Try a prompt that does not need a tool while tools are available. Confirm text starts streaming instead of waiting for the whole answer.

STOP AND DISCONNECT
• While a tool request is generating, press Stop in Hermes.
• Confirm on-device generation stops promptly and a new request can start without force-closing CodeLens.
• Repeat by closing/disconnecting Hermes during generation.

HEAT AND RUNAWAY REQUESTS
• Confirm tool selection cannot run indefinitely. It is limited to 256 output tokens and a 90-second deadline.
• If the model cannot create a valid tool call, confirm Hermes receives a readable timeout response instead of looping.
• Watch whether the phone cools normally after Stop or timeout. …

### Build 86 — uploaded 2026-07-25

Please focus on Hermes tool calling, cancellation, and device heat:

HERMES TOOL CALLING
• Connect Hermes to the OpenAI-compatible Local API and start a prompt that requires a tool.
• Confirm a valid tool call returns to Hermes and Hermes continues with a normal human-language answer.
• Try a prompt that does not need a tool while tools are available. Confirm text starts streaming instead of waiting for the whole answer.

STOP AND DISCONNECT
• While a tool request is generating, press Stop in Hermes.
• Confirm on-device generation stops promptly and a new request can start without force-closing CodeLens.
• Repeat by closing/disconnecting Hermes during generation.

HEAT AND RUNAWAY REQUESTS
• Confirm tool selection cannot run indefinitely. It is limited to 256 output tokens and a 90-second deadline.
• If the model cannot create a valid tool call, confirm Hermes receives a readable timeout response instead of looping.
• Watch whether the phone cools normally after Stop or timeout. …

### Build 87 — uploaded 2026-07-26

What to test in this build:

• Models → enable “Downloaded only.” Confirm every downloaded Assistant, Lens, Voice, and Image model appears in one list. Disable it to return to the normal catalog.
• For an installed model, confirm Hugging Face opens from the compact arrow on the right and that the other model actions remain easy to use.
• With Thinking enabled, request a long Detailed response, wait for it to finish, then immediately send a second prompt. The conversation should remain responsive without hanging or crashing.
• Repeat the long-response test with the low-memory/load option both enabled and disabled.
• While a response is generating, leave CodeLens or lock the phone, wait several seconds, then return. Generation may be cancelled by iOS background cleanup, but the app should not crash and a new prompt should work normally.
• With a tool-capable model, attach a PDF, ask the model to apply its instructions, answer any follow-up questions, and request a web search. Confirm document context and tool calls continue across multiple turns. …

### Build 88 — uploaded 2026-07-26

What to test in this build: …

### Build 89 — uploaded 2026-07-26

What to test in this build: …

### Build 90 — uploaded 2026-07-26

What to test in this build: …

### Build 91 — uploaded 2026-07-26

What to test in this build:

IMAGE HANDOFF FIX
• With the 9B Qwen text model selected, attach a screenshot and ask “What is this?”
• Confirm SmolVLM2 analyzes the image, the selected assistant reloads, and a real text answer appears. The turn must not finish after 0.1 seconds with a blank assistant card.
• Repeat with an image containing product text. Confirm the answer identifies the object and uses relevant visible text.
• Repeat with a natively multimodal assistant. Confirm it receives pixels directly.
• If the text model immediately returns an empty response, confirm CodeLens retries once automatically and never leaves a blank card. …

### Build 92 — uploaded 2026-07-26

What to test in this build:

MODEL SWITCHER
• Open the model switcher from a conversation. Confirm it lists every valid downloaded assistant model, including downloaded catalog models, and does not show models that are not installed.
• On a device with no downloaded assistant models, confirm the empty state shows “Browse Models” and that it opens the Models tab. …

### Build 93 — uploaded 2026-07-26

What to test in this build:

MODEL SWITCHER
• Open the model switcher from a conversation. Confirm it lists every valid downloaded assistant model, including downloaded catalog models, and does not show models that are not installed.
• On a device with no downloaded assistant models, confirm the empty state shows “Browse Models” and that it opens the Models tab. …

### Build 94 — uploaded 2026-07-26

What to test in this build:

MODEL SWITCH HOTFIX
• Set Nanbeige as the default model.
• Open an existing conversation, choose the downloaded Jackrong Qwen3.5 9B model, and confirm the 9B model—not Nanbeige—loads and becomes ACTIVE for that conversation.
• Confirm Nanbeige remains marked DEFAULT and is still used when starting a new chat.
• Background the app during a model load, return, and confirm the originally selected conversation model resumes loading.

INSTALLED MODEL CONSISTENCY
• Confirm every valid downloaded assistant shown in the chat model picker also appears under Models → Assistant → Installed.
• Specifically confirm Jackrong/MLX-Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-4bit appears in both places.
• Turn on “Downloaded only” and confirm the same Jackrong model is present there. …

### Build 95 — uploaded 2026-07-26

What to test in this build:

MODEL SWITCH HOTFIX
• Set Nanbeige as the default model.
• Open an existing conversation, choose the downloaded Jackrong Qwen3.5 9B model, and confirm the 9B model—not Nanbeige—loads and becomes ACTIVE for that conversation.
• Confirm Nanbeige remains marked DEFAULT and is still used when starting a new chat.
• Background the app during a model load, return, and confirm the originally selected conversation model resumes loading.

INSTALLED MODEL CONSISTENCY
• Confirm every valid downloaded assistant shown in the chat model picker also appears under Models → Assistant → Installed.
• Specifically confirm Jackrong/MLX-Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-4bit appears in both places.
• Turn on “Downloaded only” and confirm the same Jackrong model is present there. …

### Build 96 — uploaded 2026-07-27

What to test in this build:

COMPOSER KEYBOARD HOTFIX
• Open a long completed chat in Dark or OLED mode, focus the composer, and keep the keyboard open.
• Confirm the response and its footer stay above the composer instead of showing through the input field or action row.
• Enter a two-line prompt. Confirm the field expands cleanly, the divider remains visible, and every attachment/action button stays unobstructed.

MODEL SWITCH HOTFIX
• Set Nanbeige as the default model.
• Open an existing conversation, choose the downloaded Jackrong Qwen3.5 9B model, and confirm the 9B model—not Nanbeige—loads and becomes ACTIVE for that conversation.
• Confirm Nanbeige remains marked DEFAULT and is still used when starting a new chat.

INSTALLED MODEL CONSISTENCY
• Confirm every valid downloaded assistant shown in the chat model picker also appears under Models → Assistant → Installed.
• Specifically confirm Jackrong/MLX-Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-4bit appears in both places. …

### Build 97 — uploaded 2026-07-27

What to test in this build:

COMPOSER KEYBOARD HOTFIX
• Open a long completed chat in Dark or OLED mode, focus the composer, and keep the keyboard open.
• Confirm the response and its footer stay above the composer instead of showing through the input field or action row.
• Enter a two-line prompt. Confirm the field expands cleanly, the divider remains visible, and every attachment/action button stays unobstructed.

MODEL SWITCH HOTFIX
• Set Nanbeige as the default model.
• Open an existing conversation, choose the downloaded Jackrong Qwen3.5 9B model, and confirm the 9B model—not Nanbeige—loads and becomes ACTIVE for that conversation.
• Confirm Nanbeige remains marked DEFAULT and is still used when starting a new chat.

INSTALLED MODEL CONSISTENCY
• Confirm every valid downloaded assistant shown in the chat model picker also appears under Models → Assistant → Installed.
• Specifically confirm Jackrong/MLX-Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-4bit appears in both places. …

### Build 98 — uploaded 2026-07-28

What to test in this build:

COMPOSER KEYBOARD HOTFIX
• Open a long completed chat in Dark or OLED mode, focus the composer, and keep the keyboard open.
• Confirm the response and its footer stay above the composer instead of showing through the input field or action row.
• Enter a two-line prompt. Confirm the field expands cleanly, the divider remains visible, and every attachment/action button stays unobstructed.

MODEL SWITCH HOTFIX
• Set Nanbeige as the default model.
• Open an existing conversation, choose the downloaded Jackrong Qwen3.5 9B model, and confirm the 9B model—not Nanbeige—loads and becomes ACTIVE for that conversation.
• Confirm Nanbeige remains marked DEFAULT and is still used when starting a new chat.

INSTALLED MODEL CONSISTENCY
• Confirm every valid downloaded assistant shown in the chat model picker also appears under Models → Assistant → Installed.
• Specifically confirm Jackrong/MLX-Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-4bit appears in both places. …


## 2026-10

### Build 116 — uploaded 2026-10-06

_(marketing version 3.3)_

Test the 3.3 update on your iPhone.

Install over App Store 3.2.4 without deleting the app. Check that conversations, saved snippets, memories, settings, downloaded models and provider credentials remain available.

Check sharing text, links and images into the app: wait for Saved, tap Done, then open the app. Shared text should fill the composer without automatically sending.

Try model download, load, generation, cancellation, switching and unloading. Check backgrounding and recovery. Use a model that fits your phone's memory and allow the device to cool if a workload is refused.

Check local voice, microphone/camera permission denial, large text, dark appearance, legal document read states and the image-generation parental PIN.

If you use iCloud sync, check existing conversations, cross-device updates and offline recovery. Do not use Wipe all on-device data during the upgrade-preservation checks.

### Build 117 — uploaded 2026-10-07

_(marketing version 3.3)_

Test version 3.3 build 117 on your iPhone.

This build improves large Hugging Face downloads, checksum verification, model discovery after the app container changes, nested GGUF imports, and memory admission. Apple Private Cloud remains unavailable in this standard build.

Install over the existing App Store or TestFlight version without deleting the app. Check that conversations, snippets, memories, settings, downloaded models and provider credentials remain available.

Download a model with multiple files or shards. Check completion, cancellation and retry. Import a GGUF in a nested folder and confirm it appears as installed and can be selected. Try load, generation, cancellation, switching and unloading with a model that fits your phone; repeat the memory-refusal checks in Low Power Mode and check recovery after backgrounding. …

### Build 118 — uploaded 2026-10-08

_(marketing version 3.3)_

Test version 3.3 build 118 on your iPhone.

This build adds local image prompt/output checks, retains thermal and capacity checks for smaller-memory-margin loads, and updates privacy explanations and dependency notices. It includes the download, storage recovery, sharing, speech, consent and parental-control improvements from build 117. Apple Private Cloud remains unavailable in this standard build.

Install over the existing App Store or TestFlight version without deleting the app. Check that conversations, snippets, memories, settings, downloaded models and provider credentials remain available. Do not wipe app data during this check. …

### Build 119 — uploaded 2026-10-11

_(marketing version 3.3)_

Version 3.3 build 119 improves image model setup and downloads.

Download image models directly from Models → Image or from the image generator before entering a prompt. Use Change to open the compact model picker. The prompt and generation controls now appear before the image preview.

Check download progress, cancellation, retry after a connection failure, and the shared Downloads list. Completed model files should be reused when retrying. A download alone must not generate an image.

Check switching models, installed status, and deletion confirmation. Verify the download buttons remain readable in dark appearance and reachable with larger text. Generation still checks available memory, device temperature, parental controls, prompts, and generated images locally.

Install over the existing version without deleting the app, and verify existing conversations, settings, downloaded models, and credentials remain available.

### Build 120 — uploaded 2026-10-14

_No en-US test note on record._

### Build 121 — uploaded 2026-10-16

A clearer local API workspace
• A dedicated Local API Server page with separate server and model status.
• Start, stop, or restart the server and load installed local models without automatic downloads.
• Copy pinned HTTPS setup commands for OpenAI, Anthropic, and Ollama clients.
• Confirm API key rotation, hide revealed keys when leaving the page or backgrounding, and save validated port changes.
• Improved dark mode and large-text layouts.

Open Mac → Local API Server. Check start, restart, and stop; choose an installed model; verify the copied URL and TLS public-key pin; then try your client. Apply a valid port and reopen the app. Reveal the key, background the app, and confirm it hides. Memory and thermal limits still apply.

### Build 122 — uploaded 2026-10-16

A clearer local API workspace
• Open Local API Server directly from the Studio home screen.
• A dedicated Local API Server page with separate server and model status.
• Start, stop, or restart the server and load installed local models without automatic downloads.
• Copy pinned HTTPS setup commands for OpenAI, Anthropic, and Ollama clients.
• Confirm API key rotation, hide revealed keys when leaving the page or backgrounding, and save validated port changes.
• Improved dark mode and large-text layouts.

Open Home → Local API Server. Check start, restart, and stop; choose an installed model; verify the copied URL and TLS public-key pin; then try your client. Apply a valid port and reopen the app. Reveal the key, background the app, and confirm it hides. Memory and thermal limits still apply. Use Done to return to Studio.

### Build 123 — uploaded 2026-10-17

iPhone Duo UI fixes: fold and rotate while composing an unsent message. The composer should stay above the keyboard without covering setup or conversation content. Models opens directly to search and role selection without repeated zero counters. Check full model-role labels at larger text sizes, readable metadata in both appearances, larger touch targets, and sidebar recovery from Home, Models, and Voices. On a fresh install, model setup is explicit and idle models no longer appear to be preparing.

### Build 124 — uploaded 2026-10-20

_No en-US test note on record._

### Build 125 — uploaded 2026-10-26

_No en-US test note on record._

### Build 126 — uploaded 2026-10-28

What to test in this build (3.3.5, build 126): …

### Build 127 — uploaded 2026-10-28

What to test in this build (3.3.5, build 127): …

### Build 128 — uploaded 2026-10-28

What to test in this build (3.4, build 128): …

### Build 129 — uploaded 2026-10-28

What to test in this build (3.4, build 129): …

### Build 131 — uploaded 2026-10-28

What to test in this build (3.4, build 131): …

### Build 132 — uploaded 2026-10-28

What to test in this build (3.4, build 132): …

### Build 133 — uploaded 2026-10-28

What to test in this build (3.4, build 133): …

### Build 134 — uploaded 2026-10-28

What to test in this build (3.4, build 134): …

### Build 135 — uploaded 2026-10-29

What to test in this build (3.4, build 135):

LFM3 fixes on top of build 134. …

### Build 136 — uploaded 2026-10-29

What to test in this build (3.4, build 136):

Voice fixes for LFM3 Audio 2B and LFM3 Omni 2B, on top of build 135. …

### Build 137 — uploaded 2026-10-31

What to test in this build (3.5, build 137):

Assistant tool fixes, on top of build 136.

• Images in chat: ask the assistant to draw a picture. While it works, the chat shows the same progress bar and percentage as Image Generation. When the image is ready it should appear in the conversation, even if the image model takes several minutes to load or you open another chat meanwhile.
• Declined tools: ask for something that makes the assistant want to search the web or read a file, and decline. It should answer right away instead of asking for another tool.
• Regression: a tool you allow (web search, calculator, file) still runs and the answer uses it.

Please include the model name and a diagnostics export with any failure.

### Build 138 — uploaded 2026-10-31

What to test in this build (3.5, build 138):

Image-in-chat fixes, on top of build 137.

• Keep chatting after an image: ask the assistant to draw a picture. When the image appears, the chat model you picked should load again by itself. You should not need to tap Load model.
• No repeat images: after the image, ask for something unrelated (for example "write an HTML animation"). The assistant should answer that request and not draw the previous image again.
• Image sheet: open Generate an image from the chat menu, make an image and close the sheet. The chat model should load again.

Please include the model name and a diagnostics export with any failure.

### Build 139 — uploaded 2026-10-31

What to test in this build (3.5, build 139):

Tool choice fixes, on top of build 138.

• No search for writing tasks: ask "write a website in HTML" or "create a landing page". The assistant should write the code right away, without a web search or a web permission prompt.
• Search still works: ask "search for the latest Swift release" or paste a link to summarize. The web search should still run.
• Images: ask for a picture, then ask for code. The chat model should reload by itself and answer the code request without drawing again.

Please include the model name and a diagnostics export with any failure.

### Build 140 — uploaded 2026-10-31

What to test in this build (3.5, build 140):

One more tool choice fix, on top of build 139.

• No image for code requests: ask for a picture first, then ask "Write a short HTML page with a pastel animated gradient background". The assistant should write the code, not draw another image.
• Images still work: ask "Generate an image of a golden retriever puppy in a sunny meadow". It should draw the picture.

Please include the model name and a diagnostics export with any failure.

### Build 141 — uploaded 2026-10-31

What to test in this build (3.5, build 141):

Cleaner chat while tools run, on top of build 140.

• No raw tool text: ask "Generate an image of a golden retriever puppy in a sunny meadow". The reply should go straight to the Generate Image card, without a flash of <tool_call> text.
• No skipped-tool cards: then ask "Write a short HTML page with a pastel animated gradient background". No web search or image card should appear, only the answer.
• Direct answers: that reply should start with the page, not with "I don't have a tool…".

Please include the model name and a diagnostics export with any failure.


## 2026-11

### Build 142 — uploaded 2026-11-01

What to test in this build (3.5, build 142):

Fix for the app freezing and closing on the Voice screen, on top of build 141.

• Voice settings: open the Voice settings screen and the Voice library. The voice list should appear within about a second, the screen should respond, and the app should not freeze or close.
• Change the voice and tap Preview voice. It should speak with the chosen voice.
• Leave the app, come back, and open Voice settings again. It should keep working.

Please include the model name and a diagnostics export with any failure.

### Build 143 — uploaded 2026-11-01

What to test in this build (3.5, build 143):

New voices and speech options, on top of build 142.

• Supertonic 3: in Voice → voice engine, download Supertonic 3 (~400 MB) and select it. Ask something in Turkish and in English; each reply should be read in its own language.
• Paradee: download Paradee-8M (~9 MB), select it and tap Preview voice. Words like "tiny", "voice" and "water" should now sound right. Kokoro has the same fix.
• Whisper: Whisper Small and Whisper Large-v3 Turbo are new dictation downloads in the voice model catalog.
• Apple SpeechAnalyzer: in Settings → Voice, turn on "apple speechanalyzer" and dictate in the chat box. The first use may download Apple's speech model.
• LFM3 Audio / Omni: if installed, they ask for one smaller download (172 / 292 MB). Then try a voice conversation.
• Voice settings: the new "speech-native chat model" row should open the chat model list.

Please include the model name and a diagnostics export with any failure.

### Build 144 — uploaded 2026-11-04

What to test in this build (3.5.1, build 144):

Lens camera and LFM3 Omni fixes, on top of build 143. …

### Build 145 — uploaded 2026-11-04

What to test in this build (3.5.1, build 145):

Lens crash fix and a new Live mode, on top of build 144.

• Crash fix: in Lens with a GGUF model (LFM3-VL, LFM3 Omni or SmolVLM2), take a photo, tap Cancel while it is still answering, then take another photo right away. Repeat a few times. The app must not close.
• Live mode: in Lens, tap the new Live button (Live Photo icon, top bar). It turns red, gives a caption right away and keeps describing the camera every few seconds. Tap it again to stop. It should also stop when you tap Cancel, switch to code mode or leave Lens.
• Live mode for a while: leave it on for a couple of minutes. Captions should keep coming, more slowly if the phone gets warm, without the app closing.
• Still to check from build 144: the preview stays live with a large model, a "camera paused" message replaces a black view, and LFM3 Omni switches between chat and Lens without loading again.

Please include the model, the device and a diagnostics export with any failure.

### Build 146 — uploaded 2026-11-04

What to test in this build (3.5.1, build 146):

A real Live mode in Lens, on top of build 145.

• Live view: in Lens, tap the Live button (Live Photo icon, top bar). The camera should stay live, with a LIVE card at the bottom whose caption updates in place. There should be no frozen photo, spinner or answer card between updates.
• Speed: with LFM3-VL or another vision model, a new short caption should arrive every few seconds. Please tell us roughly how many seconds between captions on your phone.
• Modes: try Live in Ask and in Translate. Captions stay short (one sentence).
• Stop: the Stop button and the Live button both end Live mode. Leaving Lens or switching to code mode also ends it.
• Errors: with no vision model downloaded, Live should show the error once and switch off, not keep retrying.
• Heat: leave Live on for a few minutes. Captions may slow down when the phone is warm, but the app should not close.

Please include the model, the device and a diagnostics export with any failure.

### Build 147 — uploaded 2026-11-06

What to test in this build (3.5.1, build 147):

Interface, accessibility and engine updates, on top of build 146. …

### Build 148 — uploaded 2026-11-06

What to test in this build (3.5.1, build 148):

Answer formatting and web search, on top of build 147. …

### Build 149 — uploaded 2026-11-08

What to test in this build (3.5.1, build 149):

Voice mode reliability, on top of build 148. Use a downloaded model: a small one (1–2B) and, if you can, a 3–4B one too.

• Long conversation: talk back and forth for 10 or more turns. Replies should stay short, the mic should come back after every reply, and the phone should not get hot or stop answering.
• Headphones: connect or disconnect AirPods while the assistant is speaking and while it is listening. Voice should continue on the new route instead of going silent.
• Calls and leaving the app: take a call or switch apps mid-conversation, then come back. Voice mode should show Paused or resume on its own, with the conversation kept.
• Model menu: tap the model name at the top of voice mode. Models that are not downloaded show their size and ask before downloading.
• First use: after granting microphone and speech permission, voice mode should start listening without a "Microphone isn't ready" error.
• Appearance: voice mode follows the app's light or dark setting. …

### Build 150 — uploaded 2026-11-08

What to test in this build (3.5.1, build 150):

Large downloads and model limits, on top of build 149.

• Large downloads: download a big model (several GB). The app should no longer close when the download finishes. A download that was cut off now shows as unfinished in Models; tap Download to finish it.
• Unsupported models: a Hugging Face model that needs its publisher's own runtime is now refused before the big files download, with a message that says why.
• Memory limits: on 12 GB iPhones, models too large for the memory iOS gives the app (such as 9B models) are refused with a clear message instead of closing the app. Smaller models should load as before.
• Longer replies: Settings → Response length → Full now allows about 8,000 tokens. A reply that hits its limit continues once on its own; the Continue button still works after that.
• Longer chats: GGUF and Qwen 3.5 models keep more of the conversation when memory allows.

Please include the model name, your iPhone model, and a diagnostics export with any failure.

### Build 151 — uploaded 2026-11-09

What to test in this build (3.5.2, build 151):

Design polish, on top of build 150.

• Voice engines: open Settings → Voice settings and choose a voice engine. The sheet is redesigned: each engine is a card with one clear status, a Download button that shows the size and asks before downloading, and an ⓘ button for details. Engines this iPhone can't run are grouped under "More models" at the bottom.
• KittenTTS: picking Micro, Nano or Mini now keeps the variant you picked.
• Settings: the Voice settings row is now easy to tap.
• Consistent design: buttons, page titles and card corners now match across the app. Tell us about any screen where a button looks cut off or out of place.

Please include the model name, your iPhone model, and a diagnostics export with any failure.

### Build 152 — uploaded 2026-11-10

What to test in this build (3.5.2, build 152):

Model downloads and model management, on top of build 151. …

### Build 153 — uploaded 2026-11-12

What to test in this build (3.5.2, build 153):

New: preview and save code.

• Preview HTML: ask for a small web page, for example "Make a counter page with one button". When the reply finishes, the HTML code box shows a preview button. Tap it: the page should open in a sheet, and its buttons should work. The refresh button runs it again.
• The preview has no internet access. Pages that load scripts, styles, fonts or images from the web will look incomplete; that is expected. Self-contained pages should render fully.
• Save: tap the save button on any code block. Files opens with a file name that matches the language (for example code.html or code.py). Save it, then open it from Files.
• Copy still works on every code block.
• The buttons appear only after the reply finishes.

Checks from build 152 still apply: pause and resume model downloads, interrupted downloads, and Assistant in landscape.

Please include the model name, your iPhone model, and a diagnostics export with any failure.

### Build 154 — uploaded 2026-11-12

What to test in this build (3.5.2, build 154):

Voice transcript, on top of build 152.

• Transcript while speaking: the answer appears one sentence at a time, as it is spoken. The box keeps the sentence being spoken in view, and the highlight fills word by word.
• Replay: replaying a reply shows the text once, with no repeated sentences.
• Follow speech: scroll up in the transcript to read earlier text. Follow speech brings you back to the spoken sentence.
• Highlight at the end: when the reply finishes, the highlight clears and the whole reply is shown.

Please include the voice engine, your iPhone model, and whether the transcript stayed with the speech.

### Build 155 — uploaded 2026-11-14

What to test in this build (3.5.2, build 155):

Reliability fixes on top of build 154.

• Chat is saved sooner: send a message, then close the app while the reply is still being written. When you reopen it, your message is there and the cut-off reply is marked as stopped.
• Switching chats: start a long reply, then open another chat. The old reply stops and stays marked as stopped.
• Paused downloads: pause a model download, then run the storage cleanup in Models. The paused download is kept and resumes where it stopped.
• First launch: on cellular data the app asks before downloading a model, and models marked "won't fit" cannot be selected.
• Image generation: start an image, switch to another app and come back. The model stays available; if it was disabled earlier, Try Again enables it.
• Lens: a caption that could not run says why it paused, and large photos from the library open without a freeze.
• Import: a model folder with dots in its name (for example Llama-3.2-1B) keeps its full name. …

### Build 156 — uploaded 2026-11-15

_No en-US test note on record._

### Build 157 — uploaded 2026-11-17

Build 157 (3.5.3). Test the SenseNova-Loop 9B model. It is not in the Download Center, so import it instead. 1) Models tab > Import model > choose SenseNova-Loop-9B-Q4_0.gguf from Files. 2) Select it and send a short prompt, for example: Hi, what is 2+2? 3) Report: did it load, the exact error text if not, whether it replied, and whether the app quit or showed a memory warning. Note how long the first reply took.

### Build 158 — uploaded 2026-11-18

What to test in this build (3.5.3, build 158):

A design and layout pass. Models, downloads and answers work as in build 157. …

### Build 159 — uploaded 2026-11-19

What to test in this build (3.5.3, build 159):

A redesigned Models tab, plus the polish from build 158. …
