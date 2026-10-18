# Midas Air

Midas Air replaces the main menu presentation with one native SwiftUI popover hosted by the
existing status-item controller. It keeps the provider engine, account coordinators, saved
settings, and legacy menu-bar icon preferences intact. macOS 14 remains the minimum target.

The compact native redesign is published as **0.48.0, build 126**:
[v0.48.0-midas.1](https://github.com/enzo-prism/midas/releases/tag/v0.48.0-midas.1).
The **0.48.1, build 127** refinement is published as
[v0.48.1-midas.1](https://github.com/enzo-prism/midas/releases/tag/v0.48.1-midas.1).

## Current onboarding and account coverage

Onboarding follows Services → Accounts → Overview. See [the setup guide](MIDAS_SETUP.md)
for sign-in, cloud coverage, pricing, iCloud privacy, and missing-data behavior.
`MidasOnboardingLaunch` decides first-run presentation before settings migration;
`PreferencesSelection` persists deferred progress. `MidasSpendSetupView` uses the existing
account coordinators and finishes without blocking on provider refreshes.

The primary display is **Estimated AI token value** for the selected period, accompanied by
recorded token totals. Both preserve the 0.47.x counting and coverage rules.
`MidasSpendPeriod` selects actual daily history for calendar or rolling periods;
`MidasSpendPeriodControl` uses a native `Menu` and `Picker` for date choices. Estimate coverage
and usage-scope/sync details open as pages inside the same panel, with a Back action. Never add
a nested `.popover` or `.focusable()` key-view loop inside the status-item `NSPopover`.
`MidasAccountUsageView` keeps account capacity and reset times separate.
`UsageStore+CloudUsage` combines available Codex account history, `MidasCodexEstimate` provides
blended pricing, and `MidasCalibrationExchange` shares optional derived samples.

Version 0.48.1 removes inline **Partial total** and **Partial estimate** notices. The
neutral **More → Estimate details** action opens coverage information, including missing
sources and unpriced history. No estimate, subtotal, exclusion, or unavailable state changes.

## Everyday surfaces

- **Overview:** a 360-point panel with content-dependent height, capped at 540 points and the
  available screen height. The total and actions stay fixed while provider rows scroll. Every
  provider keeps its spend visible beside its name; a two-column quota grid retains independent
  limits, percentages left, and reset times. The footer opens spend history and usage-scope/sync
  details. Refresh, Settings, and More actions share one compact navigation capsule.
- **Provider detail:** prominent token spend (API rates), recognizable logos, explicit periods and remaining capacity, reset
  information, and separate session constraints. Codex uses weekly remaining as its quota hero;
  missing weekly data does not turn into a session metric. Claude always pins its
  **5-hour limit** and **Weekly limit** bars in the overview (`MidasClaudeLimits`, titled by window length),
  with model-only and other extra limits available in provider details. Model-only weekly limits
  (ids `claude-weekly-scoped-*`, from `limits[]` rows of kind `weekly_scoped`) retain their reset
  times and explain that the all-models weekly limit still applies. Cursor pins its
  dashboard trio (`MidasCursorLimits`): **Cursor Models**, **Other Models**, and **Grok Bot weekly**
  (or **Grok Bot trial**), falling back to Total when the pools are unreported; Total stays the hero for
  the menu-bar ring. Grok Bot carries a small monochrome Grok mark (`MidasLogo-grok`, a template image).
  When Cursor does not return Grok Bot usage, the row keeps the last known value until its weekly reset,
  or shows **Unavailable** with no bar; it never becomes the headline or a low-quota warning. Other providers show one headline limit plus any tighter window.
- **Usage window:** a native `NavigationSplitView` and selectable sidebar `List`, with Overview
  represented by no selected provider. Provider cards precede comparison history in the overview.
  Usage and Costs views retain period controls,
  daily history, provider-specific **Month by month** cost/token charts with 6/12-month controls,
  accessible monthly records, model breakdowns where available, and source-aware cost labels. Metered consumption,
  provider-reported costs, and API-equivalent estimates are distinct meanings.
- **Settings:** native split-view/sidebar navigation preserving General, Providers, Sync, Display, Advanced, About,
  and the optional Debug pane. Its height is constrained for smaller screens. The window is owned
  by `SettingsWindowController` on the app delegate; do not reintroduce a hidden SwiftUI
  keepalive window as the only listener for opening Settings.
- **Branding:** a decorative SF Symbols crown beside the Midas name in the panel and Usage sidebar,
  Midas display names and support links, and explicit
  acknowledgment of CodexBar's MIT-licensed foundation.

## Native appearance and accessibility

Midas uses the native SF Pro system font, semantic text styles, semibold headings, and
monospaced digits for money and quota readings. Provider-detail spend uses a 34-point headline;
large values scale on one line. System `NSColor` backgrounds, primary/secondary text, and the
user's accent adapt to appearance and contrast settings. SF Symbols supply standard actions;
bundled provider marks preserve service identity. The static crown is hidden from accessibility.

On macOS 26 and later, `MidasNavigationGlass` applies regular Liquid Glass once to the panel's
navigation capsule. Spend and quota content stays on solid system surfaces. Reduce Transparency
and older macOS versions use a solid capsule with a separator border. Native sidebar, menu,
picker, button, and toolbar components keep their system behavior; custom glass is limited to
navigation. macOS 14 remains supported.

Apple references: [Materials](https://developer.apple.com/design/human-interface-guidelines/materials),
[custom Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views),
[NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview),
[Typography](https://developer.apple.com/design/human-interface-guidelines/typography), and
[SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols).

## Original provider menu

Right-click the status icon or choose **Provider actions & accounts…** from the panel's menu
for the original provider actions, diagnostics, and account menu. This is an intentional
compatibility path during the presentation migration. It uses the same data and coordinators.
The packaged `MidasAirEnabled` Info.plist flag selects the new presentation; unbundled/test
runs preserve the original routing. Do not edit a signed app's plist to switch it.

## Spend and provider semantics

Local totals use all enabled providers, before Favorites filtering. Combined totals use the
shared numeric source set through `midasProvidersForTotalDisplay()`, independent of each Mac's
provider display preferences. `MidasRecordedTokenTotal` sums recorded tokens over the selected
period, excludes billed organization history that can overlap coding logs, and preserves missing,
partial, conflicting, and overflow states. Token totals are activity, not remaining quota.

Claude contributes its local Claude Code transcript value at Anthropic API rates (`CostProvenance.listPriceEstimate`,
see [Claude](claude.md#cost-usage-local-log-scan)); unpriced models remain disclosed in estimate coverage.
`MidasTotalSpend` sums primary, finite, nonnegative estimates from the selected source set.
It deduplicates providers, keeps currencies separate without conversion, and
reports coverage and reporting periods. A missing estimate is excluded rather than converted to
zero; a genuine zero estimate remains valid. Secondary API equivalents, metered balances, and
reset credits are not additional token spend (API rates). Provider valuation bases can differ, so this
total is a sum of usage-rate estimates, not billed charges. Billed organization spend (`CostProvenance.vendorBilled`,
currently the Anthropic provider) is shown on its own row as *Billed API spend* and reported in coverage as
"billed shown separately"; it never enters the estimate total, which also avoids double counting Claude Code
sessions billed to an org API key.

DGX Spark retains its own NVIDIA-branded card and a fixed rolling 30-day UTC window, independent
of the spend selector. Prospective vLLM measurements show tokens and a named hosted API-equivalent
value only when the model and token classes establish pricing. Unknown usage remains unpriced,
pricing coverage stays explicit, and the value is neither billed spend nor measured savings.
Private hub/folder sync, separate OpenAI account histories, stable record identities, offline
retry, and bounded 0.47.1 history processing remain unchanged. See
[hub setup](MIDAS_TAILSCALE_HUB.md) and [memory profiling](MIDAS_MEMORY.md).

Codex keeps weekly remaining separate from session constraints, and its single menu-bar capsule
never substitutes session data when weekly data is missing. Cursor model spend shares are not
quota; actual request counts and independent usage pools remain separate. Meta can show local
history when cost collection is disabled, without fabricating remaining capacity. Meta's
observed Current usage and Weekly limit remain percent-left readings with provider-reported
reset times, read through the Muse host. When no plan reading is available, the 0.48.1 overview
uses a short recorded-activity summary. Provider details retain Today and Last 7 days of recorded
Muse tokens and the explicitly named busiest-window baseline; these are not reported plan
allowances. The legacy menu card retains its existing rows and show-used preference.
Neither observed Meta windows nor the activity fallback drive Orbit or other quota rings.

The menu bar defaults to **Orbit**: total token spend (API rates), followed by a ring around one
favorite provider’s logo. Use **More actions → Menu-bar provider**, or
**Settings → Display → Orbit provider**. The total follows the local/shared source set described
above, regardless of the favorite selection. Codex and Claude rings use total weekly remaining;
Claude never substitutes its 5-hour or model-only limits when weekly usage is unavailable. Cursor uses
its real quota, and Meta uses a neutral dashed ring because it has no quota. A disabled or missing
favorite retains its identity with unknown capacity; it never silently switches to another provider.
An empty solid ring means exhausted capacity, while a dashed ring means unknown capacity.

Existing Ledger users move to Orbit once. Other explicit modes and the selected provider remain
unchanged; choosing Ledger again is respected. **Ledger** remains available. **Focus** pins one
provider’s quota (Codex and Claude use total weekly remaining). **Constellation** shows up to three separate
readings, prioritizing enabled Codex, Cursor, and Meta, then other enabled providers. All modes
retain one content-sized native status item. Text uses 13-point monospaced digits; equal-length
numeric updates and status changes preserve width, while shorter readings reclaim space. Settings → Display offers these modes, focus-provider
selection, menu-bar spend privacy, and **Legacy**, which restores saved original icon preferences.

Cached background refreshes stay still. Active initial/manual requests can animate a separate
refresh glyph for up to 30 seconds, while changed readings fade for 180 ms. Reduce Motion removes
both effects. Static indicators disclose low quota, service incidents, last-known data, and partial
estimate coverage. Freshness is checked once per minute without an idle animation loop.

Left-click opens the overview for Orbit/Ledger/Constellation or the pinned provider for Focus.
Option-click opens Usage directly; right-click retains provider actions. The tooltip and accessible
name retain detailed provider readings in non-Orbit modes. Orbit’s hover tooltip shows only
past-30-day token counts and coverage; its accessibility description retains detailed status.
Spend privacy
also removes dollar amounts from those descriptions; the opened panel still shows spend.

See [the design research](MIDAS_MENU_BAR_DESIGN.md) for the original alternatives and implementation
notes. Orbit is now implemented; Reset Horizon remains an exploration.

Orbit keeps spend fixed during state changes. A separate satellite moves only during the favorite’s
active initial/manual refresh, never the capacity arc. Favorite warnings use an amber arc and static
square marker; last-known capacity is dimmed. Other providers’ incidents never recolor this ring.
Orbit’s hover tooltip contains only the past-30-day token counts for the favorite and all enabled
providers. It discloses partial provider coverage in a short suffix. Shorter history and billing-cycle
totals are unavailable rather than mislabeled as 30 days. Known zero counts remain zero. Quota,
spend, provenance, and warning details remain in the overview and accessibility description.

## Local rebuild

Use full Xcode 26 or later for the canonical build, full test suite, and package. This Mac has
Xcode at `/Volumes/PortableSSD/Xcode/Xcode-27.0.0.app`; select it per command/session with
`DEVELOPER_DIR`, without changing global `xcode-select`. Point `MIDAS_BUILD` at a verified scratch
path to reuse dependencies. Example external paths require the PortableSSD checks in `AGENTS.md`;
keep source and credentials internal.

```sh
export DEVELOPER_DIR=/Volumes/PortableSSD/Xcode/Xcode-27.0.0.app/Contents/Developer
MIDAS_BUILD=/Volumes/PortableSSD/Midas/2026-10-17-native-redesign/build
MIDAS_PREVIEW_OUTPUT=/Volumes/PortableSSD/Midas/2026-10-17-native-redesign/previews
make check
swift build --scratch-path "$MIDAS_BUILD"
swift test --scratch-path "$MIDAS_BUILD"
swift test --scratch-path "$MIDAS_BUILD" \
  --filter 'Midas(Presentation|TotalSpend|SpendPresentation|SpendPeriod|AccountQuotaLayout|ClaudeLimits|CursorPresentation|OrbitQuota|MenuBarPresentation)Tests'
MIDAS_PREVIEW_OUTPUT="$MIDAS_PREVIEW_OUTPUT" \
  swift test --scratch-path "$MIDAS_BUILD" \
  --filter 'MidasPresentationTests/export'
```

Initial design exploration used CLT-only SDK/macro workarounds and an isolated validation
manifest that excluded XCTest-only files. Those historical results are not a full-suite pass.
The 0.48.1 release passed all 4,571 Swift Testing tests plus 52 XCTest tests (4,623 total)
across 524 suites and 44 shards, with no failures or timeouts and zero lint violations. Sixty
native fixtures cover the presentation states. The public archive, signatures, notarization,
and latest feeds were verified. The canonical local `/Applications/Midas.app` was verified as
0.48.1 (127), matching the public executable; About and Sparkle reported 0.48.1. Website
commit `b9086dc` reached production Ready, all 18 live browser checks passed, and the download
followed from `midas-ai.dev` matched the signed archive. Receipt on another Mac remains separate.

The 0.48.0 release validation used full Xcode and the canonical `Package.swift`: all 4,569 Swift Testing
tests plus 52 XCTest tests passed across 524 suites and 44 shards, with zero lint violations.
The Python suites ran 82 tests with 9 existing skips. The published archive, both update feeds, Sparkle archive
signatures, notarization ticket, and embedded widget build 126 were verified. Installation and
receipt on another Mac require their own readback.

Preview exports use synthetic accounts and isolated stores, with no provider or Keychain probes.
Review light/dark, empty, stale, unavailable, exhausted, multi-account, and accessibility fixtures.
Follow the repository's no-live-probe test policy. Packaging remains separate:
`./Scripts/package_app.sh release`.

The packaging script defaults to the Midas Developer ID identity (team `L49MKXGVM4`); pass
`APP_TEAM_ID` and `APP_IDENTITY` only to build for a different signing identity. Use
`codesign -dvv Midas.app` to inspect a signature; the team also determines the app-group identity.

Packaging produces `Midas.app` with a `Midas` executable and the Midas bundle identifier, app
group, Keychain services, and storage folders defined in `Sources/CodexBarCore/MidasIdentity.swift`.
The `CodexBar*` Swift targets and bundled helper binaries keep their inherited names; they are
not product identity. Restart the freshly
built bundle using the repository's `Scripts/compile_and_run.sh` development workflow or its
approved local restart command. Do not launch an older copy from another location.

To regenerate the original Midas icon artwork:

```sh
swift Scripts/build_midas_icon.swift
```

This writes `Midas.icns` and intermediate PNGs under `work/midas-icon.iconset`, using native
AppKit/SF Symbols and `iconutil`. It does not overwrite upstream `Icon.icns`. Packaging copies
`Midas.icns` into the application resource name expected by its existing metadata.

## Assets and updates

Provider logos are bundled; opening the UI does not request logos from a server. Codex and Cursor
have appearance-specific variants; Claude and Meta retain their brand color. Other providers reuse
adaptive template marks. Asset sources are recorded in
`Sources/CodexBar/Resources/MidasLogo-SOURCES.md`. Menu-bar template images and full-color panel
images use separate loaders; cached panel images are copied before being returned.

SVG dimensions are normalized from their viewBox and rendered with proportional padding. Codex
artwork uses equivalent absolute cubic paths because CoreSVG truncated the original compact arc
paths. Preserve that conversion; transparent-border tests alone do not detect missing interior
geometry. Logo regression tests also check the full square silhouette.

Signed Apple Silicon Midas packages use their own Sparkle feed and public signing key. The app
validates that exact configuration before constructing its updater. Debug, ad-hoc, and Intel
packages keep `MidasUpdatesDisabled` and an empty feed. Upstream CodexBar release links elsewhere
in this inherited README are not Midas releases.

## Implementation boundaries

- `MidasAirCoordinator.swift`: native presentation lifetime and existing action routing.
- `MidasPresentation.swift`: provider presentation and navigation state.
- `MidasTotalSpend.swift`, `MidasTotalSpendView.swift`: estimate aggregation and shared total
  display. Air opens coverage on an in-panel page with Back; do not restore a nested `.popover`.
- `MidasMenuBarPresentation.swift`, `MidasMenuBarView.swift`: typed status readings and passive native rendering.
- `StatusItemController+MidasMenuBar.swift`: status-item integration, activity filtering, and freshness updates.
- `MidasPanelView.swift`, `MidasProviderDetailView.swift`: fixed summary/actions, scrolling
  compact provider rows, in-panel information pages, and provider details.
- `MidasSpendPeriod.swift`, `MidasSpendPeriodPicker.swift`: period math in each source’s reporting
  time zone (local scans vs. UTC cloud/billed days) and the native date menu.
- `CodexAccountUsageSnapshotStore.swift`: last-known Codex quota hydration; match on non-conflicting identity, and treat managed `providerAccountID` as the visible workspace when `workspaceAccountID` is absent.
- `MidasAppcast.swift`, `MidasSignedReleaseUpdater.swift`: public-feed ZIP download when Sparkle cannot run.
- `MidasUsageWindowView.swift`, `MidasUsageHistoryView.swift`, `MidasCostPresentation.swift`: native
  sidebar navigation, provider cards, history, and costs.
- `MidasMonthlySpend.swift`, `MidasMonthlySpendView.swift`: validated calendar-month subtotals,
  compatible month-to-date comparisons, native chart selection, and monthly records. See
  [monthly spend](MIDAS_MONTHLY_SPEND.md).
- `MidasDesignSystem.swift`, `MidasProviderLogo.swift`: system colors, panel dimensions,
  accessibility-aware navigation glass, and provider identity.
- `PreferencesView.swift`, `PreferencesAboutPane.swift`: sidebar settings and product identity.

Focused model tests cover quota direction, unavailable/stale states, account boundaries, cost
semantics, and logo caching. Native interactions and final signed-bundle launch should also be
verified after changes. Tests must not initiate real Keychain/browser/provider probes unless
explicitly authorized; follow the repository's AGENTS.md testing guidance.

## Updates

**Developer ID Applications installs** use Sparkle: Check for Updates → Download → Install & Restart
against `Midas-appcast-arm64-v2.xml` for the Midas identity (0.37.0+). Settings → About can enable
automatic checks. Releases from 0.33.3 through 0.36.0 read the informational legacy feed and need
one manual download of 0.37.0 or later because the bundle identifier changed.

**Development, Apple Development, ad-hoc, and Intel packages** cannot run Sparkle (the updater
requires a Developer ID signature and the exact Midas feed/public key). Check for Updates still
reads the public appcast and offers the latest signed GitHub ZIP. That ZIP is the last
*published* binary; source on `main` can be newer.

Sparkle publication itself needs `Developer ID Application: Lorenzo Quaid Sison (L49MKXGVM4)`
with its private key, plus Sparkle `sign_update --account enzo-prism-midas`. The Developer ID
*certificate* without the private key is not enough. Do not mint a new Sparkle key; existing
0.33.3+ installs embed `Wamu4ydtrOgeiui2Synb1ixgdZcNwDOpE0TOCtDdEbA=`.

## Multiple accounts

Claude's saved accounts always refresh independently, including a single saved account, regardless
of the Codex tracking option or the global Claude source selector. `ClaudeAccountSignInSheet` owns
an isolated temporary WebKit store; `ClaudeAccountSignInModel` verifies identity and performs a
checked save with rollback. `MidasTokenAccountPolicy` ties snapshots to the current account ID,
credential, organization, and verified identity so late results cannot attach to a replaced connection.
The selected account controls the provider headline and ring; the overview/detail account rows keep
limits separate. Claude's local dollar estimate appears once per provider.


Settings → Display → Track all connected accounts refreshes every configured account independently of the legacy menu layout. In Codex details, connected accounts show separate weekly/session limits and errors. The selected account controls the menu-bar ring; quota percentages are never summed.

When enabled, Codex cost history scans the ambient Codex home and every managed account home, including archived sessions, in one scanner pass. Existing session/file deduplication prevents copied history from multiplying the total. Root changes invalidate the cache; late results from a previous scope cannot replace current results. The combined provider estimate contributes once to the total for the selected local/shared source set.

This is local-history coverage, not an account-wide billing export. Older session logs do not establish an account-by-account cost split; activity on other devices is absent unless its logs are present here. Cursor uses its connected web-session history, and Meta uses local Muse history. Adding account credentials alone cannot manufacture missing token records.
