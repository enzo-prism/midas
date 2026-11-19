---
summary: "Gemini provider data sources: OAuth-backed quota APIs, token refresh, and tier detection."
read_when:
  - Debugging Gemini quota fetch or auth issues
  - Updating Gemini CLI OAuth integration
  - Adjusting tier detection or model mapping
---

# Gemini provider

Gemini supports Gemini CLI OAuth credentials, Antigravity local/CLI quota probing, and Google OAuth remote quota fetching, plus local transcript token/cost scanning. No browser cookies.

## Data sources + fallback order

In `auto` mode, strategies run in order (each validating the pinned Google account email when `accountEmail` / `CODEXBAR_GEMINI_ACCOUNT_EMAIL` is configured):

1) **Gemini CLI OAuth API (`oauth-api`)**
   - Reads auth type from `~/.gemini/settings.json` and OAuth credentials from `~/.gemini/oauth_creds.json`.
   - Supported: `oauth-personal` (or unknown → try OAuth creds).
   - Unsupported: `api-key`, `vertex-ai` (hard error).
   - Skipped in `auto` mode when `~/.gemini/oauth_creds.json` does not exist.

2) **Antigravity desktop local probe (`antigravity-local`)**
   - Probes the running Antigravity IDE language server (`GetUserStatus`) and extracts Gemini-only model quotas (excluding non-Gemini models such as Claude or GPT).
   - Maps rolling 5-hour and 7-day weekly pools into `primary` and `secondary`, and deduplicates effort-tier variants in `extraRateWindows`.

3) **Google OAuth remote API (`oauth`)**
   - Uses Gemini-scoped Google OAuth credentials (`GEMINI_OAUTH_CREDENTIALS_JSON`, `~/.codexbar/gemini/oauth_creds.json`, or a matching `~/.codexbar/antigravity/oauth_creds.json`) against `cloudcode-pa.googleapis.com` so refreshes continue when Antigravity is closed.

4) **Antigravity `agy` CLI local HTTPS (`antigravity-cli`)**
   - Final fallback when signed into the matching Google account.

5) **Local token usage & API-rate cost estimate**
   - Scans `~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl` for Gemini `PLANNER_RESPONSE` token counts (`input_tokens`, `cache_read_tokens`, `output_tokens`).
   - Prices normalized Gemini model IDs via `models.dev` (`google` / `google-vertex`) with released Gemini 2.5 fallbacks; unknown models stay unpriced.

## OAuth credentials
- File: `~/.gemini/oauth_creds.json`.
- Required fields: `access_token`, `refresh_token` (optional), `id_token`, `expiry_date`.
- If access token is expired, we refresh via Google OAuth using client ID/secret extracted
  from the Gemini CLI install (see below).

## OAuth client ID/secret extraction
- We locate the installed `gemini` binary, then search for:
  - Homebrew nested path:
    - `.../libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js`
  - Bun/npm sibling path:
    - `.../node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js`
- Regex extraction:
  - `OAUTH_CLIENT_ID` and `OAUTH_CLIENT_SECRET` from `oauth2.js`.

## API endpoints
- Quota:
  - `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
  - Body: `{ "project": "<projectId>" }` (or `{}` if unknown)
  - Header: `Authorization: Bearer <access_token>`
- Project discovery (quota project ID):
  - Primary: `cloudaicompanionProject` from `loadCodeAssist`.
  - Fallback: `GET https://cloudresourcemanager.googleapis.com/v1/projects`
    - Picks `gen-lang-client*` or label `generative-language`.
- Tier detection:
  - `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
  - Body: `{ "metadata": { "ideType": "GEMINI_CLI", "pluginType": "GEMINI" } }`
- Token refresh:
  - `POST https://oauth2.googleapis.com/token`
  - Form body: `client_id`, `client_secret`, `refresh_token`, `grant_type=refresh_token`.

## Parsing + mapping
- Quota buckets:
  - `remainingFraction`, `resetTime`, `modelId`.
  - For each model, lowest `remainingFraction` wins.
  - `percentLeft = remainingFraction * 100`.
- Reset:
  - `resetTime` parsed as ISO-8601, formatted as "Resets in Xh Ym".
- UI mapping:
  - Primary: Pro models (lowest percent left).
  - Secondary: Flash models (lowest percent left).

## Plan detection
- Tier from `loadCodeAssist`:
  - `standard-tier` → "Paid"
  - `free-tier` + `hd` claim → "Workspace"
  - `free-tier` → "Free"
  - `legacy-tier` → "Legacy"
- Email from `id_token` JWT claims.

## Key files
- `Sources/CodexBarCore/Providers/Gemini/GeminiStatusProbe.swift`
