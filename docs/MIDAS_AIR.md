# Midas Air

Midas Air replaces the main menu presentation with one native SwiftUI popover hosted by the
existing status-item controller. It keeps the provider engine, account coordinators, saved
settings, and legacy menu-bar icon preferences intact. macOS 14 remains the minimum target.

## Everyday surfaces

- **Overview:** total token spend (API rates) across all enabled providers, ordered favorite provider rows, an All providers chooser, freshness and
  connection states, refresh, settings, and Open Usage.
- **Provider detail:** prominent token spend (API rates), recognizable logos, explicit periods and remaining capacity, reset
  information, and separate session constraints. Codex uses weekly remaining as its quota hero;
  missing weekly data does not turn into a session metric.
- **Usage window:** resizable provider navigation, Usage and Costs views, period controls,
  history, model breakdowns where available, and source-aware cost labels. Metered consumption,
  provider-reported costs, and API-equivalent estimates are distinct meanings.
- **Settings:** a stable sidebar preserving General, Providers, Display, Advanced, About,
  and the optional Debug pane. Its height is constrained for smaller screens.
- **Branding:** a gold pixel crown beside the Midas wordmark, Midas display names and support links, and explicit
  acknowledgment of CodexBar's MIT-licensed foundation.

## Typography and crown

Midas uses native SF system typography with default letterforms, semibold headings, and
monospaced digits for financial and quota readings. Amounts retain their one-line scaling for
large values. The 18-point header crown uses a fixed grid of 2-point pixels. A 0.9-second
highlight sweep repeats after a 2.4-second rest while the panel is open; closing the panel
cancels the task. Reduce Motion shows a static crown, as does the Usage window sidebar.
The crown is decorative and hidden from accessibility.

## Original provider menu

Right-click the status icon or choose **Provider actions & accounts…** from the panel's menu
for the original provider actions, diagnostics, and account menu. This is an intentional
compatibility path during the presentation migration. It uses the same data and coordinators.
The packaged `MidasAirEnabled` Info.plist flag selects the new presentation; unbundled/test
runs preserve the original routing. Do not edit a signed app's plist to switch it.

## Spend and provider semantics

`MidasTotalSpend` sums primary, finite, nonnegative estimates from all enabled providers, before
Favorites filtering. It deduplicates providers, keeps currencies separate without conversion, and
reports coverage and reporting periods. A missing estimate is excluded rather than converted to
zero; a genuine zero estimate remains valid. Secondary API equivalents, metered balances, and
reset credits are not additional token spend (API rates). Provider valuation bases can differ, so this
total is a sum of usage-rate estimates, not billed charges.

Codex keeps weekly remaining separate from session constraints, and its single menu-bar capsule
never substitutes session data when weekly data is missing. Cursor model spend shares are not
quota; actual request counts and independent usage pools remain separate. Meta can show local
history when cost collection is disabled, without fabricating remaining capacity.

The menu bar defaults to **Orbit**: total token spend (API rates), followed by a ring around one
favorite provider’s logo. Use the provider dropdown in the panel footer, or **Settings → Display → Orbit provider**. The total includes all
enabled providers, regardless of this selection. Codex’s ring uses weekly remaining, Cursor uses
its real quota, and Meta uses a neutral dashed ring because it has no quota. A disabled or missing
favorite retains its identity with unknown capacity; it never silently switches to another provider.
An empty solid ring means exhausted capacity, while a dashed ring means unknown capacity.

Existing Ledger users move to Orbit once. Other explicit modes and the selected provider remain
unchanged; choosing Ledger again is respected. **Ledger** remains available. **Focus** pins one
provider’s quota (Codex is always weekly remaining). **Constellation** shows up to three separate
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

From this repository:

```sh
make check
swift test
./Scripts/package_app.sh release
```

For a signed local build, supply `APP_TEAM_ID` and `APP_IDENTITY` for the identity already used
by the installed app. The packaging script's inherited default is the upstream developer's
identity. Use `codesign -dvv CodexBar.app` to inspect the installed public signature, then pass
the matching values when packaging; preserving the team also preserves the app-group identity.

Packaging retains the `CodexBar.app` bundle directory and `CodexBar` executable for compatibility,
while Finder/application display metadata says Midas. The existing bundle identifiers, app group,
keychain/storage identity, and signing behavior are intentionally preserved. Restart the freshly
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
- `MidasTotalSpend.swift`, `MidasTotalSpendView.swift`: estimate aggregation and shared total display.
- `MidasMenuBarPresentation.swift`, `MidasMenuBarView.swift`: typed status readings and passive native rendering.
- `StatusItemController+MidasMenuBar.swift`: status-item integration, activity filtering, and freshness updates.
- `MidasPanelView.swift`, `MidasProviderDetailView.swift`: compact surfaces.
- `MidasUsageWindowView.swift`, `MidasUsageHistoryView.swift`, `MidasCostPresentation.swift`: history and costs.
- `MidasDesignSystem.swift`, `MidasProviderLogo.swift`: adaptive visual tokens and provider identity.
- `PreferencesView.swift`, `PreferencesAboutPane.swift`: sidebar settings and product identity.

Focused model tests cover quota direction, unavailable/stale states, account boundaries, cost
semantics, and logo caching. Native interactions and final signed-bundle launch should also be
verified after changes. Tests must not initiate real Keychain/browser/provider probes unless
explicitly authorized; follow the repository's AGENTS.md testing guidance.

## Updates

Click **Check for Updates** in the panel footer for the standard Sparkle download and
Install & Restart flow. Only signed Midas releases are accepted through the Midas-only feed.
Settings → About provides automatic checks. Older releases need a one-time manual upgrade
to 0.33.3 or later.
