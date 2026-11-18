# Public page corrections for the 3.3 update

Browser inspection on 6 October 2026 confirmed that the existing support and
privacy URLs load. The marketing URL redirects to the GitHub Pages landing page.
Automated HTTP 403 responses did not establish that the pages were unavailable.

The repository landing pages and build metadata now describe the live 3.2.4
App Store app and the 3.3 update in preparation. They remove current sideload
download offers and the misleading claim that only the bridge sends data.
Existing screenshots are labelled as earlier Simulator previews. The preview
dialog script is restored, with its metadata selector fixed so it cannot replace
the entire document with a build number. These source edits are not published.

## Prepared update — 8 October 2026

The replacement English and Turkish product, privacy and support record is
prepared in `build/AppStore/public-pages/codelens.json`, with a website source
review copy in `build/AppStore/public-pages/apps.js`. It explains all optional
connections, local content checks, retention and deletion limits, and removes
obsolete purchase-restoration advice. Only the codelens record changes; the
homepage and other app records are preserved. It has not been deployed.

## Privacy page

Replace the body at <https://mesut.uk/apps/codelens/privacy> with the current
[repository privacy policy](../PRIVACY_POLICY.md), preserving its provider-policy
links. Do not retain the existing claims that everything happens on the device,
that conversations never leave it, or that the activity indicator covers every
connection. The current policy describes optional web providers, paired clients,
private CloudKit storage, retained attachments, deletion limits and Keychain
credentials that can survive uninstalling.

## Support page replacement copy

### OnDevice Local AI Studio Support

OnDevice is a local-first AI workbench for iPhone. For a useful support report,
include your device model, iOS version, app version, selected model, and steps
to reproduce. Include screenshots only after removing private content. Never
send API keys, Hugging Face tokens, pairing credentials or private conversations.

### Model downloads

Models require an explicit download choice, available storage and a network
connection. Check the model's size, compatibility and license before confirming.
If a download fails, check connectivity and free storage, then retry. Some
repositories require a Hugging Face token or acceptance of the model's terms.

### Slow replies or a warm phone

Choose a smaller compatible model and allow the device to cool. Available
memory, context length and other active features affect performance. The app
may pause or refuse heavy workloads when memory is low or the device is too hot.

### Voice mode

Check microphone and speech-recognition permissions in iOS Settings. Default
Apple transcription requires on-device recognition support for your language
and device. Typing remains available if local recognition is unavailable. Neural
voices require separate downloads and do not change the selected chat model.

### Camera and image understanding

Check camera permission in iOS Settings. Built-in OCR reads visible text without
a vision-model download. Image descriptions require a compatible installed vision
model; opening the camera does not automatically download one.

### Image generation and parental controls

Version 3.3 (build 118) introduces local checks of image prompts and outputs
before preview or sharing. Checks can make mistakes or refuse a prompt.
Version 3.3 also offers a separate parental PIN. The feature relocks when the
app backgrounds. Wiping app content retains the restriction; unlock and remove
it in Parental Controls when desired. This PIN restricts the feature and does
not verify age or classify generated content.

### Sharing into the app

Choose the app in the system share sheet, wait for Saved, tap Done, then open
the app. Complete first-launch setup if needed. One queued item is imported per
foreground visit; shared text fills the composer without automatically sending.

### Mac Bridge and the local API

Both are optional. Use a trusted local network and allow Local Network access
in iOS Settings. Mac tools require pairing; API clients require a bearer token
and HTTPS. The local API stops when the app backgrounds. Clients control their
own storage of requests and responses.

### iCloud and deleting data

iCloud sync is optional. Turning it off stops future sync and leaves existing
cloud copies in place; use the separate cloud-deletion control to remove them.
Wipe all on-device data clears local content and saved API credentials, but does
not delete provider records or existing cloud copies. A parental PIN remains.
Restart after a wipe before using model features again. See the privacy policy
for retention and backup details.

### Contact

Use <mailto:mesutcydev@gmail.com> or the
[project issue tracker](https://github.com/Mesutcydev/ios-local-llm/issues).
Remove private information before sending a report or posting an issue.

Link this page to the published app privacy policy and the existing App Store
app: <https://apps.apple.com/app/id6770114399>. Remove the obsolete Restore
Purchases instructions; the current source has no purchase-restoration flow.
