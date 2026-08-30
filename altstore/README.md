# AltStore source

This directory contains the AltStore Classic source for the iOS apps in this
repository. The source references IPA files attached to GitHub Releases; IPA
files, signing certificates, provisioning profiles, and model files do not
belong in Git.

## Add the source

After this change is merged into `main`, add this URL in AltStore Classic:

```text
https://raw.githubusercontent.com/Mesutcydev/ios-local-llm/main/altstore/source.json
```

The source currently lists:

- **On Device: LAS** — iOS 18 or newer, version 3.2.6 (build 143).
- **ForgeSign** — iOS/iPadOS 16 or newer, version 2.1 (build 13).
- **MacPair for iOS** — iOS 18 or newer, version 1.0.5 (build 6).
- **OnDevice LLM** — iOS 18 or newer, version 3.2.6 (build 103).
- **SiteAgent** — iOS 17 or newer, version 1.16 (build 2026080901).
- **Core AI: LAS** — iOS 27 or newer, version 3.2.6 (build 140).
- **Hubr** — iOS 17 or newer, version 2.1 (build 6).
- **Vamp Stream** — iPadOS 18 or newer, version 0.1.0 (build 12).
- **Vamp Assistant** — iPadOS 18 or newer, version 0.1.33 (build 54).
- **Bell Link** — iPadOS 17 or newer, version 1.1.0 (build 2026083101).
- **Diffusion Forge** — iPadOS 26 or newer, version 1.0 (build 16).

The latest seven-app sideload suite is hosted on the
`sideload-suite-2026-08-31` GitHub release. Vamp Sync is the macOS host; its
sideloadable iPad companion is listed as Vamp Stream.

The Core AI build is intentionally hidden on older iOS versions through its
`minOSVersion` value.

## Validate changes

Run the metadata validator from the repository root:

```bash
bash scripts/validate_altstore_source.sh
```

The validator checks the JSON structure, unique bundle identifiers, required
version fields, HTTPS download URLs, positive file sizes, SHA-256 format, and
declared app permissions. It does not download or install an IPA.

## Publish an update

1. Upload each IPA to a GitHub Release.
2. Put the newest version first in that app's `versions` array.
3. Copy the IPA's exact `CFBundleShortVersionString`, `CFBundleVersion`, byte
   size, HTTPS download URL, and SHA-256 digest into `source.json`.
4. Keep `appPermissions` synchronized with the signed IPA. AltStore verifies
   declared permissions before installation.
5. Run the validator and merge the source update.

The current On Device: LAS and Core AI: LAS builds declare the
increased-memory-limit and extended-virtual-addressing entitlements. A signing
workflow that removes either entitlement may cause AltStore's permission check
to reject the app or may prevent larger local models from loading after
installation.
