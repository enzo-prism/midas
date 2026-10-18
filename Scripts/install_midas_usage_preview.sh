#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" || "$#" -lt 2 ]]; then
  printf '%s\n' 'Usage: install_midas_usage_preview.sh APP_PATH PRIVATE_CONNECTION_JSON [--launch]' \
    'Installs a Midas Tailscale preview in ~/Applications and enables its private sync connection.' \
    'Keeps the release app bundle and existing sync files. The preview uses Midas local data and accounts.' \
    'Refuses to replace a preview or connection. --launch quits the running Midas app and opens the preview.'
  [[ "${1:-}" == "--help" ]] && exit 0
  exit 1
fi
[[ "$(uname -s)" == Darwin ]] || { printf 'This installer requires macOS.\n' >&2; exit 1; }
preview_app="$1"
preview_config="$2"
preview_launch="${3:-}"
[[ -z "$preview_launch" || "$preview_launch" == --launch ]] || { printf 'Unknown option.\n' >&2; exit 1; }
umask 077

# Validate all inputs before changing preferences or stopping an app.
/usr/bin/codesign --verify --deep --strict "$preview_app"
preview_target=$(/usr/bin/python3 - "$preview_app" "$preview_config" <<'PY'
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import sys
import urllib.parse

app = Path(sys.argv[1]).absolute()
config = Path(sys.argv[2]).absolute()
raw_home = Path.home().absolute()
for parent in [raw_home, *raw_home.parents]:
    if parent.is_symlink():
        raise SystemExit('Midas private configuration must stay in an internal home directory without symlinks.')
home = raw_home.resolve()
if str(home).startswith(('/Volumes/', '/mnt/', '/media/')):
    raise SystemExit('Midas private configuration must stay on internal storage.')
for path in [app, config]:
    for parent in [path, *path.parents]:
        if parent.is_symlink():
            raise SystemExit('Installer inputs must not pass through symbolic links.')
with (app / 'Contents/Info.plist').open('rb') as source:
    identity = plistlib.load(source)
if identity.get('CFBundleIdentifier') != 'com.designprism.midas.debug':
    raise SystemExit('This installer accepts only the Midas debug preview.')
info = config.stat()
if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
    raise SystemExit('The per-device connection must be a private, owned regular file with mode 600.')
if info.st_size > 8192:
    raise SystemExit('Connection file is too large.')
connection_bytes = config.read_bytes()
connection = json.loads(connection_bytes)
endpoint = urllib.parse.urlsplit(connection.get('endpoint', ''))
if endpoint.scheme != 'https' or not (endpoint.hostname or '').endswith('.ts.net'):
    raise SystemExit('A private Tailscale HTTPS endpoint is required.')
destination = home / 'Applications/Midas Tailscale Preview.app'
support = home / 'Library/Application Support/Midas/usage-sync'
connection_destination = support / 'hub-connection.json'
hub_history = support / 'hub-state.json'
for target in [destination, connection_destination, hub_history]:
    if target.exists() or target.is_symlink():
        raise SystemExit('A preview, hub connection, or hub history already exists. Review it before upgrading.')
    for parent in target.parents:
        if parent.is_symlink():
            raise SystemExit('The installation path cannot contain symbolic links.')
destination.parent.mkdir(parents=True, exist_ok=True)
support.mkdir(parents=True, exist_ok=True, mode=0o700)
support.chmod(0o700)
shutil.copytree(app, destination, symlinks=True)
try:
    with connection_destination.open('xb') as output:
        output.write(connection_bytes)
        output.flush()
        os.fsync(output.fileno())
    connection_destination.chmod(0o600)
except Exception:
    raise SystemExit('The preview was copied, but the private connection could not be saved. Preferences unchanged.')
if connection_destination.read_bytes() != connection_bytes:
    raise SystemExit('Connection verification failed. Preferences unchanged.')
print(destination)
PY
)

/usr/bin/codesign --verify --deep --strict "$preview_target"
/usr/bin/defaults write com.designprism.midas.debug midasUsageSyncTransport -string tailscaleHub
/usr/bin/defaults write com.designprism.midas.debug midasUsageSyncEnabled -bool true
/usr/bin/defaults write com.designprism.midas.debug midasUsageSyncIncludeTotals -bool true
/usr/bin/defaults write com.designprism.midas.debug midasSpendPeriodSelection -string rolling30Days
printf 'Midas Tailscale preview installed. The existing release app is preserved.\n'
if [[ "$preview_launch" == --launch ]]; then
  /usr/bin/pkill -x Midas || true
  /usr/bin/open -n "$preview_target"
fi
