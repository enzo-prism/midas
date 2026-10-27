# Getting started with Midas

Midas puts estimated inference spend, remaining usage, and reset times in your menu bar.
Download the signed Apple Silicon app from [Midas releases](https://github.com/enzo-prism/midas/releases/latest).
The public app requires macOS 14 or later. Extract the ZIP and move the app to Applications;
the bundle is **Midas.app**.

## Three short steps

1. **Services:** choose Codex, Claude, Cursor, and/or Meta. You do not need a Codex account to use Midas.
2. **Accounts:** connect the accounts you use. Codex supports multiple separate OpenAI sign-ins.
   Claude supports separate verified account sign-ins and independent usage rows.
   Cursor opens its existing browser sign-in flow. Meta reads Muse Code activity on this Mac.
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
  weekly quota resets and do not change with the spend period. The overview names the account
  whose quota and reset count it shows; a different Codex account can have a different balance.
  The count comes from OpenAI's reported reset-credit data, not the scheduled reset timer.
- **Automatic Codex dollars:** Midas estimates a blended dollar-per-token rate from recent
  priced local Codex history and applies it to available cloud token totals. This is an
  approximation of inference value at API rates, not an OpenAI bill or a precise cloud model
  breakdown. Without a usable sample, the dollar amount stays unavailable. A custom rate or
  tokens-only display is available under **Codex estimate options**.
- **Optional pricing-sample sharing:** Macs on the same iCloud Drive account can share derived pricing
  samples when enabled in Midas on each Mac. Records contain a rate, token counts, timestamps,
  a device identifier, and a hashed account-set identifier. They do not contain prompts,
  emails, or login credentials. Midas selects a valid matching sample; it does not add samples
  together or use iCloud as an account-login service. Stale samples expire after 24 hours.
- **Cursor:** the overview shows three bars, matching cursor.com/dashboard/usage: **Cursor Models**
  and **Other Models** (monthly pools, with the billing-cycle reset) and **Grok Bot weekly** (with its
  weekly reset). A Grok Bot trial reads **Grok Bot trial** with its end date, and plans without a
  Grok Bot allowance show no Grok bar. If Cursor does not report the two pools, the plan's Total
  takes their place. Total always drives the menu-bar ring and stays in the provider details.
  Cursor dollars come from cursor.com on each refresh. Midas keeps the last good estimate, labeled
  last known, when a refresh fails, and shows it right after launch instead of waiting for
  cursor.com. Available quota does not guarantee an API-equivalent dollar estimate.
- **Claude:** the overview always shows two subscription limits: the **5-hour limit** and the
  **Weekly limit**, each with % left and its reset time. If Claude reports no 5-hour window,
  only the weekly limit is shown, labeled as weekly. Model-specific weekly limits, such as Fable,
  appear in account details with their own remaining percentage and reset time. The all-models
  weekly limit still applies to that usage. Each saved Claude account refreshes separately without
  needing the Codex **Track all connected accounts** option.
  **Claude dollars** value Claude Code activity on this Mac at Anthropic API rates and count
  toward the estimated total: per-model input, output, 5-minute and 1-hour cache writes, and
  cache reads, plus fast mode, US-only inference (`inference_geo: "us"`, 1.1x), and web
  searches ($10 per 1,000). Claude Code on a subscription is not billed per token, so this is
  the API-equivalent value of your usage, not a charge. Days with a model Midas cannot price
  are shown as a partial total. Only local transcripts count; Claude Code prunes old
  transcripts (its `cleanupPeriodDays` setting), so older periods can be empty.
- **Anthropic API:** add an organization Admin API key (`sk-ant-admin…`) under
  **Settings → Providers → Anthropic** to see billed API spend and token usage. Billed spend is
  labeled **Billed API spend** and is not added to the estimated total. See [Anthropic](anthropic.md).
- **Meta:** Midas reads Muse Code terminal logs. They describe this Mac unless usage Sync is enabled.
  Meta AI / the Muse consumer app currently has no verified numeric usage source; its usage stays
  unavailable. Midas does not invent a remaining quota when the provider does not report one.
- **DGX Spark:** connect the private usage hub and install its prospective vLLM collector. The
  NVIDIA-branded card always shows recorded tokens for the last 30 UTC days. Its cloud API
  equivalent uses the verified model's published hosted rates, including cached input as a subset
  of input. It is an estimate, not a bill, electricity cost, or measured savings. Unknown models
  and incomplete measurements remain unpriced; collector gaps are disclosed. The combined total
  still follows your chosen spend period. See [Spark runtime setup](MIDAS_TAILSCALE_HUB.md#spark-local-runtime-metrics).

The period selector offers calendar periods and a rolling 30-day view. The total includes only
available estimates for the selected period. Missing data is excluded and disclosed as partial;
it is never treated as zero. Different currencies are not silently converted.

## Combine usage across Macs

For Macs and Linux machines connected through Tailscale, select **Tailscale hub** in
**Settings → Sync** and use the enrolled device's private connection file. This transport does
not depend on iCloud identity. Each device keeps its own revocable usage credential; prompts
and provider sign-in credentials stay local. See [private hub setup](MIDAS_TAILSCALE_HUB.md).
For shared-folder sync, use these steps:

1. Create a private folder such as **iCloud Drive/Midas Usage**. On Macs signed into the same Apple
   Account, iCloud Drive can deliver that folder to both Macs.
2. Open **Settings → Sync** on each Mac and choose the same folder. Give each Mac a distinct name.
3. Keep **Sync usage from this Mac** and **Show combined usage** enabled. Connect the providers
   normally on each Mac and keep Midas running to share new measurements.
4. Click **Sync now** on both Macs after iCloud delivers the files. Check that both list the other
   device and display the same recorded totals for the same UTC period.

Codex, Claude Code, and Muse Code session events are combined without counting copied sessions
twice. Cursor account history is counted once per verified account/day. Combined spend replaces
the normal local/cloud source; Codex cloud totals are not added to local session events. Switching
**Show combined usage** off restores this Mac's normal source while sharing continues. Account
sign-ins, quota percentages, and reset times remain local.

Shared history uses UTC days and retains up to 365 days of available records, including the last
received history during a folder outage. Missing source history stays unavailable. **Saved from
this Mac** confirms a local write; **Received on this Mac** confirms a peer publication was read.
Neither confirms the other Mac is online. iCloud delivery can take time.

Only numeric usage, costs, public model names, opaque event/account IDs, and device labels enter
the chosen folder. Credentials, prompts, transcripts, raw emails, and source paths stay local.
The shared JSON is readable to anyone with folder access, so keep the folder private. Disconnecting
stops sharing and keeps existing shared files. See [usage sync](MIDAS_USAGE_SYNC.md) for coverage,
deduplication, privacy, recovery, and verification details.

## Choose the menu-bar account

Open **More actions → Menu-bar provider**, then choose a provider and an account.
The selection is remembered separately for each provider. **Current account** follows the
provider's active account. Account choices include both the nickname and identity; Hide personal
information replaces those labels with account numbers.

The circle uses that account's remaining allowance: Codex's weekly limit, or its explicitly
reported monthly allowance when no weekly limit exists. A missing account or unavailable quota
stays unavailable instead of showing another account's balance. A failed refresh marks retained
usage as last known. Changing this choice does not switch the Codex or Claude CLI login, and
combined spend totals keep their existing scope. Connected accounts continue refreshing even
when the account chosen for the circle differs from the active login.

An optional Codex email filter below still restricts which accounts are available. Remove it
if you want to choose between all saved Codex logins.

## Limit Codex to one OpenAI account

The optional local preference `midasCodexAccountEmailFilter` limits Codex to a normalized
OpenAI email address. Set it in the `com.designprism.midas` defaults domain, then restart Midas.
Only matching accounts appear in Codex usage, including cached quota rows and cloud history.
If that account is unavailable, Midas does not fall back to another OpenAI login.

With this filter enabled, Codex spend and token totals use account-verified cloud history.
Combined device history and ambient local session logs are excluded because they cannot
reliably identify the OpenAI account that produced every event. Cloud history may have a
shorter reporting window or unavailable dollar estimates. Other providers retain their existing
usage scope. Saved connections and shared-history contributions are preserved.

Remove the preference and restart to restore the normal multi-account behavior.

## Multiple Claude accounts

1. Open **Settings → Providers → Claude → Add Claude account**.
2. Sign in to the account you want to connect. If Google sign-in stalls in the embedded window,
   cancel, reopen **Add Claude account**, and choose **Continue with email** instead.
3. For email sign-in, open Claude's email link. If it displays a verification code, enter that code
   in the embedded sign-in window using **Enter verification code**.
4. Click Midas's **Continue** button below the web page. Check the verified email, optionally choose
   a nickname, and click **Save account**. Saving also enables Claude in the panel.
5. Repeat for the other account. Each attempt uses a separate temporary web session.

Both accounts remain listed under **Claude accounts**. Select an account in settings to inspect its
usage, email, plan, and latest refresh. The main Claude display keeps each account's limits separate.
A failed credential cannot fall back to another account's browser, CLI, or Keychain identity.

To reconnect an expired account, use **Add Claude account** and sign in to the same email. Midas shows
**Reconnect account** and preserves the existing organization selection. A failed save leaves the
verified sign-in available for retry. If embedded authentication is unavailable, the manual session-key
or OAuth-token field remains available. Do not share the credential file or commit it to source control.

These connections do not change the active Claude Code login. Claude Code dollar estimates cover
recorded activity, combined across Macs when Sync is enabled, and appear once per provider rather
than as an account-by-account bill.

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
recorded months **inline in the panel**. Options preview their date range in this Mac’s time zone,
or UTC when combined Sync usage is selected; gold marks the
selected period. Each provider’s days are counted in its source calendar: local days for history
scanned on this Mac, UTC for shared history, Cursor account history, OpenAI cloud history, and
Anthropic cost reports. Choosing an option updates the estimate total and collapses the list.
**Partial total** / **Estimate details** also expand inline. The Air panel is already an
`NSPopover`, so those lists must not open a nested SwiftUI popover or take AppKit
first-responder focus — that combination aborts on macOS 27 (`swift_abortRetainUnowned` in
`KeyViewProxy` while `NSPopover` selects a first key view).

Recorded months come from valid daily history for displayed providers. A selected historical
month remains selectable if its cached history disappears. Recorded history can be incomplete,
and changing the spend period does not change provider quota reset schedules.

## Comparing months

Open **Spend history** from the Midas panel. **Month by month** appears in Overview with a
provider selector, and on each provider page. Choose **Costs** or **Tokens**, then **6 months**
or **12 months**. Hover over a bar, use the previous/next month buttons, or select an entry in
**Monthly records** to inspect that month. The daily-history period filter does not limit this chart.

Bars show recorded calendar-month subtotals. The current month is marked **month to date** and
uses a lighter bar. Gaps mean unavailable data; a recorded zero remains zero. A comparison uses
the immediately preceding month only. For the current month, both periods stop at the same day
number, capped at the previous month's length. Percentage change is omitted when the previous
value is zero. Comparisons are withheld when record coverage differs, values are missing or
invalid, costs include unpriced activity, or duplicate daily records conflict. Sparse matching
records can be compared, but they do not establish complete account or month coverage.

Estimates, provider metering, and billed API costs retain their source labels. Each provider is
shown separately in its original currency. Local records describe activity captured on this Mac;
they do not establish a complete account bill. Source date keys keep their reporting calendar:
UTC for shared usage, Cursor, OpenAI API, Anthropic API, Mistral, Codex cloud, and billed cost reports;
local calendar dates for this Mac's transcript history.

History defaults to 30 days. **Load up to 12 months** sets the existing history window to 365
days and requests a refresh. Local transcript providers require local cost history to be enabled;
connected OpenAI and Anthropic API reports can load longer history independently. Provider retention and source
availability still apply, and the first month may be partial. Codex cloud currently supplies only
30 days, and Mistral currently supplies only its current UTC month, so the chart leaves older
months unavailable for these sources. This control does not enable local cost
history when it is off or switch Codex between cloud and local sources.
