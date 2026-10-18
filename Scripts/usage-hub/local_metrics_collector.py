#!/usr/bin/env python3
"""Collect numeric vLLM runtime counters, never request bodies or conversation logs.

The first sample is a baseline, not historical usage. Counter resets and missed
intervals remain partial coverage. Timing is sampled, within the polling interval.
Local runtime records remain unpriced and are never cloud quota. An explicitly
verified public model mapping and cached-input deltas support display-time valuation.
"""

import argparse
import copy
import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

import midas_usage_hub as schema

REFERENCE_EPOCH = 978307200
MAX_BYTES = 32 * 1024 * 1024
MAX_COUNTER = 1_000_000_000_000
METRIC = re.compile(r'^(vllm:(?:prompt_tokens|prompt_tokens_cached|generation_tokens|request_success)_total)(\{[^\n]*\})?\s+([^\s]+)(?:\s+\d+)?$')
LABEL = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


def read_private(path):
    path = Path(path).absolute()
    for parent in [path, *path.parents]:
        if parent.is_symlink():
            raise ValueError("private file path contains a link")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError("private file must be owned by this user with mode 600")
        data = handle.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError("private state exceeds its safety limit")
    return schema.parse_json(data)


def save_private(path, value):
    data = json.dumps(value, separators=(",", ":"), allow_nan=False).encode()
    if len(data) > MAX_BYTES:
        raise ValueError("numeric state exceeds its safety limit")
    path = Path(path)
    ensure_directory(path.parent)
    if path.is_symlink():
        raise ValueError("private state cannot be a symbolic link")
    fd, name = tempfile.mkstemp(prefix=".midas-numeric-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
        parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def ensure_directory(directory):
    directory = Path(directory).absolute()
    if any(part.is_symlink() for part in [directory, *directory.parents]):
        raise ValueError("private directory path contains a link")
    if any(str(directory).startswith(prefix) for prefix in ["/Volumes/", "/media/", "/mnt/", "/run/media/"]):
        raise ValueError("numeric state must remain on internal storage")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError("private directory must be owner-only")


def validate_model_mapping(model_alias=None, public_model=None):
    if model_alias is None and public_model is None:
        return
    if not model_alias or not public_model:
        raise ValueError("model alias and public model must be configured together")
    if len(model_alias.encode()) > 160 or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in model_alias):
        raise ValueError("invalid runtime model alias")
    if len(public_model.encode()) > 160 or schema.PUBLIC_MODEL.fullmatch(public_model) is None:
        raise ValueError("invalid public model identity")


def parse_metrics(text, model_alias=None, public_model=None):
    validate_model_mapping(model_alias, public_model)
    groups = {}
    seen = set()
    process_start = None
    for line in text.splitlines():
        if line.startswith("process_start_time_seconds "):
            fields = line.split()
            if len(fields) != 2 or process_start is not None:
                raise ValueError("runtime process identity is invalid")
            process_start = float(fields[1])
            if not math.isfinite(process_start) or process_start <= 0:
                raise ValueError("runtime process identity is invalid")
            continue
        match = METRIC.fullmatch(line)
        if not match:
            continue
        metric, raw_labels, raw_value = match.groups()
        value = float(raw_value)
        if not math.isfinite(value) or value < 0 or value > MAX_COUNTER or value != int(value):
            raise ValueError("runtime returned an invalid numeric counter")
        labels = {}
        remaining = (raw_labels or "{}")[1:-1]
        while remaining.strip():
            label = LABEL.match(remaining.lstrip())
            if not label or label[1] in labels:
                raise ValueError("runtime returned invalid counter labels")
            remaining = remaining.lstrip()[label.end():].lstrip()
            labels[label[1]] = label[2]
            if remaining:
                if not remaining.startswith(","):
                    raise ValueError("runtime returned invalid counter labels")
                remaining = remaining[1:]
        series = (metric, tuple(sorted(labels.items())))
        if series in seen:
            raise ValueError("runtime returned duplicate counter series")
        seen.add(series)
        # A per-engine/model identity is kept opaque, including within local state.
        labels.pop("finished_reason", None)
        identity = hashlib.sha256(json.dumps(labels, sort_keys=True).encode()).hexdigest()
        row = groups.setdefault(identity, {})
        # Never publish arbitrary runtime labels or filesystem model paths.
        if model_alias is not None and labels.get("model_name") == model_alias:
            row["public_model"] = public_model
        name = metric.removeprefix("vllm:").removesuffix("_total")
        if name == "request_success":
            row[name] = row.get(name, 0) + int(value)
            if row[name] > MAX_COUNTER:
                raise ValueError("runtime returned an oversized counter aggregate")
        elif name in row:
            raise ValueError("runtime returned duplicate token counter series")
        else:
            row[name] = int(value)
    valid = {key: row for key, row in groups.items() if "prompt_tokens" in row and "generation_tokens" in row}
    if not valid or len(valid) > 128 or process_start is None:
        raise ValueError("supported runtime counters are unavailable")
    return {"processStartTime": process_start, "counters": valid}


