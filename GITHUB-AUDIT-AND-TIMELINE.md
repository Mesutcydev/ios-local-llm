# CodeLens (Mesutcydev/ios-local-llm) — GitHub Audit & Changelog Timeline

_Generated 2026-11-19 from live `gh` reads + local repo `~/Desktop/CodeLens`._

## 1. GitHub audit

### Repository facts
- **Repo:** Mesutcydev/ios-local-llm — public, primary language Swift, 22 stars
- **Description:** "OnDevice Local AI Studio — run LLMs on iPhone offline. SwiftUI workbench with MLX, llama.cpp, whisper.cpp, RAG, and authenticated OpenAI/Anthropic/Ollama-compatible local APIs."
- **Default branch:** `main` · **Commits on main:** 35 · **Created:** 2026-07-29 · **Last push:** 2026-11-18
- **Local checkout:** `~/Desktop/CodeLens`, currently on branch `codex/llama-v0.4.0-testing` (not `main`) with uncommitted changes (CHANGELOG.md, project.pbxproj, all Localizable.strings, VoiceModelCatalog.json) — consistent with the "versions not committed for 3.3–3.5.x releases" convention.
- **Note:** the App Store/TestFlight releases (3.3 → 3.5.3) are NOT represented in git history — build metadata stays uncommitted by convention, so the changelog below is the authoritative update record.

### Branches (20)
`main`, `gh-pages`, `release/ondevice-core-1.0.0-10`,
work in progress: `feat/gguf-audit-activity-cards`, `fix/coreai-pytest-alert`, `codex/llama-v0.4.0-testing`, `codex/ondevice-seo-links`,
agent branches: `claude/eloquent-newton-anyzfr`, `cursor/coreai-build-fixes-185c`, `cursor/verify-coreai-128-e964`,
readiness: `chore/codeql-readiness`, `chore/open-source-program-readiness`, `chore/release-v3.2.5`, `chore/supply-chain-readiness`,
dependabot: `actions/attest-4.2.2`, `actions/cache-6.1.0`, `actions/dependency-review-action-5.0.0`, `codeql-action/analyze-4.37.9`, `codeql-action/upload-sarif-4.37.3`, `pip/pytest-9.0.3`.

### Pull requests (18 total: 5 merged, 2 closed, 11 open)
| # | State | Opened | Merged | Title |
|---|-------|--------|--------|-------|
| 18 | OPEN | 2026-11-18 | — | fix: drop unused coreai-models Python manifest flagged by Dependabot |
| 17 | MERGED | 2026-11-05 | 2026-11-05 | Point Studio and LAS readers to current app pages |
| 16 | OPEN | 2026-09-01 | — | Bump actions/cache 5.1.0 → 6.1.0 |
| 15 | OPEN | 2026-09-01 | — | Bump codeql-action/analyze 4.36.2 → 4.37.9 |
| 14 | OPEN | 2026-09-01 | — | Bump actions/attest 4.2.0 → 4.2.2 |
| 13 | OPEN | 2026-08-19 | — | Bump pytest 8.4.0 → 9.0.3 (Packages/coreai-models) |
| 12 | OPEN | 2026-08-19 | — | fix: GGUF/MLX audit fixes and in-chat activity cards (build 110) — 73 files, +6,593/−3,482 |
| 11 | MERGED | 2026-08-08 | 2026-08-08 | Publish AltStore source |
| 10 | MERGED | 2026-08-07 | 2026-08-19 | Ship OnDeviceLAS 3.2.6 (143) local API server |
| 9  | OPEN | 2026-08-01 | — | Bump codeql-action/upload-sarif 4.36.2 → 4.37.3 |
| 8  | CLOSED | 2026-08-01 | — | Bump actions/attest 4.2.0 → 4.2.1 |
| 7  | OPEN | 2026-07-29 | — | Add CodeQL Swift security analysis |
| 6  | MERGED | 2026-07-29 | 2026-07-29 | Add attested source releases and OpenSSF Scorecard |
| 5  | MERGED | 2026-07-29 | 2026-07-29 | Prepare the 3.2.5 source release |
| 4  | OPEN | 2026-07-29 | — | Bump actions/dependency-review-action 4.9.0 → 5.0.0 |
| 3  | MERGED | 2026-07-29 | 2026-07-29 | Prepare iOS Local LLM for open source programs |
| 2  | MERGED | 2026-07-29 | 2026-07-29 | Bump fastlane 2.234.0 → 2.237.0 |
| 1  | CLOSED | 2026-07-29 | — | Bump actions/checkout 4 → 7 |

