# Midas menu bar: research and proposed redesign

September 4, 2026. Original design study with fictional values, followed by native implementation.

## Implementation status

Orbit is now the default for new Midas installs and migrates existing Ledger users once. Its
110-point status item puts the all-provider token-spend total before one favorite provider’s
logo and an 18-point capacity ring. Settings → Display → Orbit provider selects the favorite.
The ring stays static during refresh; a separate satellite communicates activity. Unknown capacity
uses a dashed neutral track, while exhausted capacity is an empty solid track. Codex uses weekly
remaining, Cursor uses actual quota, and Meta has no quota. The small monochrome menu-bar logo
assets preserve identity without reusing full-color panel artwork at an unsuitable size.

Ledger, Focus, and Constellation remain available, with Legacy
preserving prior icon settings. The native renderer uses stable widths of 130, 120, and 190 points
respectively, a passive Midas mark/text/badge view, and monospaced digits. Constellation uses compact
separate readings rather than subpixel quota tracks. Mixed currencies display a currency count;
the tooltip retains separate totals. Hidden spend is masked and excluded from accessibility text.

Active initial/manual refreshes animate a separate glyph for at most 30 seconds; background
refreshes with cached data stay static. Changed readings fade over 180 ms. Reduce Motion stops
both effects. Attention and last-known/partial coverage use static badges. Data older than 15
minutes is last-known; a once-per-minute freshness task updates that state. Low-quota thresholds
are currently 10% without the hysteresis proposed below. Startup animation does not add the
optional 400 ms delay. Reset Horizon remains a research direction. Orbit warnings and freshness
are scoped to the favorite; token-spend refresh errors are disclosed separately in its tooltip.

The following sections preserve the original design rationale; implementation details above
take precedence where they differ. See [Midas Air](MIDAS_AIR.md) for operating instructions.

## Recommendation: Midas Ledger

Give Midas a recognizable four-point mark and a steady estimated-spend figure: **✦ ≈$73.20**. Use a monochrome mark in the system menu bar and reserve Midas gold for the opened panel. The shape connects with Midas’s current app identity, while the figure makes its new financial focus immediately useful. The total adds the existing provider usage-rate estimates; those rates may have different bases. Label it as an estimate, expose each basis in detail, and never describe it as billed charges or a reconciled invoice.

The menu bar should answer “What is my estimated usage value?” One click should answer “Where did it go, and how much capacity remains?” Keep the total prominent above separate Codex, Cursor, and Meta readings. Their quotas have different meanings and cannot truthfully become one averaged percentage.

The proposed default occupies roughly 100–112 points including padding and a reserved status slot. This is a target, to be measured in native AppKit at actual system font sizes. Use tabular numerals and a fixed width within the chosen display mode. Compact large amounts to approximately `$1.2K` or `$12.4K`; the tooltip and panel retain exact amounts. Keep `≈` visible. Currency formatting must follow the selected locale and remain unambiguous when more than one currency is present.

Do not automatically replace spend with quota or reset time. A stable unit helps the user read the item without reconsidering its meaning. A small static warning mark can add urgency without hiding the primary reading.

## Research: what is useful for Midas