def sample(state, workspace, config, counters, now, maximum_gap=360):
    """Update stable per-runtime/day records; retries publish the identical numeric identity."""
    if state.get("workspace") != workspace or state.get("deviceID") != config["deviceID"]:
        raise ValueError("workspace or device identity changed")
    schema.validate_workspace(workspace)
    if not math.isfinite(now) or now < 0:
        raise ValueError("invalid sample clock")
    process_start = counters["processStartTime"]
    if process_start > now + 300:
        raise ValueError("runtime process identity is in the future")
    counters = counters["counters"]
    day = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime("%Y-%m-%d")
    previous = state.setdefault("counters", {})
    events = {event["id"]: event for event in state.get("events", [])}
    excluded = state.get("excludedRecords", 0)
    last_sample = state.get("lastSampleAt")
    continuous = last_sample is not None and 0 < now - last_sample <= maximum_gap
    same_day = last_sample is not None and datetime.datetime.fromtimestamp(
        last_sample, datetime.timezone.utc).strftime("%Y-%m-%d") == day
    same_process = state.get("processStartTime") == process_start
    for source, row in sorted(counters.items()):
        old = previous.get(source)
        reset = old is not None and (
            any(row[k] < old.get(k, 0) for k in ["prompt_tokens", "generation_tokens"])
            or row.get("public_model") != old.get("public_model"))
        if old is not None and (reset or not continuous or not same_day or not same_process):
            excluded += 1
        if old is not None and not reset and continuous and same_day and same_process:
            prompt = row["prompt_tokens"] - old["prompt_tokens"]
            output = row["generation_tokens"] - old["generation_tokens"]
            cached = None
            if "prompt_tokens_cached" in row and "prompt_tokens_cached" in old:
                cache_delta = row["prompt_tokens_cached"] - old["prompt_tokens_cached"]
                if 0 <= cache_delta <= prompt:
                    cached = cache_delta
                else:
                    # Preserve the valid token delta but do not guess its API-equivalent value.
                    excluded += 1
            public_model = row.get("public_model") if cached is not None else None
            requests = None
            if "request_success" in row and "request_success" in old and row["request_success"] >= old["request_success"]:
                requests = row["request_success"] - old["request_success"]
            if prompt or output or requests:
                components = [workspace["identitySalt"], "localInference", config["deviceID"], source, day]
                # A new cache-aware record never reclassifies legacy unpriced history.
                if public_model is not None:
                    components += [public_model, "cached-input-v1"]
                identity = json.dumps(components, separators=(",", ":"))
                event_id = hashlib.sha256(identity.encode()).hexdigest()
                existing = events.get(event_id, {}).get("values", {})
                old_mix = existing.get("tokenMix", {})
                input_total = old_mix.get("inputTokens", 0) + prompt
                output_total = old_mix.get("outputTokens", 0) + output
                request_total = None if requests is None or (existing and existing.get("requests") is None) else existing.get("requests", 0) + requests
                values = {"tokens": input_total + output_total,
                          "tokenMix": {"inputTokens": input_total, "outputTokens": output_total},
                          "provenance": "unknown", "unpricedRequests": max(1, request_total or 0),
                          "estimatedRequests": 0}
                if public_model is not None:
                    values["model"] = public_model
                    values["tokenMix"]["cacheReadTokens"] = old_mix.get("cacheReadTokens", 0) + cached
                if request_total is not None:
                    values["requests"] = request_total
                if any(values.get(k, 0) > MAX_COUNTER for k in ["tokens", "requests", "unpricedRequests"]):
                    raise ValueError("runtime counter aggregate exceeds its safety limit")
                events[event_id] = {"id": event_id, "provider": "localInference", "day": day,
                                    "observedAt": now - REFERENCE_EPOCH, "values": values}
        previous[source] = row
    # A disappeared series may reappear after a restart; rebaseline it rather than count a negative delta.
    state["counters"] = {key: previous[key] for key in counters}
    cutoff = datetime.datetime.fromtimestamp(now - 364 * 86400, datetime.timezone.utc).strftime("%Y-%m-%d")
    retained = sorted((event for event in events.values() if event["day"] >= cutoff), key=lambda event: (event["day"], event["id"]))
    if len(retained) > 100_000:
        raise ValueError("numeric history exceeds its safety limit")
    state["events"] = retained
    state["excludedRecords"] = excluded
    state["lastSampleAt"] = now
    state["processStartTime"] = process_start
    state["coverage"] = "Prospective deltas only; resets, long gaps, and UTC day rollover rebaseline."
    published = max(now - REFERENCE_EPOCH, state.get("pending", {}).get("publishedAt", -REFERENCE_EPOCH) + 0.001)
    state["pending"] = {"schemaVersion": 1, "workspaceID": workspace["id"], "deviceID": config["deviceID"],
                        "deviceName": config["deviceName"], "publishedAt": published,
                        "events": retained, "accountDays": [], "excludedRecords": excluded}
    schema.validate_publication(state["pending"], workspace["id"].upper(), config["deviceID"].upper(), config["deviceName"], now)


