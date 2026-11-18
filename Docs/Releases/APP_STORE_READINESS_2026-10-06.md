# App Store readiness audit 6 October 2026

The next update targets the existing App Store app, `com.codelens.CodeLens`.
The maintainer confirmed that **3.2.4** is the latest live version. The source
candidate is **OnDevice LLM 3.3 build 116**, matching the existing 3.3 draft in
App Store Connect. The account independently confirms 3.2.4 is live. Signed
bundle checks do not replace an upgrade test on a real device.

## Fixes from this audit

| Finding | Result |
| --- | --- |
| The source distribution used a different bundle ID from the live app | Restored `com.codelens.CodeLens` and `com.codelens.CodeLens.share`; retained the current project and product names. |
| The rename also changed shared storage and CloudKit identities | Restored `group.com.codelens.shared` and `iCloud.com.codelens` in runtime constants and all relevant entitlements. These values agree with the source before commit `581e088`. |
| Existing credentials and saved preferences would be looked up under new names | Restored historical namespaces for Hugging Face tokens, web keys/settings/history, bridge credentials, voice overrides, macros, benchmarks, model evaluation, and image crash recovery. |
| Old custom URL links no longer reached the app | Registered and accepted both the historical `codelens` scheme and `ios-local-llm`. Shared prompts prefill the composer without automatically sending. |
| The Share extension traversed the responder chain to call UIApplication | Replaced that path with an App Group inbox and a visible saved/error confirmation. The app imports one queued share per foreground visit. Enabled `APPLICATION_EXTENSION_API_ONLY`. |
| Sharing text or links containing ampersands could split query values | Used URLComponents and URLQueryItem for hand-offs; added round-trip coverage for query delimiters, fragments, plus signs, and Unicode. |
| Shared content could focus the composer behind the first-launch legal screen | Deferred inbox import and requested tab navigation until legal acceptance and onboarding finish. Added a real-app UI regression for the hidden-composer keyboard. |
| The extension inspected file timestamps without its own privacy manifest | Added its manifest with reason `C617.1` for app-container/App Group file metadata. |
| The Mac bridge published Bonjour without declaring its service | Declared `_localllm._tcp` and expanded the local-network purpose string to describe both bridge and API use. |
| Camera/microphone purpose strings described only earlier features | Updated them to describe Lens, photo attachments, dictation, and voice conversations. |
| Startup blocked interaction for seven seconds on each launch | Reduced the animation to approximately 1.8 seconds, allowed tap-to-skip, shortened Reduced Motion, and skipped the delay with VoiceOver. Corrected product-name capitalization. |
| The repository branding check rejected the immutable App Store bundle IDs | Added a narrow exception for the exact legacy bundle IDs; retired display branding remains checked. |
| No repeatable App Store configuration check existed | Added `scripts/validate_app_store.py` for identity, version, capabilities, persistence namespaces, privacy manifests, extension API safety, and built-bundle research-artifact checks. |

The inbox bounds envelope reads, rejects other schemes/hosts and symbolic links,
discards malformed or expired envelopes, and consumes each valid envelope once.
Pending envelopes are included in the existing local data reset. Staged payloads
and envelopes use file protection; failed inbox writes remove the associated
staged image or text file.

