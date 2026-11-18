# OnDevice LLM comparison with OnDevice Core

Reviewed on 7 October 2026 against the local working trees of this
repository and of OnDevice Core AI Studio.
OnDevice LLM started at `2552c63`; the reference started at
`6b145d5cfece26a244141582c4f38e62934a085e`, with additional local modifications.
These are working-tree findings, not a comparison of released binaries.

## Architecture and product differences

| Area | OnDevice LLM | OnDevice Core reference | Decision |
| --- | --- | --- | --- |
| Platform support | iOS 18 deployment target; MLX, llama.cpp, optional PCC | iOS 27 deployment target; additional Core AI package and native Edge0 runtime | Preserve OnDevice LLM compatibility; adding these engines requires a separate runtime integration |
| Model downloads | Serialized cancellation/deletion, path traversal checks, consumer model policy | Paginated HF enumeration and normalized LFS checksums | Adapt pagination/checksums while retaining OnDevice LLM lifecycle and license checks |
| Installed models | GGUF registration exists, but nested GGUF weights fail a second probe; stored absolute URLs are reused | Recursive GGUF validation and stale-container recovery | Fix both; constrain recovery to the original storage root and verify `.repoID` when present |
| Memory admission | Coordinated residency, thermal/cooldown policy, bounded GGUF paging and MLX profiles | Installed-entitlement checks and Low Power Mode gating; different memory estimates/caps | Adapt entitlement/power safeguards; preserve existing capacity caps |
| PCC | SDK/OS gates and explicit privacy consent; missing installed-entitlement gate | Gate signature and embedded provisioning profile before framework use | Add the installed-build gate before model construction and all facade entry points |
| Privacy and distribution | Newer HTTPS transport, web consent, shared-content inbox, on-device speech, parental controls and bundled notices | Different bridge/privacy and sideload behavior | Retain OnDevice LLM's existing privacy and release work |
| Imports and model UI | Files import/export and collision-safe destinations | Documents/Inbox import fallback, split folder/file pickers and Core AI packs | Leave this UI workflow for a separate change with Files/Simulator validation |

## Changes applied

- `HFHubMetadata.swift` accepts bare or `sha256:`-prefixed ASCII SHA-256
  digests, and extracts next-page cursors without following a supplied host.
- `HFModelDownloadManager.swift` collects every tree page before deciding
  readiness, keeps the original request endpoint, deduplicates file paths,
  propagates cancellation and later-page failures, rejects repeated cursors,
  and refuses malformed LFS checksums. Existing cancellation, cleanup,
  authentication, consumer policy and path validation remain in place.
- `ModelStoragePaths.swift` resolves symlinks and recovers stale absolute
  paths inside the same known model-storage root in the current Documents
  directory. Paths outside those roots cannot become registry download
  destinations.
- `InstalledModelRegistry` revalidates recovered records, rejects a conflicting
  or unreadable `.repoID` sidecar, and preserves record identity and installation
  date. Reconciliation no longer trusts a previous `.valid` state after files
  disappear. Nested and uppercase GGUF files use the shared recursive validator.
- `GGUFLoadPolicy` refuses zero or insufficient available memory in both
  accelerated and storage-backed modes, removing the previous zero-headroom
  bypass in `CodingAssistantService`.
- `EntitlementsProbe.swift` reads the declared Mach-O code-signature
  entitlement slot and the embedded provisioning profile. Unreadable,
  malformed, or unsupported signatures fail closed. The reader supports the
  thin little-endian Mach-O executables used by iOS and its Simulator; universal
  or DER-only entitlement signatures are conservatively refused.
- `MemoryAdvisor` uses its synthetic entitlement ceiling only when the
  installed build carries the increased-memory entitlement and Low Power Mode
  is off. On physical iOS, a missing kernel signal on an unentitled install
  no longer falls back to system-wide free RAM. Existing iPhone capacity caps
  and runtime-residency rules are unchanged.
- PCC now reports `.entitlementUnavailable` and `.notProvisioned` before
  entering Apple's framework on an unprovisioned build. An actor-level guard
  also protects direct internal calls. Privacy consent and cloud attribution
  are preserved.
- `Docs/AGENT_INTEGRATION.md` now describes the implemented HTTPS transport
  consistently with its certificate-pinning examples and the local server.

## Source and license

The selected reference helpers and policies are original OnDevice Core code
under MIT, copyright 2026 Mesut and iOS Local LLM contributors. The same
copyright and full MIT permission notice are already retained in the root
`LICENSE`. Adapted files are identified above and in their source comments.
No reference model catalog, weights, assets, native frameworks or additional
dependencies were added. The local `Packages/coreai-models` package and Edge0
runtime were inspected only; their licenses and platform requirements are
separate from these adaptations.

