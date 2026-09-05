# CoreAI Studio audit — 5 September 2026

Scope: targeted source audit of chat streaming/rendering, voice presentation, Lens output, typography, and source organization; comparison with `/Users/m/Desktop/CodeLens`. This is not a whole-repository correctness certification or measured CPU/GPU profile. Application code was not changed during this audit.

The Desktop CodeLens directory is a sibling Swift/SwiftUI iOS/Mac Catalyst source tree. Most relevant features are shared, and several newer protections exist only in CoreAI Studio. File separation in CodeLens must not be mistaken for missing features here.

## Prioritized findings

### 1. P1 — Chat code blocks are parsed as reasoning or math

Source: `IOSLocalLLM/Views/CodingAssistantView.swift:5718` (`parseBlocks`).

The parser searches the entire remaining string for `<think>`, then `$$`, before considering a code fence. It does not select the earliest delimiter or track whether it is inside fenced code. A Bash code block containing `echo $$` loses its code-block structure; XML containing `<think>literal</think>` becomes a reasoning block.

Verified by executing the actual extracted Foundation parser with two synthetic inputs:

- Fenced Bash containing `echo $$` produced two text blocks and no code block.
- Fenced XML containing `<think>literal</think>` produced text, a thinking block, and an empty code block.

Fix: one ordered block tokenizer that treats fenced code as opaque, preserves incomplete fences, and only interprets reasoning markers outside code. Add regression cases for shell PID syntax, literal XML tags, math before/after code, and truncated output. Preserve the streaming selection safeguard.

### 2. P2 — Generation completion overrides the reader's scroll position

Source: `IOSLocalLLM/Views/CodingAssistantView.swift:506`.

`followedGenerationAtBottom` captures position when generation begins. It is never updated when the reader scrolls away. On completion, the delayed task forces `isNearConversationBottom = true` and scrolls down using that stale snapshot. The 220 ms delay also provides another opportunity for a reader gesture or conversation change before the scroll executes.

Fix: track explicit follow intent and user scroll phase; re-check both current intent and conversation/generation identity after suspension. Cancel pending re-anchoring when the user scrolls or changes conversations. Test starting at bottom, scrolling up during generation, and finishing without moving the viewport. Tool-approval changes at lines 403–410 also scroll unconditionally; expose a pending-action indicator without moving a reader who opted out of following.

### 3. P2 — Lens/code review hides unfinished fenced code

Source: `IOSLocalLLM/Views/AnalysisPanelView.swift:689` (`MarkdownTextView.blocks`). Callers include CodeModeView, AnalysisPanelView, and LegalDocumentView.

Code lines are appended to views only on a closing fence. End-of-input returns `views` without flushing `codeLines`. An interrupted or token-limited response such as an opening Swift fence followed by a declaration displays none of that declaration.

Fix: flush an open code block at end-of-input. Share the eventual block tokenizer with Assistant while retaining presentation differences. Verify both streaming and stopped/truncated output.

### 4. P2 — “Follow speech” follows the end, not the spoken phrase

Source: `IOSLocalLLM/Views/Voice/KaraokeTranscriptView.swift:172`.

Every phrase-triggered scroll targets `karaoke-bottom`; the transcript is a single Text with no phrase anchors. When the full answer is present while speech is near the beginning, following hides the phrase being spoken. The earlier improvement made the button respond immediately but did not address this targeting problem.

Fix: stable phrase or paragraph anchors and scroll only when the active range exits the visible reading region. Retain manual-scroll opt-out. Test a multi-screen transcript with speech at beginning, middle, and end, including resuming follow while paused.

### 5. P2 — Reduce Motion is incomplete in chat

Sources: `CodingAssistantView.swift:369` (row scroll transition), `CodingAssistantView.swift:5530` (StreamingDots).

Rows fade, translate, and scale as they enter/leave the viewport without consulting Reduce Motion. The pre-token dots also repeat their scale animation unconditionally. The previous caret and voice dock changes do not cover these paths.

