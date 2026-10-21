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
import gzip
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
HUB_VERSION = "0.49.0"
V2_PAGE_BYTES = 1024 * 1024
V2_PUBLICATION_BYTES = 512 * 1024 * 1024
V2_PUBLICATION_RECORDS = 2_000_000
V2_UPLOAD_TTL = 3600
PAIRING_TTL = 300
V2_REVISION_TTL = 24 * 60 * 60
V2_RECEIPT_TTL = 30 * 24 * 60 * 60
V2_STORAGE_BYTES = 8 * 1024 * 1024 * 1024
OPAQUE_ID = re.compile(r"[0-9a-f]{64}\Z")
PUBLIC_MODEL = re.compile(
    r"(?:gpt-[0-9][a-z0-9.\-]*|o[1-9][a-z0-9.\-]*|claude-[a-z0-9.\-]+|"
    r"muse-spark-[0-9.]+(?:-contributor)?|Qwen/Qwen3\.8-Flash-Next)\Z"
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
           {"tokens", "requests", "costUSD", "apiEquivalentCostUSD", "model", "pricingRevision"})
    if "pricingRevision" in value:
        count(value["pricingRevision"], 2_147_483_647)
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
                         device_name: str | None = None, now: float | None = None,
                         maximum_records: int = MAX_RECORDS) -> None:
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
    require(len(events) + len(accounts) <= maximum_records, "record_limit", 413)
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


def semantic_digest(publication) -> str:
    """Delivery timestamps do not create a new numeric-data revision."""
    value = dict(publication)
    value.pop("publishedAt", None)
    value["events"] = sorted(value["events"], key=lambda row: (row["provider"], row["id"]))
    value["accountDays"] = sorted(value["accountDays"],
                                  key=lambda row: (row["provider"], row["accountScope"], row["day"]))
    # Account report fetch timestamps are delivery metadata when measurements have not changed.
    value["accountDays"] = [{key: item for key, item in row.items() if key != "observedAt"}
                            for row in value["accountDays"]]
    return hashlib.sha256(canonical(value)).hexdigest()


def publication_header(publication):
    return {key: value for key, value in publication.items() if key not in ("events", "accountDays")}


def page_records(publication):
    """Stable provider/day pages bound decoding without discarding a single identity."""
    groups = {}
    for kind in ("events", "accountDays"):
        for row in publication[kind]:
            groups.setdefault((row["provider"], row["day"], kind), []).append(row)
    result = []
    for (provider, date_key, kind), rows in sorted(groups.items()):
        del provider, date_key
        rows.sort(key=lambda row: row.get("id", row.get("accountScope", "")))
        batch, size = [], 60
        for row in rows:
            encoded = canonical(row)
            require(len(encoded) + 60 <= V2_PAGE_BYTES, "page_limit", 413)
            if batch and size + len(encoded) + 1 > V2_PAGE_BYTES:
                value = {"schemaVersion": 1, "events": [], "accountDays": []}
                value[kind] = batch
                result.append(canonical(value))
                batch, size = [], 60
            batch.append(row)
            size += len(encoded) + 1
        if batch:
            value = {"schemaVersion": 1, "events": [], "accountDays": []}
            value[kind] = batch
            result.append(canonical(value))
    return result


def page_descriptor(raw):
    value = parse_json(raw)
    return {"digest": hashlib.sha256(raw).hexdigest(), "byteCount": len(raw),
            "eventCount": len(value["events"]), "accountDayCount": len(value["accountDays"])}


def validate_page(raw, header=None):
    require(0 < len(raw) <= V2_PAGE_BYTES, "page_limit", 413)
    value = parse_json(raw)
    fields(value, {"schemaVersion", "events", "accountDays"})
    require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1)
    require(type(value["events"]) is list and type(value["accountDays"]) is list)
    if header is not None:
        publication = dict(header, events=value["events"], accountDays=value["accountDays"])
        validate_publication(publication, header["workspaceID"], header["deviceID"], header["deviceName"],
                             maximum_records=V2_PUBLICATION_RECORDS)
    return value


def validate_descriptors(descriptors):
    require(type(descriptors) is list and len(descriptors) <= 8192, "page_limit", 413)
    seen, size, records = set(), 0, 0
    for item in descriptors:
        fields(item, {"digest", "byteCount", "eventCount", "accountDayCount"})
        require(type(item["digest"]) is str and OPAQUE_ID.fullmatch(item["digest"]) is not None)
        require(item["digest"] not in seen, "duplicate_page")
        seen.add(item["digest"])
        count(item["byteCount"], V2_PAGE_BYTES)
        require(item["byteCount"] > 0)
        count(item["eventCount"], V2_PUBLICATION_RECORDS)
        count(item["accountDayCount"], V2_PUBLICATION_RECORDS)
        require(item["eventCount"] + item["accountDayCount"] > 0)
        size += item["byteCount"]
        records += item["eventCount"] + item["accountDayCount"]
    require(size <= V2_PUBLICATION_BYTES and records <= V2_PUBLICATION_RECORDS, "capacity", 413)


