#!/usr/bin/env python3
"""Allowlisted local Midas sync management. Never a remote command service.

The signed app launcher invokes this resource with its bundled Python. All reports
are deliberately limited to operational metadata; credentials and payloads stay local.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import gzip
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

APPLE_EPOCH = 978307200
LABEL = "com.designprism.midas.usage-hub"
BUNDLE_ID = "com.designprism.midas"
MAX_REPORT_BYTES = 8 * 1024 * 1024
MAX_CLOCK_SKEW_SECONDS = 30


class ManageError(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def now() -> float:
    return time.time() - APPLE_EPOCH


def canonical(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def safe_path(path: Path, *, owned=False, private=False, regular=False) -> Path:
    path = path.expanduser().absolute()
    for part in [path, *path.parents]:
        if part.is_symlink():
            raise ManageError("unsafe_path")
    if path.resolve() != path:
        raise ManageError("unsafe_path")
    if owned and path.exists():
        info = path.stat()
        if info.st_uid != os.getuid() or info.st_mode & (0o077 if private else 0o022):
            raise ManageError("unsafe_permissions")
        if regular and not stat.S_ISREG(info.st_mode):
            raise ManageError("unsafe_file")
    return path


def private_json(path: Path, maximum=MAX_REPORT_BYTES):
    safe_path(path, owned=True, private=True, regular=True)
    with path.open("rb") as file:
        info = os.fstat(file.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ManageError("unsafe_permissions")
        raw = file.read(maximum + 1)
    if len(raw) > maximum:
        raise ManageError("capacity")
    return json.loads(raw)


def atomic_private(path: Path, raw: bytes, mode=0o600):
    safe_path(path.parent, owned=True)
    descriptor, name = tempfile.mkstemp(prefix=".midas-stage-", dir=path.parent)
    staged = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as file:
            os.fchmod(file.fileno(), mode)
            file.write(raw)
            file.flush()
            os.fsync(file.fileno())
        os.replace(staged, path)
        descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        with contextlib.suppress(FileNotFoundError):
            staged.unlink()


def support_root() -> Path:
    return Path.home() / "Library/Application Support/Midas"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ManageError("redirect_rejected")


def validated_connection(path: Path):
    value = private_json(path, 4096)
    url = urllib.parse.urlsplit(value["endpoint"])
    loopback = url.scheme == "http" and url.hostname in {"127.0.0.1", "localhost", "::1"}
    private_https = url.scheme == "https" and (url.hostname or "").endswith(".ts.net")
    if (not (loopback or private_https) or url.username or url.password or url.query or url.fragment
            or url.path not in {"", "/"}):
        raise ManageError("invalid_connection")
    token = value.get("credential", "")
    if not isinstance(token, str) or not 32 <= len(token) <= 256 or not all(c.isascii() and (c.isalnum() or c in "-_") for c in token):
        raise ManageError("invalid_connection")
    uuid.UUID(value["deviceID"])
    return value


def manifest(connection):
    request = urllib.request.Request(connection["endpoint"].rstrip("/") + "/v2/manifest", headers={
        "Authorization": "Bearer " + connection["credential"], "Accept-Encoding": "gzip",
        "Accept": "application/json",
    })
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    started = time.monotonic()
    try:
        with opener.open(request, timeout=15) as response:
            compressed = response.read(MAX_REPORT_BYTES + 1)
            if len(compressed) > MAX_REPORT_BYTES:
                raise ManageError("capacity")
            if response.headers.get("Content-Encoding", "").lower() == "gzip":
                import io
                with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as decoded:
                    raw = decoded.read(MAX_REPORT_BYTES + 1)
            else:
                raw = compressed
            if len(raw) > MAX_REPORT_BYTES:
                raise ManageError("capacity")
        result = json.loads(raw)
    except urllib.error.HTTPError as error:
        raise ManageError({401: "access_rejected", 403: "access_rejected", 404: "hub_update_required", 413: "capacity"}.get(error.code, "hub_unavailable")) from None
    except (TimeoutError, socket.timeout):
        raise ManageError("timeout") from None
    except urllib.error.URLError as error:
        reason = error.reason
        if isinstance(reason, socket.gaierror):
            raise ManageError("dns_unavailable") from None
        raise ManageError("connection_unavailable") from None
    if result.get("protocolVersion") != 2:
        raise ManageError("incompatible_protocol")
    if connection.get("workspaceID") and result.get("workspace", {}).get("id", "").lower() != connection["workspaceID"].lower():
        raise ManageError("workspace_changed")
    return result, round((time.monotonic() - started) * 1000)


def revision_vector(value):
    if not isinstance(value, dict) or len(value) > 128:
        raise ManageError("invalid_operational_metadata")
    for identity, revision in value.items():
        try:
            uuid.UUID(identity)
        except (ValueError, TypeError, AttributeError):
            raise ManageError("invalid_operational_metadata") from None
        if type(revision) is not int or revision < 1:
            raise ManageError("invalid_operational_metadata")
    return value


def safe_manifest_report(value):
    heads = value.get("devices", [])
    receipts = value.get("receipts", [])
    if not isinstance(heads, list) or not isinstance(receipts, list) or len(heads) > 128 or len(receipts) > 128:
        raise ManageError("invalid_operational_metadata")
    for head in heads:
        revision_vector({head.get("deviceID"): head.get("revision")})
    for receipt in receipts:
        revision_vector({receipt.get("deviceID"): 1})
        revision_vector(receipt.get("appliedRevisions", {}))
    return {
        "hubVersion": value.get("hubVersion"), "protocolVersion": value.get("protocolVersion"),
        "checkedAt": value.get("checkedAt"), "enrolledDevices": len(heads),
        "devices": [{"deviceID": h.get("deviceID"), "revision": h.get("revision"),
                     "eventCount": h.get("eventCount"), "accountDayCount": h.get("accountDayCount"),
                     "revoked": h.get("revoked", False), "supportsReceipts": h.get("supportsReceipts", False)} for h in heads],
        "receipts": [{"deviceID": r.get("deviceID"), "checkedAt": r.get("checkedAt"),
                      "appliedRevisions": r.get("appliedRevisions", {})} for r in receipts],
    }


def doctor(root: Path, *, online=True, app_path=Path("/Applications/Midas.app"), max_age=300, required_device_ids=None):
    report = {"schemaVersion": 1, "status": "offline", "checkedAt": now()}
    connection_path = root / "usage-sync/hub-connection.json"
    if not connection_path.exists():
        report.update(status="needs_attention", code="not_paired")
        return report
    connection = validated_connection(connection_path)
    receipt_path = root / "usage-sync/sync-receipt.json"
    receipt = private_json(receipt_path) if receipt_path.exists() else None
    # This receipt is a small app-owned operational file, never a full usage payload.
    if receipt:
        for field in ("lastCheckedAt", "lastPublishedAt", "lastReceivedAt", "outboxPending", "phase", "coverageExcludedRecords"):
            if field in receipt:
                report[field] = receipt[field]
        sync_state = receipt.get("syncState") or receipt.get("state") or {}
        report["appliedRevisions"] = revision_vector(sync_state.get("appliedRevisions", receipt.get("appliedRevisions", {})))
        report["lastCheckedAt"] = sync_state.get("checkedAt", report.get("lastCheckedAt"))
        report["acceptedLocalRevision"] = sync_state.get("acceptedLocalRevision", receipt.get("acceptedLocalRevision"))
    else:
        report["code"] = "receipt_unavailable"
    info_path = app_path / "Contents/Info.plist"
    if not info_path.is_file():
        raise ManageError("app_unavailable")
    if info_path.exists():
        info = plistlib.loads(info_path.read_bytes())
        if info.get("CFBundleIdentifier") != BUNDLE_ID:
            raise ManageError("wrong_app_identity")
        report["appVersion"] = info.get("CFBundleShortVersionString")
        report["appBuild"] = info.get("CFBundleVersion")
    if not online:
        report["status"] = "unchecked"
        return report
    remote, elapsed = manifest(connection)
    report.update(safe_manifest_report(remote), durationMilliseconds=elapsed)
    own = next((h for h in remote.get("devices", []) if h.get("deviceID", "").lower() == connection["deviceID"].lower()), None)
    local = {str(k).lower(): v for k, v in report.get("appliedRevisions", {}).items()}
    pending = report.get("outboxPending")
    fresh = isinstance(report.get("lastCheckedAt"), (int, float)) and -MAX_CLOCK_SKEW_SECONDS <= now() - report["lastCheckedAt"] <= max_age
    applied = bool(remote.get("devices")) and all(local.get(h["deviceID"].lower(), 0) >= h["revision"] for h in remote["devices"] if not h.get("revoked"))
    accepted = own and isinstance(report.get("acceptedLocalRevision"), int) and report["acceptedLocalRevision"] >= own["revision"]
    report["status"] = "healthy" if fresh and pending is False and applied and accepted else "pending"
    if report["status"] == "healthy":
        report.pop("code", None)
    elif not receipt:
        report["code"] = "receipt_unavailable"
    elif not fresh:
        report["code"] = "local_receipt_stale"
    elif pending:
        report["code"] = "upload_pending"
    else:
        report["code"] = "checkpoint_pending"
    vectors = {r["deviceID"].lower(): {k.lower(): v for k, v in r.get("appliedRevisions", {}).items()} for r in remote.get("receipts", [])}
    fresh_readers = {r["deviceID"].lower() for r in remote.get("receipts", [])
                     if isinstance(r.get("checkedAt"), (int, float)) and -MAX_CLOCK_SKEW_SECONDS <= now() - r["checkedAt"] <= max_age}
    required = [h for h in remote["devices"] if (h.get("supportsReceipts", False) or h["deviceID"].lower() in vectors) and not h.get("revoked")]
    report["allReceiptCapableDevicesCaughtUp"] = bool(required) and all(h["deviceID"].lower() in fresh_readers and all(
        vectors.get(h["deviceID"].lower(), {}).get(source["deviceID"].lower(), 0) >= source["revision"]
        for source in remote["devices"] if not source.get("revoked")) for h in required)
    if required_device_ids is not None:
        expected = {str(uuid.UUID(device)).lower() for device in required_device_ids}
        heads = {h["deviceID"].lower(): h for h in remote["devices"] if not h.get("revoked")}
        report["requiredDeviceCount"] = len(expected)
        report["requiredDevicesCaughtUp"] = len(expected) >= 2 and expected <= heads.keys() and expected <= vectors.keys() and expected <= fresh_readers and all(
            all(vectors[reader].get(source["deviceID"].lower(), 0) >= source["revision"] for source in heads.values())
            for reader in expected)
    return report


def service_path() -> Path:
    return Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")


def service_payload(path: Path, root: Path):
    safe_path(path, owned=True, private=True, regular=True)
    payload = plistlib.loads(path.read_bytes())
    args = payload.get("ProgramArguments", [])
    if (payload.get("Label") != LABEL or len(args) < 8 or "serve" not in args
            or "--bind" not in args or args[args.index("--bind") + 1] != "127.0.0.1"
            or "--state-dir" not in args
            or Path(args[args.index("--state-dir") + 1]) != root / "state"):
        raise ManageError("unsafe_service")
    return payload


def restart_service(path: Path, root: Path):
    service_payload(path, root)
    if sys.platform != "darwin":
        raise ManageError("macos_required")
    result = subprocess.run(["/bin/launchctl", "kickstart", "-k", "gui/" + str(os.getuid()) + "/" + LABEL],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    if result.returncode:
        raise ManageError("service_restart_failed")


def reload_service(path: Path, root: Path):
    service_payload(path, root)
    if sys.platform != "darwin":
        raise ManageError("macos_required")
    domain = "gui/" + str(os.getuid())
    # kickstart alone keeps launchd's old ProgramArguments; bootstrap loads the staged runtime.
    subprocess.run(["/bin/launchctl", "bootout", domain + "/" + LABEL],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    result = subprocess.run(["/bin/launchctl", "bootstrap", domain, str(path)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    if result.returncode:
        raise ManageError("service_reload_failed")


def load_hub(source: Path):
    raw = source.read_bytes()
    if not 0 < len(raw) < 1024 * 1024:
        raise ManageError("source_capacity")
    compile(raw, str(source), "exec")
    spec = importlib.util.spec_from_file_location("midas_managed_hub", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def verify_resources(resource: Path):
    """Hashes are sealed by the containing app signature; reject partial resource copies."""
    metadata = json.loads((resource / "resource-manifest.json").read_bytes())
    if metadata.get("schemaVersion") != 1:
        raise ManageError("invalid_resource_manifest")
    for name in ("midas_usage_hub.py", "midas_sync_manage.py"):
        expected = metadata.get("sources", {}).get(name)
        if expected != hashlib.sha256((resource / name).read_bytes()).hexdigest():
            raise ManageError("resource_verification_failed")


def runtime_digest(runtime: Path):
    runtime = runtime.absolute()
    if not runtime.is_dir() or runtime.is_symlink():
        raise ManageError("invalid_runtime")
    entries = []
    for path in sorted(runtime.rglob("*")):
        relative = str(path.relative_to(runtime))
        if path.is_symlink():
            if not path.resolve().is_relative_to(runtime.resolve()):
                raise ManageError("unsafe_runtime_link")
            entries.append((relative, "link", os.readlink(path)))
        elif path.is_file():
            if path.stat().st_mode & 0o022:
                raise ManageError("unsafe_runtime_permissions")
            entries.append((relative, "file", hashlib.sha256(path.read_bytes()).hexdigest()))
    if not (runtime / "bin/python3").is_file():
        raise ManageError("invalid_runtime")
    return hashlib.sha256(canonical(entries)).hexdigest()


def legacy_state_digest(database: Path):
    """Compare original workspace, enrollment credentials and snapshots across rehearsal."""
    digest = hashlib.sha256()
    with contextlib.closing(sqlite3.connect(database)) as connection:
        for query in ("SELECT * FROM metadata ORDER BY key", "SELECT * FROM devices ORDER BY id"):
            for row in connection.execute(query):
                digest.update(repr(tuple(row)).encode())
                digest.update(b"\0")
    return digest.digest()


@contextlib.contextmanager
def management_lock(root: Path):
    safe_path(root, owned=True, private=True)
    descriptor = os.open(root / ".management.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
            raise ManageError("unsafe_management_lock")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ManageError("management_busy") from None
        yield
    finally:
        os.close(descriptor)


def upgrade(root: Path, source: Path, runtime: Path, plist_path: Path, *, restart=reload_service, health=None):
    with management_lock(root):
        return _upgrade(root, source, runtime, plist_path, restart=restart, health=health)


def _upgrade(root: Path, source: Path, runtime: Path, plist_path: Path, *, restart=reload_service, health=None):
    """Code/runtime rollback never replaces the live DB after accepting new writes."""
    safe_path(root, owned=True, private=True)
    source = safe_path(source)
    info = source.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid not in {0, os.getuid()} or info.st_mode & 0o022:
        raise ManageError("unsafe_source")
    raw = source.read_bytes()
    candidate = load_hub(source)
    old_payload = service_payload(plist_path, root)
    target = safe_path(root / "bin/midas_usage_hub.py", owned=True, regular=True)
    database = safe_path(root / "state/hub.sqlite3", owned=True, private=True, regular=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    backups = root / "backups"
    backups.mkdir(mode=0o700, exist_ok=True)
    safe_path(backups, owned=True, private=True)
    backup = backups / stamp
    backup.mkdir(mode=0o700)
    shutil.copy2(target, backup / "midas_usage_hub.py")
    shutil.copy2(plist_path, backup / "service.plist")
    with contextlib.closing(sqlite3.connect("file:" + urllib.parse.quote(str(database)) + "?mode=ro", uri=True)) as original:
        backup_database = backup / "hub.sqlite3"
        backup_database.touch(mode=0o600)
        with contextlib.closing(sqlite3.connect(backup_database)) as copied:
            original.backup(copied)
            if copied.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise ManageError("database_integrity_failed")
    # Verify additive migration against a copy before a new process can touch live state.
    staged_state = backup / "migration-check"
    staged_state.mkdir(mode=0o700)
    shutil.copy2(backup / "hub.sqlite3", staged_state / "hub.sqlite3")
    preserved = legacy_state_digest(staged_state / "hub.sqlite3")
    staged_store = candidate.Store(staged_state)
    staged_store.ensure_v2()
    if legacy_state_digest(staged_state / "hub.sqlite3") != preserved:
        raise ManageError("migration_changed_legacy_state")
    with contextlib.closing(sqlite3.connect(staged_state / "hub.sqlite3")) as staged:
        if staged.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ManageError("migration_integrity_failed")
    digest = runtime_digest(runtime)
    runtimes = root / "runtimes"
    runtimes.mkdir(mode=0o700, exist_ok=True)
    safe_path(runtimes, owned=True, private=True)
    installed_runtime = runtimes / digest
    if not installed_runtime.exists():
        staged_runtime = runtimes / (".stage-" + str(uuid.uuid4()))
        shutil.copytree(runtime, staged_runtime, symlinks=True)
        staged_runtime.chmod(0o700)
        if runtime_digest(staged_runtime) != digest:
            raise ManageError("runtime_verification_failed")
        os.replace(staged_runtime, installed_runtime)
    elif runtime_digest(installed_runtime) != digest:
        raise ManageError("runtime_verification_failed")
    interpreter = installed_runtime / "bin/python3"
    probe = subprocess.run([str(interpreter), "-I", "-B", "-c",
                            "import sqlite3,ssl,gzip,urllib.request; c=sqlite3.connect(':memory:'); assert c.execute('select 1').fetchone()==(1,)"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    if probe.returncode:
        raise ManageError("runtime_probe_failed")
    payload = dict(old_payload)
    payload["ProgramArguments"] = list(old_payload["ProgramArguments"])
    payload["ProgramArguments"][0] = str(interpreter)
    if "-I" not in payload["ProgramArguments"]:
        payload["ProgramArguments"].insert(1, "-I")
    payload["ProgramArguments"][payload["ProgramArguments"].index("--state-dir") - 1] = str(target)
    old_source = target.read_bytes()
    old_plist = plist_path.read_bytes()
    try:
        atomic_private(target, raw, 0o700)
        atomic_private(plist_path, plistlib.dumps(payload, sort_keys=True))
        restart(plist_path, root)
        if health:
            health()
        else:
            connection_file = root.parent / "usage-sync/hub-connection.json"
            connection = validated_connection(connection_file)
            deadline = time.monotonic() + 20
            while True:
                try:
                    observed, _ = manifest(connection)
                    if observed.get("hubVersion") != getattr(candidate, "HUB_VERSION", None):
                        raise ManageError("upgrade_version_mismatch")
                    break
                except ManageError:
                    if time.monotonic() >= deadline:
                        raise ManageError("upgrade_health_failed") from None
                    time.sleep(.25)
    except Exception:
        atomic_private(target, old_source, 0o700)
        atomic_private(plist_path, old_plist)
        try:
            restart(plist_path, root)
        except Exception:
            raise ManageError("rollback_restart_failed") from None
        raise ManageError("upgrade_rolled_back") from None
    return {"status": "healthy", "hubVersion": getattr(candidate, "HUB_VERSION", None),
            "codeSHA256": hashlib.sha256(raw).hexdigest(), "runtimeSHA256": digest, "backupCreated": True}


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=support_root(), help=argparse.SUPPRESS)
    parser.add_argument("--app", type=Path, default=Path("/Applications/Midas.app"), help=argparse.SUPPRESS)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("doctor").add_argument("--offline", action="store_true")
    commands.add_parser("check")
    commands.add_parser("restart")
    commands.add_parser("upgrade")
    commands.add_parser("pairing-list")
    for name in ("pairing-approve", "pairing-deny"):
        command = commands.add_parser(name)
        command.add_argument("--request-id", required=True, type=uuid.UUID)
        if name == "pairing-approve":
            command.add_argument("--code", required=True)
    args = parser.parse_args()
    report = {"schemaVersion": 1, "action": args.action, "checkedAt": now()}
    try:
        root = safe_path(args.root, owned=True)
        hub_root = root / "usage-hub"
        if args.action in {"doctor", "check"}:
            report.update(doctor(root, online=not getattr(args, "offline", False), app_path=args.app))
        elif args.action == "restart":
            with management_lock(hub_root):
                restart_service(service_path(), hub_root)
            report.update(status="healthy", code="service_restarted")
        elif args.action == "upgrade":
            resource = Path(__file__).resolve().parent
            verify_resources(resource)
            report.update(upgrade(hub_root, resource / "midas_usage_hub.py", resource / "runtime", service_path()))
        else:
            source = safe_path(hub_root / "bin/midas_usage_hub.py", owned=True, regular=True)
            store = load_hub(source).Store(hub_root / "state")
            if args.action == "pairing-list":
                requests = store.pairing_list()
                report.update(status="healthy", pendingRequests=requests)
            elif args.action == "pairing-approve":
                if len(args.code) != 6 or not args.code.isascii() or not args.code.isdigit():
                    raise ManageError("invalid_pairing_code")
                store.pairing_approve(str(args.request_id), args.code)
                report.update(status="healthy", code="pairing_approved")
            else:
                store.pairing_deny(str(args.request_id))
                report.update(status="healthy", code="pairing_denied")
    except ManageError as error:
        report.update(status="needs_attention", code=error.code)
    except Exception as error:
        # Never return exception arguments: they can include credentials, paths or database rows.
        report.update(status="needs_attention", code={FileNotFoundError: "not_installed", PermissionError: "access_denied",
            json.JSONDecodeError: "invalid_local_state"}.get(type(error), "local_operation_failed"))
    print(json.dumps(report, sort_keys=True, separators=(",", ":"), allow_nan=False))
    return 0 if report["status"] in {"healthy", "unchecked"} else 2


if __name__ == "__main__":
    raise SystemExit(main())
