---
summary: "z.ai provider data sources: API token in config/env and quota API response parsing."
read_when:
  - Debugging z.ai token storage or quota parsing
  - Updating z.ai API endpoints
---

# z.ai provider

z.ai is API-token based. No browser cookies.

## Token sources (fallback order)
1) Config token (`~/.codexbar/config.json` → `providers[].apiKey`).
2) Environment variable `Z_AI_API_KEY`.

### Config location
- `~/.codexbar/config.json`

## API endpoint
- `GET https://api.z.ai/api/monitor/usage/quota/limit`
- BigModel (China mainland) host: `https://open.bigmodel.cn`
- Override host via Providers → z.ai → *API region* or `Z_AI_API_HOST=open.bigmodel.cn`.
- Override the full quota URL (e.g. coding plan endpoint) via `Z_AI_QUOTA_URL=https://open.bigmodel.cn/api/coding/paas/v4`.
- Headers:
  - `authorization: Bearer <token>`
  - `accept: application/json`

## Parsing + mapping
- Response fields:
  - `data.limits[]` → each limit entry.
  - `data.planName` (or `plan`, `plan_type`, `packageName`, `level`) → plan label.
- Limit types:
  - `TOKENS_LIMIT` → primary (tokens window).
  - `TIME_LIMIT` → secondary (MCP/time window) if tokens also present.
  - If two `TOKENS_LIMIT` entries are present, the longest window is the primary token bar and the shorter
    window is the 5-hour/session bar.
- Window duration:
  - Unit + number → minutes/hours/days.
- Reset:
  - `nextResetTime` (epoch ms or seconds, numeric or string) → date.
- Usage details:
  - `usageDetails[]` per model (MCP usage list).
- Hourly model usage:
  - `GET /api/monitor/usage/model-usage` is fetched best-effort after quota data.
  - `x_time`/`xTime` plus `modelDataList`/`model_data_list` power the optional hourly token chart.
  - Token counts tolerate numeric and numeric-string values.

## Key files
- `Sources/CodexBarCore/Providers/Zai/ZaiUsageStats.swift`
- `Sources/CodexBarCore/Providers/Zai/ZaiCostUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/Zai/ZaiSettingsReader.swift`
- `Sources/CodexBar/ZaiTokenStore.swift` (legacy migration helper)

## Estimated cost (opt-in)

z.ai exposes **no billing/spend API**, so cost is an *estimate* derived from token counts × public
GLM pricing — not real billing. It is gated behind its own opt-in (independent of the global
cost-usage switch):

- **Enable:** Settings → Providers → z.ai → **Show estimated cost**.
- Also requires the global Settings → General → cost-usage toggle and a valid z.ai API token.

### How it works
- Pulls the `model-usage` endpoint over the history window (chunked into week-long requests), the
  same endpoint that powers the hourly token chart.
- Aggregates hourly per-model token counts into daily buckets.
- Prices each model with a single **blended USD-per-token rate** (z.ai's API exposes aggregate
  tokens only — no input/output split). Free tier models (e.g. `glm-4-flash`) price as $0.
- Renders the same inline 30-day cost chart and "Cost (30d)" submenu used by Codex/Claude/Bedrock.

### Pricing source
- Built-in GLM rate table in `CostUsagePricing.zai` (`glm-4.6`, `glm-4.5`, `glm-4.5-air`,
  `glm-4-plus`, `glm-4-air`, `glm-4-flash`, `glm-4-flashx`, `glm-4-long`, `glm-4v`).
- Rates are approximate (verified against z.ai/Zhipu public pricing); the built-in fingerprint
  busts caches when they change.
- `models.dev` provider id `zai` wins when available, so rates stay current once contributed
  upstream.

### CLI
```bash
codexbar cost --provider zai            # text estimate
codexbar cost --provider zai --format json   # JSON; note `"source": "estimated"`
```
The CLI runs the estimate on demand; the in-app opt-in toggle does not gate the CLI.

### Caveats
- The estimate assumes a blended rate and ignores cache/batch discounts, so it overstates cost
  relative to real billing for cached traffic.
- Region currency: z.ai Global bills USD; BigModel CN (open.bigmodel.cn) bills CNY. Estimates use
  public USD pricing for both; treat CN spend as a rough USD-equivalent proxy.