### Issues
0 open, 0 closed — the issue tracker is unused.

### GitHub Releases (18, all sideload/AltStore IPA distributions)
| Date | Tag | Release |
|------|-----|---------|
| 2026-09-26 | sideload-3.2.6-146 | **Latest** — OnDevice LAS 3.2.6 (146) — kernel memory limit |
| 2026-09-24 | sideload-3.2.6-145 | OnDevice LAS 3.2.6 (145) — refreshed icon |
| 2026-09-23 | sideload-3.2.6-144 | OnDevice LAS 3.2.6 (144) — new icon |
| 2026-09-21 | sideload-3.2.7-114 | OnDevice LLM 3.2.7 (114) — sideload IPA |
| 2026-09-05 | ondevice-core-1.0.0-10 | OnDevice Core 1.0.0 (10) — iOS 27 sideload IPA |
| 2026-09-05 | sideload-3.2.7-112 | OnDevice LLM 3.2.7 (112) — sideload IPA |
| 2026-09-04 | sideload-3.2.7-111 | OnDevice LLM 3.2.7 (111) — sideload IPA |
| 2026-08-31 | sideload-suite-2026-08-31 | Mesutcydev sideload suite — 2026-08-31 |
| 2026-08-20 | sideload-3.2.6-110 | OnDevice LLM 3.2.6 (110) — verified sideload IPA |
| 2026-08-20 | sideload-3.2.6-109 | OnDevice LLM 3.2.6 (109) — verified sideload IPA |
| 2026-08-19 | sideload-3.2.6-143 | Sideload builds 3.2.6 — OnDeviceLAS 143 |
| 2026-08-19 | sideload-3.2.6-108 | OnDevice LLM 3.2.6 (108) — verified sideload IPA |
| 2026-08-19 | sideload-3.2.6-106 | OnDevice LLM 3.2.6 (106) — verified sideload IPA |
| 2026-08-19 | sideload-3.2.6-105 | OnDevice LLM 3.2.6 (105) — verified sideload IPA |
| 2026-08-16 | sideload-3.2.6-142 | Sideload builds 3.2.6 — OnDeviceLAS 142 |
| 2026-08-13 | sideload-3.2.6-103 | OnDevice LLM 3.2.6 (103) — verified sideload IPA |
| 2026-08-13 | sideload-3.2.6-102 | iOS Local LLM 3.2.6 (102) — verified sideload IPA |
| 2026-08-07 | sideload-3.2.6-140 | Sideload builds 3.2.6 — OnDeviceLAS 140 + Core AI 138 |

### Audit findings
1. **11 stale open PRs** — 6 are Dependabot bumps from Jul–Sep 2026 that will keep pinging; PR #7 (CodeQL Swift analysis) and PR #16–15/14/9/4 are security-relevant and worth merging or closing in one sweep.
2. **PR #12 is a large unmerged feature** (+6.5k lines, build-110 GGUF/MLX audit fixes) that partially shipped as sideload builds but never merged to main — decide to merge or retire.
3. **PR #18 (opened yesterday)** drops the coreai-models manifest Dependabot flagged — triages away Dependabot noise in `Packages/coreai-models`.
4. **No issues, no `v*` version tags** — releases use `sideload-*` tags only; CHANGELOG compare-links at the bottom of CHANGELOG.md point to `v3.2.5`/`v3.2.6` tags that do not exist.
5. **Local checkout is not on main and is dirty** — the 3.5.x build metadata changes are sitting uncommitted on `codex/llama-v0.4.0-testing`.

---

## 2. Changelog timeline (every update, chronological)

_Dates for TestFlight/ASC builds come from MEMORY.md release bullets; source-release dates from git/CHANGELOG. Builds 3.3–3.5.x were never committed to git (convention), so their exact upload dates are only partially recorded._

### 2026-07-11 — TestFlight 3.2.0 (28)
- First TestFlight build; uploaded, processed, distributed to internal `test` group.