def request_json(config, path, value=None, post=False):
    validate_config(config)
    url = config["endpoint"].rstrip("/") + path
    request = urllib.request.Request(url, data=json.dumps(value, allow_nan=False).encode() if post else None,
                                     headers={"Authorization": "Bearer " + config["credential"], "Content-Type": "application/json"},
                                     method="POST" if post else "GET")
    with urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect).open(request, timeout=30) as response:
        data = response.read(128 * 1024 * 1024 + 1)
    if len(data) > 128 * 1024 * 1024:
        raise ValueError("hub response exceeds its safety limit")
    return schema.parse_json(data)


def validate_endpoint(value, metrics=False):
    parts = urllib.parse.urlsplit(value)
    loopback = parts.hostname in ["127.0.0.1", "localhost", "::1"]
    permitted = parts.scheme == "http" and loopback
    if not metrics:
        permitted = permitted or (parts.scheme == "https" and (parts.hostname or "").endswith(".ts.net"))
    if not permitted or parts.username or parts.password or parts.query or parts.fragment or not parts.hostname:
        raise ValueError("unsupported private endpoint")
    if (metrics and parts.path != "/metrics") or (not metrics and parts.path not in ["", "/"]):
        raise ValueError("unsupported private endpoint path")
    if parts.port is not None and not 1 <= parts.port <= 65535:
        raise ValueError("unsupported private endpoint port")


def validate_config(config):
    if type(config) is not dict:
        raise ValueError("invalid connection configuration")
    validate_endpoint(config["endpoint"])
    uuid.UUID(config["deviceID"])
    if config.get("workspaceID"):
        uuid.UUID(config["workspaceID"])
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", config["credential"]):
        raise ValueError("invalid connection credential")
    name = config["deviceName"]
    if not 1 <= len(name.encode()) <= 80 or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in name):
        raise ValueError("invalid device name")


def validate_state(state, config, now):
    if type(state) is not dict or state.get("deviceID") != config["deviceID"]:
        raise ValueError("invalid numeric state identity")
    schema.validate_workspace(state["workspace"])
    if "pending" in state:
        schema.validate_publication(state["pending"], state["workspace"]["id"].upper(),
                                    config["deviceID"].upper(), config["deviceName"], now)
        if state.get("events") != state["pending"]["events"]:
            raise ValueError("numeric outbox history changed")
    counters = state.get("counters")
    if type(counters) is not dict or len(counters) > 128:
        raise ValueError("invalid numeric counter state")
    for source, row in counters.items():
        if not re.fullmatch(r"[0-9a-f]{64}", source) or type(row) is not dict:
            raise ValueError("invalid numeric source identity")
        if not {"prompt_tokens", "generation_tokens"} <= row.keys() <= {
                "prompt_tokens", "generation_tokens", "prompt_tokens_cached", "request_success", "public_model"}:
            raise ValueError("invalid numeric source counters")
        if "public_model" in row:
            validate_model_mapping("verified-runtime-alias", row["public_model"])
        for key, value in row.items():
            if key == "public_model":
                continue
            if type(value) is not int or not 0 <= value <= MAX_COUNTER:
                raise ValueError("invalid numeric source counter")
    if "lastSampleAt" in state and (type(state["lastSampleAt"]) not in (float, int)
                                    or not math.isfinite(state["lastSampleAt"]) or state["lastSampleAt"] < 0):
        raise ValueError("invalid numeric sample clock")


