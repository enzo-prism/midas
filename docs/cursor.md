---
summary: "Cursor provider data sources: browser cookies or stored session; usage + billing via cursor.com APIs."
read_when:
  - Debugging Cursor usage parsing
  - Updating Cursor cookie import or session storage
  - Adjusting Cursor provider UI/menu behavior
---

# Cursor provider

Cursor is web-only. Usage is fetched via browser cookies or a stored WebKit session.

## Data sources + fallback order

1) **Cached cookie header** (preferred)
   - Stored after successful browser import.
   - Keychain cache: `com.steipete.codexbar.cache` (account `cookie.cursor`).

2) **Browser cookie import**
   - Cookie order from provider metadata (default: Safari → Chrome → Firefox).
   - Domain filters: `cursor.com`, `cursor.sh`.
   - Cookie names required (any one counts):
     - `WorkosCursorSessionToken`
     - `__Secure-next-auth.session-token`
     - `next-auth.session-token`

3) **Stored session cookies** (fallback)
   - Captured by the "Add Account" WebKit login flow.
   - Login teardown uses `WebKitTeardown` to avoid Intel WebKit crashes.
   - Stored at: `~/Library/Application Support/CodexBar/cursor-session.json`.

Manual option:
- Preferences → Providers → Cursor → Cookie source → Manual.
- Paste the `Cookie:` header from a cursor.com request.

## API endpoints
- `GET https://cursor.com/api/usage-summary`
  - Plan usage (included), on-demand usage, billing cycle window.
- `GET https://cursor.com/api/auth/me`
  - User email + name.
- `GET https://cursor.com/api/usage?user=ID`
  - Legacy request-based plan usage (request counts + limits).

## Cookie file paths
- Safari: `~/Library/Cookies/Cookies.binarycookies`
- Chrome/Chromium forks: `~/Library/Application Support/Google/Chrome/*/Cookies`
- Firefox: `~/Library/Application Support/Firefox/Profiles/*/cookies.sqlite`

## Local storage footprint
When **Settings → Advanced → Track provider local storage** is enabled, CodexBar measures:
- `~/Library/Application Support/Cursor`
- `~/Library/Application Support/Caches/cursor-updater`
- `~/.cursor`
- `~/Library/Caches/Cursor`
- `~/Library/Caches/com.todesktop.230313mzl4w4u92`
- `~/Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt`
- `~/Library/Caches/cursor-compile-cache`
- `~/Library/HTTPStorages/com.todesktop.230313mzl4w4u92`

The storage detail lists measured paths and their sizes. CodexBar does not delete Cursor data.

## Snapshot mapping
- Primary: plan usage percent (included plan).
- Secondary: Auto + Composer usage percent.
- Tertiary: API (named model) usage percent.
- Bot row: `individualUsage.botUsage` (fallback `teamUsage.botUsage`) renders a "Bot" card row when the API reports a bot limit.
- Models row: `individualUsage.modelSplit` (`cursorModelCents` / `nonCursorModelCents`) renders a "Models" card row showing the Cursor-served share of reported model spend.
- Provider cost: Extra usage USD. A capped individual budget wins; team accounts without a user cap use the shared team on-demand budget.
- Reset: billing cycle end date.

## Dashboard pools (Cursor Models / Other Models / Grok Bot)

The menu card and `codexbar usage --provider cursor` show usage-left rows in
dashboard language, from the same endpoints as cursor.com/dashboard/usage:

- `POST /api/dashboard/get-current-period-usage` (`{}` body) → **Cursor Models**
  (auto bucket %) and **Other Models** (API %) pools, resetting at
  `billingCycleEnd`.
- `POST /api/dashboard/get-sand-usage-status` (`{}` body) → **Grok Bot** weekly
  % with `nextResetTimestampUtc`. Absent for plans without the Grok feature.

Both calls are best-effort with the web session cookies: failure hides that row
instead of erroring (team accounts needing a teamId body, plans without Grok).
`sand-*` spend belongs to the Grok Bot window; `autoBucketModels` defines the
Cursor Models pool; everything else counts toward Other Models.

## Cost estimate (`codexbar cost --provider cursor`)

Billing-cycle spend in real billed dollars: plan + on-demand + bot spend, with a
per-bucket breakdown (Bot row only when the API reports a bot quota). Cursor
reports spend, not tokens, so there are no token counts — and no pricing table
is involved. Requires a Cursor web session (browser cookies or manual header);
with cookies off it explains how to enable them. Included in the
multi-provider TOTAL at face value.

## Key files
- `Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe.swift`
- `Sources/CodexBar/CursorLoginRunner.swift` (login flow)
