---
summary: "Meta provider data sources: local Muse session-log token scan and optional Meta Model API key."
read_when:
  - Debugging Meta/Muse usage parsing
  - Updating `~/.local/share/muse/sessions` log scanning
  - Adjusting Meta provider labels or auth
---

# Meta provider

Meta covers **Muse Code** (powered by Muse Spark, e.g. `muse-spark-1.3-contributor`).
`muse` authenticates via `muse login` (Meta account, browser code) or a
`META_API_KEY` (`muse auth set --provider meta --api-key-stdin`); the key always
takes priority over the account login. There is no public quota/billing API, so
usage comes from the local session logs `muse` already writes on-device.

## Data sources + fallback order

1) **Local Muse session logs (`local`, always available)**
   - Scans `~/.local/share/muse/sessions/**/session.jsonl` for `model_completed`
     events (`payload_type: "runtime.session"`, `payload.event.kind ==
     "model_completed"`), including records wrapped in `retained_frame`
     `children[].record_json`.
   - Aggregates `input_tokens`, `output_tokens`, `reasoning_tokens`,
     `cached_tokens` per local-calendar day. Primary window shows today's tokens,
     secondary shows the last 7 days; the token-cost history (`codexbar cost
     --provider meta`) shows per-day totals with per-model breakdowns (costs are
     absent — Muse exposes no pricing endpoint — so only token counts chart).
   - Needs no credentials and never touches the Keychain.

2) **Optional API key (`META_API_KEY`)**
   - Stored in `~/.codexbar/config.json` (Settings → Providers → Meta) or the
     environment. Reserved for the Meta Model API (`https://dev.meta.ai/docs`);
     the local log remains the usage source of truth until a quota endpoint is
     available.

## Usage bars

Meta publishes no quota, limit, budget, or reset for Muse Code, so there is no
provider-reported percent remaining to show. Instead, the Air panel (overview and
provider detail) and the legacy menu card show Claude-style bars that read as usage
left against the only honest baseline — your own recorded history:

- **Today** — today's recorded Muse tokens and requests, measured against the busiest
  recorded day.
- **Last 7 days** — the last 7 local-calendar days, measured against the busiest rolling
  7-day window. This window is the detail-view hero.

Bar fill is `100 - (window tokens / busiest comparable window tokens * 100)`, labeled
"N% left" with tokens used, tokens left, and the baseline named ("vs busiest day/week"),
so it drains as usage grows and warns when headroom runs low, like every other
provider's bar. The legacy menu card follows the global show-used preference
(percent used, with tokens left still shown). With no recorded baseline the bar stays
empty and says so instead of reading as full. No reset line is shown, and these bars
never feed menu-bar quota rings or Orbit, which still mean provider-reported remaining
capacity only. `MetaActivitySnapshot` (on `UsageSnapshot.metaActivity`) carries the
windows and busiest-day/week totals; when only token history is available it is derived
from that history, which follows the selected local/combined usage scope.

## Cost estimates

Each priced day shows **contributor cost** (what contributor-tier usage costs)
and the **standard API equivalent** (same tokens at standard Model API rates).
Days whose models disagree on tier, or are unknown, stay unpriced.

| Tier | Input / 1M | Output / 1M | Cached input / 1M |
| --- | --- | --- | --- |
| Contributor (data-sharing consent) | $0.10 | $0.20 | $0.002 |
| Standard | $1.25 | $4.25 | $0.15 |

Reasoning tokens bill at the output rate. Rates follow Meta's public Model API
pricing (Muse Spark 1.x announcements); re-check `https://dev.meta.ai/docs`
before treating them as exact. `codexbar cost` (multi-provider) counts Meta at
the standard-API equivalent in its TOTAL line.

## Notes

- Model label in the menu comes from the log's `model` field (or
  `~/.config/muse/settings.json`); identity stays siloed to Meta.
- If no `session.jsonl` files exist yet, the provider reports "No Muse usage
  found" — run `muse` once so logs exist.
- The provider debug log (Settings → provider → debug) reports the sessions
  root, file count, configured model, and API-key status for troubleshooting.
- Meta is selectable in the widget provider list.
- Privacy: on-device parsing only; nothing is uploaded.
