#!/usr/bin/env bash
set -euo pipefail
# No download or runtime discovery: release packaging uses an explicitly prepared standalone tree.
if [[ $# -ne 2 ]]; then
  printf '%s\n' 'Usage: bundle_midas_sync_resources.sh APP_PATH PYTHON_RUNTIME_ROOT' >&2
  exit 2
fi
sync_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
sync_app="$1"
sync_runtime="$2"
if [[ ! -x "$sync_runtime/bin/python3" ]]; then
  printf '%s\n' 'A prepared standalone Python runtime is required for Midas sync management.' >&2
  exit 1
fi
sync_resources="$sync_app/Contents/Resources/MidasSync"
mkdir -p "$sync_resources/runtime" "$sync_app/Contents/Helpers"
cp "$sync_root/Scripts/usage-hub/midas_usage_hub.py" "$sync_resources/"
cp "$sync_root/Scripts/usage-hub/midas_sync_manage.py" "$sync_resources/"
# Preserve internal links; the verification below rejects any escaping the runtime.
cp -R "$sync_runtime/." "$sync_resources/runtime/"
"$sync_resources/runtime/bin/python3" -I -B - "$sync_resources" <<'PY'
from pathlib import Path
import gzip,hashlib,json,sqlite3,ssl,sys,tempfile,urllib.request
root=Path(sys.argv[1]).absolute(); runtime=root/'runtime'
for p in runtime.rglob('*'):
    if p.is_symlink() and not p.resolve().is_relative_to(runtime.resolve()):
        raise SystemExit('Runtime has an external symbolic link')
with tempfile.TemporaryDirectory(prefix='midas-runtime-package-') as d:
    c=sqlite3.connect(str(Path(d)/'check.sqlite3'))
    assert c.execute('select 1').fetchone()==(1,)
    c.close()
# Source hashes are sealed by the containing app signature. Runtime leaf signing follows later.
sources={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in root.glob('*.py')}
(root/'resource-manifest.json').write_text(json.dumps({'schemaVersion':1,'sources':sources},sort_keys=True,separators=(',',':')))
PY
xcrun swiftc -O "$sync_root/Scripts/MidasSyncManage.swift" -o "$sync_app/Contents/Helpers/MidasSyncManage"
printf '%s\n' 'Bundled private Midas sync manager and standalone runtime.'
