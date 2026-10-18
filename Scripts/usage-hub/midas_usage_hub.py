#!/usr/bin/env python3
"""Private, numeric-only Midas snapshot relay. Python 3.10+, standard library only.

Keep state and enrollment files on encrypted internal storage. Run on loopback behind
Tailscale Serve; do not expose this HTTP listener to the internet. Token aggregation
and pricing deliberately remain in Midas's shared Swift exporter and ledger.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import hmac
import http.server
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import secrets
import socket
import sqlite3
import stat
import sys
import threading
import time
import urllib.parse
import uuid

APPLE_EPOCH = 978307200
MAX_PUBLICATION_BYTES = 32 * 1024 * 1024
MAX_EXCHANGE_BYTES = 128 * 1024 * 1024
MAX_RECORDS = 100_000
MAX_EXCHANGE_RECORDS = 250_000
MAX_DEVICES = 128
OPAQUE_ID = re.compile(r"[0-9a-f]{64}\Z")
PUBLIC_MODEL = re.compile(
    r"(?:gpt-[0-9][a-z0-9.\-]*|o[1-9][a-z0-9.\-]*|claude-[a-z0-9.\-]+|"
    r"muse-spark-[0-9.]+(?:-contributor)?)\Z"
)
PROVENANCES = {"listPriceEstimate", "vendorMetered", "mixed", "vendorBilled", "unknown"}


class HubError(Exception):
    def __init__(self, status: int, code: str):
        super().__init__(code)
        self.status = status
        self.code = code


def require(condition: bool, code: str = "invalid_record", status: int = 400) -> None:
    if not condition:
        raise HubError(status, code)


def canonical(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True, separators=(",", ":")).encode()


def parse_json(data: bytes):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result)
            result[key] = value
        return result

    def nonfinite(_):
        raise HubError(400, "invalid_json")

    try:
        return json.loads(data, object_pairs_hook=unique, parse_constant=nonfinite)
    except (ValueError, UnicodeError, RecursionError):
        raise HubError(400, "invalid_json") from None


def fields(value, required: set[str], optional: set[str] = frozenset()) -> None:
    require(type(value) is dict and required <= value.keys() and value.keys() <= required | optional)


def count(value, maximum: int = 1_000_000_000_000) -> None:
    require(type(value) is int and 0 <= value <= maximum)


def number(value, minimum: float = 0, maximum: float = 1_000_000_000) -> None:
    require(type(value) in (float, int) and math.isfinite(value) and minimum <= value <= maximum)


def uuid_string(value) -> str:
    require(type(value) is str)
    try:
        result = str(uuid.UUID(value)).upper()
    except ValueError:
        raise HubError(400, "invalid_record") from None
    require(value.upper() == result)
    return result


def text(value, minimum: int, maximum: int) -> None:
    require(type(value) is str and minimum <= len(value.encode()) <= maximum)
    require(not any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in value))


def date(value, latest: float) -> None:
    number(value, minimum=-APPLE_EPOCH, maximum=latest)


def day(value) -> str:
    require(type(value) is str and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", value) is not None)
    try:
        parsed = dt.date.fromisoformat(value)
    except ValueError:
        raise HubError(400, "invalid_record") from None
    require(parsed.isoformat() == value)
    return value


def day_for(value: float) -> str:
    return dt.datetime.fromtimestamp(value + APPLE_EPOCH, dt.timezone.utc).date().isoformat()


def validate_workspace(value) -> None:
    fields(value, {"schemaVersion", "id", "identitySalt", "createdAt"})
    require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1)
    uuid_string(value["id"])
    text(value["identitySalt"], 32, 256)
    date(value["createdAt"], time.time() - APPLE_EPOCH + 300)


def validate_values(value) -> None:
    fields(value, {"tokenMix", "provenance", "unpricedRequests", "estimatedRequests"},
           {"tokens", "requests", "costUSD", "apiEquivalentCostUSD", "model"})
    for key in ("tokens", "requests"):
        if value.get(key) is not None:
            count(value[key])
    for key in ("costUSD", "apiEquivalentCostUSD"):
        if value.get(key) is not None:
            number(value[key])
    count(value["unpricedRequests"])
    count(value["estimatedRequests"])
    require(type(value["provenance"]) is str and value["provenance"] in PROVENANCES)
    if value.get("model") is not None:
        text(value["model"], 1, 160)
        require(PUBLIC_MODEL.fullmatch(value["model"]) is not None, "nonpublic_model")
    mix = value["tokenMix"]
    fields(mix, set(), {"inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens", "reasoningTokens"})
    for item in mix.values():
        if item is not None:
            count(item)


def validate_publication(value, workspace_id: str, device_id: str | None = None,
                         device_name: str | None = None, now: float | None = None) -> None:
    fields(value, {"schemaVersion", "workspaceID", "deviceID", "deviceName", "publishedAt", "events",
                   "accountDays", "excludedRecords"})
    require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1)
    require(uuid_string(value["workspaceID"]) == uuid_string(workspace_id), "wrong_workspace", 409)
    owner = uuid_string(value["deviceID"])
    require(device_id is None or owner == device_id, "wrong_device", 403)
    text(value["deviceName"], 1, 80)
    require(device_name is None or value["deviceName"] == device_name, "wrong_device", 403)
    published = value["publishedAt"]
    date(published, (time.time() if now is None else now) - APPLE_EPOCH + 300)
    count(value["excludedRecords"])
    events, accounts = value["events"], value["accountDays"]
    require(type(events) is list and type(accounts) is list)
    require(len(events) + len(accounts) <= MAX_RECORDS, "record_limit", 413)
    identities = set()
    for row in events:
        fields(row, {"id", "provider", "day", "observedAt", "values"})
        require(type(row["id"]) is str and OPAQUE_ID.fullmatch(row["id"]) is not None)
        require(row["provider"] in ("codex", "claude", "meta", "localInference"))
        date(row["observedAt"], published + 300)
        require(day(row["day"]) == day_for(row["observedAt"]))
        identity = (row["provider"], row["id"])
        require(identity not in identities, "duplicate_event")
        identities.add(identity)
        validate_values(row["values"])
        if row["provider"] == "localInference":
            require(row["values"].get("costUSD") is None
                    and row["values"].get("apiEquivalentCostUSD") is None
                    and row["values"]["provenance"] == "unknown", "local_inference_is_unpriced")
    identities.clear()
    for row in accounts:
        fields(row, {"accountScope", "provider", "day", "observedAt", "values"})
        require(type(row["accountScope"]) is str and OPAQUE_ID.fullmatch(row["accountScope"]) is not None)
        require(row["provider"] == "cursor")
        require(day(row["day"]) <= day_for(published + 300))
        date(row["observedAt"], published + 300)
        identity = (row["provider"], row["accountScope"], row["day"])
        require(identity not in identities, "duplicate_account_day")
        identities.add(identity)
        validate_values(row["values"])


def validate_endpoint(value: str) -> str:
    parts = urllib.parse.urlsplit(value)
    host = (parts.hostname or "").lower()
    require(parts.path in ("", "/") and not parts.query and not parts.fragment and not parts.username
            and not parts.password, "invalid_endpoint")
    require((parts.scheme == "https" and host.endswith(".ts.net") and len(host) > len(".ts.net"))
            or (parts.scheme == "http" and host in ("127.0.0.1", "localhost", "::1")), "invalid_endpoint")
    try:
        require(parts.port is None or 1 <= parts.port <= 65535, "invalid_endpoint")
    except ValueError:
        raise HubError(400, "invalid_endpoint") from None
    return value.rstrip("/")


def private_directory(path: Path, create: bool = False) -> Path:
    path = path.absolute()
    require(not any(path == Path(root) or Path(root) in path.parents
                    for root in ("/Volumes", "/media", "/mnt", "/run/media")), "state_must_remain_internal")
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = path.lstat()
    require(stat.S_ISDIR(metadata.st_mode) and metadata.st_uid == os.getuid()
            and metadata.st_mode & 0o077 == 0, "unsafe_state_directory")
    # Reject a symlink in the caller's directory chain, not just the last component.
    require(path.resolve() == path, "unsafe_state_directory")
    return path


def write_private(path: Path, data: bytes) -> None:
    parent = private_directory(path.parent)
    temporary = parent / (".enrollment-" + secrets.token_hex(12))
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        os.link(temporary, path)  # Fail rather than overwrite an existing enrollment.
        directory = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def token_digest(token: str) -> str:
    return hashlib.sha256(token.encode("ascii")).hexdigest()


class Store:
    def __init__(self, directory: Path):
        self.directory = private_directory(directory)
        self.path = self.directory / "hub.sqlite3"
        metadata = self.path.lstat()
        require(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid()
                and metadata.st_mode & 0o077 == 0, "unsafe_database")

    @staticmethod
    def initialize(directory: Path, workspace=None) -> "Store":
        directory = private_directory(directory, create=True)
        if workspace is None:
            workspace = {"schemaVersion": 1, "id": str(uuid.uuid4()).upper(), "identitySalt": secrets.token_hex(32),
                         "createdAt": time.time() - APPLE_EPOCH}
        validate_workspace(workspace)
        path = directory / "hub.sqlite3"
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        os.close(descriptor)
        store = Store(directory)
        with store.connect() as connection:
            connection.executescript("""
                CREATE TABLE metadata (key TEXT PRIMARY KEY, value BLOB NOT NULL);
                CREATE TABLE devices (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE,
                    revoked INTEGER NOT NULL DEFAULT 0, snapshot BLOB, published REAL,
                    digest TEXT, record_count INTEGER NOT NULL DEFAULT 0
                );
            """)
            connection.execute("INSERT INTO metadata VALUES ('workspace', ?)", (canonical(workspace),))
        return store

    @contextlib.contextmanager
    def connect(self):
        connection = sqlite3.connect(f"file:{urllib.parse.quote(str(self.path))}?mode=rw", uri=True, timeout=10)
        try:
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("PRAGMA synchronous=FULL")
            connection.execute("PRAGMA trusted_schema=OFF")
            with connection:
                yield connection
        finally:
            connection.close()

    @staticmethod
    def workspace_in(connection):
        row = connection.execute("SELECT value FROM metadata WHERE key='workspace'").fetchone()
        require(row is not None, "uninitialized_workspace", 503)
        workspace = parse_json(row[0])
        validate_workspace(workspace)
        return workspace

    @staticmethod
    def authenticate_in(connection, token: str):
        require(type(token) is str and re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token) is not None,
                "unauthorized", 401)
        digest = token_digest(token)
        device = connection.execute("SELECT * FROM devices WHERE token_hash=? AND revoked=0", (digest,)).fetchone()
        require(device is not None and hmac.compare_digest(device["token_hash"], digest), "unauthorized", 401)
        return device

    def workspace(self, token: str):
        with self.connect() as connection:
            self.authenticate_in(connection, token)
            return self.workspace_in(connection)

    def add_device(self, name: str, endpoint: str, output: Path, device_id: str | None = None) -> str:
        text(name, 1, 80)
        endpoint = validate_endpoint(endpoint)
        device_id = uuid_string(device_id or str(uuid.uuid4()).upper())
        token = secrets.token_urlsafe(32)
        with self.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            count_devices = connection.execute("SELECT COUNT(*) FROM devices").fetchone()[0]
            require(count_devices < MAX_DEVICES, "device_limit", 413)
            require(connection.execute("SELECT 1 FROM devices WHERE id=?", (device_id,)).fetchone() is None,
                    "device_exists", 409)
            workspace = self.workspace_in(connection)
            enrollment = {"endpoint": endpoint, "deviceID": device_id, "deviceName": name, "credential": token,
                          "workspaceID": workspace["id"]}
            connection.execute("INSERT INTO devices (id,name,token_hash) VALUES (?,?,?)",
                               (device_id, name, token_digest(token)))
            write_private(output.absolute(), canonical(enrollment))
        return device_id

    def revoke(self, device_id: str) -> None:
        device_id = uuid_string(device_id)
        with self.connect() as connection:
            cursor = connection.execute("UPDATE devices SET revoked=1 WHERE id=?", (device_id,))
            require(cursor.rowcount == 1, "unknown_device", 404)

    def exchange(self, token: str, publication):
        with self.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            device = self.authenticate_in(connection, token)
            workspace = self.workspace_in(connection)
            if publication is not None:
                validate_publication(publication, workspace["id"], device["id"], device["name"])
                snapshot = canonical(publication)
                require(len(snapshot) <= MAX_PUBLICATION_BYTES, "snapshot_limit", 413)
                digest = hashlib.sha256(snapshot).hexdigest()
                if device["snapshot"] is not None:
                    require(publication["publishedAt"] >= device["published"], "stale_snapshot", 409)
                    require(publication["publishedAt"] != device["published"] or digest == device["digest"],
                            "snapshot_collision", 409)
                connection.execute("UPDATE devices SET snapshot=?,published=?,digest=?,record_count=? WHERE id=?",
                                   (snapshot, publication["publishedAt"], digest,
                                    len(publication["events"]) + len(publication["accountDays"]), device["id"]))
            totals = connection.execute(
                "SELECT COUNT(*),COALESCE(SUM(length(snapshot)),0),COALESCE(SUM(record_count),0) "
                "FROM devices WHERE snapshot IS NOT NULL"
            ).fetchone()
            require(totals[0] <= MAX_DEVICES, "device_limit", 413)
            require(totals[1] <= MAX_EXCHANGE_BYTES, "exchange_size_limit", 413)
            require(totals[2] <= MAX_EXCHANGE_RECORDS, "exchange_record_limit", 413)
            rows = connection.execute("SELECT id,name,snapshot FROM devices WHERE snapshot IS NOT NULL ORDER BY id")
            publications, rejected, total_records = [], 0, 0
            for row in rows:
                try:
                    candidate = parse_json(row["snapshot"])
                    validate_publication(candidate, workspace["id"], row["id"], row["name"])
                except (HubError, TypeError, ValueError, OverflowError):
                    rejected += 1
                    continue
                publications.append(candidate)
                total_records += len(candidate["events"]) + len(candidate["accountDays"])
            require(total_records <= MAX_EXCHANGE_RECORDS, "exchange_record_limit", 413)
            result = {"workspace": workspace, "publications": publications,
                      "publicationSucceeded": publication is not None, "unavailableFiles": 0, "rejectedFiles": rejected}
            require(len(canonical(result)) <= MAX_EXCHANGE_BYTES, "exchange_size_limit", 413)
            return result


class HubHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MidasUsageHub"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(30)

    def log_message(self, *_):
        pass  # No URL, request body, header, credential, or account data in logs.

    def send_json(self, status: int, value):
        body = canonical(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def route(self, method: str):
        try:
            require(self.path == ("/v1/workspace" if method == "GET" else "/v1/exchange"), "not_found", 404)
            require(self.headers.get("Origin") is None, "browser_origin_rejected", 403)
            auth = self.headers.get_all("Authorization", [])
            require(len(auth) == 1 and auth[0].startswith("Bearer "), "unauthorized", 401)
            token = auth[0][7:]
            require(self.headers.get("Transfer-Encoding") is None, "transfer_encoding_rejected")
            # Authenticate before accepting an upload, and again inside the write transaction.
            self.server.store.workspace(token)
            if method == "GET":
                require(self.headers.get("Content-Length", "0") == "0", "unexpected_body")
                result = self.server.store.workspace(token)
            else:
                require(self.headers.get("Content-Type", "").split(";")[0].strip() == "application/json",
                        "json_required", 415)
                lengths = self.headers.get_all("Content-Length", [])
                require(len(lengths) == 1 and re.fullmatch(r"[0-9]+", lengths[0]) is not None, "length_required", 411)
                length = int(lengths[0])
                require(0 < length <= MAX_PUBLICATION_BYTES, "snapshot_limit", 413)
                body = self.rfile.read(length)
                require(len(body) == length, "incomplete_body")
                result = self.server.store.exchange(token, parse_json(body))
            self.send_json(200, result)
        except HubError as error:
            self.send_json(error.status, {"error": error.code})
        except (ValueError, TypeError, OverflowError, RecursionError):
            self.send_json(400, {"error": "invalid_record"})
        except (TimeoutError, socket.timeout):
            self.close_connection = True
        except (sqlite3.Error, OSError):
            self.close_connection = True

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")


class HubServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, address, store: Store):
        self.store = store
        self.slots = threading.BoundedSemaphore(4)
        if ":" in address[0]:
            self.address_family = socket.AF_INET6
        super().__init__(address, HubHandler)

    def process_request(self, request, client_address):
        # Bound simultaneous decoders and in-memory complete snapshots, including unauthenticated clients.
        self.slots.acquire()
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def main(argv=None) -> int:
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, required=True, help="private internal directory (mode 700)")
    commands = parser.add_subparsers(dest="command", required=True)
    initialize = commands.add_parser("init", help="initialize exactly once; never replaces existing state")
    initialize.add_argument("--workspace-file", type=Path, help="optional existing Midas workspace.json")
    add = commands.add_parser("add-device", help="write a private enrollment file; never prints credentials")
    add.add_argument("--name", required=True)
    add.add_argument("--public-url", required=True)
    add.add_argument("--output", type=Path, required=True)
    add.add_argument("--device-id")
    revoke = commands.add_parser("revoke", help="revoke sync access; preserve historical numeric usage")
    revoke.add_argument("--device-id", required=True)
    commands.add_parser("list-devices", help="list IDs, names, status, and snapshot times without credentials")
    serve = commands.add_parser("serve", help="listen on loopback behind Tailscale Serve")
    serve.add_argument("--bind", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8766)
    serve.add_argument("--allow-non-loopback", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "init":
            workspace = parse_json(args.workspace_file.read_bytes()) if args.workspace_file else None
            Store.initialize(args.state_dir, workspace)
            print("Initialized private Midas usage hub.")
            return 0
        store = Store(args.state_dir)
        if args.command == "add-device":
            device_id = store.add_device(args.name, args.public_url, args.output, args.device_id)
            print(f"Enrolled device {device_id}; private connection written to {args.output}.")
        elif args.command == "revoke":
            store.revoke(args.device_id)
            print(f"Revoked device {args.device_id}; historical snapshots retained.")
        elif args.command == "list-devices":
            with store.connect() as connection:
                rows = connection.execute("SELECT id,name,revoked,published FROM devices ORDER BY id").fetchall()
                print(json.dumps([dict(row) for row in rows]))
        else:
            require(args.allow_non_loopback or ipaddress.ip_address(args.bind).is_loopback,
                    "non_loopback_requires_explicit_opt_in")
            require(1 <= args.port <= 65535, "invalid_port")
            server = HubServer((args.bind, args.port), store)
            print(f"Midas usage hub listening on {args.bind}:{args.port}; keep the listener private.", flush=True)
            try:
                server.serve_forever()
            finally:
                server.server_close()
        return 0
    except (HubError, OSError, sqlite3.Error, ValueError) as error:
        # Only a stable error code/type, never arguments or a URL that could contain a credential.
        print(f"Hub operation failed: {error.code if isinstance(error, HubError) else type(error).__name__}.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