Fix: identity transforms for reduced motion, with a static or gentle opacity-only status indicator. Check both an already-running stream and a settings change during a stream. Keep the existing glass, palette, spacing, and hierarchy.

### 6. Performance candidate — Chat scroll throttling is based on characters, not time

Source: `CodingAssistantView.swift:396`.

Each body evaluation counts the full final String and watches 24-character buckets. Bucket changes start a new 120 ms animated scroll. Faster generation can cross buckets faster than animations settle; slower output can grow a line without crossing a bucket. This is not a guaranteed update-rate cap. String.count also traverses variable-width grapheme text.

Fix after measurement: maintain a cheap stream revision/length at publication, coalesce updates by elapsed time or rendered geometry, and use nonanimated following during active streaming. Cache completed parsed blocks and incrementally commit stable blocks rather than formatting the entire response differently only at completion.

Measure main-thread work and scroll hitch rate with short/long outputs, Unicode, code, and a reader scrolling away. No speedup is claimed by this source audit.

### 7. Performance candidate — Voice polling continues after speech ends

Source: `IOSLocalLLM/Views/Voice/VoiceIsolatedContainers.swift:63`.

The karaoke TimelineView is scheduled at 12 Hz whenever text is nonempty, without a playback or scene pause condition. The spoken cursor remains unchanged after completion, but the view continues requesting timeline work while the transcript remains visible. `refreshHighlight` additionally copies/mutates the attributed transcript when the spoken range changes; its cost on long answers needs measurement.

Fix: pause when playback cannot advance and when the scene is inactive, preserving text/phrase observation and resume behavior. Prefer a narrow playback flag rather than observing all audio state in the parent. Compare CPU while speaking, finished, paused, and backgrounded.

### 8. Design/accessibility — Reading sizes are improved, but controls still need a coherent scale

Sources: `Models/KoduTheme.swift:372`, `Views/CodingAssistantView.swift:5204`, and voice/model-picker metadata rows.

The shared conversation font fixes the primary text mismatch. Other `sans`/`mono` fallbacks still use fixed `.system(size:)`, while bundled `.custom` fonts scale with Dynamic Type. Behavior therefore differs when Geist is unavailable. Small image Analyze controls use 9 pt labels and padding rather than an explicit 44 pt hit region.

Fix: named semantic styles for body, secondary information, code, and controls, with matching scalable custom/system fallbacks. Expand hit regions without enlarging visual chrome. Validate accessibility text sizes, narrow iPhones, VoiceOver, and both bundled-font and fallback paths. Do not globally enlarge all metadata or remove useful visual hierarchy.

## What to adopt from Desktop CodeLens

| CodeLens source | CoreAI Studio status | Benefit and action |
| --- | --- | --- |
| `Views/CameraRootView.swift` | Same responsibility embedded in `ContentView.swift:362`; live-loop safeguards already present | Extract the existing CoreAI implementation into its own file. CodeLens root navigation is 358 lines; CoreAI root is 2,114 lines. This reduces coupling and review scope, not necessarily runtime work. |
| `Services/AssistantExecutionPolicy.swift` | MLX/GGUF policy types already begin in CoreAI `CodingAssistantService.swift:17` | Extract the current policies with their tests. Preserve CoreAI-specific budgeting; do not replace them with an older sibling implementation. |
| `Views/ModelDownloadRows.swift` | Equivalent controls already embedded near the end of CoreAI `ModelsManagerView.swift` | Extract row views and retain their direct downloader observation. The benefit is maintainability; per-row observation already exists here. |
| `Packages/VoiceAgentOrb` and isolated voice presentation | Shared foundation already present | Keep the separation of audio amplitude, transcript, and controls. Extend lifecycle pausing and tests rather than adding another orb/runtime. |

