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

- **Multiple Codex accounts:** enable **Settings → Display → Track all connected accounts** to
  refresh and show each account's quota together. With tracking off, the overview follows the
  selected account. Local spend history describes activity recorded on this Mac; selecting a
  different account does not move that history into its separate sign-in directory.
- **Codex:** Midas saves a dedicated connection for each account, separate from the active Codex
  CLI login. Available cloud activity from those accounts is combined across computers, with
  each account's remaining usage and reset time kept separate. Cloud availability depends on
  private ChatGPT analytics endpoints, which can change independently of Midas; this is not
  an official OpenAI billing API integration. Quota percentages are never converted into token counts.
- **Banked resets:** each displayed Codex account has its own available reset count in the
  overview and account details. Zero means none are available; **Unavailable** means no count
  was reported. Retained stale counts are labeled **last known**. Hover the row or expand the
  account details for reported expiry information. Banked resets are separate from scheduled
  weekly quota resets and do not change with the spend period.
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
still have history pending or unavailable. Codex weekly remaining and banked resets should appear
from the last successful cache even before a live OAuth refresh finishes; **Waiting for first
update** with **Unavailable** resets while spend already shows means identity matching failed
to hydrate that cache. For Codex, use the account's reconnect action if its
connection has expired. If tokens appear but dollars do not, inspect Codex estimate options:
automatic pricing needs a usable priced sample, or you can supply your own blended rate.
Finishing setup does not wait for every provider request; background refresh continues.

## Choosing a spend period

Click the calendar control below the total to expand **This month**, **Last 30 days**, and any
recorded months **inline in the panel**. Options preview their UTC date range; gold marks the
selected period. Choosing an option updates the estimate total and collapses the list. The Air
panel is already an `NSPopover`, so the period list must not open a nested SwiftUI popover or
take AppKit first-responder focus — that combination aborts on macOS 27
(`swift_abortRetainUnowned` in `KeyViewProxy` while `NSPopover` selects a first key view).

Recorded months come from valid daily history for displayed providers. A selected historical
month remains selectable if its cached history disappears. Recorded history can be incomplete,
and changing the spend period does not change provider quota reset schedules.
