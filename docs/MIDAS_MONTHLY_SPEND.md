# Monthly spend comparisons

Midas 0.42.0 adds **Month by month** to Spend history. Overview compares one selected provider;
provider pages show that provider's chart. Costs and tokens share 6- and 12-month views, hover
selection, previous/next month buttons, and a selectable Monthly records list. See the
[setup guide](MIDAS_SETUP.md#comparing-months) for user instructions.

## Data and reporting calendars

`MidasMonthlySpend` reads the existing `CostUsageTokenSnapshot.daily` records. It builds
contiguous calendar months ending in the current month, independent of the daily chart's filter.
Whole-window totals, balances, and subscription charges are not apportioned across months.
The existing source determines cost provenance and currency; billed API spend, public-rate
estimates, and tier-priced estimates retain their meanings.

Only valid, non-future `yyyy-MM-dd` keys are accepted. Local transcript providers use the Mac's
calendar; OpenAI, Anthropic, Mistral, and Codex cloud use UTC day keys. Month identifiers are
stable `yyyy-MM` values, with neutral chart dates to avoid shifting a category at time-zone boundaries.
The daily history view uses the same source-calendar policy.

Missing cost or token values stay unavailable. An explicitly recorded zero stays zero. Negative,
non-finite, overflowing, and malformed values do not produce totals. Duplicate daily keys mark
the affected month conflicting and suppress its totals rather than counting the day twice.
Recorded days and priced days are disclosed; a subtotal is not proof of complete account coverage.
Monthly token summaries and records format integer totals without converting them to floating point.

The longer-history action changes the existing `costUsageHistoryDays` setting to 365 and requests
a refresh. Local scans require history collection to be enabled; supported API reports can load
independently. It does not enable collection, switch Codex sources, or fabricate past data.
History defaults to 30 days. The oldest loaded month can be partial. Codex cloud is currently
capped at 30 days, and Mistral currently fetches only the current UTC month. Selecting 12 months
changes the display, not the source's retention policy. This feature adds no durable ledger.

## Comparison rules

Compare only the immediately previous calendar month; do not bridge missing months. Two complete
past months can be compared even when their lengths differ. Sparse months need the same recorded
ordinal days and usable values for the selected metric. Unpriced usage suppresses cost comparisons.

For month to date, stop both months at `min(current day, previous month length)` and apply the same
coverage rules to those days. This avoids comparing a partial current month with a full previous
month. The selected month still shows its full recorded subtotal; the comparison explicitly labels
its shared day range and values. A zero baseline has an absolute change but no percentage change.
Non-finite percentage changes are omitted.

## Implementation and validation

- `Sources/CodexBar/MidasMonthlySpend.swift`: aggregation, coverage, reporting calendars, comparisons.
- `Sources/CodexBar/MidasMonthlySpendView.swift`: native Charts presentation and accessible records.
- `Sources/CodexBar/MidasUsageWindowView.swift`: provider-scoped integration and longer-history action.
- `Tests/CodexBarTests/MidasMonthlySpendTests.swift`: calendar boundaries, leap years, missing/zero
  data, duplicates, invalid values, partial pricing, compatible days, and overflow behavior.
- `Tests/CodexBarTests/MidasMonthlySpendRenderTests.swift`: synthetic native light/dark fixtures,
  narrow/wide layouts, costs/tokens, gaps, and unavailable history.

Focused verification:

```sh
SWIFT_TESTING=1 SWIFT_TESTING_ENABLED=1 swift test \
  --filter 'MidasMonthlySpend|MidasCostPresentation|MidasSpendPeriod|PathBuilderTests'
make check
```

Use a full Xcode developer directory when the active Command Line Tools installation cannot compile
asset catalogs. Pass `--scratch-path` for rebuildable SwiftPM output when needed; keep source and
credential state internal. Native fixtures are opt-in via `MIDAS_MONTHLY_PREVIEW_OUTPUT`; they use
synthetic records and `NSHostingView` so AppKit-backed segmented controls render correctly.
Tests and release checks must not read real provider credentials or trigger Keychain prompts.

The design follows Apple's guidance on understandable chart scales, selection, and accessible data:
[Design app experiences with charts](https://developer.apple.com/videos/play/wwdc2022/110340/) and
[Explore pie charts and interactivity in Swift Charts](https://developer.apple.com/videos/play/wwdc2023/10037/).
API reporting semantics remain owned by the source clients, consistent with the
[OpenAI Usage API](https://platform.openai.com/docs/api-reference/usage) and
[Anthropic Usage and Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api).
