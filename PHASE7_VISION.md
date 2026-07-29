# Phase 7 — Vision / Multimodal Agent Capabilities

**Status:** Spec captured, phasing approved, implementation paused.
**Resume by:** Reading this doc, picking the first slice (default: Phase 7a), and
running through the existing TaskList that begins at the "Phase 7 — Vision" section.

This document is a deliberate memory artifact. The full spec the user provided
in chat is preserved verbatim in [Section 1](#section-1-original-spec-verbatim)
so a future session can resume without re-eliciting requirements. Section 2 is
my phasing plan, accepted by the user. Section 3 is the inventory of what is
already in the codebase. Section 4 lists the three pending decisions that gate
the start of implementation.

---

## North-star summary

Add optional vision capabilities to the MacBridge agent. If the iPhone's
selected local model supports multimodal input, the Mac sends screenshots
(active window, full display, simulator) over the existing agent transport.
The iPhone feeds the image into its local VLM (FastVLM / SmolVLM2) and
returns a structured visual summary that the reasoning model can use to
decide next steps. Vision is **never** mandatory — text-only models keep
working, the spec is opt-in per send.

This dramatically increases the agent's usefulness:
- Inspect Simulator UI for layout bugs
- Read Xcode error overlays the bridge can't textually scrape
- Check App Store screenshot crops
- Diagnose blank/loading/crashed states
- Compare before/after screenshots after a patch

---

## Section 1 — Original spec (verbatim)

> ==================================================
> VISION / MULTIMODAL AGENT CAPABILITIES
> ==================================================
>
> Add optional vision capabilities to the MacBridge Agent system.
>
> Goal:
> If the selected local model on iOS supports multimodal input, MacBridge should send screenshots or cropped UI images to the iOS app so the local vision model can visually inspect the Mac screen, Xcode, Simulator, or app UI.
>
> This dramatically improves the agent because it can see:
> - actual Simulator UI
> - broken layouts
> - blank screens
> - wrong button positions
> - camera/Lens tab state
> - App Store screenshot issues
> - onboarding flow problems
> - error dialogs
> - permission prompts
> - iMessage/Share Extension UI state
> - Xcode visible errors
> - terminal output layout
> - visual model preview/crop problems
>
> Do not make vision mandatory.
> The system must work with text-only local LLMs too.
>
> ==================================================
> VISION ARCHITECTURE
> ==================================================
>
> MacBridge captures visual context.
> iOS app decides whether the active local model supports image input.
>
> Flow:
>
> 1. iOS agent asks MacBridge for visual context:
>    - simulator screenshot
>    - active window screenshot
>    - full display screenshot
>    - cropped region
>    - frontmost app screenshot
>    - Argent screenshot, if Argent is available
>
> 2. MacBridge captures image.
>
> 3. MacBridge compresses and sends image metadata + image payload/reference to iOS.
>
> 4. iOS app receives image.
>
> 5. If current model supports vision:
>    - feed image into multimodal model
>    - ask model to describe UI state or decide next action
>
> 6. If current model is text-only:
>    - show image to user
>    - optionally use local OCR if implemented
>    - ask user for manual confirmation
>    - return fallback message to agent
>
> ==================================================
> MODEL CAPABILITY DETECTION
> ==================================================
>
> Add a ModelCapability system to the iOS app.
>
> Each model profile must declare:
>
> ```json
> {
>   "id": "model_id",
>   "displayName": "SmolVLM / FastVLM / Gemma / Qwen / etc",
>   "supportsText": true,
>   "supportsVision": true,
>   "supportsToolCalling": true,
>   "supportsStreaming": true,
>   "maxImageResolution": {
>     "width": 1024,
>     "height": 1024
>   },
>   "preferredImageFormat": "jpeg | png | heif",
>   "visionPromptStyle": "ui_inspection | general_vlm | document_ocr"
> }
> ```
>
> Rules:
> - Never assume every model supports vision.
> - Before sending image into the model, check supportsVision.
> - If supportsVision is false, use fallback.
> - Allow user to manually select which model handles vision tasks.
> - Allow separate models:
>   - text reasoning model
>   - vision inspection model
> - Example:
>   - Qwen text model for reasoning
>   - FastVLM / SmolVLM for screenshots
> - If two-model routing is supported, use vision model to summarize screenshot, then feed summary to text model.
>
> ==================================================
> NEW MACBRIDGE TOOLS
> ==================================================
>
> Add these tools to the MacBridge ToolRegistry.
>
> ### 1. vision.capture_active_window
>
> Risk: SAFE_READ if Screen Recording permission is granted and user enabled screenshot context.
>
> Arguments:
> ```json
> {
>   "includeCursor": false,
>   "scale": 0.5,
>   "format": "jpeg",
>   "quality": 0.82,
>   "maxWidth": 1280,
>   "maxHeight": 1280
> }
> ```
>
> Returns:
> ```json
> {
>   "imageId": "uuid",
>   "source": "active_window",
>   "width": 1280,
>   "height": 720,
>   "format": "jpeg",
>   "mimeType": "image/jpeg",
>   "base64": "...",
>   "capturedAt": "ISO-8601",
>   "frontmostApp": "Xcode",
>   "windowTitle": "LensView.swift"
> }
> ```
>
> ### 2. vision.capture_display
>
> Arguments:
> ```json
> {
>   "displayId": "main",
>   "includeCursor": false,
>   "scale": 0.5,
>   "format": "jpeg",
>   "quality": 0.82,
>   "maxWidth": 1600,
>   "maxHeight": 1600
> }
> ```
>
> Returns same image payload.
>
> ### 3. vision.capture_simulator
>
> Purpose: Capture current iOS Simulator screen.
>
> Implementation priority:
> - First try Argent screenshot if available.
> - Fallback to `simctl io screenshot`.
> - Fallback to active window capture.
>
> Arguments:
> ```json
> {
>   "deviceName": "iPhone 17 Pro Max",
>   "format": "png",
>   "maxWidth": 1290,
>   "maxHeight": 2796
> }
> ```
>
> Returns:
> ```json
> {
>   "imageId": "uuid",
>   "source": "simulator",
>   "deviceName": "iPhone 17 Pro Max",
>   "width": 1290,
>   "height": 2796,
>   "format": "png",
>   "base64": "...",
>   "capturedAt": "ISO-8601"
> }
> ```
>
> ### 4. vision.capture_region
>
> Purpose: Capture a specific region of screen/window/simulator.
>
> Arguments:
> ```json
> {
>   "source": "display | active_window | simulator",
>   "x": 0,
>   "y": 0,
>   "width": 500,
>   "height": 500,
>   "scale": 1.0,
>   "format": "jpeg",
>   "quality": 0.85
> }
> ```
>
> ### 5. vision.describe_screen
>
> This is an iOS-side virtual tool, not a Mac execution tool.
>
> Purpose: After receiving an image, the iOS app feeds it to the selected local vision model and returns a structured visual summary.
>
> Input:
> ```json
> {
>   "imageId": "uuid",
>   "task": "ui_inspection | bug_detection | layout_check | simulator_state | app_store_screenshot_check | text_extraction",
>   "userQuestion": "What is wrong with the Lens tab UI?"
> }
> ```
>
> Output:
> ```json
> {
>   "summary": "The Lens tab is visible. The preview is stretched vertically and the capture button overlaps the prompt box.",
>   "visibleElements": [
>     "Lens title",
>     "model picker",
>     "camera preview",
>     "capture button",
>     "prompt text box",
>     "result panel"
>   ],
>   "detectedIssues": [
>     {
>       "type": "layout_overlap",
>       "description": "Capture button overlaps the prompt input.",
>       "confidence": 0.82
>     }
>   ],
>   "suggestedNextActions": [
>     "Read LensView.swift",
>     "Inspect camera preview aspectRatio modifier",
>     "Capture another screenshot after rotation"
>   ]
> }
> ```
>
> ==================================================
> IMAGE TRANSPORT REQUIREMENTS
> ==================================================
>
> Images can be large, so implement safe transport.
>
> Rules:
> - Downscale screenshots before sending unless full resolution is requested.
> - Prefer JPEG for Mac/Xcode screenshots.
> - Prefer PNG for Simulator UI screenshots when text sharpness matters.
> - Default max dimension: 1280 px.
> - Default JPEG quality: 0.82.
> - Max image payload size default: 3 MB.
> - If image is larger:
>   - downscale
>   - compress
>   - or chunk transfer
> - Add chunked image transfer only if needed.
>
> Do not store screenshots permanently by default.
> Screenshots should be session-scoped.
> Auto-delete temporary screenshot files after session ends.
> Allow user to clear screenshot cache.
>
> Privacy:
> - MacBridge must show when screenshot sharing is enabled.
> - MacBridge must show each screenshot capture in Action Log.
> - User can disable screenshot context globally.
> - User can require approval for every screenshot.
> - Redact screenshot thumbnails in logs unless user enables thumbnails.
> - Never capture screen silently while disconnected.
> - Never capture background periodically without active session.
>
> ==================================================
> VISION AGENT LOOP
> ==================================================
>
> Add visual observe-think-act loop.
>
> Example flow:
>
> User: "Open the Simulator and check why the Lens tab looks wrong."
>
> Agent loop:
> 1. Request simulator launch.
> 2. Request vision.capture_simulator.
> 3. iOS receives screenshot.
> 4. If current model supports vision:
>    - call local multimodal model with screenshot.
> 5. Vision model returns structured UI summary.
> 6. Text reasoning model decides:
>    - read LensView.swift
>    - patch aspect ratio / safe area / preview crop
>    - rebuild
>    - relaunch
>    - capture screenshot again
> 7. Compare before/after screenshots.
> 8. Return final result.
>
> The loop should support:
> - screenshot before fix
> - screenshot after fix
> - visual comparison summary
> - stop after max steps
>
> Max visual tool calls per user request: default 5
>
> ==================================================
> VISION PROMPT TEMPLATES
> ==================================================
>
> ### Template: UI Inspection
>
> You are inspecting a screenshot from an iOS Simulator or macOS app.
> Describe only what is visible.
> Do not guess hidden code.
> Focus on:
> - visible screen name
> - main UI elements
> - layout problems
> - cropped/overlapping elements
> - unreadable text
> - broken spacing
> - wrong safe area
> - disabled buttons
> - loading/error states
> Return structured JSON with:
> - screenSummary
> - visibleElements
> - detectedIssues
> - confidence
> - suggestedNextActions
>
> ### Template: Simulator State
>
> You are inspecting an iOS Simulator screenshot.
> Determine:
> - which app/screen is open
> - whether the app is loading, crashed, blank, or usable
> - whether there are alerts/permission prompts
> - which UI element should be tapped next for the user's task
> Return JSON:
> ```json
> {
>   "state": "usable | loading | blank | crashed | permission_prompt | unknown",
>   "screen": "...",
>   "nextAction": {
>     "type": "tap | type | wait | read_file | stop",
>     "targetDescription": "...",
>     "approximateCoordinates": { "x": 0, "y": 0 }
>   },
>   "issues": []
> }
> ```
>
> ### Template: Layout Bug Finder
>
> Inspect this app screenshot for visual/layout bugs.
> Focus on: overlap, clipping, empty space, wrong alignment, button too close to edges, text unreadable, keyboard covering input, content behind tab bar, wrong aspect ratio, stretched camera preview, missing loading/error state.
>
> Return:
> ```json
> {
>   "layoutQuality": "good | acceptable | broken",
>   "issues": [
>     {
>       "type": "...",
>       "description": "...",
>       "severity": "low | medium | high",
>       "confidence": 0.0
>     }
>   ],
>   "recommendedFixAreas": [
>     "SwiftUI safeAreaInset",
>     "aspectRatio",
>     "GeometryReader",
>     "ScrollView keyboard handling"
>   ]
> }
> ```
>
> ==================================================
> SIMULATOR SCREENSHOT IMPLEMENTATION
> ==================================================
>
> For Simulator screenshot fallback, use:
> ```
> xcrun simctl io booted screenshot /tmp/macbridge-sim.png
> xcrun simctl io <UDID> screenshot /tmp/macbridge-sim.png
> ```
> Then load → resize/compress → base64 → send.
>
> If Argent is available: prefer Argent screenshot/inspect; normalize result into same `vision.capture_simulator` schema.
>
> ==================================================
> MAC SCREEN CAPTURE IMPLEMENTATION
> ==================================================
>
> Use ScreenCaptureKit where possible.
>
> Implement:
> - Permission check for Screen Recording.
> - Capture active display.
> - Capture active window if possible.
> - Fallback to CGWindowListCreateImage if available and allowed.
> - Make sure capture runs off main thread.
> - Resize image efficiently.
> - Strip metadata before sending.
> - Do not include cursor by default.
>
> ==================================================
> iOS IMAGE INPUT HANDLING
> ==================================================
>
> Add ImageArtifact model:
> ```swift
> struct ImageArtifact {
>     let id: UUID
>     let source: ImageSource
>     let width: Int
>     let height: Int
>     let mimeType: String
>     let data: Data
>     let capturedAt: Date
>     let metadata: [String: String]
> }
> ```
>
> Add image preview cards in AgentChatView:
> - thumbnail
> - source
> - dimensions
> - captured time
> - button: Analyze with vision model
> - button: Delete
>
> When feeding to model:
> - Convert to required input format.
> - Resize to model max resolution.
> - Preserve aspect ratio.
> - Use model-specific preprocessing.
> - Handle failure gracefully.
>
> If no vision model, show:
> "This selected model does not support images. Switch to a vision-capable model or continue with text-only context."
>
> ==================================================
> MULTI-MODEL ROUTING
> ==================================================
>
> Reasoning model: stronger text/code model — planning + patching.
> Vision model: smaller multimodal model — screenshots.
>
> Flow:
> 1. Vision model summarizes screenshot.
> 2. Reasoning model receives: user request + screenshot summary + tool results + code context.
> 3. Reasoning model decides next tool call.
>
> Add setting: "Use separate vision model for screenshots"
>
> ==================================================
> UI SETTINGS
> ==================================================
>
> iOS settings:
> - Enable screenshot context
> - Ask before requesting screenshots
> - Preferred vision model
> - Max screenshot size
> - Auto-analyze simulator screenshots
> - Delete images after session
>
> MacBridge settings:
> - Allow screenshot sharing
> - Require approval before every screenshot
> - Allow simulator screenshots
> - Allow active window screenshots
> - Allow full display screenshots
> - Max image size
> - Clear temporary images
>
> ==================================================
> ACCEPTANCE CRITERIA
> ==================================================
>
> Feature complete when:
> 1. MacBridge can capture a Simulator screenshot.
> 2. MacBridge can send the screenshot to iOS.
> 3. iOS displays the screenshot in the agent chat.
> 4. iOS detects whether selected model supports vision.
> 5. If vision is supported, iOS feeds screenshot to local multimodal model.
> 6. Vision result is converted into structured summary.
> 7. Reasoning agent can use the visual summary to decide next steps.
> 8. Screenshot capture appears in MacBridge action log.
> 9. User can disable screenshot sharing.
> 10. App still works with text-only models.
>
> Text-only local model: MacBridge sends selected code/logs/errors.
> Vision local model: MacBridge sends screenshots + UI state.

---

## Section 2 — Phasing plan (accepted by user)

| Phase | Scope | Est. hours | Smoke test |
|---|---|---|---|
| **7a** | Mac `vision.capture_active_window` via `CGWindowListCreateImage` + Screen Recording permission row on dashboard + base64 in existing tool_result + iOS renders image inline in chat + if FastVLM/SmolVLM2 active, feed image through and append the description | 2–3 | iPhone asks `/mac screenshot xcode`, sees the image, sees FastVLM's description |
| **7b** | `vision.capture_simulator` (`simctl io booted screenshot`), `vision.capture_display`, Argent screenshot as simulator fallback, iOS `ImageArtifact` model | 2–3 | Simulator + display capture both work end-to-end |
| **7c** | `vision.capture_region`, ScreenCaptureKit migration (replaces CGWindowList — sharper + Sonoma-blessed), `tool_chunk` framing for >1 MB payloads | 3 | Region capture works; large payloads stream cleanly |
| **7d** | Two-model routing (vision summarizes → reasoning decides), structured JSON output schemas, vision agent loop with before/after comparison, max-step guard (default 5) | 3–4 | "Find the layout bug in this Simulator screen, patch it, rebuild, compare" works one-shot |
| **7e** | Settings (require-approval, max size, auto-delete, "preferred vision model"), action log thumbnails, redaction defaults | 2 | Privacy posture matches spec |

**Total estimate:** 12–15 hours of focused work plus per-phase testing.

---

## Section 3 — Inventory (what's already in the codebase)

iOS side — most vision plumbing already exists, only needs to be exposed
outside the Lens tab:

```
IOSLocalLLM/Services/
  FastVLMService.swift            ← runs FastVLM on UIImage
  FastVLMPromptBuilder.swift      ← prompt templates per task
  FastVLMRepoAutoDiscovery.swift
  FastVLMModelBundleValidator.swift
  FastVLMCoreMLStub.swift
  MLXVisionService.swift          ← runs SmolVLM2 + other MLX VLMs
  VLMCapabilities.swift           ← partial capability registry, per-VLM
  BundledVLMInstaller.swift
  SmolVLM2Rescue.swift
  OCRService.swift                ← on-device OCR as text-only fallback
```

iOS side — what's missing:
- `AgentChatView` doesn't exist; `/mac` lives inside `CodingAssistantView`.
  Image rendering needs to land there.
- `ModelCapability` per-model-id registry (current `VLMCapabilities` is
  per-VLM only — text models like Qwen3-4B aren't represented).
- `ImageArtifact` model.
- Multi-model routing (chat = single model today).

Mac side — nothing exists for vision:
- No ScreenCaptureKit usage.
- No `CGWindowListCreateImage` usage.
- No `simctl io` wrapper.
- No Screen Recording TCC permission row on the dashboard.
- No thumbnail handling in the audit log.

Wire side:
- Envelopes are JSON. Embedding a 3 MB base64 string works once but is
  wasteful; `tool_chunk` framing (already named in CLAUDE.md's protocol
  section) needs implementation for streaming larger payloads.

Argent:
- `argent run screenshot` exists. Discovered in `argent tools` output
  during the build-6 detection work. Easy to wrap for the
  `vision.capture_simulator` Argent-preferred path.

---

## Section 4 — Pending decisions (3 questions to answer before any code)

These were asked in chat and dismissed; they need answers to start:

1. **First slice — smoke test or production API?**
   - (a) Phase 7a with `CGWindowListCreateImage` (fastest, deprecated, ~2-3h)
   - (b) Skip to ScreenCaptureKit in 7a (modern, +2h plumbing)
   - (c) Plan only — no code yet

2. **Bundling — already answered. Build 7 fixes shipped separately.**
   This decision is already resolved: the pill + load-a-model + cert-pin
   fixes ship as Mac PKG build 7 and iOS 1.5.6 build 6. Phase 7 will ship
   as build 8 / 1.5.7 once started.

3. **First vision tool to wire first?**
   - (a) Active window (highest leverage for Xcode debugging)
   - (b) iOS Simulator (best for app development)
   - (c) Full display (broadest context, biggest privacy surface)

---

## Section 5 — Resume protocol

To resume Phase 7 in a future session:

1. Read this entire document.
2. Pick answers for the three Section 4 decisions (or ask the user).
3. Open `TaskList`. Tasks #1–37 cover Phases 1–6 and are completed.
   Create new tasks under a "Phase 7 — Vision" header, one per slice.
4. Start with Section 4's Decision 1 + 3 to choose the first PR.
5. Implement, build, test, ship as iOS 1.5.7+ / Mac PKG build 8+.

---

## Section 6 — Risks / open questions

- **TCC for Screen Recording** is harsher than Accessibility. macOS requires
  a hard relaunch after the user grants — there's no in-process refresh path.
  Plan to detect grant state and surface a "Quit & Relaunch" affordance.
- **Image size budget on Wi-Fi.** A 1280×720 JPEG @ q0.82 averages ~200 KB;
  fine. A Simulator portrait PNG at 1290×2796 can hit 4–5 MB. We'll need
  the `tool_chunk` framing OR aggressive downscale (max-dim 1280 for
  Simulator too, with the user able to opt into full-res).
- **VLM context windows.** FastVLM is 4K context; SmolVLM2 similar.
  Don't embed huge images and long text in one call — chunk the
  "vision summary then reasoning" so the reasoning model only gets the
  ~200-token summary, not the raw image.
- **Two-model routing perf.** Running FastVLM AND Qwen back-to-back will
  pressure RAM. Need to test that the loaded model unload-on-switch logic
  doesn't churn through memory and trigger Jetsam kills.
- **Argent simulator capture vs simctl io.** Argent's screenshot is more
  flexible (can target specific devices including Android), but `simctl io
  booted screenshot` is zero-dep and faster. Use simctl by default and
  Argent only when requested.

---

_Last updated: 2026-05-22 by claude during build-7-bundling work._
