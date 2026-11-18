# Release audit — OnDevice LLM 3.4 (build 134)

Audit date: 2026-10-28  
App: `OnDevice: Local AI Studio` (`6770114399`, `com.codelens.CodeLens`)  
Version: `3.4` (App Store version `422466d9-5492-4378-9f39-a549a0932650`)  
Build: `134` (`7deafda7-6612-48a3-a200-f58548b51cba`)

## Verdict

**Technically ready for submission; hold until App Privacy is reconciled.**

- App Store Connect readiness: **0 errors**, 1 warning, 2 infos.
- Build: `VALID`, encrypted status exempt, attached to 3.4.
- Tests: **656 passed, 0 failures, 4 skipped** (signed Simulator run).
- Source hygiene: repository validator and `git diff --check` pass.
- Primary release risk: the public App Store privacy label has previously shown
  **Data Not Collected**, while the bundled privacy manifest declares optional
  provider collection. Verify and publish the correct App Privacy answers before
  submitting.

## App Store Connect

| Check | Result |
| --- | --- |
| Version state | `PREPARE_FOR_SUBMISSION` |
| Attached build | `134` |
| Build processing | `VALID` |
| Release type | `MANUAL` |
| Review details | Present (`e0a35d60-2e24-435f-879c-9fe53001ea81`) |
| Review contact | Present |
| Export compliance | `ITSAppUsesNonExemptEncryption = false`; build exempt |
| Submission in flight | No |
| Blocking issues | 0 |
| TestFlight validation | 0 errors, 0 warnings |
| Internal TestFlight | `IN_BETA_TESTING` |
| What’s New | Set for 6 locales |

`asc validate` findings:

| Severity | Finding | Assessment |
| --- | --- | --- |
| Warning | `APP_IPHONE_DUO` screenshot display type unknown | Intentional Duo captures; the CLI size catalog does not recognize the new type. App Store accepted the set. |
| Info | Manual release | Expected; release must be started manually after approval. |
| Info | App Privacy publish state unverifiable by API | Requires manual App Store Connect check. |

## Metadata and localizations

Six App Store locales are configured. All have description, keywords, support
and marketing URLs, and localized What’s New.

| Locale | Description | Keywords | What’s New |
| --- | ---: | ---: | ---: |
| en-US | 1243 | 96 | 390 |
| ru | 1387 | 77 | 408 |
| ar-SA | 1110 | 70 | 343 |
| pt-PT | 1379 | 78 | 422 |
| ro | 1360 | 74 | 443 |
| el | 1405 | 77 | 482 |

All What’s New values are below Apple’s 4000-character limit and describe the
LFM3 text/vision/audio update.

Gaps:

- The app ships 15 interface languages, but the 3.4 App Store page has only 6
  localizations. Missing: `de-DE`, `es-ES`, `fr-FR`, `hi`, `it`, `ja`, `ko`,
  `tr`, `zh-Hans`.
- TestFlight “What to Test” is populated only for `en-US`; the other five build
  localizations are empty. This does not block App Store submission.

## Screenshots

| Locale | iPhone 6.7" | iPad 12.9" | iPhone Duo |
| --- | ---: | ---: | ---: |
| en-US | 6 | 6 | 4 |
| ru | 6 | 6 | — |
| ar-SA | 6 | 6 | — |
| pt-PT | 6 | 6 | — |
| ro | 6 | 6 | — |
| el | 6 | 6 | — |

The Duo captures are 1398 × 2034 (outer) and 2853 × 2007 (inner), recorded in
`Docs/IPHONE_DUO.md`. The single readiness warning is the new Duo display-type
catalog, not a missing or malformed screenshot.

## Privacy and age rating

Age rating declaration:

- Unrestricted web access: **true**
- Parental controls: **true**
- Gambling, ads, UGC, chat, health, medical, violence, sexual content: false/none

Confirm the resulting App Store age rating matches the unrestricted web-access
answer, especially under Apple’s newer age-rating bands.

Privacy risk:

- `PrivacyInfo.xcprivacy` declares collected: Search History, User ID, Other
  Data Types, linked, with App Functionality / Analytics / Other purposes.
- `Docs/Releases/APP_STORE_PRIVACY_REVIEW_3_3.md` records that the public label showed
  **Data Not Collected**, and that the reconciled proposal was never applied.
- A mismatch between the live privacy label and optional provider/iCloud data
  can block or delay review.

Required before submission: confirm the account’s published App Privacy answers
match the manifest and actual provider/iCloud behavior, then publish them.

## Build and artifact verification

| Item | Value |
| --- | --- |
| IPA | `build/AppStore/export-3.4-134/IOSLocalLLM.ipa` |
| Size | 113,198,902 bytes |
| SHA-256 | `66c600c734526f301bdef3a642e59b1b73c86eb2a374de29b268c592247bf37e` |
| Archive | `build/AppStore/OnDevice-3.4-134.xcarchive` |
| Signing | Apple Distribution, team `PUH4GMFV56` |
| Apple validation | `VERIFY SUCCEEDED` |
| Verification record | `build/AppStore/TestFlight-3.4-134-verification.json` |

## Source and tests

| Check | Result |
| --- | --- |
| Full signed unit suite | 656 passed, 4 skipped, 0 failures |
| VoiceAgentOrb package | 25 passed |
| `scripts/validate_open_source.sh` | Passed |
| `git diff --check` | Clean |
| Interface localization audit | 2327 keys across 15 languages |
| Version consistency | `project.yml`, app/share `Info.plist`, `CITATION.cff`, `SBOM.spdx.json`, `CHANGELOG.md` at 3.4 |
| Build number consistency | App and share extension both 134 |

Skipped tests are weight-gated LFM3/vision smoke tests requiring external
reviewed models; they do not download weights in normal runs.

## Source-control and release-process gaps

- **253 files are uncommitted** (156 modified, 95 untracked). The shipped binary
  is therefore not reproducible from a commit/tag yet. Commit and tag the 3.4
  source before publishing a release note or archive.
- `fastlane/Fastfile` pointed at the old `CodeLens.xcworkspace`/scheme. Updated
  during this audit to `IOSLocalLLM.xcworkspace`, `IOSLocalLLM` scheme, and
  `IOSLocalLLM.xcodeproj`.
- `README.md` still links a sideload build from 3.2.7 (111). Refresh the
  sideload link when a 3.4 sideload IPA exists.
- `releaseType` is MANUAL. After approval, use
  `asc versions release --version-id 422466d9-5492-4378-9f39-a549a0932650 --confirm`
  or switch to automatic release deliberately.

## Recommended actions before submission

1. **Publish and verify App Privacy** answers; resolve the Data Not Collected
   versus provider-collection mismatch. (Blocking)
2. Confirm the final App Store age rating with unrestricted web access. (High)
3. Commit and tag the 3.4 source so build 134 is reproducible. (High)
4. Optionally add the remaining nine App Store locales and fill TestFlight
   notes for the other five existing locales. (Medium)
5. Optionally update App Review notes with the LFM3 model/import instructions.
   (Low)
6. Refresh the README sideload link when a 3.4 sideload artifact exists. (Low)
