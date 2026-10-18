---
summary: Private cross-device numeric usage history, setup, data boundaries, and verification.
read_when:
  - Connecting multiple Macs or changing usage-sync behavior.
---

# Usage across Macs

The development preview also supports a private Tailscale hub. Its connection and offline cache
are independent of iCloud identity; the numeric exporters and merge ledger are shared with the
folder transport. See [Tailscale hub setup and coverage](MIDAS_TAILSCALE_HUB.md). Combined summary
totals use the same synchronized provider set on every Mac. Sync opt-in collects supported local
Codex, Claude, and Muse Code numeric logs regardless of provider display toggles.

Midas can combine recorded usage from multiple Macs through a private shared folder. On Macs
using the same Apple Account, select the same folder in iCloud Drive. A separate Midas account
or a server holding provider credentials is unnecessary for this release.

This feature is opt-in. It synchronizes historical measurements; provider login, quota limits,
reset times, and credentials remain local. It currently supports Macs, not an iOS client.

## Setup

1. Create a dedicated private folder, such as `iCloud Drive/Midas Usage`.
2. In Midas Settings → Sync, choose that folder on each Mac. Use the same folder, not separate
   folders with identical names. Do not share it with other people.
3. Connect each provider normally on the Mac that collects its usage. Enable its Midas provider.
4. Keep **Sync usage from this Mac** and **Show combined usage** enabled for combined spend history. Turn the latter off
   to inspect this Mac's normal source while synchronization continues.
5. Use **Sync now** after setup. Both Macs must publish and subsequently read the folder before
   their views converge. iCloud can delay downloads; a local save is not proof of remote delivery.

There is no inbound listening port, Wi-Fi pairing, or remote-control service. Macs need not be
online together. Polling runs every minute while Midas is running; token refresh also schedules
an exchange. iCloud's own upload/download schedule remains outside Midas's control.

## Source coverage

| Source | Shared data | How duplication is prevented |
| --- | --- | --- |
| Codex | Local recorded session events, priced with existing API-rate estimates | Workspace-salted session/turn/exact-event-time identity; copied events count once; existing fork parsing is retained |
| Claude Code | Local recorded message/request usage | Canonical message/request identity; streamed and copied subagent messages count once |
| Cursor | Existing authenticated account daily reports | One complete latest report per verified account and UTC day; the same account on two Macs counts once |
| Meta / Muse Code | Local completed Muse Code response usage | Stable response/stream/sequence identity; copied responses count once |
| Meta AI / Muse consumer app | **Unavailable** | No verified documented numeric consumer usage feed; unavailable is not zero |

Codex's account-wide cloud report is not added to local session history. Combined scope uses
local Codex events so the same activity cannot appear once as a cloud total and again as local
activity. Switching to this Mac's scope restores the normal configured source. This also means
combined history can differ from an account-wide cloud report when logs are missing.

Subscription quota percentages are never added or converted to dollars. Dollars retain their
existing source meaning: API-rate equivalents and estimates do not become subscription bills.
Unpriced activity remains marked as partial. Daily Cursor reports retain their fetch timestamp,
so a later corrected report can decrease a prior daily total. Unowned/mismatched Cursor reports
are not exported. Cursor fetches and cache schema 2 explicitly use UTC; older local-day cache
files are left intact and ignored rather than being relabeled as UTC.

Muse Code's session journals are documented by [Meta](https://dev.meta.ai/docs/cookbook/audit-agent-sessions).
Meta's [numeric usage dashboard](https://dev.meta.ai/help/usage-and-limits/api-usage) describes Model API
and Playground usage. The [Muse personal-agent announcement](https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/)
describes a separate consumer product. Midas does not inspect its conversation database or infer
tokens from message length.

## Privacy and format

The shared folder contains `workspace.json` and `devices/<random-device-UUID>.json`. A publication
contains UTC day keys, source timestamps, numeric token classes/request counts/costs, pricing
provenance, public model names, opaque event/account IDs, a user-selected device name, and
partial-coverage counts. It contains no prompts, transcripts, credentials, cookies, file paths,
raw provider emails, raw session IDs, or hardware identifiers.