## Validation

- `./scripts/validate_open_source.sh`: passed before and after implementation.
- `swift test --package-path Packages/VoiceAgentOrb --scratch-path /tmp/codelens-voiceagentorb-build`:
  25 tests passed.
- PCC source type-check with `FM_PCC`, the installed iOS 27 Simulator SDK,
  and the new entitlement probe: passed.
- Focused app regression suites on iPhone 18 Pro / iOS 27 Simulator:
  **134 tests passed, zero failures**. Includes HF metadata/pagination,
  entitlement parsing and PCC facade refusal, model-storage recovery,
  device/memory policy, GGUF load policy, download lifecycle, model category,
  and Apple Private Cloud tests. The app and test targets compiled with their
  existing deployment and build settings.
- `git diff --check`: passed.
- XcodeGen regenerated the project to register the new source/test files;
  `pod install --deployment` restored the existing locked integration.
  Dependency versions and original build settings were retained.

The successful run used `-parallel-testing-enabled NO` on a directly booted
Simulator. Its result bundle is `/tmp/codelens-comparison-tests-verified.xcresult`;
its build/test log is `/tmp/codelens-comparison-xcodebuild-verified.log`.
PCC was separately type-checked with `FM_PCC` enabled; the app's normal scheme
keeps that optional flag disabled. An entitled PCC generation was not run.

Physical-device measurements are still required for Jetsam, thermal behavior,
increased-memory entitlements, and entitled PCC generation. Simulator checks
do not establish these properties. No model inference benchmark or App Store
approval is claimed by this comparison.

## Selective reliability follow-up — 26 October 2026

The current working trees were compared again. The reference still starts at
`6b145d5` with local modifications; this app still starts at `2552c63` with
substantial local privacy, localization, release, and adaptive-layout work.
The earlier adaptations above were retained.

The following additional improvements were implemented:

- IPv6 classification now parses address bytes, covering alternate loopback,
  mapped IPv4, NAT64, 6to4, and reserved forms. Unlike the reference, the
  existing IPv4 documentation and relay ranges remain blocked. Malformed
  IPv4 fields cannot be silently discarded during parsing.
- Web page bodies are bounded during streaming. The old `data(for:)` path
  bypassed the data delegate used to count bytes: a synthetic 3 MiB response
  was fully buffered while the delegate observed zero bytes. Search providers
  now share the redirect validator, retain their existing streaming cap and
  query escaping, and validate the final destination. Early refusals and
  completed reads explicitly cancel the associated response task.
- Knowledge Base imports own their embedding workers, propagate cancellation,
  invalidate outstanding work on clear/reset, and check remaining capacity
  again when committing. A controlled import/clear reproduction restored one
  document before this change; the generation check prevents that commit.
  Reset cancels producers before deleting stores and deletes the index without
  recreating it from an in-memory singleton.
- Attachment reads and decoding run outside the main actor and read a bounded
  prefix. PDFs have file-size and page-count limits. UTF-8 truncation preserves
  complete characters and includes the truncation marker in the output cap.
  The reference's incomplete-tail/Latin-1 behavior and complete-scalar trimming
  were corrected; normal Latin-1 documents retain their decoding fallback.
- GGUF Assistant generation now observes critical thermal transitions, as the
  existing MLX path already did. The watcher reads the current process state,
  stops only its own generation, and is cancelled when native inference exits.
  Critical stopping remains independent of the optional thermal-warning UI.
  Native prefill/decode also honors sticky Swift task cancellation, so a queued
  request cannot erase an earlier Stop when resetting its native cancel flag.

`ReferenceReliabilityTests.swift` adds deterministic tests for import/clear,
import/reset, caller cancellation, concurrent capacity admission, response
limits, private redirects, Unicode boundaries, oversized PDFs, and thermal
watcher cancellation. Existing URL-classifier tests were extended to protect
both the new IPv6 coverage and the stricter existing IPv4 behavior.

Core AI/Edge0 integration, higher memory ceilings, CPU fallback experiments,
product identity, and reference model catalogs were not part of this update.
The existing iOS 18 deployment target, residency coordination, HTTPS transport,
consumer model policy, consent flows, and memory limits were preserved.
No dependencies, weights, assets, or native frameworks were added. Original
reference integration code retains the root MIT copyright and permission
notice; no additional third-party source was imported.

Validation for the follow-up:

- The 28 focused XCTest cases passed on macOS against copies of the current
  production services and the exact repository test sources. Only the app's
  toast/haptic presentation adapters were replaced for this isolated target;
  the thermal helper was extracted unchanged from `DeviceSafetyMonitor.swift`.
  Log: `/tmp/codelens-reference-audit/focused-tests-final.log`.
- The ten original IP audit cases now all pass, including the two IPv4 ranges
  omitted by the reference implementation.
- The repository validator passed, including 2,270 interface keys across 15
  languages. `git diff --check` and parsing of the changed Swift sources passed.
- The unchanged VoiceAgentOrb package passed its 25 tests during this audit.

## Optional Core AI integration — 26 October 2026

The earlier scope exclusions above describe the original comparison. A later
explicit request adds an optional Core AI text runtime while retaining the
iOS 18 deployment target, MLX/GGUF dispatch and Simulator support.

- `Packages/CoreAITextRuntime` vendors only the language runtime, shared helpers
  and grammar bridge from the pinned Apple source documented in its README.
  Physical iOS/SDK compilation and iOS 27 availability guards isolate the SDK.
  Tokenizer loading cannot silently access the network; prompt/token diagnostics
  and the unused logits export utility are removed.
- Loading uses the existing Assistant residency, memory and thermal admission
  policies. Generation and loading are cancelled and drained before unload.
  Loaded-model identity is checked separately from the selected pack.
- The download library exposes 15 commit-pinned Apache-2.0 text packs. Metadata
  and embedded tokenizer configuration were checked at the pinned revisions.
  Unsupported vision/utility packs and unclear-license/custom-kernel packs are
  excluded from the visible download catalog. Model weights are not bundled.
- Downloads retain explicit user initiation, bounded file transfers, checksum
  checks and staging validation. Cancellation retains ownership until its task
  drains. Installed packs appear in the library, storage totals and model picker.
- Pack installation rejects path traversal, symlinks, missing expected resources,
  wrong sizes and declared checksum mismatches. Source and dependency licenses
  are documented in `THIRD_PARTY_NOTICES.md` and bundled notices.
- Primary library controls are translated into the existing 15 app languages.
  New technical diagnostics currently retain an explicit English fallback.

Validation in progress: the device CoreAILM package compiled with an iOS 18
minimum, and a Core AI symbol probe confirmed weak imports. Full app regression
and physical-device inference checks must finish before an upload is approved
as ready. Artifact availability checks do not certify every pack on every device.

Current validation checkpoint (26 October): repository hygiene and localization
validation pass (2,324 keys across 15 languages), as does source App Store
preflight. Builds use `/Applications/Xcode.app` (27.1), as required by the
existing iPhone Duo layout. The full signed Simulator suite ran 635 tests
with 634 passed, one skipped and zero failures; the Core AI download-library UI test passed.
An earlier unsigned run failed Keychain access, correctly locking parental
controls; ad-hoc Simulator signing resolved all failures without weakening
production checks. Model names, sizes, license links and disabled Simulator
download controls were also checked visually. Xcode's result collector stalled
after the signed suite completed and was terminated; the complete passing
console log is retained, but that run's xcresult bundle is incomplete.

Disposable build caches and the task's fresh QA Simulator were reclaimed after
disk exhaustion. The signed Release archive and App Store export for 3.3.4
(125) succeeded. The exported IPA passed distribution signature/profile,
Production CloudKit, privacy, bundle identity and memory-entitlement checks.
The final binary retains an iOS 18 minimum and weak-links Core AI and
FoundationModels. The archive's initial CloudKit environment was corrected to
Production during export and verified on the exported IPA.

App Store Connect processed build 125 as VALID and it is attached to the
3.3.4 version draft (`3142fd13-5dbd-48b7-bafb-d55c209e8749`). Both What's New
and promotional text were updated and read-back verified for en-US, ru,
ar-SA, pt-PT, ro and el; other localization fields were preserved. The update
remains in PREPARE_FOR_SUBMISSION with manual release. It was not submitted
to App Review or released. The CLI's initial post-upload status request timed
out; a fresh API query confirmed the existing upload succeeded.

Physical Core AI inference is not yet verified, and per-pack artifact checks
are not inference benchmarks. The signed archive and IPA are retained outside
Git under `/tmp/codelens-3.3.4-125.xcarchive` and
`/tmp/codelens-3.3.4-125-export/IOSLocalLLM.ipa`. Validation logs and ASC read-back
evidence are under `/tmp/coreai-compat-probe/`. Disposable compilation caches
were removed after export; approximately 7 GiB remained free at completion.
