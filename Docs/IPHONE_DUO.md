# iPhone Duo support

Build with **Xcode 27.1 or newer**. The minimum runtime remains iOS 18. Full
Duo display use and vertical system bars are enabled by the SDK used to build
the app, not by an Info.plist capability or a device-name check. If multiple
Xcode installations are present, use the 27.1 developer directory as described
in [setup](../SETUP_INSTRUCTIONS.md).

## Adaptive behavior

- The same system `TabView` uses sidebar-adaptable navigation and, on iOS 27,
  prefers a sidebar where the system supports it. Compact windows retain
  system tabs. The selected tab, model residency policy, and bridge navigation
  requests stay in the existing `ContentView`.
- Home, Models, and Voices have native navigation hosts so the sidebar can
  still be revealed after it is hidden. Their existing content headings and
  the state owned by `ContentView` remain in place.
- Home uses minimum-width-driven card and action grids. Chat, Models, Voice,
  and Settings keep text and controls within a readable column.
- Models leads directly into search and role selection, without redundant
  zero-state inventory counters. Download progress and nonempty storage stay
  available. Role-grid minimum widths scale with Dynamic Type. Full role labels remain
  visible, with 44-point minimum control bounds. Metadata uses stronger,
  opaque reading colors in both appearances.
- Missing assistant weights lead to a model-selection action. Idle installed
  models offer Load; preparation copy is reserved for actual preparation.
  Automatic preparation and the status-bar Load action disallow downloads.
- Chat uses native system overflow on iOS 27, gives primary actions higher
  visibility, and adapts the model picker to an icon when bar space is narrow.
  Composer controls wrap at their minimum touch width while Send stays at the
  trailing edge; the same dictation view survives changes in column count.
  The composer occupies its own measured row above the keyboard. The clipped
  conversation viewport and intrinsic-height empty state stay above that row.
  Sheet completion and cancellation controls include symbols so the system
  can present them vertically.
- Dashboard actions, the chat composer, Lens control groups, and voice dock use active division
  regions from their own geometry to avoid straddling a vertical fold. Each
  group occupies the widest uninterrupted horizontal region. Horizontal folds
  do not add horizontal padding. System safe areas and sheet placement remain
  responsible for the system bars and presentations.
- Capture and analysis orientation still follow the camera sensor; physical
  orientation is not used to choose application layout. Camera image mapping
  remains in the existing preview and capture pipeline.
- The app permits portrait and both landscape orientations and opts into
  multitasking. It retains one application scene because inference and
  capture services currently have shared ownership.

New iOS 27/27.1 APIs are runtime-gated. The iOS 27.1-specific toolbar-axis and
reserved-region calls are excluded from Mac Catalyst compilation. Earlier
runtimes retain the existing menu and ordinary safe-area layout.

