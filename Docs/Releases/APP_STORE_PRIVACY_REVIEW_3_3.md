# Privacy label review for 3.3

The public App Store page for app 6770114399 showed **Data Not Collected** on
6 October 2026. The current source manifest declares optional provider collection.
[APP_STORE_PRIVACY_3_3.json](APP_STORE_PRIVACY_3_3.json) is a local proposal matching
that manifest exactly. It has not been applied or published. It assumes there
are no additional services beyond this checkout; the maintainer's confirmation
of that assumption is still pending.

| Proposed data type | Linked to user | Purposes | Reason |
| --- | --- | --- | --- |
| Search History | Yes | App Functionality, Analytics, Other Purposes | Optional provider queries may be retained under the user's API account and reused. |
| User ID | Yes | App Functionality | Configured API credentials identify the provider account. |
| Other Data Types | Yes | App Functionality, Analytics | Provider connection/request metadata, subject to provider practices. |

No tracking or advertising purpose is proposed. There is no app analytics SDK.
The Analytics purpose covers the declared provider use, not transmission of
local benchmarks or MetricKit logs to the maintainer. This is a source-based
proposal, not verification of private provider agreements or a live account diff.

## Basis and open checks

- The web tool sends the displayed query or URL; it does not send full chat
  history or attachments. It uses explicit consent. This does not automatically
  make all collection exempt from disclosure. Apple requires retention beyond
  the immediate request to be considered and sets several conditions for
  optional disclosure. [Apple privacy details](https://developer.apple.com/app-store/app-privacy-details/).
- Brave's August 2026 API notice describes query retention of up to 90 days,
  associated with the customer's API account. [Brave API privacy](https://api-dashboard.search.brave.com/app/documentation/general/privacy-policy).
- Tavily's policy permits query reuse to improve future responses unless a
  customer contract says otherwise. [Tavily privacy](https://www.tavily.com/privacy).
- Exa's June 2026 policy describes query use for product improvement and model
  training. It also distinguishes business processing governed by customer
  agreements. [Exa privacy](https://exa.ai/privacy-policy).
- Review provider contracts and the final category mapping for retained IP
  addresses, usage metadata or derived location. Do not assume a provider's
  website cookie practices automatically describe its API behavior. Add or
  refine categories if applicable to the app's actual traffic.
- Local camera/audio inference, local conversations and local diagnostics do
  not themselves establish collection. Apple handles its own service data;
  optional private CloudKit sync should be assessed according to actual access.
  User-configured LAN clients and custom endpoints control their own retention.
- Reconcile this proposal with the data collected by the currently live app
  before publishing an app-level label. Apple says live-app answers must reflect
  that version. Coordinate any changed declaration with the release.
  [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy).

## Account follow-through

The CLI web-session read failed because its cached session expired. API-key
access used for draft metadata and signing profiles does not replace that web
session. No session cookies were printed or exported. Sign in through the
owner's normal App Store Connect web-session flow, then run the non-mutating
plan against the checked-in JSON. Review the actual diff before applying and
publishing, then pull the result to verify it.

The applied privacy-label skill requires: “Review with the user before applying.”
This review should cover the concrete declaration above and any differences
found in the account, rather than approving an unspecified privacy update.

```bash
asc web privacy plan --app 6770114399 --file Docs/Releases/APP_STORE_PRIVACY_3_3.json --pretty
```

The separate public privacy/support copy is prepared in
[APP_STORE_PUBLIC_PAGES_3_3.md](APP_STORE_PUBLIC_PAGES_3_3.md).
