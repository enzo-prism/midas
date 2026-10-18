---
summary: "Private multi-device numeric usage collection, hub setup, and verification"
read_when:
  - "Connecting Midas on multiple devices through Tailscale"
  - "Installing or diagnosing a Spark usage collector"
---

# Private usage across devices

The Mac mini hosts the shared numeric ledger. Midas on each Mac and the Linux collector use the same
workspace salt, log parsers, model pricing, publication validation, and duplicate reconciliation.
Tailscale carries the exchange privately. A device-specific bearer credential adds revocation and
prevents a device from publishing as another device.

The displayed dollar value is an estimate of supported token usage at known model prices. It is not
an invoice or subscription spend. Cached input stays in the token mix and receives its cached-input
price. Unknown prices remain unknown. Account-wide quota percentages are not token events and must
never be added across machines.

## Coverage

- Codex native session logs, including additional session roots, and archived sessions.
- Claude native projects logs with stable request/message identities.
- Supported Meta numeric session records.
- Existing supported provider-account numeric history is exchanged by the Midas app; the collector
  reads local logs and does not fetch provider accounts, browser cookies, or Keychain secrets.

An absent or inaccessible source is unknown. The collector does not manufacture zero usage for it.
Consumer ChatGPT/Claude iPhone activity is not available merely because the iPhone joined Tailscale.
The separate vLLM runtime collector described below supports verified Prometheus token counters.
Other Ollama and Hermes usage needs a verified numeric source integration; it remains unavailable
until that integration exists. Token counts for a local model do not imply a paid API bill, and
API-equivalent value must be labeled separately.

## Build

The existing `CodexBarCLI` product runs on macOS and Linux; it is installed as `midas-collector` below.
It requires Swift 6.2 or newer and the repository's existing SwiftPM dependencies. No new parser or
package dependency is introduced. The macOS application and widget targets are excluded on Linux.
Build on each host for its architecture; Spark is Linux ARM64.

```sh
swift build -c release --product CodexBarCLI
```

Keep source, configuration, credentials, scanner state, and numeric ledgers on each machine's
internal protected storage. Rebuildable build output can use an explicitly selected verified build
volume. Do not move any usage state or credentials onto an unencrypted PortableSSD.

## Configure the hub and enroll devices

Keep the hub listener bound to loopback. Serve it through private Tailscale HTTPS, never Funnel or a
public listener. Restrict access in the tailnet policy to the approved machines; a URL alone is not
an access policy. The mini needs to be awake for exchange. Collection continues from the cached
workspace when it is offline.

Prepare the hub and device connection files using `Scripts/usage-hub/midas_usage_hub.py` (see its `--help`).
The hub owns the single workspace ID and salt. Every device gets a different UUID and credential.
Do not create three independent workspaces: copied source logs must produce the same event IDs.
Do not put bearer credentials into shell arguments, source code, environment files, screenshots,
or logs. Deliver the private connection JSON to the matching device over an approved private path.

For a new workspace, the setup commands are:

```sh
umask 077
mkdir -p "$HOME/Library/Application Support/Midas/usage-hub" "$HOME/.config/midas"
python3 Scripts/usage-hub/midas_usage_hub.py \
  --state-dir "$HOME/Library/Application Support/Midas/usage-hub" init
python3 Scripts/usage-hub/midas_usage_hub.py \
  --state-dir "$HOME/Library/Application Support/Midas/usage-hub" \
  add-device --name "Spark" --public-url "https://mini.example-tailnet.ts.net" \
  --output "$HOME/.config/midas/spark-connection.json"
python3 Scripts/usage-hub/midas_usage_hub.py \
  --state-dir "$HOME/Library/Application Support/Midas/usage-hub" serve --port 8766
```

Replace the example URL with the mini's verified private Tailscale HTTPS URL. If adopting an existing
sync workspace, pass its private workspace file to `init --workspace-file` instead of creating a new
salt. Use `add-device --device-id` to preserve the app's existing UUID where appropriate. Repeat
enrollment with a unique name and output file for each machine. `list-devices` shows enrollment
status; `revoke --device-id UUID` disables one credential. Configure Tailscale Serve and its access
policy only after reviewing that exact private endpoint and the approved devices.

