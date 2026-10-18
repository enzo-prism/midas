"""Print a small numeric sync receipt without reading credentials or provider logs."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--wait", type=int, default=0, help="Wait up to this many seconds for all three devices")
args = parser.parse_args()
if not 0 <= args.wait <= 600:
    parser.error("--wait must be between 0 and 600")
cache = Path.home() / "Library/Application Support/Midas/usage-sync/hub-state.json"
binary = Path.home() / "Applications/Midas Tailscale Preview.app/Contents/MacOS/Midas"
deadline = time.monotonic() + args.wait
last_stamp = None
publications = []
issue = None
expected_devices = {"Mac mini", "MacBook Pro", "Spark local runtime"}
while True:
    try:
        for component in (cache, *cache.parents):
            if component.is_symlink():
                raise ValueError("Private sync cache path contains a symbolic link")
        metadata = cache.stat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
            raise ValueError("Sync cache is not a private owned regular file")
        if metadata.st_size > 128 * 1024 * 1024:
            raise ValueError("Sync cache exceeds the verification limit")
        if metadata.st_mtime_ns != last_stamp:
            last_stamp = metadata.st_mtime_ns
            publications = json.loads(cache.read_bytes()).get("publications", [])
        if {p.get("deviceName") for p in publications} >= expected_devices:
            break
    except (OSError, ValueError, TypeError) as error:
        issue = type(error).__name__
    if time.monotonic() >= deadline:
        break
    time.sleep(2)

ordered = sorted(publications, key=lambda p: p["deviceID"])
def publication_digest(publication):
    return hashlib.sha256(json.dumps(
        publication, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode()).hexdigest()

configuration = {}
for label, key in (("period", "midasSpendPeriodSelection"), ("combined", "midasUsageSyncIncludeTotals"),
                   ("transport", "midasUsageSyncTransport")):
    result = subprocess.run(["/usr/bin/defaults", "read", "com.designprism.midas.debug", key],
                            capture_output=True, text=True)
    configuration[label] = result.stdout.strip() if result.returncode == 0 else None
receipt = {
    "receivedDevices": [{"name": p["deviceName"], "publishedAtAppleEpoch": p["publishedAt"],
                         "events": len(p["events"]), "accountDays": len(p["accountDays"]),
                         "publicationSHA256": publication_digest(p)} for p in ordered],
    "publicationSetSHA256": hashlib.sha256(json.dumps(
        ordered, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest(),
    "appBinarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest() if binary.is_file() else None,
    "allThreeDevicesReceived": {p["deviceName"] for p in ordered} >= expected_devices,
    "configuration": configuration,
}
if issue and not ordered:
    receipt["verificationIssue"] = issue
print(json.dumps(receipt, separators=(",", ":")))
raise SystemExit(0 if receipt["allThreeDevicesReceived"] else 2)