### 2026-07-18 — TestFlight 3.2.3 (66) and (67)
- **(66)** Voice Mode orb-lag fixes, karaoke sync fixes; new Waveform/Aurora/Orbit voice themes. Shipped via `fastlane beta`.
- **(67)** Audio pipeline: `AudioPlaybackService` reconnects player→mixer only when idle (fixes sped-up/skipping speech), `AVAudioConverter` rate conversion, chunk anchored at real playhead, karaoke can't leap ahead. Motion: 120 FPS cap for cheap themes, dt-normalized EMA (attack τ 0.077s / release τ 0.26s). New neon-eye default app icon with classic pink as alternate icon + picker in Settings → Appearance.

### 2026-07-25 — TestFlight 3.2.4 (80) and (81)
- **(80)** Storage-backed paging for imported large GGUF models (experimental mmap-backed CPU/storage path; normal accelerated loading stays default; MLX unaffected).
- **(81)** Hermes Agent / OpenAI-compatible Local API tool calling: function tools, tool-choice modes, streaming, parallel tool calls, assistant/tool replay, Hermes custom-provider options, OpenAI text-part content arrays.

### 2026-07-26 — TestFlight 3.2.4 (85) and (86)
- **(85)** Installed-model export to Files; Files visibility for Documents/HFModels; one-shot oversized-MLX experimental load after explicit risk acceptance.
- **(86)** Qwen 3.5 response-length regression fix (removed accidental shared Bonsai 27B 128-token output cap; kept Qwen's bounded 2K 4-bit rotating KV cache). 38 focused memory/device tests pass.

### 2026-07-29 — Open-source release day (repo created; source releases 3.2.5 & 3.2.6)
- Repo `ios-local-llm` published on GitHub; identity standardized from "OnDeviceiOS".
- **3.2.5 source release:** open-source governance, provenance, validation, security-model, citation, SBOM, coding-agent docs; reproducible llama.cpp/whisper.cpp framework build tooling; standalone VoiceAgentOrb licensing; dependency lockfiles synced; Qwen3 license corrected to Apache-2.0; Clang warnings + static analyzer checks; responsible-disclosure guidance. (PRs #2, #3, #5 merged)
- **3.2.6 source release:** OpenSSF Scorecard with public results + code-scanning upload; reproducible source-release archives with SHA-256 checksums and GitHub/Sigstore provenance attestations; release-verification instructions. (PR #6 merged)

### 2026-08-07 → 2026-08-20 — Sideload era 3.2.6 (IPA builds 102–110)
- Branding workbench as "OnDevice Local AI Studio"; Local API Server marked Beta with project page links (Aug 6–9).
- AltStore source published (PR #11 merged Aug 8) + icon fix.
- Builds 105/106/108/109/110 released as verified sideload IPAs (Aug 13–20).
- **Local API server shipped (PR #10, merged Aug 19):** OnDeviceLAS 3.2.6 (143) with streaming.

### 2026-08-16 — 3.2.7 feature landing (source commit; IPA builds Aug 20+)
_This batch is recorded under `## [3.2.7]` in CHANGELOG.md (dated 2026-09-05); builds 110–114 released Sep 4–21._
- **Added:** in-chat streaming, approval, running-tool, citation, and image-generation cards; **True Continue** (resume the same assistant turn reusing live KV cache, no fake "please continue"); standard imported GGUFs reuse matching prompt-prefix KV across turns.
- **Changed:** llama.cpp bumped to v0.4.0 with compatible sampler calls; silver eye icon + splash; consistent chat typography; smoother voice feedback; reduced-motion Lens transitions.
- **Fixed:** imported GGUF assistants get chat template/sampler/system+tool prompts; MLX seed & frequency/presence penalties applied; Local API reports real token usage; truncated replies labeled; Gemma templates fold system prompt once; GGUFs no longer inherit MLX output cap; Ornith continuation resumes at correct KV position; speculative prefetch only while charging + thermally nominal; imported/manually-copied GGUF models registered in installed-model registry (build 113).
- **PR #12** tracks this work on GitHub but remains OPEN (never merged).

### 2026-08-31 — AltStore suite refresh
- Updated AltStore source with latest sideload builds + unlocked CompressKit.

### 2026-09-04 → 2026-09-21 — 3.2.7 sideload IPAs (111, 112, 114)
- Build 112: llama.cpp v0.4.0 release IPA; 114 (Sep 21) the last 3.2.7 sideload.

### 2026-09-05 — OnDevice Core 1.0.0 (10) — iOS 27 sideload
- First "OnDevice Core" build for iOS 27 devices (Core AI line), added to AltStore source.

### 2026-09-23 → 2026-09-27 — OnDevice LAS 3.2.6 (144 / 145 / 146)
- **(144)** new icon; **(145)** refreshed icon.
- **(146)** "kernel memory limit": model memory admission trusts the kernel-reported per-app limit; recorded measured load peaks; context sized from free memory; replies run to 8K tokens with automatic continuation.
- Post-146 fixes ported for Max (stop/wipe/sync/model-deletion fixes; trust kernel-reported app memory limit) — merged to main 2026-09-27.

### 3.3 series — App Store candidates (builds 118 / 120 / 123, dates not committed)
- **3.3 (118):** preserves App Store identity, shared storage, CloudKit container, credential namespaces when upgrading from App Store 3.2.4; Share extension content via App Group inbox; legal-action accessibility + Turkish safety/download translations; MLX pinned one-bit fork; Spotlight removal during data reset; shorter startup animation honoring Reduced Motion/VoiceOver; rating pre-prompt removed; local safety checks of image prompts + generated images with separate parental PIN; replacement build for the ASC 3.3 draft.
- **3.3.1 (120):** performance — convert only requested history page, serialize model-storage scans, avoid unchanged readiness publishes, paired Lens services once per shell; a11y — 44-pt image-generation options target, PIN-form scrolling; release prep — 12 iPhone + 6 iPad screenshots × 6 languages (ar, en-US, el, pt-PT, ro, ru), localized What's New.
- **3.3.2 (123):** Local API Server tile + dedicated API workspace (start/stop/restart, separate listener/model readiness, no implicit downloads, model cleanup, pinned HTTPS recipes for OpenAI/Anthropic/Ollama, 8 documented routes, API-key rotation, device-only clipboard, port validation); iPhone Duo/a11y (sidebar reveal control, 44-pt touch targets, composer row above keyboard); localized release notes for six languages + TestFlight testing instructions.
- **3.3.3:** simplified OnDevice Core AI Studio design (quieter surfaces, redesigned Models page, downloaded models separated from discovery, focused detail sheets, refined composer); full 15-language interface catalogs incl. share extension; applied locale + Arabic RTL without discarding drafts; offline localization audit.
- **3.3.4:** optional **Core AI** text inference on supported physical iOS 27 devices (coordinated residency, memory admission, thermal cancellation); 15 pinned text packs with license links, validated installation, cancellation, storage totals; iOS 18/MLX/GGUF/Simulator support preserved; hardened document import limits, knowledge-base cleanup, web-fetch limits, address validation; 15-language Core AI library controls.

### 3.4 — App Store candidate (date not committed)
- LFM3 family: LFM3 1.7B text, LFM3 VL 2B, LFM3 Audio 2B, LFM3 Omni 2B GGUF presets with pinned revisions, file allowlists, verified projectors.
- Native LFM3 Audio/Omni voice turns (16 kHz mic input, 24 kHz speech output) under existing residency/thermal/cancellation/approval policies.
- Native LFM3 `<tool>` function decoding in chat, Voice and local API with strict validation.
- QAD LFM3 VL checkpoint + Q8 projector, low-temperature vision prompt, single-residency 4K Lens profile; Assistant image turns fall back across installed VLMs; conversation model preserved across vision handoffs.
- GGUF vision pair discovery under HFModels/GGUFModels and `local_<name>` imports; optional prompt on native `describe_image`; in-place LFM3 VL download offer.
- Image-generation install guidance stays visible before the parental lock.

### 3.5.1 — Build 148 (date not committed)
- Private Cloud Compute stays opt-in (local-only entitlements default; `FM_PCC` enabled explicitly after managed-capability verification); restricted research model artifacts removed from bundle; required local image-safety classifier in Release.
- Rewritten usage descriptions (camera/photo/mic/local-network) matching Lens, voice conversations, Mac Bridge, Local API Server; `_localllm._tcp` Bonjour advertised.
- Landscape allowed (`UIRequiresFullScreen` off); legacy `codelens` URL scheme kept.
- Local API bounded: concurrent-connection cap + request-size cap without valid key.
- 15-language Live mode/voice-catalog/speech labels; SF Symbol names excluded from localization audit.
- First-run legal documents fixed (paragraph joining, markdown rendering, tappable links, real "read to the end" gate, explicit Close, "OnDevice LLM" copy).
- Assistant answers laid out as separate blocks (headings/lists/quotes/tables) instead of one line.
- Web-search answers: heading + short answer + [n] citations; sources card lists every fetched source.
- Onboarding: 44-pt skip, "Not now" model picker, recommended follows device-tier model, VoiceOver-hidden decoration.
- Accessibility: RTL-mirrored chevrons, Dynamic Type in Code mode/Diagnostics/activity cards/voice views, 4.5:1 contrast fixes.
- MLX dependencies updated: mlx-swift-lm 3.32.3 + PrismML fork, swift-transformers 1.3.5, swift-jinja 2.5.2; FastVLM adopts new `LanguageModel.prepare` requirement.

### 3.5.2 — Build 155 (uploaded 2026-11-14)
_Reliability pass on top of build 154._
- Downloads: pause/resume keeping every file; cancel asks first (it deletes); terminated downloads resume on next launch and attach to in-flight system transfers; "Clean up partial downloads" no longer deletes paused downloads; resume no longer refused for unneeded disk space; GGUF search downloads one quantization (4-bit preferred) + projector with honest pre-download size; SmolVLM2 downloads only its Q8 pair (~520 MB); curated MLX/vision entries pinned to reviewed revisions.
- Chats: turns saved on send and on backgrounding; switching/clearing a chat stops the in-progress reply; unreadable history files reloaded instead of discarded; landscape composer stays above the keyboard.
- Voice: answers reveal sentence-by-sentence with word-fill highlight; no repeated sentences; recovered playback highlight; stalled playback/route changes/calls/backgrounding recovery; no surprise model downloads.
- Image generation: stops before decoding on cancel/background; Try Again re-enables a disabled model; stale status line dropped.
- Reset App Data also deletes iCloud conversation copies (or marks them for next sync).
- Local API: deadline-cut streams report truncated finish reason.
- Lens: paused-caption explanation, cancelled-caption late results ignored, library photos decoded downsized off-main.
- Imports: model-folder imports keep dotted names and move (not copy) Files picks; failed imports cleaned up.
- Removed: Download Center screen, widget-less download Live Activity, FastVLM repo setting, "Clone your voice" placeholder.
- All six beta-localization "What to Test" notes attached 2026-11-14.

### 3.5.3 — Builds 157–159 (latest; date not committed)
- **Build 157** (SenseNova model test) reverted.
- **Build 158:** Apple **Liquid Glass** button styles (`glassButton`: prominent glass for main actions, system capsule shapes); one layout scale (spacing 16 pt × φⁿ, Apple text styles, radii/tiles from four values each, `scripts/audit_ui_metrics.py` guard); removed Running-tool/Image-generated toasts; no cross-fade on finished replies; Analyze button on generated image; Get-button width fixes.
- **Build 159:** **Models tab rebuilt** — My Models shows storage used/free, per-surface model usage (Assistant/Lens/Voice), grouped installed-model list incl. Core AI packs, search/filters from six models up; Discover shows top-3 per category with See-all and one-tap Get with in-place progress, parental PIN on image rows, Edge mode + Guided setup into •••; model pages follow the App Store layout (info list: size/memory fit/devices/runtime/repository); recommended setups grouped with low-storage/memory warnings; KittenTTS Mini and Kokoro sizes corrected; standard Downloads title bar, one number format; single grouped Settings list, sentence-case labels, native switches, dark Lens notices, one Home/Voice tile size; interface text in all 15 languages, App Store "Get" wording.

### Recent GitHub-only updates
- **2026-10-01** — commit `f38d6ce`: retired public AltStore distribution ahead of App Store releases.
- **2026-11-05** — PR #17 merged: Studio and LAS readers point to current app pages.
- **2026-11-18** — PR #18 opened: drop unused coreai-models Python manifest flagged by Dependabot.