The collector's `--config` file has this shape, with real values supplied by enrollment:

```json
{
  "endpoint": "https://mini.example-tailnet.ts.net/",
  "deviceID": "7d74f49d-6c1c-4d98-82cb-641c76bd9201",
  "deviceName": "Spark",
  "credential": "<unique revocable device credential>",
  "workspaceID": "6b329302-a41d-4b52-bc44-11554126ec86"
}
```

Use an owner-only regular file (0600), in an owner-only directory (0700). The Midas app's hub
connection uses the same connection format. Run the Midas app as the collector on each Mac, and
the standalone collector on Spark. Use one stable identity and one writer per device; simultaneous
app and standalone writers for the same UUID can conflict even if their local directories differ.

### MacBook preview package

The private Apple silicon setup package contains `Midas.app`, `install_midas_usage_preview.sh`,
`install-mac.sh` (a copy of `Scripts/install_midas_macbook.sh`), and the enrolled MacBook's
`private-connection.json`. Deliver that package only to the matching MacBook over an approved
private transfer. After extracting it into Downloads, run:

```sh
bash "$HOME/Downloads/Midas-MacBook-Setup-2026-10-17/install-mac.sh"
```

The installer verifies the app signature, refuses to overwrite a preview, connection, or hub
history, and installs `~/Applications/Midas Tailscale Preview.app`. It enables hub sync, combined
totals, and Last 30 days. First sync fetches and pins the hub's actual workspace; an offline first
attempt retries later. It preserves the stable app bundle but uses Midas's existing local storage
and accounts. Launching quits the running Midas process. Keep the preview running for background
sync; original supported logs can be collected after an app or network outage. The package is an
ad hoc signed development preview, not a notarized public release. Do not bypass a macOS security
warning; resolve signing or use the normal approved release workflow if one appears.

## Run the collector

First perform one exchange with the hub available so the shared salt can be cached:

```sh
.build/release/CodexBarCLI usage-sync collect \
  --config "$HOME/.config/midas/collector-connection.json" --once
```

Normal continuous operation collects every 180 seconds. To override the interval, use
`--interval 180` without `--once`. Scheduled services use `--once` every three minutes, allowing the
OS to avoid running an idle daemon. The command emits only safe numeric status JSON. Exit 0 means
the publication succeeded; exit 2 means it is queued/offline; exit 1 means configuration, state,
or collection could not be validated. Raw errors are intentionally not printed because they can
contain URLs or source paths.

Default persistent state locations:

- macOS: `~/Library/Application Support/Midas/usage-collector/`
- Linux: `~/.local/share/midas/usage-collector/`

`received.json` keeps the workspace and last-good numeric publications. `outbox.json` retains local
numeric history and is flushed before every send. Files are capped, validated, atomically replaced,
and owner-only. `collector.lock` prevents overlapping processes. Do not delete state to fix an
outage; it holds numeric history after original source logs roll off. Re-enrolling to a different
workspace requires a separate state directory; mismatches fail safely.

Fixture or nonstandard source paths can be selected explicitly:

```sh
.build/release/CodexBarCLI usage-sync collect \
  --config /private/fixture/connection.json --state-root /private/fixture/state \
  --providers codex,claude,meta \
  --codex-root /private/fixture/codex/sessions \
  --claude-root /private/fixture/claude/projects \
  --meta-root /private/fixture/meta/sessions \
  --trace-database /private/fixture/absent-trace.sqlite --once --refresh
```

`--codex-additional-root` and `--claude-root` can repeat. Set every enabled provider's root plus
`--trace-database` during fixture testing, or limit `--providers` to the fixture providers, so the
test never scans real accounts. The collector uses 365 days of retained numeric history; the
app's 30-day display selects the correct window from that history.

## Prepare background collection

Run as the logged-in user. The installer uses no `sudo`, does not enable remote access, and
prepares an inactive service unless `--start` is explicitly supplied. It refuses to overwrite an
existing installation.

