# Getting started with Midas

Midas puts estimated inference spend, remaining usage, and reset times in your menu bar.
Download the signed Apple Silicon app from [Midas releases](https://github.com/enzo-prism/midas/releases/latest).
The public app requires macOS 14 or later. Extract the ZIP and move the app to Applications;
the bundle retains the CodexBar filename for compatibility.

## Three short steps

1. **Services:** choose Codex, Cursor, and/or Meta. You do not need a Codex account to use Midas.
2. **Accounts:** connect the accounts you use. Codex supports multiple separate OpenAI sign-ins.
   Cursor opens its existing browser sign-in flow. Meta reads Muse activity on this Mac.
3. **Overview:** preview estimates for the selected period, then choose **Open Midas**.

Fresh installations open setup automatically. Existing users can choose **Set up Midas** in
Settings. **Set up later** returns to the menu bar; **Continue setup** remembers your step,
including after restarting. Optional account names, connection help, and estimate settings
remain collapsed until needed. Privacy mode hides account identities in setup.

## Accounts, computers, and estimates

- **Codex:** Midas saves a dedicated connection for each account, separate from the active Codex
  CLI login. Available cloud activity from those accounts is combined across computers, with
  each account's remaining usage and reset time kept separate. Cloud availability depends on
  private ChatGPT analytics endpoints, which can change independently of Midas; this is not
  an official OpenAI billing API integration. Quota percentages are never converted into token counts.
- **Automatic Codex dollars:** Midas estimates a blended dollar-per-token rate from recent
  priced local Codex history and applies it to available cloud token totals. This is an
  approximation of inference value at API rates, not an OpenAI bill or a precise cloud model
  breakdown. Without a usable sample, the dollar amount stays unavailable. A custom rate or
  tokens-only display is available under **Codex estimate options**.
- **Optional iCloud sharing:** Macs on the same iCloud Drive account can share derived pricing
  samples when enabled in Midas on each Mac. Records contain a rate, token counts, timestamps,
  a device identifier, and a hashed account-set identifier. They do not contain prompts,
  emails, or login credentials. Midas selects a valid matching sample; it does not add samples
  together or use iCloud as an account-login service. Stale samples expire after 24 hours.
- **Cursor:** account data supplies supported usage pools and history. Available quota does not
  guarantee an API-equivalent dollar estimate.
- **Meta:** Muse history is local to this Mac. Other computers' Meta activity is not included,
  and Midas does not invent a remaining quota when the provider does not report one.

The period selector offers calendar periods and a rolling 30-day view. The total includes only
available estimates for the selected period. Missing data is excluded and disclosed as partial;
it is never treated as zero. Different currencies are not silently converted.

## If data is missing

Refresh usage once, then inspect the provider's connection status. A connected account can
still have history pending or unavailable. For Codex, use the account's reconnect action if its
connection has expired. If tokens appear but dollars do not, inspect Codex estimate options:
automatic pricing needs a usable priced sample, or you can supply your own blended rate.
Finishing setup does not wait for every provider request; background refresh continues.
