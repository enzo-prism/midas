# Midas sync operations

Midas keeps the hub listener on `127.0.0.1` and uses the existing Tailscale HTTPS route.
The service label remains `com.designprism.midas.usage-hub`. Updating code does not
create a workspace, enroll a replacement device, change a credential, or alter Tailscale.

## Runtime and release packaging

Release packaging requires an explicitly prepared, relocatable Python 3.10+ tree:

```sh
MIDAS_HUB_PYTHON_ROOT=/absolute/path/to/python-runtime \
MIDAS_SWIFTPM_BUILD_SYSTEM=native ./Scripts/package_app.sh
```

For FileProvider-managed checkouts, set distinct absolute `.app` paths such as
`MIDAS_APP_STAGE=/tmp/midas-package/stage/Midas.app` and
`MIDAS_APP_OUTPUT=/tmp/midas-package/Midas.app` to keep signing outside Documents.
The bounded Swift suite runner also honors `MIDAS_SWIFTPM_BUILD_SYSTEM`.

The runtime must provide `bin/python3`, its standard library and required shared
libraries. SQLite, SSL, gzip and urllib must work after relocation. The packager
rejects symbolic links escaping the tree and probes a real SQLite database. It
never downloads a runtime. Exclude site-packages and unnecessary tests/UI libraries
when preparing the tree. Retain the runtime distributor's required license files.
The release architecture must match the prepared runtime architecture.

`Contents/Helpers/MidasSyncManage` is a native launcher. It invokes the bundled
interpreter with `-I -B` and an allowlist of actions without a shell. The packager
signs each actual Mach-O file in the runtime (without following duplicate symlinks),
then the native helper, then the enclosing app. Source hashes in
`resource-manifest.json` cover Python sources only; the app signature seals the
manifest and resources. Runtime hashes are computed after signing, at installation.
No installed service needs the Codex cache or a Homebrew Python executable.

## Existing service upgrades

Use the signed installed app's fixed helper on the hub-owning Mac:

```sh
/Applications/Midas.app/Contents/Helpers/MidasSyncManage upgrade
```

The helper validates the owner-private existing database and loopback service,
creates a consistent SQLite backup and code/plist backup, migrates a separate
copy, and runs SQLite integrity checks. It copies the runtime to the hub's
`runtimes/<sha256>` directory, probes it, atomically replaces code/plist, and reloads
the same LaunchAgent. Authenticated v2 health must succeed before success is reported.
Failure restores code and service configuration. It deliberately does not replace
the live database during rollback: any writes accepted by the new process survive.
Backups and older runtime versions remain available for operator recovery.

The helper's other fixed actions are `doctor`, `check`, `restart`, `pairing-list`,
`pairing-approve --request-id UUID --code 123456`, and
`pairing-deny --request-id UUID`. Pairing approval is local to the hub owner. There
is no remote command or remote approval endpoint. The app runs management off the
main actor and renders sanitized JSON outcomes.

The initial installer still requires an explicit `--initialize` to create a new
workspace. `--runtime-root /absolute/path` copies a prepared runtime into a private
Midas-owned versioned directory. `--python` remains useful for development and
Linux fixtures. An existing installation must use the upgrade operation; initial
installation never overwrites its files.

## Evidence of synchronization

The app writes an owner-only `usage-sync/sync-receipt.json` after canonical data and
received state are durable. The doctor combines that receipt with a fresh
authenticated v2 manifest. Cached device names and a reachable hub never prove sync.

For an end-to-end two-Mac check, run this on each Mac using the preserved enrolled
UUIDs from its connection and the peer's connection (never print their credentials):

```sh
python3 Scripts/verify_midas_usage_preview.py --wait 60 \
  --require-peer-receipts --required-device-id MACBOOK_UUID \
  --required-device-id MINI_UUID
```

The checker requires the production bundle identity, a fresh durable local receipt,
no pending outbox, the accepted local revision, every active published revision
applied locally, and fresh revision vectors from both explicitly named devices.
Receipt-capable devices with no first receipt remain pending. Legacy v1 devices
remain visible but cannot establish application receipt evidence. Offline reports
are explicitly unchecked and exit unsuccessfully. Reports contain operational IDs,
counts, revisions and timestamps; they omit credentials, workspace salt, payloads,
account details and device labels.

## Automated gates

```sh
python3 -m unittest discover -s Scripts/usage-hub -p 'test_*.py' -v
```

Fixtures use private temporary directories, synthetic usage, local HTTP, and fake
service restarters. They never touch provider accounts, Keychain, production
launchd, or real Tailscale configuration. CI runs the Python contracts separately
from the Swift suites. Lifecycle tests cover migration rehearsal, integrity,
runtime copy verification, partial resources, failed health rollback with accepted
writes preserved, and fresh receipt requirements.

The real Swift URLSession gate launches the real Python v2 server on loopback and
transfers two synthetic 75,000-event device histories alongside a v1 publisher:

```sh
MIDAS_RUN_HUB_INTEGRATION=1 MIDAS_TEST_PYTHON=/path/to/python3 \
  swift test --filter MidasUsageHubIntegrationTests
```

It drops committed-upload and applied-receipt responses, truncates a page, delays a
page response, restores a missing transport cache, verifies all 150,000 records,
checks idempotent revision 1, and requires zero page transfers on an unchanged run.
The fixture writes private temporary enrollment files and never prints credentials.
