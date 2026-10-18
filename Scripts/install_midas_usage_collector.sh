#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: Scripts/install_midas_usage_collector.sh --binary PATH --config PATH [--start]

Installs the collector and a per-user 180-second launchd/systemd schedule.
Without --start, writes the files for review and leaves the schedule inactive.
The private connection file must already exist, be owned by you, and have mode 0600.
Existing collector installations are never overwritten. No sudo is used.
USAGE
}

collector_binary=""
collector_config=""
collector_start=0
while (($#)); do
  case "$1" in
    --binary) collector_binary="${2:?Missing --binary value}"; shift 2 ;;
    --config) collector_config="${2:?Missing --config value}"; shift 2 ;;
    --start) collector_start=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
[[ -n "$collector_binary" && -n "$collector_config" ]] || { usage >&2; exit 1; }
umask 077

collector_service=$(python3 - "$collector_binary" "$collector_config" <<'PY'
import os
import pathlib
import plistlib
import shutil
import stat
import sys

binary = pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True)
raw_config = pathlib.Path(sys.argv[2]).expanduser().absolute()
config = raw_config.resolve(strict=True)
if raw_config.is_symlink():
    raise SystemExit("Connection configuration must be a regular private file.")
info = config.stat()
if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
    raise SystemExit("Connection configuration must be owner-only (0600).")
home = pathlib.Path.home().resolve()
if not config.is_relative_to(home):
    raise SystemExit("Keep the connection configuration in your internal home directory.")
if not binary.is_file() or not os.access(binary, os.X_OK):
    raise SystemExit("Collector binary must be an executable file.")
label = "com.designprism.midas.usage-collector"
if sys.platform == "darwin":
    root = home / "Library/Application Support/Midas/usage-collector"
    target = root / "bin/midas-collector"
    service = home / "Library/LaunchAgents" / (label + ".plist")
    logs = home / "Library/Logs/Midas"
    paths = [target, service]
else:
    root = home / ".local/share/midas/usage-collector"
    target = home / ".local/bin/midas-collector"
    service = home / ".config/systemd/user/midas-usage-collector.service"
    timer = service.with_suffix(".timer")
    paths = [target, service, timer]
if any(path.exists() or path.is_symlink() for path in paths):
    raise SystemExit("An installation already exists. Stop it and review the exact files before upgrading.")
for directory in [root, target.parent, service.parent]:
    if not directory.resolve().is_relative_to(home):
        raise SystemExit("Collector installation must stay in your internal home directory.")
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
if root.is_symlink() or root.stat().st_uid != os.geteuid() or stat.S_IMODE(root.stat().st_mode) & 0o077:
    raise SystemExit("Collector state directory must be private and owned by you.")
with target.open("xb") as output, binary.open("rb") as source:
    shutil.copyfileobj(source, output)
    output.flush()
    os.fsync(output.fileno())
target.chmod(0o700)
arguments = [str(target), "usage-sync", "collect", "--config", str(config), "--state-root", str(root), "--once"]
if sys.platform == "darwin":
    logs.mkdir(parents=True, exist_ok=True, mode=0o700)
    log = logs / "usage-collector.log"
    if log.is_symlink():
        raise SystemExit("Collector log cannot be a symbolic link.")
    log.touch(mode=0o600, exist_ok=True)
    log.chmod(0o600)
    payload = {
        "Label": label,
        "ProgramArguments": arguments,
        "StartInterval": 180,
        "RunAtLoad": True,
        "ProcessType": "Background",
        "LowPriorityIO": True,
        "Umask": 0o077,
        "StandardOutPath": str(log),
        "StandardErrorPath": str(log),
    }
    with service.open("xb") as output:
        plistlib.dump(payload, output)
else:
    def quote(value):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%") + '"'
    command = " ".join(map(quote, arguments))
    service.write_text("[Unit]\nDescription=Midas private numeric usage collector\n"
                       "After=network-online.target\n\n[Service]\nType=oneshot\n"
                       f"ExecStart={command}\nUMask=0077\nNoNewPrivileges=true\n"
                       "PrivateTmp=true\nTimeoutStartSec=150\n")
    timer.write_text("[Unit]\nDescription=Collect Midas usage every three minutes\n\n"
                     "[Timer]\nOnStartupSec=30\nOnUnitActiveSec=180\nPersistent=true\n\n"
                     "[Install]\nWantedBy=timers.target\n")
    timer.chmod(0o600)
service.chmod(0o600)
print(service)
PY
)

printf 'Prepared collector schedule: %s\n' "$collector_service"
if ((collector_start)); then
  if [[ "$(uname -s)" == Darwin ]]; then
    launchctl bootstrap "gui/$(id -u)" "$collector_service"
  else
    systemctl --user daemon-reload
    systemctl --user enable --now midas-usage-collector.timer
  fi
  printf 'Collector schedule started. Verify a successful exchange in Midas and the service log.\n'
else
  printf 'Schedule is inactive. Review it before rerunning the appropriate launchctl/systemctl start command.\n'
fi
