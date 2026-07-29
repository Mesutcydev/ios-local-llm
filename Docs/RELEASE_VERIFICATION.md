# Release verification

Official releases contain source only. They do not contain an App Store build,
signed IPA, generated native framework, or model weights.

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
