# 3.3.3 design and localization

The update adapts the simpler OnDevice Core AI Studio interface while keeping
the existing inference, admission, download, and model-residency services.

## Interface

- Models opens the downloaded library, with a separate Discover destination.
  Import, Downloads, and Storage remain accessible from either destination.
- Model rows open focused details. Follow-up sheets open after the detail
  sheet closes. Role filters wrap at accessibility text sizes.
- Home, Settings, Voice Library, surfaces, and typography follow the simpler
  visual system. Settings categories retain the existing advanced controls.
- The composer has a clearer writing area, quieter model and attachment
  controls, readable disabled actions, and full touch targets. It hides during
  generation while the existing top Stop action remains available.
- SiteAgent and BellLink were inspected as visual references for the composer;
  their source and assets were not imported.

## Localization

The app bundles 2,270 interface keys in all 15 supported languages: English,
German, French, Spanish, Portuguese, Italian, Greek, Romanian, Russian,
Turkish, Arabic, Hindi, Simplified Chinese, Japanese, and Korean.

The selected language drives native SwiftUI text, custom components, interface
status messages, and the share extension. Arabic uses right-to-left layout.
Language changes update the existing view tree and preserve drafts. User text,
documents, chat output, model identifiers, and custom names remain verbatim.
Recently used translation catalogs are cached rather than retaining all
languages in inference memory.

The catalogs derive from developer-written interface text. Missing translations
were machine assisted under explicit authorization to send only those strings
to Google Translate. Main navigation and additional Turkish terminology were
reviewed. The app performs no network translation at runtime.

For maintenance, run `python3 scripts/audit_localizations.py`. Use `--extract`
to inventory source keys and `--compiler-strings` with an Xcode build's
intermediate directory to collect exact native interpolation formats. Add
translations to every catalog and preserve all interpolation arguments.
Native string literals localize normally. Explicitly localize computed
interface labels; keep dynamic user content verbatim. The repository validator
now runs the offline localization audit.

## Verification

- 46 focused app unit tests passed, including catalog integrity, language
  fallback, interpolation preservation, and model-category behavior.
- 14 UI scenarios passed, covering Models navigation, sheet handoffs,
  dark appearance, large text, Settings search, keyboard layout, draft
  retention, Turkish native controls, Arabic/Japanese screens, and live
  switching to Turkish. The inner-display sidebar scenario was skipped on
  the compact display.
- All 25 standalone VoiceAgentOrb package tests passed.
- Repository validation, localization audit, and whitespace checks passed.

The local release evidence is in `build/localization-release-124/`, including
screenshots, source/resource hashes, test logs, and App Store metadata readback.
Promotional text and What's New were updated in every configured App Store
locale: en-US, pt-PT, el, ro, ar-SA, and ru.

## Distribution

Version 3.3.3, build 124 was uploaded to App Store Connect on October 20, 2026.
Apple processing completed with status `VALID`. The build is attached to the
3.3.3 version in `PREPARE_FOR_SUBMISSION`, and both requested text fields were
read back exactly in all six store locales.

The exported IPA passed strict signature and provisioning checks for the app
and share extension. All 15 exported localization tables match the verified
source catalogs, and the bundled safety classifier is present. The release
source/resource hash manifest also matches the final working tree.
