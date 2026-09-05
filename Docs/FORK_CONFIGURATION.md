# Fork and signing configuration

A fork must use identifiers owned by its Apple development team. Changing only
the app bundle identifier is insufficient because the share extension, App
Group, CloudKit container, and two runtime constants must agree.

## Required replacements

Choose a reverse-DNS prefix such as `com.example.localllm`, then replace:

| Existing value | Where it must remain consistent |
| --- | --- |
| `com.mesutcydev.ioslocalllm.IOSLocalLLM` | app target bundle ID |
| `com.mesutcydev.ioslocalllm.IOSLocalLLM.share` | share extension bundle ID |
| `com.mesutcydev.ioslocalllm.IOSLocalLLMTests` | unit-test bundle ID |
| `com.mesutcydev.ioslocalllm.IOSLocalLLMUITests` | UI-test bundle ID |
| `group.com.mesutcydev.ioslocalllm.shared` | all app/share/PCC/Catalyst entitlements, `AppBridge.swift`, and `ShareViewController.swift` |
| `iCloud.com.mesutcydev.ioslocalllm` | app/PCC/Catalyst entitlements and `CloudSyncService.swift` |
| `com.mesutcydev.ioslocalllm.scheme` | URL type name in `project.yml` |

Make target-level changes in `project.yml`, then update the tracked entitlement
and Swift files. Regenerate with:

```bash
xcodegen generate
pod install
```

Internal Keychain service names, queue labels, logging subsystems, Spotlight
domains, and background-session identifiers can remain stable for a private
development build. Public forks should replace them to avoid data/keychain
collisions with another installed distribution.

## Capabilities

Create the App Group and CloudKit container in your own Apple developer account
before device signing. If your signing profile does not grant increased memory
limit, extended virtual addressing, iCloud, or a newer Foundation Models
capability, remove only the unavailable entitlement and test the resulting
limits. Do not publish a profile, certificate, `.p8`, `.p12`,
`.mobileprovision`, team ID, or private CloudKit credential.

Simulator builds do not require a paid Apple Developer Program membership and
are the safest first verification target.
