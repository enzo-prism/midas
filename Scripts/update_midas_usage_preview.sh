#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == --help || "$#" -lt 1 || "$#" -gt 2 \
  || ( "$#" -eq 2 && "${2:-}" != --all-openai-accounts ) ]]; then
  printf '%s\n' 'Usage: update_midas_usage_preview.sh APP_PATH [--all-openai-accounts]' \
    'Updates the installed Midas Tailscale preview and reopens it.' \
    'Keeps its connection, preferences, usage history, and a backup of the prior app.' \
    'Optional: enable all connected OpenAI accounts and their reported history, then restart the preview.'
  [[ "${1:-}" == --help ]] && exit 0
  exit 1
fi
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  printf 'This update requires an Apple silicon Mac.\n' >&2
  exit 1
}
/usr/bin/codesign --verify --deep --strict "$1"
/usr/bin/python3 - "$1" "${2:-}" <<'PY'
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time

os.umask(0o077)
source = Path(sys.argv[1]).absolute()
all_openai_accounts = sys.argv[2:] == ['--all-openai-accounts']
home = Path.home().absolute()
destination = home / 'Applications/Midas Tailscale Preview.app'
if str(home).startswith(('/Volumes/', '/mnt/', '/media/')):
    raise SystemExit('The preview must stay on internal storage.')
for path in (source, home, destination):
    for component in (path, *path.parents):
        if component.is_symlink():
            raise SystemExit('Update paths cannot contain symbolic links.')
for app in (source, destination):
    with (app / 'Contents/Info.plist').open('rb') as f:
        if plistlib.load(f).get('CFBundleIdentifier') != 'com.designprism.midas.debug':
            raise SystemExit('Both apps must be the Midas debug preview.')
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
def digest(app):
    value = hashlib.sha256()
    for name in ('Contents/MacOS/Midas', 'Contents/Info.plist', 'Contents/_CodeSignature/CodeResources'):
        value.update((app / name).read_bytes())
    return value.hexdigest()
def preview_pids():
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,command='], check=True, capture_output=True, text=True)
    executable = str(destination / 'Contents/MacOS/Midas')
    return [int(parts[0]) for line in result.stdout.splitlines()
            if len(parts := line.strip().split(None, 1)) == 2
            and (parts[1] == executable or parts[1].startswith(executable + ' '))]
def stop_preview():
    for pid in preview_pids():
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for _ in range(50):
        if not preview_pids():
            return
        time.sleep(0.1)
    raise SystemExit('Midas is still quitting. The installed preview is unchanged.')
def enable_all_openai_accounts():
    for preference in ('midasTrackAllAccounts', 'midasCloudUsageEnabled'):
        subprocess.run(['/usr/bin/defaults', 'write', 'com.designprism.midas.debug',
                        preference, '-bool', 'true'], check=True)
    print('All connected OpenAI accounts and their reported history are enabled.')
old_hash, new_hash = digest(destination), digest(source)
if old_hash == new_hash:
    print('The preview already has this update.')
    if all_openai_accounts:
        stop_preview()
        enable_all_openai_accounts()
    subprocess.run(['/usr/bin/open', str(destination)], check=True)
    raise SystemExit(0)
stage = destination.parent / ('.Midas-preview-stage-' + new_hash[:12] + '.app')
backup = destination.parent / ('Midas Tailscale Preview-backup-' + old_hash[:12] + '.app')
if any(p.exists() or p.is_symlink() for p in (stage, backup)):
    raise SystemExit('An update stage or backup already exists. Review it before updating.')
shutil.copytree(source, stage, symlinks=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(stage)], check=True)
if digest(stage) != new_hash:
    raise SystemExit('Copied app verification failed. The installed preview is unchanged.')
stop_preview()
destination.rename(backup)
try:
    stage.rename(destination)
except OSError:
    if not destination.exists():
        backup.rename(destination)
    raise
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
if all_openai_accounts:
    enable_all_openai_accounts()
subprocess.run(['/usr/bin/open', *([] if all_openai_accounts else ['-n']), str(destination)], check=True)
print('Midas preview updated. Connection, usage history, and other preferences preserved.'
      if all_openai_accounts else 'Midas preview updated. Connection, preferences, and usage history preserved.')
print('The prior app was retained as a backup in Applications.')
PY
