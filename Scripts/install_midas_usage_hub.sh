#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: Scripts/install_midas_usage_hub.sh [--initialize [--workspace-file PATH]] [--start]
       [--source PATH] [--python PATH | --runtime-root PATH] [--install-root PATH]
       [--launch-agents-dir PATH] [--log-dir PATH] [--port NUMBER]

Prepare a private per-user macOS usage hub. No sudo, enrollment, or Tailscale changes.
The default installation stays on internal storage under Application Support/Midas.
The numeric database is separate from bin/. Existing files are never overwritten.
--initialize explicitly creates a new workspace; --workspace-file adopts an existing one.
Without --initialize, an existing valid numeric database must already be present.
Without --start, the LaunchAgent is written for review and remains inactive.
USAGE
}

hub_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
hub_source="$hub_script_dir/usage-hub/midas_usage_hub.py"
hub_python="$(command -v python3)"
hub_runtime_root=""
hub_install_root=""
hub_launch_agents=""
hub_log_dir=""
hub_workspace=""
hub_port=8766
hub_initialize=0
hub_start=0
while (($#)); do
  case "$1" in
    --source) hub_source="${2:?Missing --source value}"; shift 2 ;;
    --runtime-root) hub_runtime_root="${2:?Missing --runtime-root value}"; shift 2 ;;
    --python) hub_python="${2:?Missing --python value}"; shift 2 ;;
    --install-root) hub_install_root="${2:?Missing --install-root value}"; shift 2 ;;
    --launch-agents-dir) hub_launch_agents="${2:?Missing --launch-agents-dir value}"; shift 2 ;;
    --log-dir) hub_log_dir="${2:?Missing --log-dir value}"; shift 2 ;;
    --workspace-file) hub_workspace="${2:?Missing --workspace-file value}"; shift 2 ;;
    --port) hub_port="${2:?Missing --port value}"; shift 2 ;;
    --initialize) hub_initialize=1; shift ;;
    --start) hub_start=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
if [[ -n "$hub_workspace" && "$hub_initialize" -ne 1 ]]; then
  printf '%s\n' '--workspace-file requires --initialize.' >&2
  exit 1
fi
if ((hub_start)) && [[ "$(uname -s)" != Darwin ]]; then
  printf '%s\n' '--start requires macOS.' >&2
  exit 1
fi
umask 077
if [[ -n "$hub_runtime_root" ]]; then
  hub_python="$hub_runtime_root/bin/python3"
fi

hub_prepared_service=$("$hub_python" - "$hub_source" "$hub_install_root" "$hub_launch_agents" \
  "$hub_log_dir" "$hub_workspace" "$hub_port" "$hub_initialize" "$hub_runtime_root" "$hub_script_dir/usage-hub/midas_sync_manage.py" <<'PY'
import hashlib
import importlib.util
import shutil
import os
from pathlib import Path
import plistlib
import stat
import sys
import sqlite3
import types
import urllib.parse

if sys.version_info < (3, 10):
    raise SystemExit("Python 3.10 or newer is required.")

os.umask(0o077)
home = Path.home().resolve(strict=True)
source = Path(sys.argv[1]).expanduser().absolute()
root = Path(sys.argv[2]).expanduser().absolute() if sys.argv[2] else home / "Library/Application Support/Midas/usage-hub"
agents = Path(sys.argv[3]).expanduser().absolute() if sys.argv[3] else home / "Library/LaunchAgents"
logs = Path(sys.argv[4]).expanduser().absolute() if sys.argv[4] else root / "logs"
workspace_path = Path(sys.argv[5]).expanduser().absolute() if sys.argv[5] else None
try:
    port = int(sys.argv[6])
except ValueError:
    raise SystemExit("Port must be a number between 1 and 65535.") from None
if not 1 <= port <= 65535:
    raise SystemExit("Port must be between 1 and 65535.")
initialize = sys.argv[7] == "1"
label = "com.designprism.midas.usage-hub"
state = root / "state"
bin_dir = root / "bin"
target = bin_dir / "midas_usage_hub.py"
service = agents / (label + ".plist")
log = logs / "usage-hub.log"
external = tuple(Path(value) for value in ("/Volumes", "/media", "/mnt", "/run/media"))


def safe_path(path, require_home_volume=False):
    if not path.is_absolute() or any(path == prefix or prefix in path.parents for prefix in external):
        raise SystemExit("Hub files must stay on internal storage.")
    for component in [path, *path.parents]:
        if component.is_symlink():
            raise SystemExit("Hub installation paths cannot contain symbolic links.")
    if path.resolve() != path:
        raise SystemExit("Hub installation paths must be canonical.")
    if require_home_volume:
        existing = path
        while not existing.exists():
            existing = existing.parent
        if existing.stat().st_dev != home.stat().st_dev:
            raise SystemExit("Hub state must stay on the internal home volume.")


def private_directory(path, shared_parent=False):
    safe_path(path, require_home_volume=True)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    metadata = path.lstat()
    forbidden = 0o022 if shared_parent else 0o077
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) & forbidden:
        raise SystemExit("Hub directories must be private, owned by this user, and have mode 700.")


