# Performance audit — 3.3.1 (120)

Audit date: 14 October 2026. Scope: current OnDevice working tree,
startup and SwiftUI ownership, model-management refreshes, conversation storage,
streaming, memory/residency and lifecycle paths. Existing workspace changes were
preserved. OnDeviceMax was inspected as a reference; its CoreAI runtime and
navigation shell were not imported.

## Implemented improvements

| Area | Finding | Change |
| --- | --- | --- |
| Lens services | ContentView created a fresh camera and analysis pair before StateObject could retain its original instance. Live service updates also invalidated the whole tab shell. | A lazily created StateObject owns the pair once. CameraRootView continues observing the services directly; lifecycle and residency cleanup stay in their existing paths. |
| Storage refresh | Each request could launch another recursive filesystem scan. Older scans could publish stale totals, and unchanged totals still invalidated observing views. | Serial collection, latest-request coalescing, suppression of superseded snapshots, and publication only when totals change. |
| Download readiness | Repeated tab/foreground probes assigned identical published state to each downloader. | Publish only actual readiness changes; detect a removed destination without overriding active downloads or cleanup. |
| History pagination API | A 200-message page converted the entire stored transcript. Invalid offsets could form invalid ranges. | Slice first, convert only the page, clamp offsets, and keep the short-transcript fast path. These helpers currently have no callers in CodingAssistantView; this is an API improvement, not a measured chat-opening speed claim. |
| Image Generation accessibility | The More options control failed the release accessibility audit because its tap region was too small. | A 44-point minimum target and content shape. PIN restrictions and local content checks are unchanged. |

## Measurements and validation

The host microbenchmark compiles the exact before/after pagination functions,
StoredMessage conversion, and ChatMessage types with Swift optimization. Each
median below covers five runs of 100 reads. All input is synthetic.

| Transcript messages | Page size | Before (µs/page) | After (µs/page) |
| --- | --- | --- | --- |
| 200 | 200 | 8.07 | 7.32 |
| 2,000 | 200 | 73.50 | 11.24 |
| 20,000 | 200 | 652.08 | 10.47 |

This measures page conversion on the host Mac, not UI frame rate, inference
throughput, iPhone thermals, battery life, or model memory limits.

- Focused Release tests: 36 passed, 0 failed.
- VoiceAgentOrb package: 25 passed.
- Repository validator and source App Store preflight passed.
- Initial full Debug unit/UI suite: 574 passed, 2 UI failures, 1 skipped
  model-dependent test. The failures concerned a small More options tap target
  and a test scroll starting on the numeric keyboard. A 44-point target and
  keyboard-aware test scrolling were implemented. The targeted rerun passed
  all 10 tests, and the complete ReleaseScreensUITests rerun passed all 14.
- The exported 3.3.1 IPA passed app/extension version, signature, profile,
  Production CloudKit, privacy, and memory-entitlement checks. The final
  archive includes the accessibility correction and was exported with stable
  Xcode 27.0 (27A266a).
- Fresh iPad preview capture tests passed. They use the real production views
  and full iPad display. The app targets iPhone (UIDeviceFamily [1]), so iPad
  screenshots accurately show compatibility mode. A separate OCR capture
  selects the built-in option and verifies no stale-model warning remains.

## Reference comparison and remaining opportunities

OnDeviceMax uses the same buffered streaming coordinator and the same history
pagination implementation. Its model-storage refresh also performs background
collection. These patterns supported focused improvements here; no new runtime,
model dependency, UI package, or model weights were added.

The current chat screen still restores its complete transcript. UI pagination
would need a separate design that preserves full persistence, search, export,
and model-facing context. Startup history loading and whole-index Spotlight
rebuilds are also candidates for a later measured pass on large real histories.

The full suite reported synchronous AVAudioSession work during data-wipe tests
and transient invalid-frame warnings. These need a targeted physical-device
profile before further changes; no quantified reliability claim is made here.

The native Instruments capture failed to export within 300 seconds on the
selected Xcode beta. No native CPU/hang/leak result is claimed. Apple’s
performance-metrics endpoint returned no product data. A paired iPhone was
reachable, but sustained model load/generate/cancel/switch, thermal, and energy
measurements were not performed.

## Release state

App ID: 6770114399. Version: 3.3.1. Build: 120. Release policy remains Manual.
Version 3.3.1 (120) was uploaded, processed as VALID, attached, and submitted
to App Review on 14 October 2026 at 17:53 UTC. Both version and review
submission states were read back as WAITING_FOR_REVIEW. Release type is MANUAL;
the public 3.3 listing changes after approval and manual release.

What's New and promotional text were saved and read back in all six existing
locales: ar-SA, en-US, el, pt-PT, ro, and ru. Each has six localized iPhone
and six iPad screenshots. All 72 placements were read back in order with
COMPLETE delivery state, correct dimensions, and matching local MD5 checksums.
The app UI in the captures is English; marketing copy is localized, including
Arabic RTL. The final readiness check had zero blockers and zero warnings.

- App Store version ID: e221f7ed-95ed-4e03-b2ff-33ead4a37d32
- Build ID: 31c0624a-72e7-4849-a859-833734e1cf58
- Review submission ID: 07c45a37-ab46-4360-bcec-a6f883dda0ef
- [App Store Connect](https://appstoreconnect.apple.com/apps/6770114399/distribution/ios/version/inflight)
- [All-language preview and release copy](../AppStoreScreenshots/premium-v4/review-all-locales.html)
- [Saved asset and submission verification](../AppStoreScreenshots/premium-v4/asc-all-locales-upload-record.json)

Local test/build evidence and the task-specific source patch are preserved in
`/private/tmp/ondevice-performance-evidence`. The final signed archive and IPA
are in `/private/tmp/OnDevice-3.3.1-120-final.xcarchive` and
`/private/tmp/OnDevice-3.3.1-120-final-export`. These build artifacts are outside
Git. Preexisting workspace changes were retained; no source commit was created.
