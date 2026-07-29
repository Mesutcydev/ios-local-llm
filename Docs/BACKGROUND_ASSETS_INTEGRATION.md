# Managed Background Assets integration

## Current safe boundary

CodeLens continues to use `BackgroundDownloadCoordinator` and a background
`URLSession` for Hugging Face and other dynamic model downloads. Those files
can be chosen at runtime, can require an authorization header, and don't have
an app-versioned asset-pack identity. They are not candidates for Managed
Background Assets.

The first migration candidate is the app-owned
`BundledVoiceModels` directory. It is fixed at release time, currently ships
inside the app, and can be packaged independently. Its proposed policy is
`prefetch`, not `essential`, so a voice payload can't delay first launch.

The preparation files are:

- `BackgroundAssets/Manifests/offline-voice-models.json`
- `scripts/package_background_assets.sh`

Run:

```sh
scripts/package_background_assets.sh
```

The script uses Xcode's `ba-package`, writes the `.aar` and SHA-256 checksum
under `build/background-assets`, and cleans its temporary directory on every
exit.

## Why runtime activation is intentionally still off

Do not reference `AssetPackManager.shared`, add `BAHasManagedAssetPacks`, or
remove the current bundled voice resources yet.

Apple states that the first reference to the shared manager opts the app into
automatic asset-pack management, and that using it without the corresponding
managed downloader extension is a programmer error. Runtime activation
therefore waits until all of these are complete together:

1. Add a managed Background Download extension target.
2. Configure the shared App Group (`group.com.codelens.shared`) for the app and
   extension.
3. Choose Apple hosting or a production self-hosted manifest.
4. Upload and validate version 1 of the asset pack in App Store Connect or on
   the production host.
5. Add `BAAppGroupID`, `BAHasManagedAssetPacks`, and, for Apple hosting,
   `BAUsesAppleHosting`.
6. Add an iOS 26 availability-gated resolver that reads pack files without
   persisting the process-lifetime URL returned by Background Assets.
7. Keep the existing app-bundled voice resources as the rollback path for one
   release. Remove them only after TestFlight install, update, offline-launch,
   and quota/storage testing passes.

## Rollout invariants

- Dynamic and authenticated model downloads remain on background `URLSession`.
- The app must never claim a pack is available until the system confirms local
  availability.
- No voice-model resource is removed from the app bundle before a TestFlight
  build proves install and update behavior.
- iOS 18–25 keep the existing resource and download paths.
- A missing, outdated, or failed pack falls back to the bundled resource for
  the rollback release; it never leaves Voice mode in a partially configured
  state.

## Primary references

- https://developer.apple.com/documentation/backgroundassets/assetpackmanager
- https://developer.apple.com/documentation/backgroundassets/creating-managed-asset-packs
- https://developer.apple.com/videos/play/wwdc2025/325/