```sh
Scripts/install_midas_usage_collector.sh \
  --binary "$PWD/.build/release/CodexBarCLI" \
  --config "$HOME/.config/midas/collector-connection.json"
```

On macOS, review `~/Library/LaunchAgents/com.designprism.midas.usage-collector.plist`, then start:

```sh
launchctl bootstrap "gui/$(id -u)" \
  "$HOME/Library/LaunchAgents/com.designprism.midas.usage-collector.plist"
```

The private log is `~/Library/Logs/Midas/usage-collector.log`. A LaunchAgent runs while that user is
logged in. On Linux, review `~/.config/systemd/user/midas-usage-collector.service` and `.timer`, then:

```sh
systemctl --user daemon-reload
systemctl --user enable --now midas-usage-collector.timer
journalctl --user -u midas-usage-collector.service --since today
```

User services require a user session. Running across logout/reboot needs the host's approved user
service policy; the installer does not enable lingering or change security settings. Suspend
collection with `launchctl bootout gui/UID/…` on macOS or
`systemctl --user disable --now midas-usage-collector.timer` on Linux. Revoke the matching hub
credential to stop the device's access immediately. Keep its local history unless removal is
explicitly intended.

## Spark local runtime metrics

`Scripts/usage-hub/local_metrics_collector.py` adds prospective vLLM token usage without reading
requests, prompts, transcripts, model labels, or provider credentials. It reads only loopback
`/metrics`, requires `process_start_time_seconds`, and recognizes the verified numeric
`vllm:prompt_tokens_total`, `vllm:generation_tokens_total`, and optional
`vllm:request_success_total` counters. It publishes the separate `localInference` namespace with
unknown prices. These tokens contribute to token totals; they do not add a fabricated dollar value.

Ship `local_metrics_collector.py` together with `midas_usage_hub.py`, which supplies shared wire
validation. Both use Python 3.10+ and the standard library. Enroll a distinct device such as
`Spark local runtime`; do not reuse the Swift Spark collector's UUID, because each writer publishes
its complete own snapshot. Keep both the unique connection and state directory private and internal.

```sh
python3 Scripts/usage-hub/local_metrics_collector.py \
  --config "$HOME/.config/midas/spark-runtime-connection.json" \
  --state-dir "$HOME/.local/share/midas/local-runtime-usage" \
  --metrics-url http://127.0.0.1:11434/metrics --interval 180 --once
```

Remove `--once` for a continuous collector. Its numeric state and outbox are atomically flushed
before counter advancement is sent. It retries a retained publication even if the runtime itself
has become unavailable. No redirects or environment proxies are used. It reloads the private
credential configuration every cycle, and a process lock prevents two instances using one state
directory. Exit 0 means both a current sample and publication succeeded; exit 2 means the retained
publication was uploaded while the current sample was unavailable; exit 1 means collection or
exchange remains pending.

The first sample establishes a baseline and does not reconstruct history. Only a pair of samples
within the same UTC day, same runtime process, and at most twice the configured interval produces
a delta. Counter decreases, runtime restarts, clock reversal, longer gaps, and UTC day rollover
establish a new baseline and increase the partial-coverage count. The collector deliberately does
not assign an outage's lifetime-counter difference to the latest day. This can omit usage during
those gaps and the interval around midnight; the 30-day total remains the measured portion.
Missing request counters stay unknown. Polling bounds timing precision to the sample interval.
Exact historical attribution would require per-request numeric events from the runtime.

## Verify completion

Use synthetic provider logs to avoid spending credits. Give three logical devices unique records,
copy one session to another device, and confirm their union counts the copy once. Repeat uploads,
append a streaming completion, and restart collectors; totals must remain deterministic. Disconnect
the hub, collect another fixture, and confirm the durable outbox retains it. Reconnect, exchange,
and confirm both Macs show the same 30-day tokens and estimated value. The app should show stale
or missing devices; equal cached numbers alone are not proof of a current exchange.

Validate separate gates: parser/merge tests, collector tests, hub authentication/identity tests,
local service lifecycle, each real device's last successful exchange, and both Macs' live display.
Do not label deployment or complete-device coverage as done based only on a passing local fixture.
