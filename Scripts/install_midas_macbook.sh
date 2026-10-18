#!/usr/bin/env bash
set -euo pipefail

# This entry point is shipped next to the app and this device's private connection.
setup_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  printf 'This preview package requires an Apple silicon Mac.\n' >&2
  exit 1
}
[[ -f "$setup_root/private-connection.json" ]] || {
  printf 'This package has not been enrolled for this MacBook yet. No changes made.\n' >&2
  exit 1
}
exec /bin/bash "$setup_root/install_midas_usage_preview.sh" \
  "$setup_root/Midas.app" "$setup_root/private-connection.json" --launch
