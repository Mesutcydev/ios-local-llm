# Retired AltStore source

Public sideload distribution has ended as the apps move to the App Store.
`source.json` remains at its existing URL with empty `apps` and `featuredApps`
arrays so existing source subscribers no longer receive IPA download listings.

GitHub release IPA assets have been withdrawn. Source code, source archives,
and historical release notes remain available. Official App Store links will
be published at [ondevice.fun](https://ondevice.fun/) when available.

Validate the retired catalog with:

```bash
bash scripts/validate_altstore_source.sh
```

The validator accepts an empty catalog and continues checking all required
app and version fields whenever an app is present.
