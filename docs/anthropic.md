---
summary: "Anthropic API provider: Admin API organization spend and token usage, separate from Claude subscription limits."
read_when:
  - Updating Anthropic API Platform (Claude Console) spend or usage display
  - Debugging ANTHROPIC_ADMIN_KEY behavior
  - Changing how billed spend relates to Midas estimate totals
---

# Anthropic API provider

The Anthropic provider tracks your **Anthropic API Platform organization** (Claude Console): billed spend,
token usage, and top models. It is separate from the Claude provider, which tracks Claude subscription
session/weekly limits and Claude Code usage. You can enable both at once. This mirrors the split between Codex
(ChatGPT subscription) and OpenAI (API organization).

## Data sources

An organization Admin API key (`sk-ant-admin…`) is required. It calls:

- `GET https://api.anthropic.com/v1/organizations/cost_report` with `bucket_width=1d` and `group_by[]=description`.
  `amount` is a decimal string in cents and is converted to USD.
- `GET https://api.anthropic.com/v1/organizations/usage_report/messages` with `bucket_width=1d` and
  `group_by[]=model`. Tokens are summed from uncached input, cache creation (5m + 1h), cache read, and output.
- `GET https://api.anthropic.com/v1/organizations/me`, best-effort, for the organization name shown as the
  account.

The history window follows the app's cost-history setting (1–365 days). Requests are split into 31-day ranges,
the reports' page limit, and every `next_page` is followed. Days are UTC buckets. Anthropic says new usage
usually appears within about five minutes, so the latest hours can still be settling.

Normal inference keys (`sk-ant-api03…`) and workspace-scoped keys get HTTP 401/403. The error shown includes
Anthropic's own message and a reminder that an Admin API key is required. Anthropic has no public API for the
prepaid credit balance; use **Open billing** in Settings.

## Setup

- Settings → Providers → Anthropic → **Admin API key** (stored in `~/.codexbar/config.json`).
- CLI: `printf '%s' "$ANTHROPIC_ADMIN_KEY" | codexbar config set-api-key --provider anthropic --stdin`
- Environment: `ANTHROPIC_ADMIN_KEY` (or `ANTHROPIC_ADMIN_API_KEY`).
- Token accounts can hold keys for several organizations.

Create Admin keys at <https://console.anthropic.com/settings/admin-keys>. Only organization admins can do this.

## Relationship to the Claude provider

The Claude provider still has its own **Admin API key** field and `API (Admin key)` source. When Claude is in
Auto mode and sees an Admin key, it shows organization spend *instead of* subscription limits. To see both, put
the key in the Anthropic provider and leave Claude's Admin API key empty. Note that an `ANTHROPIC_ADMIN_KEY`
exported into the app's environment is visible to both providers.

## Spend semantics

Cost-report dollars are **billed charges**, recorded with `CostProvenance.vendorBilled`. They are not
API-rate estimates:

- Midas Air shows the amount on the Anthropic row, labeled *Billed API spend*, for the selected period.
- The all-provider *Estimated inference spend* total does **not** include billed spend. Claude Code sessions
  billed to an org API key show up in both the org cost report and Claude's local log value, so adding them
  would double count. The coverage line reports `N billed shown separately`.
- `codexbar cost` keeps Anthropic out of the list-rate TOTAL and lists it as `billed separately`.

## CLI

```bash
codexbar usage --provider anthropic
codexbar cost --provider anthropic --days 90
```
