---
summary: "Suno provider notes: signed-in Suno CLI, credits, downloads and renewal."
read_when:
  - Adding or modifying the Suno provider
  - Debugging the Suno CLI source or `suno credits --json` parsing
---

# Suno Provider

The Suno provider shows your Suno plan usage. It reads it from the official `suno` CLI, using the CLI's own
login. Midas needs no API key or cookie and never opens a browser.

The provider is off by default. Enable **Suno** in **Settings -> Providers**.

## Features

- **Credits**: monthly credits used of the plan allowance, such as `470 / 2,500 credits`. Purchased top-up
  credits are added as `+N top-up`.
- **Downloads**: commercial downloads used this period, such as `20 / 20 downloads`. Extra purchased
  downloads show as `+N extra`.
- **Renewal**: both bars reset on the renewal date (`renews_on`). Pace uses the real length of that billing
  month (28 to 31 days).
- **Plan**: the plan name without the "Plan" suffix (`Pro Plan` → `Pro`), marked `Inactive` when the
  subscription is not active.

## Setup

```bash
suno auth --login
```

Midas finds `suno` at `SUNO_CLI_PATH`, on the login-shell PATH, or in `~/.local/bin`, `~/.cargo/bin`,
`/opt/homebrew/bin` and `/usr/local/bin`.

## How It Works

- Command: `suno credits --json --no-browser --quiet` (30 s timeout).
  - `--json` returns the version 1 envelope: `{ "version": "1", "status": "success", "data": { … } }`.
  - `--no-browser` stops the CLI from opening a browser or importing browser cookies when its session needs
    a refresh, so a refresh in Midas can never cause a browser or Keychain prompt.
  - The command only reads; it never spends credits.
- Fields used: `monthly_usage`, `monthly_limit`, `credits` (top-up), `total_credits_left`, `is_active`,
  `plan.name`, `period`, `renews_on`, and `download_usage.current_period_downloads_used`,
  `current_period_downloads_limit`, `additional_download_remaining`.
- Errors: the CLI writes an error envelope to stderr. Exit code 2 (or an auth/token error code) shows as
  signed out, exit code 4 as rate limited.

## Troubleshooting

### "The Suno CLI is signed out"

Run `suno auth --login` in Terminal, then refresh Midas.

### "Suno CLI not found"

Install the `suno` CLI or set `SUNO_CLI_PATH`. The Midas debug log (**Settings -> Debug**) shows which
binary was found and the exact command Midas runs.