Apple documents that Share extensions cannot launch their containing app through
the Today-widget open-URL mechanism; shared-container hand-off avoids that
dependency. [App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html).
Bonjour registration requires service declarations, and reason `C617.1` covers
file metadata inside an App Group container. [Local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy),
[Required reason APIs](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

## Existing preparation retained

The checkout already contained changes to remove research-only FastVLM model
offers, enforce local-only Apple speech recognition, require TLS/pinning for
bridge pairing and the local API, add explicit web-provider consent, improve
data reset, bundle dependency notices, add image parental controls, and remove
the custom review pre-prompt. This audit preserves those changes; they are not
all new work from this pass.

The parental PIN is a feature restriction, not age verification or an image
content classifier. The app still allows local generation and user-selected
models. App Store age-rating answers and metadata must describe that behavior.
The Stability AI model notices do not establish the maintainer's registration
or commercial-license eligibility; that remains an account/business check.

Baseline Clang safety diagnostics are already enabled. Enhanced Security,
arm64e, and memory tagging remain deferred under the recorded dependency and
device-validation decision in `Docs/XCODE_SECURITY_SETTINGS.md`.

## Follow-up fixes and account preparation

- Both workspaces now mirror transitive upstream MLX references to the exact
  pinned PrismML one-bit fork. Stable Xcode package resolution completes without
  the identity-conflict warning; package revisions have not been upgraded.
- Explicit closure captures and synchronous `NSLock.withLock` calls remove the
  app's identified Swift 6 capture/async-lock warnings while preserving the
  current Swift 5 language mode and cancellation behavior.
- Local data reset awaits Spotlight deletion and records failures in its
  receipt instead of returning before the index cleanup finishes.
- Legal actions wrap at large text sizes, document buttons expose their read
  state, and icons no longer contaminate the Agree button's accessible label.
  Parental PIN fields have numeric keyboards, visible wrapping labels, compact
  placeholders and minimum 44-point height. Image-model subtitles wrap fully.
- Added Turkish safety, legal-screen chrome, download preflight and compatibility
  labels; fixed the singular model count and removed the obsolete research-model
  search suggestion. Long-form legal documents remain English. Other supported
  locales retain their existing partial translations and English fallback.
- Added verbatim notices for all three pinned official Apache-2.0 Kitten 0.8
  variants. Their six temporary test artifacts match manifest sizes and SHA-256
  hashes; weights remain outside Git.
- The previous named distribution profiles were invalid. Created and installed
  two new App Store profiles using the owner's existing valid distribution
  certificate. Verified the App Group, historical CloudKit container, memory
  capabilities and disabled debugging. No certificate or old profile was revoked.
- Updated the existing 3.3 draft's six localized descriptions and release notes
  (en-US, el, ro, ar-SA, ru, pt-PT) and reviewer instructions. Removed inaccurate
  claims about automatic downloads, prompts never leaving the phone, and network
  requests being limited to downloads. Review contacts, screenshots and release
  mode were retained. Exact submitted draft text: `APP_STORE_METADATA_3_3.json`.
- Corrected only the editable draft's parentalControls answer to true after PIN
  validation. Compared before/after API records: every other answer and the live
  declaration are unchanged. Content-frequency answers remain an owner review.
- Browser-verified the public support/privacy pages and existing App Store link.
  The public label is currently Data Not Collected. Prepared a three-category
  privacy proposal matching the final manifest in `APP_STORE_PRIVACY_3_3.json`,
  with rationale in `APP_STORE_PRIVACY_REVIEW_3_3.md`. Its account diff could not
  be fetched because the CLI web session expired; nothing was applied/published.
- Updated the repository landing pages for the live 3.2.4 App Store app and the
  3.3 update in preparation. Removed current sideload offers and inaccurate
  network claims, labelled historical previews, and restored preview dialogs.
  Fixed a metadata-selector bug that could replace the entire HTML document
  with the build number. Browser-verified the layout and dialog open/close.
  Public support/privacy replacement copy is in `APP_STORE_PUBLIC_PAGES_3_3.md`.
  Website source and replacement copy have not been published.
- Added optional distribution verification to the local preflight. It validates
  app/extension signatures, certificate/profile matching, expiry, App Store
  profile type, production CloudKit and memory entitlements. This requires
  macOS access to signing metadata; sandboxed `codesign` inspection can report
  unavailable certificate chains even for a valid signature.

## Validation

| Check | Evidence |
| --- | --- |
| Source and built-bundle preflight | 3.3 (116) passed for source, Simulator app, signed archive and exported IPA. The distribution verifier also rejected the same IPA when an incorrect team was supplied. |
| Dependency notices | Regenerated from exact lockfile checkouts; 38 license/notice sections. |
| Repository hygiene and whitespace | Passed. |
| VoiceAgentOrb package | Initial pass: 25 tests passed; follow-ups do not change this package. |
| App unit suite | Full signed-Simulator run: 521 executed, 520 passed and one artifact-dependent Kitten test skipped, zero failures. The skipped gate subsequently passed with all three pinned real ONNX variants, finite non-silent PCM, and no Apple-TTS fallback. |
| Compact-screen UI suite | All 16 tests passed on iPhone SE (3rd generation), including Voice Mode, setup gating, parental PIN persistence, legal read-state semantics, largest text, dark appearance and Turkish preflight. Both focused final English/Turkish regressions also passed; screenshots confirm the translated compatibility label. |
| Accessibility audits | Legal and image screens passed hit-region, sufficient-description, trait and text-clipping checks. This establishes tested accessibility semantics; spoken VoiceOver navigation and contrast across the entire app remain device QA. |
| Manual Share extension flow | Initial pass: saved confirmation, queue preserved through legal setup, URL delimiters/fragment intact, composer prefilled after setup, envelope consumed once. |
| Stable Xcode distribution | Xcode 27.0 (27A266a), iOS 27 SDK: signed archive and local App Store IPA export succeeded. Exported app and extension signatures/profiles, production CloudKit and both memory entitlements passed validation. |
| App Store Connect readiness | Initial draft validation: zero metadata warnings, one blocker (no attached build). The owner subsequently requested TestFlight upload; 3.3 (116) is VALID and IN_BETA_TESTING in the existing internal group, test. The public page shows Data Not Collected; account privacy edits require a renewed web session and review. App Store release remains MANUAL. |

The initial 3.2.7 unsigned candidate was validated before account access confirmed
an existing 3.3 draft. Its previous test evidence remains an initial baseline,
not proof of the final 3.3 export. The first compact run used an unsigned
Simulator build; Keychain refused access with -34018 and parental controls
correctly failed closed. Rerunning with an ad-hoc Simulator signature and team
entitlements passed the affected unit and PIN tests. Accessibility failures then
identified actual subtitle clipping and button semantics, which were corrected.
A duplicate archive run during final localization was stopped. The final export
comes from the subsequent successful sequential build. A final Turkish test
initially selected the hidden search card behind the sheet; scoping it to the
presented form resolved that test failure without hiding a product issue.

Simulator tests use the installed iOS 27 beta runtime and Xcode beta. Release
archives use stable Xcode. Simulator audio inference does not establish real
phone voice quality, thermal behavior, memory admission or live CloudKit sync.

Evidence (temporary artifacts, not tracked source):

- `/tmp/ondevice-followups-package-resolution.log`
- `/tmp/ondevice-followups-tests-signed.log`
- `/tmp/ondevice-followups-kitten-inference.log`
- `/tmp/ondevice-followups-ui-final.log` and
  `/tmp/ondevice-appstore-audit/Logs/Test/Test-IOSLocalLLM-2026.10.06_19-10-19-+0300.xcresult`
- `/tmp/ondevice-followups-translations-complete.log` and
  `/tmp/ondevice-followups-translations-complete-evidence`
- UI attachments in `/tmp/ondevice-followups-ui-evidence`; initial manual Share
  evidence in `/tmp/ondevice-appstore-manual-evidence`
- `/tmp/ondevice-followups-signed-archive-complete.log`
- `/tmp/ondevice-followups-export-final.log`
- `build/AppStore/OnDevice-3.3-116.xcarchive`
- `/tmp/ondevice-appstore-3.3-116-export/IOSLocalLLM.ipa` and `.ipa.sha256`
- `/tmp/ondevice-followups-distribution-validation.log`
- `/tmp/ondevice-followups-asc-readiness-final.json`

The final IPA is also retained outside Git at
`build/AppStore/OnDevice-3.3-116.ipa`, with its SHA-256 sidecar and
`verification.json`. Size: 83,152,489 bytes. SHA-256:
`47d946d6b12b9a6417afb78d09fcd92eb77fdf9e12d56a3fd4d2c3248c538f16`.

Reproduce preflight:

```bash
python3 scripts/validate_app_store.py
python3 scripts/validate_app_store.py --app /path/to/IOSLocalLLM.app
python3 scripts/validate_app_store.py --app /path/to/exported/IOSLocalLLM.app --distribution-team YOUR_TEAM_ID
./scripts/validate_open_source.sh
swift test --package-path Packages/VoiceAgentOrb
```

The production environment is applied during App Store export; archive signing
alone does not establish the exported CloudKit environment. Use stable Xcode on
this machine for release work. Signing settings and profiles are temporary/local
assets and are not committed. [Apple submission requirements](https://developer.apple.com/app-store/submitting/).

## Release gates

1. The owner authorized TestFlight upload on 6 October 2026. The exact verified
   3.3 (116) IPA was accepted, processed as VALID, and became IN_BETA_TESTING in
   the existing internal group, test. Build ID:
   `1d441f36-264c-4b1c-a6d4-f3dc6024ef7b`. English testing notes are saved.
   Apple automatically activated the all-builds internal group; a redundant
   manual assignment was rejected, and subsequent group/state checks confirmed
   availability. No external group was added, no manual tester notification was
   sent, and nothing was submitted to beta review or App Store review or released.
   Attach the build to the App Store draft separately when release gates pass.
2. Retain the verified production signing and capability identities. Standard
   builds keep managed Private Cloud Compute off.
3. Upgrade an installed App Store 3.2.4 build through TestFlight without deleting
   it. Check conversations, snippets, memories, settings, downloaded models,
   credentials, custom links, share imports, and optional CloudKit sync. Source
   history establishes the expected namespaces; it does not prove migration on
   a signed installation.
4. Complete real-device model load/generate/cancel/switch/unload, background,
   memory, thermal, microphone/camera denial, and LAN permission checks from
   `Docs/VALIDATION.md`. Simulator cannot validate memory limits or LAN prompts.
5. Update App Store privacy answers to match optional web-provider transmissions,
   user-linked API accounts, iCloud sync, and the published policy. Publish the
   updated policy/support pages before submitting; the in-app policy URL points
   to the repository's main branch.
6. Reconcile the age-rating questionnaire with actual AI text/image generation,
   web access and controls. The draft currently declares parentalControls=true,
   ageAssurance=false, unrestrictedWebAccess=true, and sensitive content as NONE.
   The new PIN qualifies as a feature restriction under Apple's parental-control
   definition; it provides neither age verification nor content classification.
   Only the draft parentalControls answer was changed by this task. Supply current screenshots and
   review notes describing model downloads, hardware requirements, offline OCR,
   local voice defaults, optional network features, and the Share extension's
   save-then-open flow. Downloaded models are data used by bundled runtimes;
   compatibility should not be described as downloadable executable features.
7. Validate the signed archive in Organizer/App Store Connect, inspect the
   privacy report and embedded frameworks, and use TestFlight before release.
   Mac Catalyst is a separate validation gate if shipping a Mac update; ONNX
   Runtime's resolved XCFramework has no Catalyst slice.

Apple requires accurate metadata, complete review access, and disclosure and
explicit permission before third-party data sharing. Review notes should make
the optional connected features easy to test. [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).

## Remaining release checks

- Test App Store 3.2.4 → TestFlight upgrade on a physical phone and live
  multi-device CloudKit conflicts/offline recovery. The original storage and
  credential identities are preserved, but source checks cannot prove migration.
- Validate physical model load/generate/cancel/switch/unload, memory/thermal
  refusal, background cleanup and permission denial, plus spoken VoiceOver.
- Renew the expired App Store Connect web session, review the concrete privacy
  proposal and publish the appropriate declaration at the right release stage.
  Review the remaining age/content answers and publish current policy/support
  copy. The mesut.uk URLs load in a browser, but the published privacy page
  overstates local-only behavior and the support page has obsolete purchase
  restoration instructions. Corrected copy is prepared in the repository.
- Confirm Stability AI commercial registration/revenue eligibility or an
  enterprise license before retaining the optional community-licensed image
  models in the commercial release. The maintainer's account status is not
  inferable from checked-in license text.
- Refresh/review App Store screenshots for current behavior and have native
  speakers review the edited store translations. Preserve the manual release
  setting until the release gates are satisfied.

Apple distinguishes parental feature restrictions from age assurance. Broad
public content sharing is a separate age-rating capability; the app's local
chat history alone does not establish it. [Apple age-rating definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/).

Remaining build diagnostics are upstream C++ compatibility/libtool and optional
App Intents extraction messages; runtime Simulator logs also warn about existing
synchronous audio-session calls. These are not represented as fixed by the
Swift capture/lock cleanup.