def private_regular(path, maximum=None):
    safe_path(path, require_home_volume=True)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as file:
        metadata = os.fstat(file.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600:
            raise SystemExit("Private workspace/state files must be owned regular files with mode 600.")
        if maximum is not None and metadata.st_size > maximum:
            raise SystemExit("Workspace file exceeds its safety limit.")
        return file.read(maximum + 1) if maximum is not None else None


def write_new(path, data, mode):
    # No final, temporary, service, log, or live state is replaced or deleted by this installer.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(descriptor, "wb") as file:
        file.write(data)
        file.flush()
        os.fsync(file.fileno())
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    if path.read_bytes() != data or stat.S_IMODE(path.stat().st_mode) != mode:
        raise SystemExit("Hub installation readback failed. Preserve the prepared files for review.")


try:
    for path in (root, agents, logs):
        safe_path(path, require_home_volume=True)
    safe_path(source)
    if any(path.exists() or path.is_symlink() for path in (target, service, log)):
        raise SystemExit("Hub installation already exists. Review the exact existing files before upgrading.")
    source_descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(source_descriptor, "rb") as source_file:
        source_info = os.fstat(source_file.fileno())
        if not stat.S_ISREG(source_info.st_mode) or source_info.st_uid not in (0, os.getuid()) or source_info.st_mode & 0o022:
            raise SystemExit("The hub source must be an owned regular file that others cannot write.")
        source_bytes = source_file.read(1024 * 1024 + 1)
        if not 0 < len(source_bytes) <= 1024 * 1024:
            raise SystemExit("The hub source exceeds its safety limit.")
    runtime = Path(sys.executable).resolve(strict=True)
    safe_path(runtime)
    runtime_info = runtime.stat()
    if not stat.S_ISREG(runtime_info.st_mode) or runtime_info.st_uid not in (0, os.getuid()) or runtime_info.st_mode & 0o022:
        raise SystemExit("The Python runtime must be an owned internal executable that others cannot write.")
    if not os.access(runtime, os.X_OK):
        raise SystemExit("The Python runtime is not executable.")
    module = types.ModuleType("midas_hub_install_source")
    module.__file__ = str(source)
    exec(compile(source_bytes, str(source), "exec"), module.__dict__)
    workspace = None
    if workspace_path:
        workspace = module.parse_json(private_regular(workspace_path, maximum=4096))
        module.validate_workspace(workspace)
    database = state / "hub.sqlite3"
    safe_path(database)
    if initialize:
        if database.exists() or database.is_symlink():
            raise SystemExit("A hub database already exists. Initialization never replaces existing numeric state.")
    elif not database.exists():
        raise SystemExit("No initialized workspace exists. Use --initialize explicitly to create one.")
    for path in (root, bin_dir, state, logs):
        private_directory(path)
    # ~/Library/LaunchAgents is shared with other applications and commonly already has mode 755.
    # Preserve its existing mode; our plist is always 600, and no other user may write the directory.
    private_directory(agents, shared_parent=True)
    if initialize:
        module.Store.initialize(state, workspace)
    else:
        private_regular(database)
        module.Store(state)
        with sqlite3.connect(f"file:{urllib.parse.quote(str(database))}?mode=ro", uri=True) as connection:
            connection.row_factory = sqlite3.Row
            module.Store.workspace_in(connection)
    if sys.argv[8]:
        runtime_root = Path(sys.argv[8]).expanduser().absolute()
        spec = importlib.util.spec_from_file_location("midas_install_manage", sys.argv[9])
        manager = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(manager)
        digest = manager.runtime_digest(runtime_root)
        runtime_parent = root / "runtimes"
        private_directory(runtime_parent)
        installed_runtime = runtime_parent / digest
        if installed_runtime.exists():
            raise SystemExit("Managed runtime already exists; preserve prepared files and review.")
        shutil.copytree(runtime_root, installed_runtime, symlinks=True)
        installed_runtime.chmod(0o700)
        if manager.runtime_digest(installed_runtime) != digest:
            raise SystemExit("Managed runtime verification failed.")
        runtime = installed_runtime / "bin/python3"
    # Install exactly the source bytes inspected above, then verify SHA-256 and byte equality.
    write_new(target, source_bytes, 0o700)
    if hashlib.sha256(target.read_bytes()).digest() != hashlib.sha256(source_bytes).digest():
        raise SystemExit("Hub source verification failed. Preserve both files for review.")
    write_new(log, b"", 0o600)
    payload = {
        "Label": label,
        "ProgramArguments": [str(runtime), "-I", "-B", str(target), "--state-dir", str(state), "serve", "--bind", "127.0.0.1", "--port", str(port)],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 30,
        "ProcessType": "Background",
        "LowPriorityIO": True,
        "Umask": 0o077,
        "WorkingDirectory": str(state),
        "StandardOutPath": str(log),
        "StandardErrorPath": str(log),
    }
    write_new(service, plistlib.dumps(payload, sort_keys=True), 0o600)
    if plistlib.loads(service.read_bytes()) != payload:
        raise SystemExit("Hub LaunchAgent verification failed. Preserve the prepared files for review.")
    print(service)
except Exception as error:
    # Never print workspace content, identifiers, credentials, or raw exception arguments.
    raise SystemExit("Hub preparation failed (" + type(error).__name__ + "). Existing files were preserved.") from None
PY
)

printf 'Prepared private hub LaunchAgent: %s\n' "$hub_prepared_service"
if ((hub_start)); then
  /bin/launchctl bootstrap "gui/$(id -u)" "$hub_prepared_service"
  printf '%s\n' 'Hub started on loopback. Tailscale sharing remains a separate setup step.'
else
  printf '%s\n' 'LaunchAgent is inactive. Review the plist before starting it with launchctl.'
fi