Opaque IDs use SHA-256 with a random workspace salt. The salt travels with the workspace so both
Macs can identify copied records. This pseudonymization is not encryption: the JSON ledger is
readable to anyone who has access to the chosen folder. iCloud protections depend on the user's
Apple settings; Midas does not claim unconditional end-to-end encryption. Choose a private folder.

Local bookmarks, the offline outbox, received history, and environment fingerprints remain in
Midas's internal app-support/preferences storage. Hardware binding and iCloud-account fingerprint
are local opaque values used to detect migrated preferences or an account change; neither is
included in the shared publication.

The account token is archived locally and compared with Apple's `isEqual` identity contract.
Its serialized bytes are not treated as an account identifier. A stable local label binds the
cache to the verified account. Connections saved by the earlier byte-hash implementation require
choosing the folder once after updating; their shared files remain intact.

## Merge and recovery

Each Mac writes only its own device file through coordinated atomic replacement. Workspace
creation is exclusive and only occurs on an explicit connection. A restored connection never
reinitializes missing metadata or silently joins a different workspace.

The ledger selects the latest complete publication per device, unions stable local events, and
selects a whole report per account/day. Event revisions keep the complete streaming result;
monetary and token fields are never independently maximized. Canonical tie-breaking and sorted
aggregation make the same input converge independent of read order.

UTC is the shared reporting calendar on every Mac. The ledger retains up to 365 days of recorded
history. Missing days remain unavailable. Last received peer history is retained when a Mac or
its file is temporarily unavailable; source-log cleanup does not erase previously recorded local
history within this window. Disconnecting stops this Mac and clears its displayed shared view;
it does not delete files from the shared folder.

The outbox is saved locally before upload. A failed local save blocks publication. Shared-folder
failure keeps the outbox and last received history for retry. An unchanged iCloud notification
does not disconnect sync. When iCloud identity is temporarily unavailable, publication stops and
the shared view is hidden while the bookmark, offline outbox, and received cache remain intact.
Midas automatically resumes when the same account returns, including after restarting. A confirmed
different iCloud account or workspace identity clears the connection and requires choosing the folder again.

Safety limits: 128 distinct devices, 512 directory entries, 32 MiB per publication, 128 MiB per
exchange, 100,000 records per publication, and 250,000 records across the selected device union.
Export reserves space for account reports and retains newer records first; omitted records are
reported as partial coverage. Schemas, ownership, dates, models, finite/nonnegative measurements,
and arithmetic bounds are validated. Symlinks, nonregular files, conflicts, corrupt publications,
and unavailable cloud placeholders cannot redirect file IO or silently contribute totals.

## Why shared folders first

Apple supports [CloudKit for Developer ID apps](https://developer.apple.com/developer-id/), and
[CKSyncEngine](https://developer.apple.com/videos/play/wwdc2023/10188/) is a useful next transport.
Midas currently has no production CloudKit container/profile/schema for its own identity. Adding
one requires Apple capability/provisioning and production-schema work, not an upstream CodexBar
container. The private-folder transport delivers the requested Mac use case without a credential
backend, hosting bill, or provider OAuth integrations that do not expose local coding sessions.

The ledger/export boundary is independent of the folder transport, allowing a future CloudKit
or account-backed transport to reuse deduplication and coverage semantics.

## Verification and remaining release gates

Synthetic tests use isolated defaults, source fixtures, and private temporary folders. They cover
copied sessions, streaming/fork identity, UTC boundaries, account correction/deduplication,
convergence, corruption, symlink races, limits, unavailable files, offline retry, and presentation.
The full suite must run with live-provider, browser, app-state, and real iCloud paths denied.
Native SwiftUI snapshots exercise setup, waiting, combined, and offline states in both appearances.

Two simulated Macs in a local folder prove the algorithm and transport, not real iCloud delivery.
A release requires normal lint/test/build and signed/notarized packaging. Acceptance of a connected
two-Mac setup additionally requires a real readback showing the same recorded totals after both devices have exchanged. The second Mac's
installation and delivery cannot be claimed from this Mac's local save.
