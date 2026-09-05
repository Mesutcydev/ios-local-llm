# Release verification

Version tags (`v*`) publish source-only archives. Separate `sideload-*` releases
may publish ad-hoc device IPAs for installer re-signing. Source archives never
contain signed apps, generated frameworks, or model weights.

Starting with `v3.2.6`, the `Source release` GitHub Actions workflow creates a
reproducible source archive from the tagged commit, publishes its SHA-256
checksum, and records a GitHub artifact attestation backed by Sigstore.

## Download and verify

Install the [GitHub CLI](https://cli.github.com/), then download a release:

```bash
gh release download v3.2.6 \
  --repo Mesutcydev/ios-local-llm \
  --pattern 'ios-local-llm-*-source.tar.gz*'
```

Verify its checksum:

```bash
shasum -a 256 \
  --check ios-local-llm-3.2.6-source.tar.gz.sha256
```

Verify that GitHub Actions produced the archive from this repository:

```bash
gh attestation verify \
  ios-local-llm-3.2.6-source.tar.gz \
  --repo Mesutcydev/ios-local-llm
```

The attestation proves the workflow identity and artifact digest. It does not
change the licenses of the source, dependencies, or separately downloaded
models. Review `LICENSE`, `THIRD_PARTY_NOTICES.md`, and `PROVENANCE.md` before
redistribution.

## Sideload IPA verification

The current OnDevice LLM build is **3.2.7 (112)**, published separately under
`sideload-3.2.7-112`. Download the IPA, its `.sha256` file, and verification JSON
from that release. Run `shasum -a 256 --check` on the checksum file in the same
directory as the IPA.

The ZIP contains `Payload/IOSLocalLLM.app`, an arm64 iPhoneOS executable, its
embedded native frameworks, and `PlugIns/IOSLocalLLMShareExtension.appex`.
The app and extension versions match. The ad-hoc signatures retain the source
entitlement dictionaries; the package has no embedded provisioning profile.
The iOS 27 SDK build includes the Private Cloud Compute entitlement alongside
App Groups, CloudKit, increased memory, and extended virtual addressing.

An ad-hoc signature is not an Apple installation authorization. The installer
must supply its own team signature and provisioning. App Groups, iCloud,
Private Cloud Compute, and memory capabilities need authorization from that
profile; preserving the entitlement keys in this download does not grant them
to an unsupported signing account. Check the installed app's entitlements if
your installer changes or strips capabilities.

No model weights are included. `ThirdPartyNotices.txt` inside the app preserves
licenses from the resolved native and Swift dependencies. The attached source
audit records Simulator tests and build checks; physical-device inference,
thermal/battery behavior, live iCloud, and audio comparisons are not certified
by packaging verification.