| Precedent | Verified behavior | Midas application |
| --- | --- | --- |
| Apple MenuBarExtra | Apple recommends its window style for complex, data-rich menu-bar content. | Keep the existing spacious Air popover and Usage window. A new icon does not require rewriting the working AppKit lifecycle. [Apple documentation](https://developer.apple.com/documentation/swiftui/menubarextra) |
| iStat Menus Combined | Information in the menu bar and information in the dropdown can be configured separately. | Offer a small number of menu-bar modes while keeping all providers in the panel. [Combined mode](https://bjango.com/help/istatmenus7/combined/) |
| iStat Menus overflow guidance | Small screens, many status items, and camera housings reduce available room and may hide items. | Start with one compact item, allow icon-only mode, and preserve an independent keyboard path into Midas. Avoid a permanently expanding strip. [Hidden items](https://bjango.com/help/istatmenus7/hiddenitems/) |
| Ice | Offers a separate area for hidden items, layout controls, search, and spacing options. | Put Midas’s expanded provider information below the menu bar. Avoid building a second system-wide menu-bar manager. [Ice](https://www.icemenubar.app/) |
| Dato | Uses contextual actions, optional multiple status items, keyboard window pinning, and modifier shortcuts. Its developer also notes the cost of frequent menu-bar updates. | Retain simple click behavior, expose all shortcuts visibly, and keep idle drawing event-driven. Reuse the existing Usage window for extended inspection. [Dato documentation](https://sindresorhus.com/dato) |
| Apple Reduce Motion | Exposes the user’s preference to limit motion. | Apply the preference to the menu-bar driver as well as the Air popover. [Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion) |

The timings, dimensions, thresholds, and new interaction choices below are design proposals, not claims that Apple requires them.

## Creative directions explored

### 1. Ledger — recommended default

**✦ ≈$73.20**

Best for the current spend-first direction. The brand mark stays still at rest. The amount changes only when underlying estimates change. A reserved trailing position carries a static attention marker or last-known marker, with a precise accessible description.

The opened panel anchors the same total, then lists provider spend beside that provider’s remaining capacity. The transition from the menu bar to the panel feels like opening a compact receipt. No rolling odometer or celebratory spending effects.

Tradeoff: quota requires opening the panel. Users who constantly watch one limit should choose Focus or enable the optional capacity accessory.

### 2. Focus — provider capacity

**✦ C 72%** with one small capacity track, or icon-only track for maximum compactness.

Pin a provider explicitly. Codex always means weekly remaining, honoring the existing request. Cursor must name the chosen pool in its tooltip and panel; model spend share must never become quota. Meta shows an unavailable indication when it has no quota source. A setting should preview the full meaning, such as “Codex · weekly remaining.”

For production, use tested template provider marks where they remain recognizable at 14–16 points. The study uses C/U/M abbreviations to compare geometry without inventing replacement logos. The full provider names belong in accessibility text and tooltips.

Tradeoff: a provider-specific view puts the global estimate one click away. Keep it an explicit mode, never an automatic rotation.

### 3. Constellation — compact provider awareness

**✦ C ▰ U ▰ M —**

One status item containing up to three pinned providers, each with its own tiny horizontal fill. Provider order remains fixed. A missing quota is a dash. No aggregate quota and no implied equal weighting. Clicking opens the overview; selecting a provider happens inside the panel, preserving one clear status-item hit target.

Tradeoff: tiny fills are directional rather than precise, and logos plus tracks require more width. Best as an optional power-user mode. Text percentages in the opened panel provide precision.

### 4. Orbit — capacity around the Midas mark

A partial ring around the central mark could encode one pinned provider’s remaining capacity. Visually distinctive and compact, but a ring is easy to mistake for a loading spinner, particularly when combined with animation. Small arcs also complicate missing-versus-zero states. Worth a later static icon-only experiment; not the first default.

### 5. Reset horizon — time until capacity returns

Show a compact `2h` accessory only when the pinned quota is exhausted and a reset timestamp is actually known. Keep the original `0%` reading or make this an explicitly selected display mode. Update at minute boundaries. Never infer recovery from the clock alone; confirm with a fresh provider snapshot.

Tradeoff: differing weekly/session resets need explicit labels. This is most useful inside the panel before earning permanent menu-bar space.

### 6. Touch of gold — event-driven character

A restrained state transition can make the mark feel alive: a short fade when fresh data lands, a brief deliberate refresh indication, and a static warning shape when action is needed. Keep the native menu-bar template tint; introduce gold within the panel. Motion is a layer shared by Ledger and Focus, not an alternative metric.

I would leave out continuous blinking, animated faces, rotating provider carousels, marquee totals, confetti, and a notch-attached overlay. They consume attention or add substantial window-management complexity without improving spend or capacity comprehension. Color emoji remain appropriate in explanatory copy; the tiny persistent status mark benefits from crisp, predictable vector geometry.

## State and motion contract

Model freshness, activity, and availability separately. An old reading, a failed request, and a quota limit are different facts and can coexist.

| Condition | Menu bar | Opened panel | Motion |
| --- | --- | --- | --- |
| Fresh, idle | Stable amount or selected quota | Period, coverage, last update | None |
| Initial fetch actually running | Mark and unavailable reading | “Fetching usage…” | Small busy indication after 400 ms; stop when work ends |
| Background refresh with cached data | Keep cached reading | Quiet refreshing status | No menu-bar motion |
| User explicitly refreshes | Keep cached reading and stable brand mark | Refresh control shows progress | Optional small rotating refresh glyph, maximum 30 seconds; static busy indicator thereafter |
| Fresh value arrives | Update in the same width | Update affected values | Optional 180 ms opacity transition; no counting through fictional intermediate values |
| Refresh fails, cache exists | Keep number with last-known marker | Timestamp and precise failure reason | None |
| Reading ages beyond policy | Keep number with last-known marker | “Last updated…” | None; age alone is not an account error |
| Low selected quota | Keep amount/quota plus static `!` | Name affected provider and window | None |
| Quota exhausted | Explicit `0%` in Focus | Known reset time and other independent limits | None |
| Quota unavailable | Dash; no fabricated fill | Explain unavailable quota | None |
| No estimates | Dash, never `$0` | “No usable estimates” | None unless a request is active |
| Partial estimates | Known subtotal with coverage marker | “2 of 3 providers,” identify missing estimate | None |
| Multiple currencies | Compact currency-count indicator | Separate totals, no silent conversion | None |
| Provider service incident | Small static attention marker | Name affected provider and incident independently from account status | None |
| Reduce Motion | Same data and state markers | Same operations available | Remove optional transitions and rotation |

Proposed freshness policy: use the configured refresh cadence, for example the later of three expected refresh intervals or 15 minutes, subject to provider source cadence. Treat this as a tunable policy requiring fixtures, not an established fact about all providers. Proposed low-capacity warning: enter at 10%, clear above 12% to reduce threshold chatter, and scope it to the explicitly selected window. Existing provider-specific warning settings should take precedence.

For simultaneous states, preserve the metric and let the single small marker indicate attention. Resolve details in the panel: actionable connection failure or service incident, exhausted/low quota, then last-known/partial coverage. Tooltips and VoiceOver must enumerate the relevant facts and provider identities; a warning about Meta must not sound like Codex is broken.

## Interaction and privacy

- Left-click toggles the existing Air panel. Escape dismisses it and restores expected focus.
- Right-click opens existing quick actions. Preserve Settings, Refresh, Usage, and Quit.
- Optional Option-click opens the existing Usage window. Keep the same action visible in the panel; do not make a hidden gesture essential.
- Tooltip includes exact estimated amount, currency, reporting period, coverage, and the selected provider’s quota window. Privacy mode also suppresses dollar values in tooltips and accessibility text.
- A keyboard shortcut opens Midas when its status item is hidden by crowding. Preserve its current configured shortcut rather than inventing a conflicting system shortcut.
- No automatic hover expansion or scrolling-to-switch-provider in the first version: those can activate accidentally while reaching nearby system controls.
- “Hide spend” retains a stable masked field. Do not claim automatic screen-sharing detection or privacy protection without implementing and verifying it separately.
- Show-only-icon, Ledger, and Focus belong in a small setting with real-scale previews. Keep split-provider items available for existing users; avoid changing saved placement silently.

## Code findings and implementation seam

Three independent audits examined architecture, state behavior, and primary-source precedents. The root reviewed the existing total model and status-item construction as integration checks.

The current renderer uses an 18×18-point template canvas. Codex’s single capsule is already centered, but the inherited renderer still carries facial decoration and other providers retain old bar shapes. Brand mode combines a logo and ordinary button text without dedicated stable-width numeric layout. See [IconRenderer.swift](../Sources/CodexBar/IconRenderer.swift) and [brand-mode rendering](../Sources/CodexBar/StatusItemController+Animation.swift).

The current loading predicate can animate merely because data is missing, even when no fetch is running. Reduce Motion is absent from the audited menu-bar animation paths. Fix those together rather than just replacing the drawn shape. See [loading predicate](../Sources/CodexBar/StatusItemController+Animation.swift).

The audited `isStale` helper checks errors, so time-based age needs a separate representation. See [UsageStore.swift](../Sources/CodexBar/UsageStore.swift). The status-item tooltip starts with a generic application title and should become a meaningful reading. See [status-item setup](../Sources/CodexBar/StatusItemController.swift).

Codex’s bar resolver is weekly-remaining-only, while brand text can follow configurable windows and used/left preferences. The new typed presentation must unify these semantics. See [IconRemainingResolver.swift](../Sources/CodexBar/IconRemainingResolver.swift).

Build a `MidasMenuBarPresentation` model with mode, selected provider/window, amount/currency/coverage, quota availability, freshness, activity, attention, and accessible summary. Feed it into a dedicated Midas renderer. Retain NSStatusItem identity, saved placement, click routing, render-signature caching, and fetching/account boundaries. Reuse [MidasTotalSpend.swift](../Sources/CodexBar/MidasTotalSpend.swift) so enabled-provider scope, deduplication, estimate provenance, separate currencies, and exclusion rules stay consistent with the panel. Do not add reset credits, metered balances, or secondary API-equivalent figures to that sum.

## Acceptance before shipping

1. Fixture tests cover every state above, combinations, unknown versus zero, missing weekly Codex data, Cursor pool semantics, Meta’s absent quota, partial totals, mixed currencies/periods, and privacy.
2. Render the actual 1× and 2× status images in light/dark appearance. Verify no clipped mark or unreadable outline and stable width across number changes and warnings.
3. Confirm no animation timer runs while idle, no missing-data-only spinner, reduced-motion behavior, and no update on unchanged signatures.
4. Check live menu-bar placement, multiple displays, crowded/notched screens, keyboard access, left/right-click, panel dismissal, and the exact running binary after packaging. Native rendering fixtures alone cannot prove those behaviors.
5. Run focused menu-bar/model regressions and required formatting/build checks. Keep provider probes out of a design-only verification pass unless explicitly authorized.

The original interactive study compared Ledger, Focus, and Constellation plus ten data states, privacy, and reduced motion. Its critique pass added explicit estimate provenance, separated missing estimates from missing Codex quota, replaced low constellation fills with legible numbers, improved supporting type, and kept the brand mark still during refresh. That study is a layout proposal, not a native benchmark or live account dashboard; the app implementation is described above.

Prototype verification: 30 concept/state combinations passed in headless Chromium, with no JavaScript errors. Refresh completion, panel toggling, masked-dollar accessibility text, reduced-motion CSS, and 375-pixel layout checks passed. Light and dark rendered previews were visually inspected. These results validate the prototype only; the native acceptance steps above remain necessary for app implementation.