This implementation follows the
[`swiftui-iphone-duo` skill](https://github.com/FloWritesCode/fwc-swiftui-skills/tree/main/skills/swiftui-iphone-duo)
and Apple's [Duo preparation guidance](https://developer.apple.com/iphone-duo/prepare/).
It adds no model, runtime dependency, or camera-accessory scene.

## Validation

Focused app checks, with the native frameworks and CocoaPods prepared:

```bash
xcodebuild test \
  -workspace IOSLocalLLM.xcworkspace \
  -scheme IOSLocalLLM \
  -destination 'platform=iOS Simulator,name=iPhone Duo' \
  -only-testing:IOSLocalLLMTests/DisplayDivisionLayoutTests \
  -only-testing:IOSLocalLLMUITests/AdaptiveLayoutUITests
./scripts/validate_open_source.sh
```

The policy tests cover flat displays, unrelated and zero-width regions,
off-center folds, changing container sizes, multiple divisions, asymmetric
container origins, horizontal folds, and empty containers. UI tests use the
production tab hierarchy to check draft retention through rotation and tab
changes, API-sheet dismissal with large text, explicit model setup, and the
readable labels and hit bounds of large-text role controls. They do not
download or run an inference model.

Before shipping, use Device Hub to verify these transitions in the **same
running session**, keeping an unsent draft and a selected model:

1. Outer display → open inner display → partially open → closed. Repeat with
   both landscape rotations and with Voice or Lens selected.
2. Narrow, intermediate, and wide resizable windows. Check all tabs, keyboard
   entry, long responses, scrolling, model search, and download progress.
3. Split View on both sides. Check asymmetric insets, navigation, and that
   Stop, the composer, and sheet dismissal remain reachable.
4. Settings, model pickers, history, API, and image-generation sheets in each
   pose, including the largest accessibility text size and right-to-left UI.
5. On a physical device, check camera framing, tap-to-focus, capture
   orientation, microphone cleanup, backgrounding, cancellation, and memory
   and thermal refusals. Simulator layout checks do not validate these paths.

## Implementation-session checks — 17 October 2026

- The full Debug app build passed for the arm64 iOS Simulator with the 27.1
  SDK. Simulator signing and indexing were disabled for this compiler check.
- All five layout-policy tests passed in an isolated Swift package using the
  production policy and test files unchanged.
- All 25 `VoiceAgentOrb` package tests passed.
- The new layout helpers passed compiler checks for an iOS 18 simulator target
  with the 27.1 SDK and for Mac Catalyst with its iOSSupport frameworks.
- App, unit-test, and UI-test Swift sources passed syntax checks. Repository
  hygiene validation and `git diff --check` passed.
- Native Duo screenshots were subsequently captured and visually checked on
  an isolated iOS 27.1 simulator: Studio on the closed outer display and open
  inner display, the expanded model library, and the dark Local API workspace.
  Home-to-Models navigation was checked through the production view hierarchy.
  These initial checks were followed by the audit-fix validation below.

## App Store screenshots — 17 October 2026

Four native captures were uploaded to app `6770114399`, version `3.3.2`, locale
`en-US`, using the App Asset Library API and its `IPHONE_DUO_PROFILE` group.
The outer Studio capture is 1398 × 2034; the three inner captures are
2853 × 2007. Screenshots use the completed simulator build and production views
through the existing release UI fixture. They contain no user documents or
downloaded model content.

Only fully opaque alpha channels were removed for App Store compatibility;
the RGB pixels and original dimensions were verified unchanged. The upload
was read back to verify all four processed images, their specifications and
display order, and `ACTIVE` placements. All 14 pre-existing placements were
preserved. The version remains `PREPARE_FOR_SUBMISSION`.

Local screenshots, the preview, capture hashes, and upload verification are in
`build/duo-screenshots-2026-10-17/` (ignored by Git). The temporary simulator and
its streaming helper were removed after capture.

API reference: [App Store Connect API 4.5.1](https://developer.apple.com/documentation/appstoreconnectapi/app-store-connect-api-4-5-1-release-notes).

## Audit-fix validation — 17 October 2026

- All six `AdaptiveLayoutUITests` scenarios passed on the open inner display.
  Focused composer/keyboard and largest-text catalog checks also passed at
  120 degrees. The catalog test uses the full content column; sidebar recovery
  is covered independently on Home, Models, and Voices.
- Native production views were checked with the actual system accessibility
  text setting. The closed-display Models page leads into search and all four
  full role labels without the repeated zero counters. The setup disclosure
  keeps complete words. Normal-size model controls retain 44-point bounds.
- An unsent synthetic draft, keyboard focus, and the selected model survived
  open, half-open, closed, and open transitions. While typing, the empty
  welcome panel is hidden and the editor stays in its own row above the
  keyboard. Model selection remains reachable in the runtime status bar.
- Native screenshot spot checks of the four previously flagged metadata
  areas measured 5.26–6.36:1 in light appearance and 6.92–8.45:1 in dark
  appearance. These are local pixel measurements, not a whole-app conformance
  assessment.
- Four refreshed English Duo screenshots were uploaded and read back as
  `ACTIVE`. Their native dimensions and RGB pixels were preserved; only fully
  opaque alpha channels were removed. The prior four Duo placements were
  replaced, their library images retained, and all 14 other placements kept.

Evidence, final captures, test logs, and upload receipts are in
`build/duo-fixes-123/` (ignored by Git). The disposable QA simulator was removed
after capture. Camera, inference, and thermal behavior still require the
physical-device checks above.

## Build 123 delivery — 17 October 2026

Version `3.3.2 (123)` was archived and exported with the 27.1 SDK. The app and
share extension passed strict signature verification with their existing App
Store distribution profiles. Release verification also checked both version
numbers, the frozen UI source manifest, and the bundled safety classifier.

[Build 123](https://appstoreconnect.apple.com/apps/6770114399/testflight/ios/28170c86-c1bd-4eaa-b4b1-6e09051d8b42)
was uploaded, processed as `VALID`, and submitted with version `3.3.2` for
App Review on 17 October 2026. Apple confirmed `WAITING_FOR_REVIEW` with build
`123` selected. The release type remains `MANUAL`, so approval does not
automatically publish the update.
Delivery, signature, and draft readback receipts are retained in
`build/duo-fixes-123/`. The archive and exported IPA remain in `build/AppStore/`.

After verification and upload, the disposable QA simulator and approximately
2.56 GB of this task's regenerable caches were removed. Shared package caches,
other simulators, release artifacts, and native evidence were preserved.
