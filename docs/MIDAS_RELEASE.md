# Midas releases

Midas releases belong exclusively to [enzo-prism/midas](https://github.com/enzo-prism/midas/releases).
The inherited `.mac-release.env`, `Scripts/release.sh`, and `Scripts/sign-and-notarize.sh` target
upstream CodexBar and must not be used unchanged to publish this fork.

## 0.49.1 changes: choose the menu-bar account

Version 0.49.1 (build 133) adds a persistent menu-bar account choice per provider, independent
of the active CLI login. The circle follows the selected account's quota; aggregate spend is
unchanged. Codex free accounts with an explicit monthly allowance use a monthly label.
The exact binary identifies source `3c5d89b4f`. The canonical full Swift test suite passed in
45 bounded suite groups, and strict lint passed with zero violations. Selection, persistence,
privacy, removed-account, refresh-cap, stale/error, and monthly/weekly period regressions pass.
Two separate saved Codex accounts returned fresh, error-free app-written usage snapshots;
the ambient CLI authorization file was unchanged. Native live menu automation timed out, so
these checks do not claim a live click-through. The public Apple Silicon release is
[v0.49.1-midas.1](https://github.com/enzo-prism/midas/releases/tag/v0.49.1-midas.1).

Apple notarization submission `d2a17feb-2d3e-49cd-8c15-cc543124a115` was Accepted.
The app and dSYM share arm64 UUID `E9DB2FFA-CF67-34CE-94AE-AFE3E5E441A3`.
Deep strict signature, stapled ticket and Gatekeeper checks passed. Downloaded draft assets,
anonymous public downloads, archive verification against the embedded Sparkle public key,
both XML signatures, and both actual latest-feed routes match. A native Sparkle information
probe using the 0.49.0 (132) host discovered 0.49.1 (133) at the public archive URL.
Archive SHA-256: `619da8f2f5aee0e390d204465a912dab50a03c2755ad226fa598ca8c47348d2d`.

The identical public notarized bundle is installed on the Mac mini. Local nicknames and circle
selection survived. At publication, remote [CI run 39590867857](https://github.com/enzo-prism/midas/actions/runs/39590867857)
had passed Linux x64/arm64 builds, tests and smoke checks, Python contracts, and macOS lint;
macOS integration/full tests were still running separately from the completed local full suite.

Website commit `6f62ce9bc39948b6eae9e891eb675f64a37a778f` reached production Ready as
`dpl_56UCmZYdExvNWzCU9GxaHPZLhSH5` at `midas-ai.dev`. The site build and all 18 live
browser checks passed. Both public download links select the verified 0.49.1 archive;
a download followed from the live page matches the published SHA-256 above.

## Current distribution

The release selected in `version.env` is **0.49.1**, build **133**, published as the latest stable release. 0.37.0 (build 109) was the first build with
Midas’s own identity: bundle identifier `com.designprism.midas`, `Midas.app` with a `Midas` executable, team
`L49MKXGVM4`, its own app group, Keychain services, `~/Library/*/Midas` folders, and Sparkle feed.
Everything is defined once in `Sources/CodexBarCore/MidasIdentity.swift` and mirrored by
`Scripts/package_app.sh`.

The current **signed, notarized, Sparkle-published** binary is **0.49.1**, build **133**, tagged
`v0.49.1-midas.1`, superseding 0.49.0 (build 132, `v0.49.0-midas.1`), 0.48.4 (build 130, `v0.48.4-midas.1`), 0.48.3 (build 129, `v0.48.3-midas.1`), 0.48.2 (build 128, `v0.48.2-midas.1`),
0.48.1 (build 127, `v0.48.1-midas.1`),
0.48.0 (build 126, `v0.48.0-midas.1`),
0.47.1 (build 125, `v0.47.1-midas.2`),
0.47.0 (build 124, `v0.47.0-midas.1`), and the earlier 0.46.x releases. Check GitHub releases for the current published binary; source and installed local
builds are not publication proof. 0.36.0 (build 108) was the last CodexBar-identity build.
The downloadable app is for Apple Silicon Macs running macOS 14 or later.

### Update feeds after 0.37.0

Sparkle refuses to install an update whose bundle identifier differs from the running app, so
0.33.3–0.36.0 clients cannot update themselves to 0.37.0. Every latest stable release therefore
ships two feeds, both written by `Scripts/make_midas_appcast.py`:

- `Midas-appcast-arm64-v2.xml` — the real feed for the Midas identity (0.37.0+): signed enclosure.
- `Midas-appcast-arm64.xml` — the legacy feed (`--informational`): no enclosure, a link to the
  release page, and a note asking for a one-time manual download. Keep publishing it until the
  0.35.x install base is gone.

Installed Midas reads `/releases/latest/download/<feed>`. Users who install 0.37.0 manually keep
their settings (adopted on first launch) and update automatically from then on. Widgets must be
re-added once because the app identity changed.

## 0.49.0 changes: durable incremental sync

Version 0.49.0, build 132, retains canonical event identities in private pages and
exchanges only changed history pages through the existing Tailscale hub. Expected-base
revisions, durable outboxes and explicit applied receipts protect interrupted uploads,
restored backups and peer cache recovery. Checked, accepted, applied and peer-received
states are separate from source coverage. Old aggregate history remains preserved with
its uncertainty; source absence never deletes history.

The app bundles a managed hub helper and relocatable Python runtime, with database
backup, migration rehearsal, health checks and code rollback. The hub retains legacy
collector support. See [operations](SYNC_OPERATIONS.md) and [protocol](SYNC_V2_PROTOCOL.md).
[PR #17](https://github.com/enzo-prism/midas/pull/17) merged after the exact release
commit `d7e852b9a0cf35208359549b19feb97d359a75ec` passed
[all four CI jobs](https://github.com/enzo-prism/midas/actions/runs/39527235096):
4,607 macOS unit tests, the actual 150,000-event Swift/Python wire fixture,
121 Python tests, and Linux x64/arm64 build, test and smoke checks. Eight synthetic
native sync fixtures covered setup, waiting, combined and offline states in light/dark.
The binary embeds source `0bb9b4357`; subsequent changes affect tests and CI only.

Apple notarization submission `480ffa29-8144-4eb4-8d2c-6bb7cbf48a0e` was Accepted.
App and dSYM share arm64 UUID `CB0E0CDB-5E2A-3164-BA7A-AE8809B6ED19`.
The public app passed deep strict signature, stapled-ticket and Gatekeeper checks.
Anonymous downloads matched all five prepared assets; the archive and both XML
signatures verified against the app's embedded Sparkle key, and both actual latest
feed routes returned build 132. Published October 20, 2026; archive SHA-256:
`e56e5b225a1b1d8474e9788eb2eeac61a66fca811ecc45b60d37dd0248f884ad`.

The identical public binary was installed and restarted on both Macs. Their durable
numeric records matched, fresh mutual receipts covered all current heads, and
baseline event/day identities and tokens were retained. Tailscale and connection
identities remain unchanged. Legacy peers without v2 applied receipts remain unconfirmed;
opaque historical aggregate overlap remains explicitly uncertain.

## 0.48.4 changes: complete cross-Mac sync history

Version 0.48.4, build 130, fixes busy Macs sharing only their newest days. A publication holds
32 MiB / 100,000 records; heavy Claude Code use exceeded it, so the exporter and retention step
discarded older events (a MacBook Pro shared only ~10 days, 74,128 records excluded). Older
provider days now publish as device-scoped day rollups in the unchanged wire format. See
[usage sync](MIDAS_USAGE_SYNC.md#merge-and-recovery).

Sync ledger/exporter/coordinator/hub/collector suites (150 tests) and strict lint passed. A real
76,329-event publication reduced to 19,798 events (7.8 MB) with identical per-provider tokens,
costs, and daily series. On the Mac mini hub, the installed build's publication was accepted and
excluded records fell from 3,892 to 69.

Apple notarization submission `f5ec4b4e-a63f-4697-a51d-0c66bd897f8c` was Accepted.
App and dSYM share arm64 UUID `BA9AC796-555A-3148-9467-EEFA58871323`; source commit `536ddeadf`.
Stapling, Gatekeeper, archive verification against the embedded Sparkle public key,
both signed XML feeds, downloaded draft assets, anonymous public downloads, and both latest
feed URLs passed. Published October 20, 2026; archive SHA-256:
`10744a28fb001c002cf678f3afbab4028635fed28f38fa3802da57ddc32cb920`.
The Mac mini runs the verified public bundle. Website commit `fa26077` is live on
midas-ai.dev; all 18 production browser checks passed and the download link resolves to the
verified archive. MacBook Pro receipt through Sparkle is verified separately from its hub publication.

## 0.48.3 changes: selected OpenAI account

Version 0.48.3, build 129, adds an optional local Codex account filter. Quotas, cloud
history, menus, setup previews, and widgets honor the selected identity. Missing or
mismatched accounts cannot fall back to another login. Mixed-account local and shared
Codex totals are excluded while scoped; saved accounts and other providers remain intact.
Single-account refresh retains verified identity when the quota response omits email.
See [setup](MIDAS_SETUP.md#limit-codex-to-one-openai-account).

The exact source `e20f0e760` passed 4,629 local tests in 525 suites and 44 bounded groups,
with no test failures or runner timeouts. Strict lint passed with zero violations. Synthetic
Codex light/dark provider fixtures were rendered and inspected. Remote CI is tracked separately
in [run 39156445988](https://github.com/enzo-prism/midas/actions/runs/39156445988).

Apple notarization submission `afad4fa0-0c1a-4f6f-853e-16248a69429a` was Accepted.
App and dSYM share arm64 UUID `5C1F26A8-9DF2-3D7F-9FFC-25550B06CF4D`.
Stapling, Gatekeeper, archive verification against the embedded Sparkle public key,
both signed XML feeds, downloaded draft assets, anonymous public downloads, and both latest
feed URLs passed. Published October 18, 2026; archive SHA-256:
`57c9df5bf92aa3b638ae21407addde49509b67a6e689b14a6c0fad7136a0365b`.

The installed 0.48.2 app discovered 0.48.3 through Sparkle, installed it, and relaunched.
About shows 0.48.3 (129); the running installed binary matches the verified public archive.
The selected-account setting survived and live Codex quota/reset readings remained scoped.
Website commit `4c122d9` reached production Ready as `dpl_2U7UwAwEohYZqS31J7VCWCHp2dnw`;
all 18 production browser checks passed, and both live download links resolve to the verified archive.

## 0.48.2 changes: AI Spend heading

Version 0.48.2, build 128, replaces the overview heading with **AI Spend** in both the
menu panel and Usage window. Its help text explains the public API-rate estimate basis.
Unavailable-value accessibility uses the same label. Amounts, recorded tokens, independent
quotas, source coverage, and billed-charge exclusions are unchanged. The canonical package
passed 4,623 tests across 524 suites in 44 bounded groups, with no failures or shard timeouts.
Strict lint passed with zero violations; 60 native synthetic fixtures were rendered and the
new heading was inspected.

The signed binary identifies source `9cd5d1298`. Apple notarization submission
`103230b8-c8b5-4393-8bb8-8cd9c5b6f4be` was Accepted; app and dSYM share arm64 UUID
`6F0FC0C7-98DA-3545-A65B-5DCAE87B1B0E`. Stapling, Gatekeeper, archive and both XML feed
signatures, downloaded draft assets, anonymous public assets, and both latest feeds passed.
Published October 18, 2026, with archive SHA-256
`be7985471fc2430c53e12e11f915f097b9c923736dfa21215adccf095e75e8aa`.

The identical public bundle is running at `/Applications/Midas.app` on the release Mac mini.
About shows 0.48.2 (128); Sparkle reports it is newest. Five superseded 0.48.1 installer ZIPs,
the previous installed app, and three transient current app copies were moved to recoverable
Trash with hash readback. Source, app state, release evidence, and crash symbols remain.
Website commit `bb8f8db` reached production Ready as `dpl_HkLpJ11WbTjXf4D9Fqw9RAae15G8`.
All 18 production browser checks passed, and the live-page download matches the public archive.

## 0.48.1 changes: quieter overview and compact Meta

Version 0.48.1, build 127, removes the inline Partial total row and repeated partial-estimate
badges. The compact panel moves estimate coverage to **More actions → Estimate details…**;
Usage retains a neutral details control, and provider details keep source qualifications.
Accounting flags, exact dollar totals, currencies, billed exclusions, and unavailable values
are unchanged.

Meta's recorded-activity fallback uses two compact columns with percentage left, a neutral bar,
and a short busiest-day/week caption. Full token/request breakdowns remain in provider details,
tooltips, and accessibility. Without a recorded baseline, it shows token count and No baseline
without a capacity bar. Provider-reported Meta quota/reset readings keep their existing layout.
The canonical package passed 4,571 Swift Testing tests and all 52 XCTest tests
across 524 suites in 44 bounded shards, without failures or shard timeouts. Strict lint
passed with zero violations. Sixty synthetic native fixtures cover light/dark and accessibility
appearances, including compact Cursor/Meta rows and missing-baseline states. Native layout
measurements verify that Meta fits the same space as two Claude limits.

The signed binary identifies source `66d5a193f`. Apple notarization submission
`c88ed560-d219-4d5a-a626-330a327bd0a2` was Accepted. App and dSYM share arm64 UUID
`7CCEAF5A-E64E-3D6F-96DB-42CB786CE80A`. Stapling, Gatekeeper, embedded Sparkle key,
archive and both XML feed signatures, downloaded draft assets, anonymous public assets, and
both actual latest-feed URLs passed verification. The release was published October 17, 2026
(October 18 UTC). Archive SHA-256:
`bca8b2fcd9f2b5c2bf00053504dd50aa997c10c7ae08827dfd006a4c867c4f84`.

The identical public bundle is running at `/Applications/Midas.app` on the release Mac mini.
About shows 0.48.1 (127); Sparkle's live check reports it is the newest available version.
Five superseded 0.48.0 installer/notarization ZIPs (134.3 MiB), the old installed app, and
three verified transient app copies were moved to recoverable Trash with checksum readback.
Source, settings, provider state, release evidence, and crash symbols were retained.
Website commit `b9086dc` reached production Ready as `dpl_At6A4DbU8LfFdsukBsCmDdiTwE9K`.
All 18 browser checks passed against `midas-ai.dev`. Both live download links select 0.48.1,
and an archive downloaded through the live page matches the signed public SHA-256.

## 0.48.0 changes: native macOS redesign

Version 0.48.0, build 126, adopts a compact native menu-bar panel, system typography,
SF Symbols, semantic system colors, and macOS 26 Liquid Glass navigation controls.
Reduce Transparency and older macOS versions use an opaque navigation surface.
The panel is 360 points wide, with a dynamic height capped at 540 points. Exact dollar
amounts, independent account allowances, reset times, and estimate coverage remain visible.
Usage history and Settings use native split-view sidebars. Coverage and sync status open
inside the panel; direct menus keep common actions short.

This integrates on top of 0.47.1: shared usage, both-account history, DGX Spark pricing
coverage and token totals, and memory improvements are preserved. Local API-equivalent
value remains an estimate, not a bill; billed provider charges stay separate.

The canonical package passed 4,569 Swift Testing tests and all 52 XCTest tests across
524 suites, using the repository's bounded suite runner (44 groups, no failures or timeouts).
Strict lint passed with zero violations. The 82 Python hub/collector tests passed with nine
existing skips, and native light/dark/accessibility render fixtures were inspected. A synthetic
wheel fixture now clears inherited modifier flags, preventing a held Shift key from turning its
vertical event into a horizontal one; production scrolling is unchanged.

The signed binary identifies source `ff062967f`. Apple notarization submission
`d9e4c376-ec76-4925-bc2a-2fee5ed32725` was Accepted. The app and dSYM share arm64 UUID
`8BFBF2DC-0E57-3EEF-978E-339043D98C2A`. Stapling, Gatekeeper, the embedded Sparkle key,
both XML feed signatures, the archive signature, and downloaded draft and anonymous public
asset checks passed. The release was published October 17, 2026 (October 18 UTC), with archive
SHA-256 `e73ebc67debb354dfd3619eb137b6f49aecb106df123d5a9a831bbcff06df623`.

The same public bundle is installed at `/Applications/Midas.app` on the release Mac mini.
Its running executable matches the downloaded binary; About shows 0.48.0 (126), and Sparkle's
live check confirms it is the newest available version. Twelve superseded installer/notarization
ZIPs and three old app/preview bundles were moved to recoverable Trash with hash readback;
source, preferences, provider state, release evidence, and crash symbols were retained.

Website commit `e846d43` reached production Ready as `dpl_HuKx7AdGSU34AkpwxaFDm4vNaqk6`.
All 18 production browser tests passed; both public download links point to the verified archive,
and a download followed from `midas-ai.dev` matches its SHA-256.

Full Xcode is available at `/Volumes/PortableSSD/Xcode/Xcode-27.0.0.app/Contents/Developer`;
set `DEVELOPER_DIR` per command rather than changing the machine's selected developer tools.
This full canonical validation supersedes the initial CLT-only preview workaround.

## 0.47.1 changes: shared-history performance

Version 0.47.1, build 125, reduces shared-history allocation and recurring UI-thread
work without changing usage totals, account scope, source identities, or estimated
pricing coverage. Identical records skip canonical JSON; the ledger accumulates
compact day/model totals; export reuses bounded bookkeeping; publication validation
reuses UTC day boundaries; and stable ID hashing avoids per-byte formatting.

The coordinator restores one decoded cache and moves recurring merge/encode/atomic
write work to a serial worker with cancellation and generation checks. An unchanged
Codex scan skips the full cache rewrite, and cache freshness is bound to file
identity. Codec/scan autorelease pools and bounded network buffer ownership reduce
transient allocation. Bounded envelope/publication encoding and size-only byte counting
avoid whole-history encoder graphs on saves, uploads, and peer validation. See [memory footprint](MIDAS_MEMORY.md) for profiling details
and invariants. The final fixed-corpus comparison reduced peak physical footprint
from 626.9 to 321.2 MiB with identical snapshots and about 18% less elapsed work.
A separate envelope-encoding comparison reduced its peak from 585.6 to 253.5 MiB.
These results apply to the measured workloads; intermediate samples can be higher.

Build 125 passed all 4,568 Swift tests in 516 suites, the 82 Python hub/collector tests,
and strict lint. Linux arm64 and x64 CI passed for the released source. The signed
archive identifies source `d83d70d70`; Apple notarization submission
`2837865c-f321-44f5-a9a3-1c6f1dbc9704` was Accepted. The app and dSYM share arm64 UUID
`6658FCC8-6449-36C2-9526-E625508B5BFA`. Stapling, Gatekeeper, the embedded Sparkle key,
both XML feed signatures, the archive signature, and downloaded draft and
anonymous public asset checks passed.

The public archive was published as
[`v0.47.1-midas.2`](https://github.com/enzo-prism/midas/releases/tag/v0.47.1-midas.2)
on October 17, 2026 (local release date). Its SHA-256 is
`80c60fa54306ee5c798a179b1d702124d95ae5d90e43479fa6fb8ece1c475415`.
The public bundle is installed on the release Mac. Installation on any other Mac
requires its own version/checksum receipt. The marketing repository
`bf65627` was deployed to `midas-ai.dev` as
`dpl_7nPAUYEvxzvj96AvLuV8nCzA5Kbh`; all 18 production browser checks passed,
and both immutable download links point to the verified archive.

## 0.46.2 changes: Meta scan streaming

Version 0.46.2, build 123, removes the largest memory spike found in the October 15
profile (see [memory footprint](MIDAS_MEMORY.md)): `MuseSessionLogScanner` loaded whole
Muse `session.jsonl` files via `readToEnd()` and fully JSON-parsed every line on each
Meta refresh. It now streams with `CostUsageJsonl.scan`, a `model_completed` byte
prefilter, `Data`-level parsing, and per-line/per-file autoreleasepools. On the profile
machine (1.7 GB of Muse logs) the startup footprint peak dropped from 3.59 GB to
129 MB and steady footprint sits near 50 MB; Meta totals are unchanged.

Build 123 passed the full suite except the known PathBuilder timing flake (also failing
on the untouched base under full-suite load; passes in isolation), `make check`,
Developer ID signing, notarization (submission `d42192b2-bb82-46ea-8b72-04781798512e`,
Accepted), stapling, Sparkle archive/feed signature checks, and downloaded draft and
public asset verification (SHA-256
`de8684bebb8cc21979afacc8894e8f598cfb8e7933f0949ac3b592bb8196ebb8`). The binary
identifies source commit `45b377da1`. The marketing site was updated to 0.46.2 and its
production download was verified against the same checksum.

## 0.46.1 changes: retained-window cost scans and sync recovery

Version 0.46.1, build 122, cuts cost-scan work and keeps usage sync connected:

- Claude/Codex/Pi scans only force a full reparse on backward window expansion; Claude
  scans retain the union of requested and cached windows (bounded, never truncating the
  request), skip cache rebuild/re-encode when nothing changed, and memoize built
  reports by content fingerprint. Repeat scans over 4.4 GB of logs drop from ~26 s to
  under a second. Claude cache artifact is now `claude-v6.json`.
- Offscreen dashboard WebViews are capped at 2 idle entries; a memory-pressure monitor
  evicts them and returns free malloc pages; usage-sync completion also relieves.
- Sync compares archived iCloud identity tokens correctly and preserves the folder and
  offline history through temporary identity outages.

Build 122 passed the full suite except the known PathBuilder timing flake, `make check`,
Developer ID signing, notarization (submission `d4e23901-eb95-4daa-b94c-265217388fc9`,
Accepted), stapling, Sparkle archive/feed signature checks, and downloaded draft and
public asset verification (SHA-256
`6400a0516dead43f5cbeccc4b106ec115e4512a2c9be20a12a2e8b60513356ee`). The binary
identifies source commit `78a82258f`. It was superseded by 0.46.2 the same day.

## 0.47.0 changes: DGX Spark and private hub sync

Build 124 adds a dedicated NVIDIA-branded DGX Spark card with rolling 30-day UTC tokens and
cache-aware hosted API-equivalent value for verified Qwen3.8-Flash-Next measurements. The
versioned Lyceum comparison uses $0.20 uncached input, $0.05 cached input, and $0.50 output
per million tokens; the local NVIDIA NVFP4 variant can differ from hosted inference. Values
are estimates rather than charges or measured savings. Legacy or incomplete records remain
unpriced, and runtime counters are collected prospectively without invented historical dates.

Private Tailscale hub transport reuses the validated deduplication ledger, durable offline retry,
and per-device credentials. It does not require iCloud identity. Both Macs derive totals from
the same shared source set; each OpenAI account's verified cloud history and quota remain
separate from recorded-event totals. Per-provider freshness cannot be refreshed by an unrelated
device's publication. See [hub setup](MIDAS_TAILSCALE_HUB.md) for data and coverage rules.

Source, collector fixtures, native render fixtures, signed artifacts, notarization, public release,
and website deployment are separate release gates. Record publication evidence only after each
gate succeeds.

Build 124 passed 4,536 Swift tests in 512 suites, all 82 Python collector/hub tests,
and `make check`. Ten native synthetic fixtures cover the Spark card and detail in light and
dark appearances, including waiting, unpriced, stale, and mixed price-coverage states. Live Spark records were received
by the private hub with the verified public model and separate input/output/cache deltas; retained
unclassified history stayed unpriced. These checks do not by themselves prove binary publication
or an update on another Mac.

The signed Apple Silicon archive was published on October 17, 2026 as
[`v0.47.0-midas.1`](https://github.com/enzo-prism/midas/releases/tag/v0.47.0-midas.1).
It identifies source commit `a7c061162`. Notarization submission
`79fd1c81-6106-46c6-8dd5-26a606391b23` was Accepted. Stapling, Gatekeeper, matching arm64
dSYM UUIDs, archive verification against the app's embedded Sparkle public key, both signed
feeds, and downloaded draft/public asset checks passed. The app ZIP's SHA-256 is
`fe5dac2287cb5bb2456befb9dde20ed075fb8c19ef059e4478869a5dbc191de0`.
The marketing repository's `0de36e1` was deployed to `midas-ai.dev` as
`dpl_FNqjaypMZrEupJU6QUAGwmQcum9C`; all 18 public-site browser checks passed.
The public bundle was installed and its three-device receipt verified on the release Mac.
Another Mac's installation still requires its own version/checksum receipt.

## 0.46.0 changes: Meta plan usage

Version 0.46.0, build 121, replaces the recorded-activity estimate with Meta's own
plan windows:

- `MetaSubscriptionUsage` parses the Muse host's MSP `SubscriptionUsage` payload
  (current-window used percent, duration, and reset; weekly used percent and reset;
  opaque tier id; observation stamp) and persists on `UsageSnapshot.metaUsage`.
  `MetaSubscriptionFetchStrategy` runs before the local-log strategy, combines the
  windows with local token totals for spend, and falls back when unobserved.
- `MetaUsageProbe` / `MetaMSPClient` spawn `muse serve`, resume Midas's dedicated
  "Midas usage check" session (created and named on first use), try `usage/read`,
  and otherwise send one minimal prompt to trigger `usage/changed`.
  `MetaSubscriptionUsageCache` throttles probes to one per 55 minutes and keeps the
  last reading through failures. Two pipe bugs found in live testing are fixed by
  design: SIGPIPE is ignored before writing to the child, stderr goes to the null
  device, and reads use a readability-handler line stream (`readData(ofLength:)`
  blocks for a full buffer on pipes).
- Air and the legacy card render **Current usage** / **Weekly limit** as quota bars
  (% left, reset countdowns, show-used preference honored, both pinned in the
  overview) whenever `metaUsage` is present; the 0.45 activity bars remain the
  fallback. Orbit still excludes Meta. Live verification: `codexbar usage
  --provider meta` reported source `muse-usage` with Current 12% left (resets in
  1h 3m) and Weekly 71% left (resets in 5d 16h), matching the account's usage page.

Build 121 passed the focused Meta suites (54 tests), `make check`, Developer ID
signing, notarization (submission `9e6c2d83-5cd1-48ca-8b36-1cfe337f49ad`, Accepted),
stapling, Sparkle archive/feed signature checks, and downloaded draft and public
asset verification (SHA-256 `becbc04d51cfa22e95f4a4fc1ab2cb058c067afbe8bc7495bd79cb9676b8e951`).
The binary identifies source commit `fa2b3a2b1`. The full suite showed only the known
PathBuilder timing flake, which pass in isolation. The marketing site was updated to
0.46.0 and production serves the new download.

## 0.45.0 changes: Meta usage left

Version 0.45.0, build 120, makes Meta bars show how much usage is left:

- `MetaActivityWindow` gains `remainingPercent` (100 minus the used share),
  `remainingTokens`, and `hasBaseline`. Air (`MidasActivityBar`, detail hero) renders
  remaining with the shared `MidasRemainingBar` warning when headroom is low; the
  legacy menu card shows percent left (or used, following `usageBarsShowUsed`) with
  tokens left in the trailing label.
- Copy always names the baseline ("vs busiest day/week", "Left estimated vs busiest
  recorded day/week · Meta reports no plan limit") because Meta publishes no quota,
  limit, or reset. No baseline keeps the bar empty instead of reading as full.
  Menu-bar rings and Orbit are unchanged: Meta keeps its neutral ring.
- Focused coverage in `MetaActivityBarsTests` covers draining (idle 100% left,
  busiest 0% left, no-baseline), Air "% left" presentation, and the legacy card in
  both show-left and show-used modes. The anti-fabrication contracts in
  `MidasMetaPresentationTests` (no quota hero/metrics, no % in the summary) still pass.

Build 120 passed the focused Meta suites, `make check`, Developer ID signing,
notarization (submission `091654fe-ebf5-443a-aa94-bd0078c0b4f1`, Accepted), stapling,
Sparkle archive/feed signature checks, and downloaded draft and public asset
verification (SHA-256 `80eb1b80b4ae62f1517e1cc2001708d27f008ac9cb26154fb75473602bb8d3ba`).
The binary identifies source commit `7d635d55b`. Full-suite runs showed only timing
flakes (login-runner, Antigravity HTTPS, PathBuilder) that pass in isolation, the same
pattern recorded for 0.44.0. The marketing site was updated to 0.45.0 and its production
download was verified against the same checksum.

## 0.44.0 changes: Meta activity bars

Version 0.44.0, build 119, gives Meta Claude-style bars without inventing a quota:

- `MetaActivitySnapshot` records Today / Last 7 days / Last 30 days Muse tokens and
  requests plus busiest-day and busiest-rolling-week totals, persisted on
  `UsageSnapshot.metaActivity`; `MetaActivitySnapshot(tokenSnapshot:)` derives the same
  windows from token history when only that is available.
- Air overview and provider detail render `MidasActivityBar` rows (detail hero is Last
  7 days) with the shared `MidasRemainingBar` capsule in activity tone; the legacy menu
  card shows the same Today / Last 7 days rows. Labels read "N% of busiest day/week";
  no percent-left, reset, or menu-bar quota ring is produced for Meta.
- Focused coverage lives in `MetaActivityBarsTests`; the anti-fabrication contracts in
  `MidasMetaPresentationTests` (no hero, no quota metrics, no % in the summary) still pass.

Build 119 passed the focused Meta suites and lint, Developer ID signing, notarization
(submission `047758b0-3b49-4d9f-af85-00550a2f6fe5`, Accepted), stapling, Sparkle archive/feed
signature checks, and downloaded draft and public asset verification. The binary identifies
source commit `a7c7ac71e`. Three AppKit menu-timing tests flaked under full-suite parallel
load and passed when their suites were rerun; they are unrelated to this change.

## 0.43.0 changes: usage sync

Private shared-folder usage sync combines recorded Codex, Claude Code, Muse Code, and verified
Cursor account history across Macs. The selected scope also supplies monthly comparisons,
spend history, menu-bar totals, and widgets. See [usage sync](MIDAS_USAGE_SYNC.md).
Build 118 passed 4,487 local tests and lint, Developer ID signing, notarization, stapling,
Sparkle archive/feed signature checks, and downloaded draft and public asset verification.
The binary identifies source commit `08a899aea`; later publication metadata edits are documentation only.
Source changes and synthetic two-device tests do not establish MacBook installation or real
iCloud delivery. Check that separately after connecting both devices.

## 0.42.0 changes

Version 0.42.0, build 117, adds calendar-month comparisons to Spend history:

- `MidasMonthlySpend` groups validated daily records into 6 or 12 contiguous calendar months.
  It retains missing versus zero values, rejects conflicting daily duplicates, and compares only
  compatible recorded days. Current-month comparisons stop both periods at the same ordinal day.
- `MidasMonthlySpendView` uses native Swift Charts with hover selection, month navigation,
  costs/tokens controls, and accessible monthly records. Both Overview and provider pages use the
  full provider snapshot, independent of the daily-history filter.
- A user-initiated longer-history action sets the existing 365-day setting and refreshes supported
  sources. It does not enable logging, change accounts, or switch Codex sources.
- API/cloud day keys use UTC; local transcript history uses the Mac's reporting calendar.
  Codex cloud's 30-day and Mistral's current-month limits remain explicit.

See [monthly spend](MIDAS_MONTHLY_SPEND.md) for data boundaries, comparison semantics, and
synthetic native preview verification. Provider costs retain their source meaning; the chart does
not turn a subscription usage estimate into a bill or persist a new historical ledger.

## 0.41.2 changes

Version 0.41.2, build 116, adds independent Claude account connections:

- An isolated temporary sign-in session verifies the email before a checked save. Nicknames,
  reconnect, failed-save rollback, and privacy masking use the existing account settings.
- Saved accounts refresh with their own credentials, including when the source selector is CLI.
  They cannot silently fall back to shared browser, CLI, or Keychain credentials.
- Account display rejects stale credential results and mismatched returned identities. Limits,
  reset times, freshness, and connection errors stay with the corresponding account.
- The overview pins 5-hour and all-models weekly limits; model-specific limits stay in details.
  Local Claude Code dollar estimates remain provider-wide.

Two separate accounts were signed in, identity-verified, saved, and read back with distinct live usage
in the local release app. Public documentation and release assets must not include their emails,
credentials, configuration, or usage screenshots. See [setup](MIDAS_SETUP.md#multiple-claude-accounts).

## 0.41.1 changes

Orbit selects only the provider’s weekly allowance (Cursor’s total monthly allowance), with
no session, model-only, or pool fallback. Missing/non-finite readings stay unknown. Low-quota
attention uses the same selected allowance; provider errors and service incidents remain visible.
The panel and other menu-bar modes retain their existing limit selection.

Packaging accepts `MIDAS_SWIFTPM_SCRATCH_PATH` and `MIDAS_WIDGET_DERIVED_DATA_PATH`
to place rebuildable compilation artifacts separately from internal signed release outputs.

## 0.41.0 changes

Version 0.41.0, build 114 (PRs #12–#16):

- `CodexOAuthRefreshCoordinator` single-flights Codex token rotation per `auth.json`;
  `CodexOAuthCredentialsStore.save` forces 0600; credits reuse the usage response
  (`rememberCodexUsageCredits`).
- `MidasSpendPeriod` computes ranges in the source's reporting time zone (local scans vs UTC cloud/billed).
- Cursor spend carries its owner (`CostUsageTokenSnapshot.accountEmail`, cost scope `cursor:<account>`);
  `CursorSpendSnapshotCache` only stores owned values.
- Grok Bot: lenient `CursorSandUsageStatus` decoding, retried dashboard calls, `grokBotUnavailableReason`,
  `UsageStore.retainingCursorGrokBot`, and the `MidasLogo-grok` template mark.
- Provider registration macros removed (upstream `faab45eb9`, `30506ca7f`, `22a07ef22`); Linux CLI CI is green.

## 0.40.0 changes

Version 0.40.0, build 113:

- `MidasCursorLimits` pins Cursor's dashboard trio (`cursor-pool-models`, `cursor-pool-other`,
  `cursor-grok-bot`) in the overview.
- `CursorSandUsageStatus.allowance` reads `includedLimitZero` and `sandTrialExpiresAt`.
- `CursorUsageEventsFetcher` retries pagination races and widens the model aliases used for
  omitted-cost events.
- `CursorSpendSnapshotCache` (`cursor-spend-v1.json`) hydrates the last good Cursor estimate at launch.
  The store keeps it, labeled last known, through refresh failures.

## 0.39.0 changes

Version 0.39.0, build 112, surfaces Claude's model-only weekly limits (today, Fable). It ports upstream
CodexBar #1851 and its all-models follow-up (`limits[]` `weekly_scoped` rows from the OAuth and web APIs,
`ClaudeScopedWeeklyLimitMapper`) and upstream's CLI "Current week (<Model>)" parsing, with a tolerant
all-models filter. `MidasClaudeLimits` pins `claude-weekly-scoped-*` bars as "<Model> weekly limit". The
CLI reset matcher accepts "Reset"/"Resets" without breaking compact captures.

## 0.38.0 changes

Version 0.38.0, build 111, makes Claude dollars visible. The Claude local-log token snapshot is now
`CostProvenance.listPriceEstimate` (it was `.unknown`, which Midas treats as not displayable). The
built-in Claude table adds the Claude 5 family, and rows carry the fast-mode, US-only-inference, and
web-search modifiers. The Claude cache version moves to `claude-v5.json`, which triggers one local
rescan. Unpriced rows are counted per day so period totals are disclosed as partial. Claude pricing
now lives in `CostUsagePricing+Claude.swift`, outside the Codex parser hash. The previous Codex
producer key stays compatible, so Codex caches are not rebuilt.

## 0.37.1 changes

Version 0.37.1, build 110, adopts cache items from the CodexBar-era cache service
(`com.steipete.codexbar.cache`) into `com.designprism.midas.cache` on first use. 0.37.0 adopted only
the main Keychain service, so cached browser sessions such as `cookie.cursor` were orphaned and
Cursor showed Needs attention. Each item is attempted once; macOS may ask to allow the read.

## 0.37.0 changes

Version 0.37.0, build 109, moves Midas to its own product identity and adopts pre-0.37.0 data on
first launch (preferences, storage folders, app group, and lazily the Keychain items). See
[the changelog](../CHANGELOG.md).

## 0.36.0 changes

Version 0.36.0, build 108:

- **Claude limits:** the Air overview pins Claude's **5-hour limit** and **Weekly limit** bars
  (`MidasClaudeLimits`), titled by window length.
- **Anthropic provider:** organization billed spend via the Admin API (`CostProvenance.vendorBilled`),
  shown per provider and excluded from the estimate total.
- **Settings:** now an AppKit window owned by the app delegate (`SettingsWindowController`), replacing the
  hidden SwiftUI keepalive window that macOS 27 could tear down, which left Settings clicks with no effect.

## 0.35.4 changes

Version 0.35.4, build 107, updates Sparkle to 2.10.0 (Golden Gate compatibility release)
and KeyboardShortcuts to 3.1.0 (Swift 6.3 release-build crash fix), and clears the
format/lint gate. No behavior changes.

## 0.35.3 changes

Version 0.35.3, build 106, expands the spend-period list and estimate-coverage details inline so
Last 30 days → This month and Partial total do not abort on macOS 27, hydrates cached Codex
weekly usage when managed accounts omit `workspaceAccountID`, and offers the public signed ZIP
from Check for Updates when Sparkle cannot run. Period math is unchanged.

## 0.35.2 changes

Version 0.35.2, build 105, adds per-account Codex banked reset counts, explicit missing and stale
reading states, and fresh menu-bar pop-up anchoring on every opening. The published archive and
signed update feed passed public checksum, signature, and notarization verification.

## 0.35.1 changes

Version 0.35.1, build 104, is published as `v0.35.1-midas.1`. It improves the spend-period dropdown
with direct anchoring, distinct interaction states, date previews, keyboard controls, and validated
historical-month choices. See [setup](MIDAS_SETUP.md#choosing-a-spend-period).

## 0.35.0 changes

See [the changelog](../CHANGELOG.md) and [setup and estimate coverage](MIDAS_SETUP.md).
This release combines the focused spend design, multi-account Codex cloud usage, automatic
pricing and optional iCloud calibration sharing, and resumable three-step onboarding.

## 0.33.6 changes

- Brighten the pixel crown with a crisp highlight, warm trail, and a single-point sparkle.
- Give the crown a longer rest between loops; Reduce Motion keeps it static.

## 0.33.5 changes

- Size menu-bar items to their visible content, removing unused horizontal space.
- Preserve readable amounts and provider indicators across Orbit, Ledger, Focus, and Constellation.

## 0.33.4 changes

- Sharper native SF typography across the panel, provider details, and Usage window.
- A gold pixel crown with a subtle looping shimmer in the panel header; Reduce Motion keeps it static.
- A fixed footer for Favorite provider and Check for Updates, with an explicit selector label.

## 0.33.3 changes

- Switch the menu-bar circle provider directly from the panel’s provider dropdown.
- Add a visible Check for Updates action using Sparkle’s standard signed download/install flow.
- Ship Orbit, the selected-provider ring, and concise 30-day token-count tooltips.

## 0.33.2 changes

- Replaces “Estimated spend” with “Token spend (API rates)” in provider cards, totals,
  menu-bar tooltips, and accessibility descriptions.
- Keeps provider-metered values distinct and preserves the explanation that API-rate values
  are estimates, not billed charges. Usage calculations and remaining-capacity behavior are unchanged.
- Validated with 34 focused presentation/layout tests, strict lint, and light/dark native fixtures.

## Release procedure

1. Run `make check` and the relevant native/menu regression tests. Inspect light/dark native fixtures.
   For Swift Testing, set `SWIFT_TESTING=1` (also accepted by usage-store startup detection);
   `SWIFT_TESTING_ENABLED=1` can additionally be set for compatibility with older harnesses.
   Test stores skip automatic provider detection, token-source scans, automatic background
   refreshes, and implicit prior-spend scans. Manual fixture callbacks remain available.
   Do not replace fixture checks with live provider probes.
2. Set the next build number in `version.env` and commit the reviewed source. Build from that exact
   commit so `CodexGitCommit` identifies the release. Push `main` only after the source and release
   actions have been approved; do not force-push or replace published tags/assets.
3. Confirm `security find-identity -v -p codesigning` lists a valid **Developer ID Application**
   identity with its private key. Apple Development and Apple Distribution identities are not
   substitutes for outside-the-App-Store distribution. Stop binary publication if it is missing.
   Build with `APP_TEAM_ID` and `APP_IDENTITY` matching the installed Midas developer signature:
   `APP_TEAM_ID=... APP_IDENTITY='Developer ID Application: ...' ./Scripts/package_app.sh release`.
4. Verify with `codesign --verify --deep --strict Midas.app` and inspect the timestamp/team.
5. Create a temporary ZIP using `ditto --norsrc -c -k --keepParent`, then submit it with
   `asc notarization submit --file <zip>`. Use `asc notarization status --id <id>` until accepted.
6. Staple with `xcrun stapler staple Midas.app`, then run `xcrun stapler validate` and
   `spctl --assess --type execute --verbose Midas.app`.
7. Create a new final ZIP of the stapled app and a SHA-256 checksum. Never reuse the unstapled ZIP
   for distribution. Prepare the release against the exact tested commit in `enzo-prism/midas`
   with an explicit architecture label. Include license notices and the existing bundled credits.
8. Sign the final app ZIP using Sparkle’s `sign_update --account enzo-prism-midas`.
   The private key remains in the login Keychain; never export it into the repository.
   Generate `Midas-appcast-arm64-v2.xml` using `Scripts/make_midas_appcast.py` with that signature,
   the exact version/build/tag, and the final archive, and `Midas-appcast-arm64.xml` with
   `--informational` for pre-0.37.0 clients. Include both feeds in **every** latest stable
   GitHub release: installed Midas reads `/releases/latest/download/<feed>`.
   Verify the archive signature with `sign_update --account enzo-prism-midas --verify` before publishing.
   Sign the XML feed too with `sign_update --account enzo-prism-midas <feed.xml>`, then verify it
   using `--verify`. Generate final checksums after signing. Upload the archive, feed, checksums,
   and matching dSYM as a draft; verify downloaded draft assets before publishing it as latest.
   Never replace a release asset after signing it. Do not publish Intel archives on this feed.
9. Download the published asset, verify its SHA-256, and inspect the extracted app signature/ticket.
   Extract into a clean temporary directory outside Documents to avoid File Provider metadata
   modifying signed bundles. Restart the local app from the same validated bundle and confirm its process remains running.

Keep signed archives and signing credentials on internal encrypted storage. Do not publish logs,
provider account data, keys, or local settings. A source push, a signed build, an accepted Apple
submission, and a verified public download are separate verification steps.

## Website publication

The marketing site is a separate repository at `enzo-prism/midas-site` (Vercel project
`midas-by-prism`, production domain `midas-ai.dev`). Verify its actual Git remote before pushing.
Update version labels, download URLs, and the Updates entry only after the matching GitHub
archive is public and verified. Build and test the site, deploy production, then follow the
public download link and confirm it retrieves the exact signed archive. Do not advertise a
release candidate as available while notarization or signing is blocked.
