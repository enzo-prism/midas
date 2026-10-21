#!/usr/bin/env python3
"""Compatibility entrypoint for the production-aware Midas sync doctor.

A cached list of names is never proof of convergence. The default path is the
stable Midas app; optional fixture paths are accepted only by this local script.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import sys
import time


def load_manager():
    source = Path(__file__).resolve().parent / "usage-hub/midas_sync_manage.py"
    spec = importlib.util.spec_from_file_location("midas_sync_manage", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wait", type=int, default=0, help="Wait up to 600 seconds for a fresh applied checkpoint")
    parser.add_argument("--max-age", type=int, default=300)
    parser.add_argument("--root", type=Path, default=Path.home() / "Library/Application Support/Midas")
    parser.add_argument("--app", type=Path, default=Path("/Applications/Midas.app"))
    parser.add_argument("--offline", action="store_true", help="Inspect local receipt without claiming online health")
    parser.add_argument("--require-peer-receipts", action="store_true")
    parser.add_argument("--required-device-id", action="append", default=[], help="Enrolled UUID, repeat for each Mac to prove peer convergence")
    args = parser.parse_args()
    if not 0 <= args.wait <= 600 or not 1 <= args.max_age <= 3600:
        parser.error("wait must be 0...600; max-age must be 1...3600")
    manager = load_manager()
    deadline = time.monotonic() + args.wait
    while True:
        try:
            report = manager.doctor(args.root, online=not args.offline, app_path=args.app, max_age=args.max_age, required_device_ids=args.required_device_id or None)
        except manager.ManageError as error:
            report = {"schemaVersion": 1, "status": "needs_attention", "code": error.code}
        except Exception:
            report = {"schemaVersion": 1, "status": "needs_attention", "code": "local_state_unavailable"}
        healthy = report["status"] == "healthy" and (not args.require_peer_receipts or report.get("requiredDevicesCaughtUp") is True)
        if healthy or time.monotonic() >= deadline or args.offline:
            break
        time.sleep(min(2, max(0, deadline - time.monotonic())))
    print(json.dumps(report, sort_keys=True, separators=(",", ":"), allow_nan=False))
    return 0 if healthy else 2


if __name__ == "__main__":
    raise SystemExit(main())