def prefer_record(candidate, old, account=False):
    candidate_tokens = candidate["values"].get("tokens")
    old_tokens = old["values"].get("tokens")
    candidate_tokens = -1 if candidate_tokens is None else candidate_tokens
    old_tokens = -1 if old_tokens is None else old_tokens
    if not account and candidate_tokens != old_tokens:
        return candidate_tokens > old_tokens
    if candidate["observedAt"] != old["observedAt"]:
        return candidate["observedAt"] > old["observedAt"]
    if candidate["values"].get("pricingRevision", 0) != old["values"].get("pricingRevision", 0):
        return candidate["values"].get("pricingRevision", 0) > old["values"].get("pricingRevision", 0)
    def quality(row):
        values = row["values"]
        return (100 * (values.get("costUSD") is not None)
                + 20 * (values.get("apiEquivalentCostUSD") is not None)
                + (values.get("model") is not None)
                + {"unknown": 0, "listPriceEstimate": 10, "mixed": 5,
                   "vendorMetered": 30, "vendorBilled": 40}[values["provenance"]])
    if quality(candidate) != quality(old):
        return quality(candidate) > quality(old)
    return canonical(candidate) > canonical(old)


def rollup_id(device_id, provider, day, values):
    parts = ["midas-day-rollup-v1", device_id.upper(), provider, day,
             values.get("model") or "", values["provenance"],
             "priced" if values.get("costUSD") is not None else "unpriced"]
    return hashlib.sha256(canonical(parts).replace(b"/", b"\\/")).hexdigest()


def legacy_projection(publication):
    """Derived v1 view only; canonical identities always remain in v2 pages."""
    days = {}
    for row in publication["events"]:
        rolled = rollup_id(publication["deviceID"], row["provider"], row["day"], row["values"]) == row["id"]
        days.setdefault((row["provider"], row["day"]), {True: [], False: []})[rolled].append(row)
    groups = {}
    for provider_day, variants in sorted(days.items()):
        legacy, fine = variants[True], variants[False]
        covered = all(sum(row["values"].get(key) or 0 for row in fine) >=
                      sum(row["values"].get(key) or 0 for row in legacy)
                      for key in ("tokens", "requests", "costUSD", "apiEquivalentCostUSD"))
        selected = fine if fine and (not legacy or covered) else legacy
        for row in selected:
            values = row["values"]
            key = (*provider_day, values.get("model"), values["provenance"], values.get("costUSD") is not None)
            groups.setdefault(key, []).append(row)
    events = []
    def summed(rows, key):
        numbers = [row[key] for row in rows if row.get(key) is not None]
        if not numbers:
            return None
        return math.fsum(numbers) if any(type(n) is float for n in numbers) else sum(numbers)
    for (provider, day, model, provenance, priced), rows in groups.items():
        sources = [row["values"] for row in rows]
        values = {"provenance": provenance, "unpricedRequests": summed(sources, "unpricedRequests"),
                  "estimatedRequests": summed(sources, "estimatedRequests"), "tokenMix": {}}
        for key in ("tokens", "requests", "costUSD", "apiEquivalentCostUSD"):
            number = summed(sources, key)
            if number is not None:
                values[key] = number
        for key in ("inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens", "reasoningTokens"):
            number = summed([value["tokenMix"] for value in sources], key)
            if number is not None:
                values["tokenMix"][key] = number
        if model is not None:
            values["model"] = model
        revision = max(value.get("pricingRevision", 0) for value in sources)
        if revision:
            values["pricingRevision"] = revision
        events.append({"id": rollup_id(publication["deviceID"], provider, day, values),
                       "provider": provider, "day": day, "observedAt": max(row["observedAt"] for row in rows),
                       "values": values})
    return dict(publication, events=sorted(events, key=lambda row: (row["provider"], row["id"])))


def merge_legacy(previous, fresh):
    """v1 clients may be stale: import upserts into v2, never replace its richer canonical view."""
    result = dict(fresh)
    for kind in ("events", "accountDays"):
        account = kind == "accountDays"
        key = (lambda row: (row["provider"], row["accountScope"], row["day"])) if account else (
            lambda row: (row["provider"], row["id"]))
        records = {key(row): row for row in previous[kind]}
        for row in fresh[kind]:
            identity = key(row)
            if identity not in records or prefer_record(row, records[identity], account):
                records[identity] = row
        result[kind] = [records[item] for item in sorted(records)]
    return result