The focused comparison did not establish a compelling missing end-user feature to copy wholesale. The concrete benefits are source organization, shared regression tests, and deliberate convergence of presentation utilities.

Do not port the sibling's older Lens diagnostics: its `LensInferenceLoop.swift` describe breadcrumb prints the prompt, whereas this app omits it. The sibling VoiceConversationService also lacks this app's startup safety refusal and preferred-TTS-readiness checks. Preserve CoreAI routing, explicit execution-location UI, consent, and residency behavior.

## Suggested implementation order

1. Fix and test the block tokenizer and unfinished fences; prevent completion from stealing scroll position.
2. Make voice follow target the active phrase; pause idle transcript polling.
3. Complete Reduce Motion and semantic typography/hit-region coverage.
4. Extract CameraRootView, execution policies, and download rows using the current CoreAI source. Make no runtime changes in extraction commits.
5. Profile chat, voice, and Lens on a physical iPhone with representative local models; only then tune cadence and animation cost further.

## Validation and limits

The two Assistant parser failures were reproduced using a standalone Swift harness generated from the current parser. Remaining findings are source-backed behavior analysis or explicitly labeled measurement candidates.

The preceding polish pass passed Swift parsing and all 25 VoiceAgentOrb tests. It did not validate these new findings. Its Simulator build failed because CoreAIShared could not resolve `CoreAI` and ONNX Runtime's XCFramework copy phase failed. The open-source validator cannot run without this folder's missing Git metadata. Those limitations still prevent claiming full app tests, rendered-screen verification, or measured performance improvements.

## Implementation checkpoint — 2026-09-05

Implemented the first focused reliability and presentation stage:

- Shared fenced-code-aware block parsing for chat and analysis, preserving incomplete fences and literal reasoning/math markers inside code.
- Conversation follow ownership and a cancellable delayed completion scroll; time-based streaming scroll coalescing and reduced-motion handling.
- Shared conversation typography and voice transcript follow targets based on bounded Unicode-safe text segments; inactive speech timelines pause.
- Document imports use cancellation generations, commit-time capacity checks, isolated embedding jobs, and serialized background persistence. Clear/wipe invalidates pending imports.
- Benchmark callbacks are consumed in sequence, max-token limits use per-request overrides, and fallback stream-chunk counts are identified in the result UI.

Validation: generic iOS device Debug build succeeded after regenerating the project and restoring CocoaPods integration. All 17 focused parser/import/transcript policy checks and all 25 VoiceAgentOrb package tests passed. The repository validator cannot run because this working copy has no Git metadata. Full Simulator app verification remains blocked by the installed Simulator SDK's unavailable CoreAI module; device build success does not replace interactive chat, microphone, camera, or inference testing. Native model runtime upgrades and the remaining larger product changes are not completed by this checkpoint.

## Second implementation checkpoint — 2026-09-05

Document-context retrieval now embeds and scores an immutable index snapshot off the main actor. The chat composer displays preparation status, supports cancellation, and checks conversation, model, and attachment identity before starting generation. Excerpts supplied to each reply have stable document/chunk IDs and are stored with that reply. The Sources used sheet displays those saved excerpts without claiming they verify every generated statement. Optional persistence fields keep existing histories readable; added source round-trip and older-message decoding tests in StoredConversationTests.

Branding requested during this stage: replaced the default icon, icon preview, and shared small logo with the supplied silver eye. The Classic alternate remains selectable. Splash uses a high-resolution copy on a matching neutral background, with a brief entrance instead of the previous seven-second timeline. The system launch background uses the same named color. Verified layout using the actual splash SwiftUI source in an isolated iPhone 17 iOS 27 Simulator app; this is splash-only verification, not full app runtime QA.

The device build passed after the retrieval/source and initial branding changes. Focused policy checks remain 17/17. Full Simulator tests, including the new persistence tests, remain unavailable with this app's CoreAI dependency. Remaining roadmap work is not claimed complete.
