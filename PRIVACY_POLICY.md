# OnDevice LLM Privacy Policy

_Last updated: 2026-11-13_

OnDevice LLM (the iOS Local LLM project) runs downloaded AI models locally by
default. We do not operate an account system, advertising service, analytics
service, or telemetry backend. Optional network features send data to the
recipients described below. Do not include private information in web queries.

## Local storage

Conversations are saved in the app sandbox with iOS file protection. A saved
conversation can include message text, image thumbnails from camera captures
or imported photos, and model context derived from documents, web pages or the
Knowledge Base. These attachments are retained with the conversation; they
are not always discarded after analysis. Camera preview frames that are not
attached to a conversation are processed in memory.

Memories, snippets, custom personas, macros and settings are saved locally.
The Knowledge Base stores imported document content and derived indexes.
Downloaded models, temporary download data, and cached resources stay in the
app sandbox. Local diagnostics and benchmarks contain operational information
and are not sent to us. Web activity history can contain search queries and
URLs and is rotated at 500 entries or approximately 1 MB.

## Optional network features

- **Model discovery and downloads:** After you request them, Hugging Face or
  the selected source receives model requests and connection metadata such as
  your IP address. A saved Hugging Face token is sent only to authorized
  Hugging Face endpoints when needed. Model terms are separate from the app's
  source license. FastVLM research weights are not offered in the consumer app.
- **Web search and web pages:** The query or URL shown in the permission sheet
  is sent to the selected provider or website. Your complete chat history and
  attachments are not sent by the web tool. Providers receive connection
  metadata and an API credential when configured. They may retain queries,
  associate them with the API account, and use them to improve their services.
  Brave's API notice specifies query retention for up to 90 days; Tavily and
  Exa describe query reuse under their applicable terms. Review the provider's
  policy before allowing a request. Changing an app setting does not delete
  records already held by a provider. The App Store privacy label lists this
  search and request data, with an Analytics purpose, because providers may
  reuse it; the app itself includes no analytics SDK and sends no usage data to
  the developer.
- **Mac Bridge and Local API:** When enabled, these features send prompts,
  outputs and requested tool data between this app and authorized clients on
  your network. TLS encrypts the connection. Pairing can disclose a device
  identifier to the paired client. Clients control their own storage.
- **iCloud sync:** Off by default. When enabled, Apple stores entire saved
  conversations, including attached thumbnails and model context, in your
  private CloudKit database. Disabling sync stops future synchronization but
  does not delete existing cloud copies. Use the separate cloud deletion
  control to remove them.
- **Private Cloud Compute:** Available only in builds configured with Apple's
  approved capability. Choosing this model requires a separate disclosure and
  explicit consent before prompts are sent to Apple's cloud service. Standard
  builds do not enable this capability.
- **External links and exports:** Links open after your action. When you export
  or share content, the chosen app or destination controls its handling.

Provider policies: [Hugging Face](https://huggingface.co/privacy),
[Brave API](https://api-dashboard.search.brave.com/app/documentation/general/privacy-policy),
[Tavily](https://www.tavily.com/privacy), [Exa](https://exa.ai/privacy-policy),
[Apple](https://www.apple.com/legal/privacy/).

The network indicator covers the app's monitored networking layer, not every
system or framework connection. There is no silent fallback from local
inference to a remote model.

## Camera, microphone and speech

Camera and microphone access require system permission. Selected images may
be saved as conversation thumbnails as described above. Microphone audio is
transcribed with a local Whisper model or Apple's on-device Speech framework.
If on-device recognition is unavailable, the app refuses the operation instead
of allowing server recognition. Apple frameworks operate under Apple's
privacy practices. Turning off permission in system Settings stops access.

## Calendar and Reminders

The assistant can read your upcoming calendar events, add a calendar event, or
add a reminder only after you approve each request in the chat, and only after
iOS shows its own permission prompt. Event and reminder text stays on the device
and is used only as context for the local model. If calendar details are in a
chat, any later web search asks for your approval again and shows the exact
query before it is sent. Voice conversations cannot use these tools. Turning
off Calendar or Reminders access in system Settings stops access.

## Deletion and retention

Local content remains until you delete it, wipe it, or a documented cache or
history limit rotates it. "Wipe all on-device data" clears local conversations,
snippets, memories, custom prompts, web activity, downloaded models, cached
resources, app preferences and saved API credentials. It also disables iCloud
sync and stops local servers. Existing cloud copies and third-party records
are not deleted. A parental PIN is retained so resetting content cannot bypass
a parent's restriction; unlock and remove it in Parental Controls when desired.
Restart after a wipe before using model features again.

Uninstalling removes the app sandbox. Keychain credentials can survive
uninstallation; clear saved credentials before uninstalling if desired. System
backups and exports you made are controlled separately by you and Apple.

## Local content checks

Generated image prompts and outputs are checked on the device. The image
classifier runs locally before an output is shown or shared; it does not send
images or prompts to us. These checks can make mistakes and are separate from
the parental feature lock. Language-model safety instructions do not guarantee
that arbitrary downloaded models will always produce appropriate content.

## Parental controls

A parent or guardian can set a separate PIN to restrict image generation. The
PIN verifier and retry limits are kept in the device-only Keychain; the PIN is
not sent to us. Access relocks when the app backgrounds. This feature lock does
not verify age or replace content safeguards. Screen Time can restrict access
to the entire app. The app is not designed as a children's educational app.

## Contact and changes

For privacy questions, email mesutcydev@gmail.com or use the repository's
support page: https://github.com/Mesutcydev/ios-local-llm/issues. Do not include
private content or credentials in an email or issue. We update this policy when handling changes;
optional network features keep their own consent controls.