class Store:
    def __init__(self, directory: Path):
        self.directory = private_directory(directory)
        self.path = self.directory / "hub.sqlite3"
        self._migration_lock = threading.RLock()
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
        self.ensure_v2()
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
            self._sync_v1_heads(connection)
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


    def ensure_v2(self):
        """Additive migration, with a consistent backup before changing an existing v1 database."""
        with self._migration_lock:
            with self.connect() as connection:
                if connection.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('v2_heads','v2_leases','v2_pages','v2_revisions','v2_legacy','v2_uploads','v2_receipts','v2_pairing')").fetchone()[0] == 8:
                    return
                backup_dir = private_directory(self.directory / "backups", create=True)
                backup = backup_dir / ("pre-v2-" + str(int(time.time())) + "-" + secrets.token_hex(4) + ".sqlite3")
                descriptor = os.open(backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
                os.close(descriptor)
                with contextlib.closing(sqlite3.connect(backup)) as destination:
                    connection.backup(destination)
                    require(destination.execute("PRAGMA quick_check").fetchone()[0] == "ok", "backup_failed", 503)
                connection.executescript("""
                    CREATE TABLE IF NOT EXISTS v2_pages (
                        digest TEXT PRIMARY KEY, body BLOB NOT NULL, byte_count INTEGER NOT NULL,
                        event_count INTEGER NOT NULL, account_count INTEGER NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS v2_revisions (
                        device_id TEXT NOT NULL, revision INTEGER NOT NULL, digest TEXT NOT NULL,
                        header BLOB NOT NULL, pages BLOB NOT NULL, event_count INTEGER NOT NULL,
                        account_count INTEGER NOT NULL, created REAL NOT NULL,
                        PRIMARY KEY(device_id,revision)
                    );
                    CREATE TABLE IF NOT EXISTS v2_heads (device_id TEXT PRIMARY KEY, revision INTEGER NOT NULL);
                    CREATE TABLE IF NOT EXISTS v2_leases (
                        device_id TEXT NOT NULL, revision INTEGER NOT NULL, expires REAL NOT NULL,
                        PRIMARY KEY(device_id,revision)
                    );
                    CREATE TABLE IF NOT EXISTS v2_legacy (device_id TEXT PRIMARY KEY, digest TEXT NOT NULL);
                    CREATE TABLE IF NOT EXISTS v2_uploads (
                        id TEXT PRIMARY KEY, device_id TEXT NOT NULL, specification BLOB NOT NULL,
                        spec_digest TEXT NOT NULL, created REAL NOT NULL, receipt BLOB
                    );
                    CREATE TABLE IF NOT EXISTS v2_receipts (
                        reader_id TEXT PRIMARY KEY, applied BLOB NOT NULL, checked REAL NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS v2_pairing (
                        id TEXT PRIMARY KEY, name TEXT NOT NULL, secret_hash TEXT NOT NULL,
                        endpoint TEXT NOT NULL, code_hash TEXT NOT NULL, created REAL NOT NULL,
                        status TEXT NOT NULL, enrollment BLOB
                    );
                """)

    @staticmethod
    def _prune_v2_in(connection, force=False):
        now = time.time()
        stamp = connection.execute("SELECT value FROM metadata WHERE key='v2_last_gc'").fetchone()
        if not force and stamp is not None and float(stamp[0]) + 3600 > now:
            return
        connection.execute("DELETE FROM v2_leases WHERE expires<?", (now,))
        connection.execute("DELETE FROM v2_pairing WHERE created<?", (now - PAIRING_TTL,))
        connection.execute("DELETE FROM v2_revisions WHERE created<? AND NOT EXISTS "
                           "(SELECT 1 FROM v2_heads h WHERE h.device_id=v2_revisions.device_id AND h.revision=v2_revisions.revision) "
                           "AND NOT EXISTS (SELECT 1 FROM v2_leases l WHERE l.device_id=v2_revisions.device_id "
                           "AND l.revision=v2_revisions.revision)", (now - APPLE_EPOCH - V2_REVISION_TTL,))
        connection.execute("DELETE FROM v2_uploads WHERE (receipt IS NULL AND created<?) OR (receipt IS NOT NULL AND created<?)",
                           (now - V2_UPLOAD_TTL, now - V2_RECEIPT_TTL))
        referenced = set()
        for row in connection.execute("SELECT pages FROM v2_revisions"):
            referenced.update(item["digest"] for item in parse_json(row[0]))
        for row in connection.execute("SELECT specification FROM v2_uploads WHERE receipt IS NULL"):
            referenced.update(item["digest"] for item in parse_json(row[0])["pages"])
        for row in connection.execute("SELECT digest FROM v2_pages").fetchall():
            if row[0] not in referenced:
                connection.execute("DELETE FROM v2_pages WHERE digest=?", (row[0],))
        connection.execute("INSERT INTO metadata VALUES ('v2_last_gc',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                           (str(now),))

    @staticmethod
    def _head_in(connection, device_id):
        return connection.execute(
            "SELECT r.* FROM v2_revisions r JOIN v2_heads h ON h.device_id=r.device_id "
            "AND h.revision=r.revision WHERE r.device_id=?", (device_id,)).fetchone()

    @staticmethod
    def _publication_in(connection, row):
        publication = parse_json(row["header"])
        publication["events"], publication["accountDays"] = [], []
        for descriptor in parse_json(row["pages"]):
            raw = connection.execute("SELECT body FROM v2_pages WHERE digest=?", (descriptor["digest"],)).fetchone()
            require(raw is not None, "missing_page", 503)
            value = validate_page(raw[0])
            require(hashlib.sha256(raw[0]).hexdigest() == descriptor["digest"], "corrupt_page", 503)
            publication["events"].extend(value["events"])
            publication["accountDays"].extend(value["accountDays"])
        return publication

    @staticmethod
    def _store_page_in(connection, raw):
        descriptor = page_descriptor(raw)
        if connection.execute("SELECT 1 FROM v2_pages WHERE digest=?", (descriptor["digest"],)).fetchone() is None:
            size = connection.execute("SELECT COALESCE(SUM(byte_count),0) FROM v2_pages").fetchone()[0]
            require(size + len(raw) <= V2_STORAGE_BYTES, "capacity", 413)
        connection.execute("INSERT OR IGNORE INTO v2_pages VALUES (?,?,?,?,?)",
                           (descriptor["digest"], raw, descriptor["byteCount"], descriptor["eventCount"],
                            descriptor["accountDayCount"]))
        return descriptor

    @staticmethod
    def _set_revision_in(connection, publication, descriptors):
        device_id = publication["deviceID"]
        digest = semantic_digest(publication)
        previous = Store._head_in(connection, device_id)
        if previous is not None and previous["digest"] == digest:
            return previous["revision"], digest
        revision = 1 if previous is None else previous["revision"] + 1
        connection.execute("INSERT INTO v2_revisions VALUES (?,?,?,?,?,?,?,?)",
                           (device_id, revision, digest, canonical(publication_header(publication)),
                            canonical(descriptors), len(publication["events"]), len(publication["accountDays"]),
                            time.time() - APPLE_EPOCH))
        connection.execute("INSERT INTO v2_heads VALUES (?,?) ON CONFLICT(device_id) DO UPDATE SET revision=excluded.revision",
                           (device_id, revision))
        return revision, digest

    def _sync_v1_heads(self, connection):
        rows = connection.execute("SELECT id,digest FROM devices WHERE snapshot IS NOT NULL ORDER BY id").fetchall()
        for row in rows:
            imported = connection.execute("SELECT digest FROM v2_legacy WHERE device_id=?", (row["id"],)).fetchone()
            if imported is not None and imported[0] == row["digest"]:
                continue
            device = connection.execute("SELECT * FROM devices WHERE id=?", (row["id"],)).fetchone()
            try:
                publication = parse_json(device["snapshot"])
                validate_publication(publication, self.workspace_in(connection)["id"], device["id"], device["name"])
            except (HubError, TypeError, ValueError, OverflowError):
                # Keep the damaged original for diagnosis without hiding healthy peer heads.
                continue
            previous = self._head_in(connection, device["id"])
            if previous is not None:
                publication = merge_legacy(self._publication_in(connection, previous), publication)
            validate_publication(publication, self.workspace_in(connection)["id"], device["id"], device["name"],
                                 maximum_records=V2_PUBLICATION_RECORDS)
            pages = page_records(publication)
            require(sum(map(len, pages)) <= V2_PUBLICATION_BYTES, "capacity", 413)
            descriptors = [self._store_page_in(connection, raw) for raw in pages]
            self._set_revision_in(connection, publication, descriptors)
            connection.execute("INSERT INTO v2_legacy VALUES (?,?) ON CONFLICT(device_id) DO UPDATE SET digest=excluded.digest",
                               (device["id"], device["digest"]))

    def manifest(self, token):
        self.ensure_v2()
        with self.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            self.authenticate_in(connection, token)
            self._sync_v1_heads(connection)
            self._prune_v2_in(connection)
            devices = []
            lease_expires = time.time() + V2_REVISION_TTL
            for row in connection.execute(
                    "SELECT r.*,d.name,d.revoked FROM v2_revisions r JOIN v2_heads h "
                    "ON h.device_id=r.device_id AND h.revision=r.revision JOIN devices d ON d.id=r.device_id "
                    "ORDER BY r.device_id"):
                connection.execute("INSERT INTO v2_leases VALUES (?,?,?) ON CONFLICT(device_id,revision) DO UPDATE SET expires=excluded.expires",
                                   (row["device_id"], row["revision"], lease_expires))
                supports = connection.execute("SELECT 1 FROM v2_receipts WHERE reader_id=?", (row["device_id"],)).fetchone()
                committed = connection.execute("SELECT 1 FROM v2_uploads WHERE device_id=? AND receipt IS NOT NULL LIMIT 1",
                                               (row["device_id"],)).fetchone()
                devices.append({"deviceID": row["device_id"], "deviceName": row["name"], "revision": row["revision"],
                                "digest": row["digest"], "header": parse_json(row["header"]),
                                "pages": parse_json(row["pages"]), "eventCount": row["event_count"],
                                "accountDayCount": row["account_count"], "revoked": bool(row["revoked"]),
                                "supportsReceipts": bool(supports or committed), "leaseExpiresAt": lease_expires - APPLE_EPOCH,
                                "legacyViewStale": connection.execute("SELECT 1 FROM metadata WHERE key=?",
                                    ("v2_legacy_stale:" + row["device_id"],)).fetchone() is not None})
            receipts = [{"deviceID": row["reader_id"], "appliedRevisions": parse_json(row["applied"]),
                         "checkedAt": row["checked"]} for row in
                        connection.execute("SELECT * FROM v2_receipts ORDER BY reader_id")]
            return {"protocolVersion": 2, "hubVersion": HUB_VERSION, "workspace": self.workspace_in(connection),
                    "limits": {"pageBytes": V2_PAGE_BYTES, "publicationRecords": V2_PUBLICATION_RECORDS,
                               "publicationBytes": V2_PUBLICATION_BYTES, "storageBytes": V2_STORAGE_BYTES}, "devices": devices, "receipts": receipts,
                    "checkedAt": time.time() - APPLE_EPOCH}

    def get_page(self, token, device_id, revision, digest):
        device_id = uuid_string(device_id)
        require(type(revision) is int and revision > 0)
        require(type(digest) is str and OPAQUE_ID.fullmatch(digest) is not None)
        self.ensure_v2()
        with self.connect() as connection:
            self.authenticate_in(connection, token)
            row = connection.execute("SELECT pages FROM v2_revisions WHERE device_id=? AND revision=?",
                                     (device_id, revision)).fetchone()
            require(row is not None, "revision_expired", 410)
            require(any(page["digest"] == digest for page in parse_json(row[0])), "unknown_page", 404)
            page = connection.execute("SELECT body FROM v2_pages WHERE digest=?", (digest,)).fetchone()
            require(page is not None, "missing_page", 503)
            require(hashlib.sha256(page[0]).hexdigest() == digest, "corrupt_page", 503)
            return page[0]

    def upload_start(self, token, value):
        fields(value, {"uploadID", "expectedRevision", "header", "pages"})
        upload_id = uuid_string(value["uploadID"])
        count(value["expectedRevision"], 2**53 - 1)
        header = value["header"]
        fields(header, {"schemaVersion", "workspaceID", "deviceID", "deviceName", "publishedAt", "excludedRecords"})
        validate_descriptors(value["pages"])
        self.ensure_v2()
        with self.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            device = self.authenticate_in(connection, token)
            validate_publication(dict(header, events=[], accountDays=[]), self.workspace_in(connection)["id"],
                                 device["id"], device["name"])
            self._sync_v1_heads(connection)
            self._prune_v2_in(connection)
            specification = canonical(value)
            digest = hashlib.sha256(specification).hexdigest()
            existing = connection.execute("SELECT * FROM v2_uploads WHERE id=?", (upload_id,)).fetchone()
            if existing is not None:
                require(existing["device_id"] == device["id"], "wrong_device", 403)
                require(existing["spec_digest"] == digest, "upload_collision", 409)
                if existing["receipt"] is not None:
                    return {"uploadID": upload_id, "missingDigests": [], "committed": True,
                            "receipt": parse_json(existing["receipt"])}
                require(existing["created"] + V2_UPLOAD_TTL >= time.time(), "upload_expired", 409)
            current = self._head_in(connection, device["id"])
            require(value["expectedRevision"] == (current["revision"] if current else 0), "revision_conflict", 409)
            if existing is None:
                active = connection.execute("SELECT COUNT(*) FROM v2_uploads WHERE device_id=? AND receipt IS NULL AND created>?",
                                            (device["id"], time.time() - V2_UPLOAD_TTL)).fetchone()[0]
                require(active < 32, "too_many_uploads", 429)
                connection.execute("INSERT INTO v2_uploads VALUES (?,?,?,?,?,NULL)",
                                   (upload_id, device["id"], specification, digest, time.time()))
            missing = [page["digest"] for page in value["pages"] if connection.execute(
                "SELECT 1 FROM v2_pages WHERE digest=?", (page["digest"],)).fetchone() is None]
            return {"uploadID": upload_id, "missingDigests": missing, "committed": False}

    def upload_page(self, token, upload_id, digest, raw):
        upload_id = uuid_string(upload_id)
        require(type(digest) is str and OPAQUE_ID.fullmatch(digest) is not None)
        require(hashlib.sha256(raw).hexdigest() == digest, "page_digest_mismatch")
        self.ensure_v2()
        with self.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            device = self.authenticate_in(connection, token)
            upload = connection.execute("SELECT * FROM v2_uploads WHERE id=?", (upload_id,)).fetchone()
            require(upload is not None, "unknown_upload", 404)
            require(upload["device_id"] == device["id"], "wrong_device", 403)
            require(upload["created"] + V2_UPLOAD_TTL >= time.time() or upload["receipt"] is not None,
                    "upload_expired", 409)
            specification = parse_json(upload["specification"])
            expected = next((page for page in specification["pages"] if page["digest"] == digest), None)
            require(expected is not None, "unexpected_page")
            value = validate_page(raw, specification["header"])
            del value
            require(expected == page_descriptor(raw), "page_descriptor_mismatch")
            self._store_page_in(connection, raw)
            return {"stored": True, "digest": digest}

    @staticmethod
    def _guard_history_in(connection, device_id, publication):
        old = Store._head_in(connection, device_id)
        if old is None:
            return
        previous = Store._publication_in(connection, old)
        for kind in ("events", "accountDays"):
            key = (lambda row: (row["provider"], row["id"])) if kind == "events" else (
                lambda row: (row["provider"], row["accountScope"], row["day"]))
            included = {key(row): row for row in publication[kind]}
            require(all(key(row) in included for row in previous[kind]), "history_omission", 409)
            require(all(row == included[key(row)] or not prefer_record(row, included[key(row)], kind == "accountDays")
                        for row in previous[kind]), "history_regression", 409)

    def upload_commit(self, token, value):
        fields(value, {"uploadID"})
        upload_id = uuid_string(value["uploadID"])
        self.ensure_v2()
        with self.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            device = self.authenticate_in(connection, token)
            upload = connection.execute("SELECT * FROM v2_uploads WHERE id=?", (upload_id,)).fetchone()
            require(upload is not None, "unknown_upload", 404)
            require(upload["device_id"] == device["id"], "wrong_device", 403)
            if upload["receipt"] is not None:
                return parse_json(upload["receipt"])
            require(upload["created"] + V2_UPLOAD_TTL >= time.time(), "upload_expired", 409)
            specification = parse_json(upload["specification"])
            current = self._head_in(connection, device["id"])
            require(specification["expectedRevision"] == (current["revision"] if current else 0),
                    "revision_conflict", 409)
            publication = dict(specification["header"], events=[], accountDays=[])
            total_bytes = 0
            for descriptor in specification["pages"]:
                stored = connection.execute("SELECT body FROM v2_pages WHERE digest=?", (descriptor["digest"],)).fetchone()
                require(stored is not None, "missing_page", 409)
                raw = stored[0]
                require(hashlib.sha256(raw).hexdigest() == descriptor["digest"], "corrupt_page", 503)
                require(page_descriptor(raw) == descriptor, "corrupt_page", 503)
                page = validate_page(raw, specification["header"])
                total_bytes += len(raw)
                publication["events"].extend(page["events"])
                publication["accountDays"].extend(page["accountDays"])
            require(total_bytes <= V2_PUBLICATION_BYTES, "capacity", 413)
            validate_publication(publication, self.workspace_in(connection)["id"], device["id"], device["name"],
                                 maximum_records=V2_PUBLICATION_RECORDS)
            self._guard_history_in(connection, device["id"], publication)
            revision, digest = self._set_revision_in(connection, publication, specification["pages"])
            receipt = {"deviceID": device["id"], "revision": revision, "digest": digest,
                       "acceptedAt": time.time() - APPLE_EPOCH, "publicationSucceeded": True}
            connection.execute("UPDATE v2_uploads SET receipt=? WHERE id=?", (canonical(receipt), upload_id))
            # A fresh, conservative derived v1 view keeps older collectors working independently
            # from canonical pages. Impossible legacy bounds never discard committed v2 history.
            connection.execute("INSERT OR REPLACE INTO metadata VALUES (?,?)", ("v2_legacy_stale:" + device["id"], "1"))
            try:
                legacy = legacy_projection(publication)
                validate_publication(legacy, self.workspace_in(connection)["id"], device["id"], device["name"])
                raw = canonical(legacy)
                require(len(raw) <= MAX_PUBLICATION_BYTES, "snapshot_limit", 413)
                other = connection.execute("SELECT COALESCE(SUM(length(snapshot)),0),COALESCE(SUM(record_count),0) FROM devices WHERE id != ?", (device["id"],)).fetchone()
                records = len(legacy["events"]) + len(legacy["accountDays"])
                require(other[0] + len(raw) <= MAX_EXCHANGE_BYTES and other[1] + records <= MAX_EXCHANGE_RECORDS,
                        "exchange_size_limit", 413)
            except (HubError, OverflowError, ValueError):
                pass
            else:
                connection.execute("DELETE FROM metadata WHERE key=?", ("v2_legacy_stale:" + device["id"],))
                encoded_digest = hashlib.sha256(raw).hexdigest()
                connection.execute("UPDATE devices SET snapshot=?,published=?,digest=?,record_count=? WHERE id=?",
                                   (raw, publication["publishedAt"], encoded_digest, records, device["id"]))
                connection.execute("INSERT INTO v2_legacy VALUES (?,?) ON CONFLICT(device_id) DO UPDATE SET digest=excluded.digest",
                                   (device["id"], encoded_digest))
            return receipt

    def applied_receipt(self, token, value):
        fields(value, {"appliedRevisions"})
        vector = value["appliedRevisions"]
        require(type(vector) is dict and len(vector) <= MAX_DEVICES)
        vector = {uuid_string(key): item for key, item in vector.items()}
        for revision in vector.values():
            count(revision, 2**53 - 1)
            require(revision > 0)
        self.ensure_v2()
        with self.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            device = self.authenticate_in(connection, token)
            for device_id, revision in vector.items():
                head = self._head_in(connection, device_id)
                require(head is not None and revision <= head["revision"], "unknown_revision", 409)
            old = connection.execute("SELECT applied FROM v2_receipts WHERE reader_id=?", (device["id"],)).fetchone()
            if old is not None:
                for device_id, revision in parse_json(old[0]).items():
                    vector[device_id] = max(vector.get(device_id, 0), revision)
            checked = time.time() - APPLE_EPOCH
            connection.execute("INSERT INTO v2_receipts VALUES (?,?,?) ON CONFLICT(reader_id) "
                               "DO UPDATE SET applied=excluded.applied,checked=excluded.checked",
                               (device["id"], canonical(vector), checked))
            return {"deviceID": device["id"], "appliedRevisions": vector, "checkedAt": checked}

    def pairing_request(self, value):
        fields(value, {"deviceName", "requestID", "requestSecret", "endpoint"})
        request_id = uuid_string(value["requestID"])
        text(value["deviceName"], 1, 80)
        require(type(value["requestSecret"]) is str and re.fullmatch(r"[A-Za-z0-9_-]{32,256}", value["requestSecret"]))
        endpoint = validate_endpoint(value["endpoint"])
        self.ensure_v2()
        with self.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute("SELECT * FROM v2_pairing WHERE id=?", (request_id,)).fetchone()
            if existing is not None:
                require(hmac.compare_digest(existing["secret_hash"], token_digest(value["requestSecret"])), "unauthorized", 401)
                # Codes are deliberately not recoverable; the requester retains the original response.
                raise HubError(409, "pairing_exists")
            recent = connection.execute("SELECT COUNT(*) FROM v2_pairing WHERE created>?", (time.time() - PAIRING_TTL,)).fetchone()[0]
            require(recent < 5, "pairing_rate_limited", 429)
            code = f"{secrets.randbelow(1_000_000):06d}"
            connection.execute("INSERT INTO v2_pairing VALUES (?,?,?,?,?,?,?,NULL)",
                               (request_id, value["deviceName"], token_digest(value["requestSecret"]), endpoint,
                                token_digest(code), time.time(), "pending"))
            return {"requestID": request_id, "code": code, "expiresAt": time.time() - APPLE_EPOCH + PAIRING_TTL,
                    "status": "pending"}

    def pairing_status(self, value):
        fields(value, {"requestID", "requestSecret"})
        request_id = uuid_string(value["requestID"])
        require(type(value["requestSecret"]) is str and re.fullmatch(r"[A-Za-z0-9_-]{32,256}", value["requestSecret"]))
        self.ensure_v2()
        with self.connect() as connection:
            row = connection.execute("SELECT * FROM v2_pairing WHERE id=?", (request_id,)).fetchone()
            require(row is not None and hmac.compare_digest(row["secret_hash"], token_digest(value["requestSecret"])),
                    "unauthorized", 401)
            status = row["status"] if row["created"] + PAIRING_TTL >= time.time() else "expired"
            result = {"requestID": request_id, "status": status}
            if status == "approved":
                result["connection"] = parse_json(row["enrollment"])
            return result

    def pairing_list(self):
        self.ensure_v2()
        with self.connect() as connection:
            return [{"requestID": row["id"], "deviceName": row["name"],
                     "expiresAt": row["created"] - APPLE_EPOCH + PAIRING_TTL, "status": row["status"]}
                    for row in connection.execute("SELECT * FROM v2_pairing WHERE created>? ORDER BY created",
                                                  (time.time() - PAIRING_TTL,))]

    def pairing_approve(self, request_id, code):
        request_id = uuid_string(request_id)
        require(type(code) is str and re.fullmatch(r"[0-9]{6}", code))
        self.ensure_v2()
        with self.connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute("SELECT * FROM v2_pairing WHERE id=?", (request_id,)).fetchone()
            require(row is not None and row["status"] == "pending" and row["created"] + PAIRING_TTL >= time.time(),
                    "pairing_unavailable", 409)
            require(hmac.compare_digest(row["code_hash"], token_digest(code)), "pairing_code_mismatch", 403)
            require(connection.execute("SELECT COUNT(*) FROM devices").fetchone()[0] < MAX_DEVICES, "device_limit", 413)
            token = secrets.token_urlsafe(32)
            device_id = str(uuid.uuid4()).upper()
            enrollment = {"endpoint": row["endpoint"], "deviceID": device_id, "deviceName": row["name"],
                          "credential": token, "workspaceID": self.workspace_in(connection)["id"]}
            connection.execute("INSERT INTO devices (id,name,token_hash) VALUES (?,?,?)",
                               (device_id, row["name"], token_digest(token)))
            connection.execute("UPDATE v2_pairing SET status='approved',enrollment=?,created=? WHERE id=?",
                               (canonical(enrollment), time.time(), request_id))
            return {"requestID": request_id, "status": "approved", "deviceID": device_id}

    def pairing_deny(self, request_id):
        request_id = uuid_string(request_id)
        self.ensure_v2()
        with self.connect() as connection:
            changed = connection.execute("UPDATE v2_pairing SET status='denied',enrollment=NULL WHERE id=? AND status='pending'",
                                         (request_id,)).rowcount
            require(changed == 1, "pairing_unavailable", 409)
            return {"requestID": request_id, "status": "denied"}


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
        self.send_bytes(status, canonical(value))

    def send_bytes(self, status: int, body: bytes):
        compressed = False
        if len(body) >= 16 * 1024:
            for encoding in self.headers.get("Accept-Encoding", "").split(","):
                parts = [part.strip() for part in encoding.split(";")]
                if parts[0].lower() != "gzip":
                    continue
                quality = next((part[2:] for part in parts[1:] if part.lower().startswith("q=")), "1")
                try:
                    compressed = 0 < float(quality) <= 1
                except ValueError:
                    compressed = False
                break
            if compressed:
                body = gzip.compress(body, compresslevel=1, mtime=0)
        self.send_response(status)
        if compressed:
            self.send_header("Content-Encoding", "gzip")
        self.send_header("Vary", "Accept-Encoding")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        for offset in range(0, len(body), 64 * 1024):
            self.wfile.write(memoryview(body)[offset:offset + 64 * 1024])
        self.close_connection = True

    def read_body(self, maximum):
        require(self.headers.get("Content-Type", "").split(";")[0].strip() == "application/json",
                "json_required", 415)
        require(self.headers.get("Content-Encoding", "identity").lower() == "identity", "encoding_unsupported", 415)
        lengths = self.headers.get_all("Content-Length", [])
        require(len(lengths) == 1 and re.fullmatch(r"[0-9]+", lengths[0]) is not None, "length_required", 411)
        length = int(lengths[0])
        require(0 < length <= maximum, "snapshot_limit", 413)
        body = self.rfile.read(length)
        require(len(body) == length, "incomplete_body")
        return body

    def route(self, method: str):
        try:
            require(self.headers.get("Origin") is None, "browser_origin_rejected", 403)
            require(self.headers.get("Transfer-Encoding") is None, "transfer_encoding_rejected")
            path = urllib.parse.urlsplit(self.path)
            require(not path.query and not path.fragment, "not_found", 404)
            route = path.path
            public_pair = method == "POST" and route in ("/v2/pairing/request", "/v2/pairing/status")
            if not public_pair:
                auth = self.headers.get_all("Authorization", [])
                require(len(auth) == 1 and auth[0].startswith("Bearer "), "unauthorized", 401)
                token = auth[0][7:]
                self.server.store.workspace(token)
            else:
                token = None
            if method == "GET":
                require(self.headers.get("Content-Length", "0") == "0", "unexpected_body")
                if route == "/v1/workspace":
                    result = self.server.store.workspace(token)
                elif route == "/v2/manifest":
                    result = self.server.store.manifest(token)
                elif match := re.fullmatch(r"/v2/pages/([A-Fa-f0-9-]{36})/([0-9]+)/([0-9a-f]{64})", route):
                    raw = self.server.store.get_page(token, match[1], int(match[2]), match[3])
                    self.send_bytes(200, raw)
                    return
                else:
                    raise HubError(404, "not_found")
            elif route == "/v1/exchange":
                result = self.server.store.exchange(token, parse_json(self.read_body(MAX_PUBLICATION_BYTES)))
            elif route == "/v2/upload/start":
                result = self.server.store.upload_start(token, parse_json(self.read_body(2 * 1024 * 1024)))
            elif match := re.fullmatch(r"/v2/upload/page/([A-Fa-f0-9-]{36})/([0-9a-f]{64})", route):
                result = self.server.store.upload_page(token, match[1], match[2], self.read_body(V2_PAGE_BYTES))
            elif route == "/v2/upload/commit":
                result = self.server.store.upload_commit(token, parse_json(self.read_body(4096)))
            elif route == "/v2/receipt":
                result = self.server.store.applied_receipt(token, parse_json(self.read_body(64 * 1024)))
            elif route == "/v2/pairing/request":
                result = self.server.store.pairing_request(parse_json(self.read_body(4096)))
            elif route == "/v2/pairing/status":
                result = self.server.store.pairing_status(parse_json(self.read_body(4096)))
            else:
                raise HubError(404, "not_found")
            self.send_json(200, result)
        except HubError as error:
            self.send_json(error.status, {"error": error.code})
        except (ValueError, TypeError, OverflowError, RecursionError, KeyError):
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
    commands.add_parser("pairing-list", help="list pending private pairing requests without credentials")
    approve = commands.add_parser("pairing-approve", help="approve a pairing locally after comparing its short code")
    approve.add_argument("--request-id", required=True)
    approve.add_argument("--code", required=True)
    deny = commands.add_parser("pairing-deny", help="deny a pending pairing locally")
    deny.add_argument("--request-id", required=True)
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
        elif args.command == "pairing-list":
            print(json.dumps(store.pairing_list()))
        elif args.command == "pairing-approve":
            print(json.dumps(store.pairing_approve(args.request_id, args.code)))
        elif args.command == "pairing-deny":
            print(json.dumps(store.pairing_deny(args.request_id)))
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
