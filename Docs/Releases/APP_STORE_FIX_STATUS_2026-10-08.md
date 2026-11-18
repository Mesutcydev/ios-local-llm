# App Store audit fixes — 8 October 2026

Candidate: OnDevice 3.3, build 118, `com.codelens.CodeLens`.
This records local changes and verification; it is not an App Review approval.
Existing unrelated working-tree changes and prior archives are preserved.

## Completed in the local candidate

| Step | Change | Verification |
| --- | --- | --- |
| Rating requests | Verified the existing removal of the custom sentiment-gated rating sheet. Added a source preflight check against its return. No rating request is present in the candidate. | Source/bundle preflight; source search. |
| Memory admission | Removed the unconditional unsafe-load bypass. A smaller-margin attempt still checks live capacity, thermal state and pressure recovery, and reserves 150 MB. Ordinary admission retains its 500 MB reserve. | Capacity, overflow, unknown-size and recovery tests; full unit suite. |
| Image safeguards | Added explicit prompt checks before downloading and a bundled CPU-only sexual-content classifier before preview/share. Missing checks, malformed scores, failures and cancellation withhold new output. The parental PIN is a separate feature lock. | Frozen-graph/Core ML numerical parity, bundled-model inference, malformed-score tests and UI refusal before download. |
| Chat guidance | Added safety instructions without changing user messages or silently changing inference providers. The compact GGUF path retains them. | Prompt-preservation/idempotence tests and full unit suite. |
| Usability | Added a keyboard dismissal control to keep image generation reachable on compact screens. Existing PIN, legal, download and OCR flows remain available. | 13 distinct UI scenarios passed across the final run and focused rechecks. |
| Privacy and support | Updated the in-app policy/disclaimer and legal version to 6. Prepared and applied local English/Turkish website corrections for optional web/iCloud/LAN features, retention, deletion and Keychain persistence; removed purchase-restoration instructions. New safeguards have version-specific wording on the website. | Policy/source parity; browser review; other website app records and homepage preserved. |
| Model provenance | Pinned new SD-Turbo/SDXL-Turbo downloads to the audited revisions. Added classifier source/hash, conversion instructions and bundled license notices. Weights and generated Core ML resources remain excluded from the public source distribution. | Hash verification, license inventory, repository hygiene and bundle preflight. |
| Store preparation | Prepared six metadata localizations, reviewer notes, privacy-label proposal, an 18+ age-rating proposal, and replacement iPhone/iPad lead screenshots. Incremented app and extension to build 118. | Field lengths, identities, manifests, compiled checker and screenshot dimensions verified. |

## Test evidence

- All **548 app unit tests passed** in `build/AppStore/evidence/appstore-fixes-regression-tests.log`.
- **13 distinct UI scenarios passed**: the final run passed 11; the two affected
  PIN/Turkish cases passed their focused recheck. The scrolling helper now uses
  short drags, accounts for offscreen frames and allows enough travel for large
  text. The PIN test dismisses the keyboard before its actions.
- The new image refusal test opens the real Home → Models → Image Generation
  flow and verifies refusal before a download. It generates no explicit media.
- Core ML conversion matched an independent evaluation of the pinned frozen
  graph on four procedural fixtures, with maximum probability error below
  0.000008. The bundled Vision path also matches the reference scores. The
  solid-color fixture is uncertain and correctly withheld; it is not evidence
  of accuracy on photographs or generated art.
- Repository hygiene, diff whitespace and App Store source/built-bundle preflight
  pass. UI screenshots are saved under `build/AppStore/evidence/ui-verification-118`
  and `build/AppStore/evidence/ui-rechecks-118` (the passing PIN/Turkish rechecks).

Earlier build attempts hit disk exhaustion, one missing status switch case and
Simulator runner termination. The compile issue is fixed; failed assertions
were repaired and rechecked. These failures are retained in the evidence logs.

## Release verification

Stable Xcode successfully archived build 118 and exported an App Store IPA:

- Archive: `build/AppStore/OnDevice-3.3-118.xcarchive`.
- IPA: `build/AppStore/export-118/IOSLocalLLM.ipa`.
- Verification/checksum: `build/AppStore/Release-3.3-118-verification.json`.
- Distribution preflight passed for app and share-extension signatures,
  unexpired App Store profiles, production CloudKit, historical identities,
  shared App Group, memory capabilities, privacy manifests, bundled classifier
  and dependency notices. Standard distribution has no managed PCC entitlement.
  The archive's pre-export CloudKit environment is Development; export correctly
  signs the IPA for Production. Validate the exported IPA for distribution.

Prior build 117 has not been withdrawn or replaced.

All twelve existing iPhone/iPad screenshots were visually reviewed. Three have
confirmed misleading blanket privacy claims: iPhone lead (no cloud/API keys),
iPhone chat (conversations never leave the phone) and iPad privacy (nothing
leaves the phone; model-download-only network). Others show legacy UI, including
an image model no longer offered. A compact replacement plan uses one current
app-in-use Home capture per display type, retaining the actual iPhone
compatibility presentation on iPad. See
`Docs/Releases/APP_STORE_SCREENSHOT_REPLACEMENT_3_3.json`; it has not been applied.

## Remaining before resubmission

1. **Content-check evaluation on actual devices.** Numerical parity is not an
   accuracy assessment. Test ordinary portraits/art, generated images, supported
   languages, evasion attempts, false positives/negatives, cancellation and
   memory/thermal behavior. The classifier focuses on sexual content; it does
   not classify every form of violence or hate. Language safety instructions
   cannot guarantee arbitrary downloaded models obey them. See
   [IMAGE_CONTENT_SAFETY.md](IMAGE_CONTENT_SAFETY.md). The three paired physical
   iPhones were unavailable with developer services inactive at the final
   device check; no physical-device generation or accuracy test was performed.
2. **Stability AI commercial eligibility.** Confirm registration and aggregate
   revenue eligibility under the pinned Community License, or the applicable
   enterprise agreement. No business eligibility was fabricated and no license
   agreement was accepted on the owner's behalf.
3. **App Store Connect session and declarations.** The privacy web session is
   expired. Sign in using the normal owner flow, run the non-mutating privacy
   plan, review its actual diff, then apply/publish and read it back. Reconcile
   app-level answers with the currently live build and provider contracts.
   The age-rating frequency answers are a review proposal, not observed counts
   or a substitute for blocking prohibited content. See
   [APP_STORE_PRIVACY_REVIEW_3_3.md](APP_STORE_PRIVACY_REVIEW_3_3.md),
   [APP_STORE_PRIVACY_3_3.json](APP_STORE_PRIVACY_3_3.json) and
   [APP_STORE_AGE_RATING_3_3.json](APP_STORE_AGE_RATING_3_3.json).
4. **Publish the corrected pages and update the pending submission.** Review
   only the intended website changes before deployment; that repository also
   contains unrelated existing changes. After the replacement archive and
   remaining release checks pass, withdraw submitted 3.3 (117), attach the
   verified replacement and update screenshots/metadata. Maintain manual release.

The original fix pass did not upload, publish, withdraw, resubmit or release
anything. The original Apple rejection text has not been supplied.

## TestFlight follow-up — 8 October 2026

At the owner's explicit request, the verified 3.3 (118) IPA was uploaded to
TestFlight. Apple processed build `3e714de5-4eb6-4ae5-9eeb-93edea1e68bb`
successfully (`VALID`). Its internal state is `IN_BETA_TESTING`, and membership
in the existing internal group `test` was verified. That group has access to
all builds.
English testing notes cover upgrade preservation, image checks, cancellation,
memory/thermal refusals, sharing, speech, consent and iCloud.

English testing notes were read back and matched the prepared text (Apple trims
the trailing newline). The encryption declaration is false for non-exempt
encryption. External testing remains `READY_FOR_BETA_SUBMISSION`; no external
Beta App Review was submitted. Evidence is saved in
`build/AppStore/evidence/testflight-118-*`; the IPA verification manifest records
the upload. This upload does not change the App Store version submission,
publish website/declaration changes or resolve the remaining release checks.

Relevant primary references: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/),
[App privacy details](https://developer.apple.com/app-store/app-privacy-details/),
[Age-rating definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions).
