# Security model

## Protected assets

- prompts, conversations, images, audio, memories, and local documents;
- Hugging Face tokens and local API bearer tokens;
- downloaded models and generated output;
- paired-device authorization and tool execution consent; and
- app availability under memory and thermal pressure.

## Trust boundaries

```text
untrusted model/download source ──HTTPS──> app sandbox
untrusted LAN client ──HTTP + bearer token──> opt-in Local API
paired Mac client ──authenticated protocol──> explicit tool-risk policy
app sandbox ──optional CloudKit──> user's private iCloud database
app ──optional web search──> configured third-party provider
```

On-device inference does not make every input trustworthy. Model files,
documents, web content, prompts, tool arguments, and LAN traffic can all be
hostile.

## Security properties

- The Local API and Mac bridge are opt-in and authenticated.
- Tool requests carry explicit risk levels; clients must not treat model text
  as authorization.
- Sensitive tokens belong in Keychain-backed storage and must never enter
  logs, screenshots, issues, or commits.
- File imports and downloads stay inside app-controlled locations and are
  validated before model loading.
- Memory warnings, critical thermal state, backgrounding, and cancellation can
  stop heavy work and release model resources.

## Known limitations

- The Local API uses bearer-authenticated HTTP and is intended only for a
  trusted local network. The bearer token protects authorization but does not
  encrypt LAN traffic. Do not expose the port to the public internet, and use
  a trusted tunnel when transport confidentiality is required.
- Third-party model and search endpoints observe normal network metadata and
  receive user-requested queries or downloads as documented.
- AI output is untrusted data. Generated code and tool arguments require human
  review and application-level authorization.
- Denial-of-service resistance is bounded by iOS lifecycle, RAM, storage, and
  thermal limits rather than a hardened internet-facing server design.

## Reporting

Follow [SECURITY.md](../SECURITY.md). Avoid public issues for vulnerabilities.
