---
summary: "ElevenLabs provider notes: signed-in CLI or API key, and subscription usage fields."
read_when:
  - Adding or modifying the ElevenLabs provider
  - Debugging ElevenLabs API keys, the ElevenLabs CLI source, or subscription usage parsing
  - Adjusting ElevenLabs credit or voice-slot labels
---

# ElevenLabs Provider

The ElevenLabs provider reads subscription usage from the ElevenLabs API. It gets there in one of two ways:

- **ElevenLabs CLI** (no API key): Midas runs the official CLI (`@elevenlabs/cli`), which uses the session
  that `elevenlabs auth login` saved.
- **API key**: Midas calls the API directly with an `xi-api-key`.

**Settings -> Providers -> ElevenLabs -> Usage source** picks one:

| Source | Behaviour |
| --- | --- |
| Auto (default) | Uses an API key when one is set (Settings, token account or environment). Without a key it runs the CLI. A rejected key also falls back to the CLI, unless a token account is selected. |
| ElevenLabs CLI | Always runs the CLI. The API key field is hidden. |
| API key | Only uses the API key. |

## Features

- Character credit usage from the current subscription period.
- Reset timing when the API returns `next_character_count_reset_unix`.
- Voice slot and professional voice slot usage when those fields are present.
- Plan/status text from the subscription response.

## Setup

### ElevenLabs CLI (no API key)

```bash
npm install -g @elevenlabs/cli
elevenlabs auth login
```

Then enable **ElevenLabs** in **Settings -> Providers**. Midas finds `elevenlabs` at `ELEVENLABS_CLI_PATH`, on
the login-shell PATH (which covers nvm, fnm and Volta), or in `~/.local/bin`, `~/.npm-global/bin`,
`/opt/homebrew/bin` and `/usr/local/bin`.

Midas runs `elevenlabs user subscription get --format json` with no API key in its environment, so the CLI
uses its own session. That session lives in the CLI's own Keychain item (`elevenlabs:OAuth`). Midas never
reads it, so no Keychain prompt appears and no credential passes through Midas.

### API key from the command line

Store the API key without opening Settings:

```bash
printf '%s' "$ELEVENLABS_API_KEY" | codexbar config set-api-key --provider elevenlabs --stdin
```

This trims the piped key, writes it to `~/.codexbar/config.json` with restrictive permissions, and enables ElevenLabs by default. Use `--no-enable` to save the key without enabling the provider.

### Settings

1. Open **Settings -> Providers**
2. Enable **ElevenLabs**
3. Open `https://elevenlabs.io/app/settings/api-keys`
4. Create or copy an API key
5. Paste the key into CodexBar's ElevenLabs provider settings

### Environment Variables

CodexBar also accepts these environment variables:

- `ELEVENLABS_API_KEY`
- `XI_API_KEY`

For tests or self-hosted/proxy setups, override the API base URL with `ELEVENLABS_API_URL`.

## How It Works

- CLI: `elevenlabs user subscription get --format json` (30 s timeout). The JSON is the same subscription
  body the API returns. An auth error (`{"error":{"code":401,…}}`, exit code 2) shows as signed out.
- API endpoint: `GET https://api.elevenlabs.io/v1/user/subscription`
- Auth header: `xi-api-key`
- Fields used: `character_count`, `character_limit`, `voice_slots_used`, `voice_limit`, `professional_voice_slots_used`, `professional_voice_limit`, `tier`, `status`, `next_character_count_reset_unix`

## Troubleshooting

### "The ElevenLabs CLI is signed out"

The CLI's session expired or was never created. Run `elevenlabs auth login` in Terminal, then refresh Midas.

The CLI deletes its saved login whenever a token refresh is rejected, and an ElevenLabs refresh token works
once. Two copies of the CLI refreshing at the same moment, or a copy stopped between the refresh and the
Keychain write, therefore sign you out. Midas runs the CLI under an exclusive lock,
`~/Library/Caches/Midas/locks/elevenlabs-cli.lock`, shared by the app and its bundled `codexbar` CLI, and
never stops a run early. Other scripts that call `elevenlabs` should take the same lock, for example:

```bash
perl -e 'use Fcntl qw(:flock); $^F = 255; open(my $l, ">>", shift) or die; flock($l, LOCK_EX) or die; exec { $ARGV[0] } @ARGV' \
  ~/Library/Caches/Midas/locks/elevenlabs-cli.lock elevenlabs user subscription get --format json
```

### "ElevenLabs CLI not found"

Install it with `npm install -g @elevenlabs/cli`, or point `ELEVENLABS_CLI_PATH` at the binary. The Midas
debug log (**Settings -> Debug**) shows which `elevenlabs` binary was found.

### "Sign in with the ElevenLabs CLI … or add an ElevenLabs API key"

No key and no CLI were found. Sign in with the CLI, or set the key with `codexbar config set-api-key --provider elevenlabs --stdin`, add it in **Settings -> Providers -> ElevenLabs**, set `ELEVENLABS_API_KEY`, or configure an ElevenLabs token account.

### "ElevenLabs API error"

Confirm the API key is valid and that the current network can reach `api.elevenlabs.io`.