def collect_once(config, state_path, metrics_url, interval=180, model_alias=None, public_model=None):
    validate_config(config)
    validate_endpoint(metrics_url, metrics=True)
    validate_model_mapping(model_alias, public_model)
    state = read_private(state_path) if state_path.exists() else None
    workspace = request_json(config, "/v1/workspace") if state is None else state["workspace"]
    if config.get("workspaceID") and workspace["id"].lower() != config["workspaceID"].lower():
        raise ValueError("workspace identity changed")
    if state is None:
        state = {"workspace": workspace, "deviceID": config["deviceID"], "events": [], "counters": {}, "excludedRecords": 0}
    else:
        validate_state(state, config, time.time())
    schema.validate_workspace(workspace)
    endpoint_hash = hashlib.sha256(metrics_url.encode()).hexdigest()
    if state.get("metricsEndpointHash", endpoint_hash) != endpoint_hash:
        raise ValueError("runtime endpoint changed; use a separate numeric state directory")
    state["metricsEndpointHash"] = endpoint_hash
    # Cache enrollment before a metrics outage so the next offline sample can establish a baseline.
    save_private(state_path, state)
    # A runtime outage must not block delivery of an already durable numeric publication.
    sampled = False
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect).open(metrics_url, timeout=10) as response:
            raw = response.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            raise ValueError("runtime metrics exceed their safety limit")
        candidate = copy.deepcopy(state)
        sample(candidate, workspace, config, parse_metrics(raw.decode(), model_alias, public_model),
               time.time(), maximum_gap=2 * interval)
        save_private(state_path, candidate)  # durable outbox before upload or counter advancement
        state = candidate
        sampled = True
    except Exception:
        if "pending" not in state:
            raise
    result = request_json(config, "/v1/exchange", state["pending"], post=True)
    if result.get("workspace") != workspace or result.get("publicationSucceeded") is not True:
        raise ValueError("hub did not acknowledge the pinned workspace publication")
    acknowledged = next((item for item in result.get("publications", [])
                         if item.get("deviceID", "").upper() == config["deviceID"].upper()), None)
    if acknowledged != state["pending"]:
        raise ValueError("hub did not return the exact numeric publication")
    state["lastSyncedAt"] = time.time()
    save_private(state_path, state)
    return {"sampleSucceeded": sampled, "publicationSucceeded": True,
            "excludedRecords": state["excludedRecords"], "events": len(state["events"])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--metrics-url", default="http://127.0.0.1:11434/metrics")
    parser.add_argument("--interval", type=int, default=180)
    parser.add_argument("--model-alias", help="Verified served model_name label; never sent to the hub")
    parser.add_argument("--public-model", help="Verified canonical public model ID for that alias")
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    config = read_private(args.config)
    validate_config(config)
    validate_endpoint(args.metrics_url, metrics=True)
    validate_model_mapping(args.model_alias, args.public_model)
    if not 30 <= args.interval <= 86400:
        parser.error("interval must be between 30 and 86400 seconds")
    directory = Path(args.state_dir).absolute()
    ensure_directory(directory)
    lock_fd = os.open(directory / "collector.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    with os.fdopen(lock_fd, "w") as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
            parser.error("collector lock must be private and regular")
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        while True:
            try:
                config = read_private(args.config)
                result = collect_once(config, directory / "numeric-state.json", args.metrics_url, interval=args.interval,
                                      model_alias=args.model_alias, public_model=args.public_model)
                print(json.dumps(result, separators=(",", ":")), flush=True)
                if args.once and not result["sampleSucceeded"]:
                    return 2
            except Exception as error:
                print("Local runtime collection pending; numeric state retained (" + type(error).__name__ + ").", flush=True)
                if args.once:
                    return 1
            if args.once:
                return 0
            time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
