# iOS Local LLM Privacy Policy

_Last updated: 2026-07-29_

iOS Local LLM is a privacy-first iOS app. AI inference and app storage are local by
default. The iOS Local LLM project does not operate an account system, analytics
service, advertising service, or telemetry backend.

## What iOS Local LLM does NOT do

- We do not collect any personal information.
- We do not require an account or sign-in.
- We do not include analytics, advertising SDKs, or third-party trackers.
- We do not send your conversations, photos, code, or voice to an iOS Local LLM-operated service.
- We do not have access to your data — even if we wanted to, we have no servers that hold it.

## What stays on your device

- **Conversations**: stored locally in `~/Documents/conversations.json` with iOS at-rest encryption (file-protection class: "complete unless open").
- **Memories** ("remember this about me" facts): stored in `UserDefaults`, never uploaded.
- **Snippets**: same as memories.
- **Models**: downloaded from huggingface.co to `~/Documents/HFModels/`. A
  download uses HTTPS and may include a Hugging Face token if you explicitly
  save one for gated repositories.
- **MetricKit diagnostics** (crash/perf reports): stored locally for your reference. Apple aggregates these system-wide; that's an OS behavior, not ours.

## When iOS Local LLM DOES talk to the network

The app makes network requests only for these explicit, user-initiated actions:

1. **Searching Hugging Face** in the Download Center.
2. **Downloading a model** after you choose it.
3. **Web search** when you enable it and submit a query. The configured search
   provider receives the query under its own privacy terms.
4. **Mac Bridge and Local API Server** when you enable them. Requests are sent
   between devices on your local network.
5. **iCloud sync** when you enable it.
6. **External links and optional companion downloads** when you choose to open
   or download them.

The app includes a network-activity indicator for requests made through its
monitored networking layer. Treat it as a useful diagnostic, not as a
system-wide packet monitor.

## iCloud sync (optional, off by default)

If you turn on "Sync conversations to iCloud" in Settings, your conversations are saved to your **private CloudKit database** (the same place your Notes/Reminders go). Apple, not us, controls this storage. We never see it. You can turn this off at any time and wipe the cloud copy from Settings.

## Children's privacy

iOS Local LLM does not knowingly collect any data — from any age group, including children.

## Your control

- "Wipe all on-device data" in Settings clears every conversation, snippet, memory, downloaded model, and cache.
- Uninstalling iOS Local LLM removes everything we've stored.

## Models

iOS Local LLM can run third-party models through Apple's MLX framework and other
local runtimes. Models are subject to their own licenses and may be open
source, source-available, community-licensed, non-commercial, or research-only.
We do not relicense them.

## Contact

If you have questions about this policy, open an issue in the iOS Local LLM GitHub
repository. Do not put private data in a public issue.
