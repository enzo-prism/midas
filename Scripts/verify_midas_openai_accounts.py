#!/usr/bin/env python3
"""Print a bounded, read-only receipt for explicitly requested Midas account caches.

This checks persisted data and configuration, not pixels or a live provider response.
It never opens authentication files, Keychain items, provider logs, or network connections.
"""

import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import time

MAX_FILE_BYTES = 16 * 1024 * 1024
APPLE_EPOCH = 978307200
FRESH_SECONDS = 15 * 60
MAX_COUNT = (1 << 63) - 1
UTC = dt.timezone.utc


class VerificationError(Exception):
    """Only fixed, non-sensitive error codes may leave the reader."""


def normalize_email(value):
    return value.strip().lower() if isinstance(value, str) else None


def normalized(value):
    return value.strip().lower() if isinstance(value, str) and value.strip() else None


def read_private_json(path):
    """Walk without following symlinks, then bound and validate the opened file."""
    path = Path(path).absolute()
    parent = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY)
    try:
        try:
            for component in path.parts[1:-1]:
                child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                os.close(parent)
                parent = child
            descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        except FileNotFoundError:
            return None
        except OSError:
            raise VerificationError("unsafe_or_unreadable_path") from None
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                raise VerificationError("not_regular_file")
            if metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
                raise VerificationError("not_private_owned_file")
            if metadata.st_size > MAX_FILE_BYTES:
                raise VerificationError("file_too_large")
            with os.fdopen(descriptor, "rb", closefd=False) as source:
                data = source.read(MAX_FILE_BYTES + 1)
            if len(data) > MAX_FILE_BYTES:
                raise VerificationError("file_too_large")
            try:
                result = json.loads(data, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
            except (ValueError, UnicodeError, RecursionError):
                raise VerificationError("invalid_json") from None
            if not isinstance(result, dict):
                raise VerificationError("invalid_json_shape")
            return result
        finally:
            os.close(descriptor)
    finally:
        os.close(parent)


def read_configuration(home, alternate_home=False):
    domain = str(home / "Library/Preferences/com.designprism.midas.debug.plist") if alternate_home else (
        "com.designprism.midas.debug")
    values = {}
    for label, key in (("trackAllAccounts", "midasTrackAllAccounts"),
                       ("cloudUsageEnabled", "midasCloudUsageEnabled")):
        try:
            result = subprocess.run(["/usr/bin/defaults", "read", domain, key],
                                    capture_output=True, text=True, timeout=5, check=False)
            value = result.stdout.strip().lower() if result.returncode == 0 else ""
            values[label] = True if value in ("1", "true", "yes") else (
                False if value in ("0", "false", "no") else None)
        except (OSError, subprocess.SubprocessError):
            values[label] = None
    return values


def apple_date(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return None
    try:
        return dt.datetime.fromtimestamp(value + APPLE_EPOCH, UTC)
    except (OverflowError, OSError, ValueError):
        return None


def date_fields(value, now):
    stamp = apple_date(value)
    age = (now - stamp).total_seconds() if stamp else None
    return {"fetchedAtUTC": stamp.isoformat() if stamp else None,
            "ageSeconds": round(age, 3) if age is not None else None,
            "isFresh": age is not None and -60 <= age <= FRESH_SECONDS}


def quota_window(value):
    if not isinstance(value, dict):
        return None
    percent = value.get("usedPercent")
    if isinstance(percent, bool) or not isinstance(percent, (int, float)) or not math.isfinite(percent) or percent < 0:
        return None
    minutes = value.get("windowMinutes")
    reset = apple_date(value.get("resetsAt"))
    return {"usedPercent": percent,
            "windowMinutes": minutes if isinstance(minutes, int) and not isinstance(minutes, bool) and minutes >= 0 else None,
            "resetsAtUTC": reset.isoformat() if reset else None}


def matching_metadata(record, email, metadata):
    identity = record.get("accountIdentity")
    snapshot = record.get("snapshot")
    if not isinstance(identity, dict) or not isinstance(snapshot, dict):
        return None
    provider_identity = snapshot.get("identity")
    if not isinstance(provider_identity, dict) or provider_identity.get("providerID") != "codex":
        return None
    if normalize_email(identity.get("normalizedEmail")) != email or (
            normalize_email(provider_identity.get("accountEmail")) != email) or (
            normalize_email(snapshot.get("accountEmail")) != email):
        return None
    for account in metadata:
        if normalize_email(account.get("email")) != email:
            continue
        account_id = normalized(account.get("id"))
        if not account_id or normalized(identity.get("storedAccountID")) != account_id:
            continue
        workspace = normalized(account.get("workspaceAccountID")) or normalized(account.get("providerAccountID"))
        cached_workspace = normalized(identity.get("workspaceAccountID"))
        if workspace != cached_workspace:
            continue
        # OAuth rotation changes the runtime credential fingerprint; saved account metadata can lag.
        # Stable account UUID, compatible workspace, and all three cached emails bind this receipt.
        return account
    return None


def cloud_key_matches(cache, record, account):
    key = record.get("id")
    signature = cache.get("signature")
    if not isinstance(key, str) or not isinstance(signature, str):
        return False
    identity = record.get("accountIdentity", {})
    workspace = normalized(identity.get("workspaceAccountID")) or normalized(account.get("workspaceAccountID")) or (
        normalized(account.get("providerAccountID")))
    for entry in signature.split(";"):
        parts = entry.split("|")
        if len(parts) == 3 and parts[0] == key and normalized(parts[2]) == normalized(account.get("id")):
            return workspace is None or normalized(parts[1]) == workspace
    return False


def cloud_summary(value, now):
    summary = {"present": isinstance(value, dict), "identityMatchedByCacheKey": False,
               "reported30DayTokens": None, "dayCount": 0, "statsAsOf": None, **date_fields(None, now)}
    if not isinstance(value, dict):
        return summary
    summary.update(date_fields(value.get("fetchedAt"), now))
    stats = value.get("statsAsOf")
    if isinstance(stats, str) and len(stats) <= 80:
        try:
            dt.datetime.fromisoformat(stats.replace("Z", "+00:00"))
            summary["statsAsOf"] = stats
        except ValueError:
            pass
    days = value.get("days")
    if not isinstance(days, list):
        return summary
    start = (now.date() - dt.timedelta(days=29)).isoformat()
    end = now.date().isoformat()
    seen = set()
    total = 0
    for row in days:
        if not isinstance(row, dict):
            return summary
        day, count = row.get("date"), row.get("tokens")
        try:
            valid_day = isinstance(day, str) and dt.date.fromisoformat(day).isoformat() == day
        except ValueError:
            valid_day = False
        if not valid_day or day in seen or isinstance(count, bool) or not isinstance(count, int) or not 0 <= count <= MAX_COUNT:
            return summary
        seen.add(day)
        if start <= day <= end:
            total += count
            if total > MAX_COUNT:
                return summary
            summary["dayCount"] += 1
    if summary["dayCount"]:
        summary["reported30DayTokens"] = total
    return summary


def make_receipt(home, expected_emails, now=None, alternate_home=False):
    now = now or dt.datetime.now(UTC)
    support = Path(home) / "Library/Application Support"
    files = (("managedAccounts", support / "Midas/managed-codex-accounts.json"),
             ("quotaSnapshots", support / "Midas/codex-account-snapshots.json"),
             ("midasCloud", support / "Midas/midas-cloud-usage.json"),
             ("legacyCloud", support / "CodexBar/midas-cloud-usage.json"))
    loaded, issues = {}, []
    for label, path in files:
        try:
            loaded[label] = read_private_json(path) or {}
        except VerificationError as error:
            loaded[label] = {}
            issues.append(label + ":" + str(error))
        except OSError:
            loaded[label] = {}
            issues.append(label + ":unreadable_cache")
    metadata = loaded["managedAccounts"].get("accounts", [])
    records = loaded["quotaSnapshots"].get("records", [])
    if not isinstance(metadata, list) or not all(isinstance(item, dict) for item in metadata):
        metadata = []
        issues.append("managedAccounts:invalid_accounts")
    if not isinstance(records, list) or not all(isinstance(item, dict) for item in records):
        records = []
        issues.append("quotaSnapshots:invalid_records")
    configuration = read_configuration(Path(home), alternate_home)
    accounts = []
    for email in expected_emails:
        quota = {"present": False, "identityMatched": False, "hasError": False, "error": None,
                 "credentialFingerprintChanged": None, "primary": None, "secondary": None,
                 **date_fields(None, now)}
        cloud = cloud_summary(None, now)
        matches = [(record, matching_metadata(record, email, metadata)) for record in records]
        matches = [(record, account) for record, account in matches if account is not None]
        if matches:
            record, account = max(matches, key=lambda pair: apple_date(pair[0]["snapshot"].get("updatedAt")) or (
                dt.datetime.min.replace(tzinfo=UTC)))
            snapshot = record["snapshot"]
            has_error = record.get("error") is not None
            quota = {"present": True, "identityMatched": True, "hasError": has_error,
                     "error": "cached_refresh_error" if has_error else None,
                     "credentialFingerprintChanged": normalized(record["accountIdentity"].get("authFingerprint")) != (
                         normalized(account.get("authFingerprint"))),
                     "primary": quota_window(snapshot.get("primary")),
                     "secondary": quota_window(snapshot.get("secondary")),
                     **date_fields(snapshot.get("updatedAt"), now)}
            candidates = []
            for label in ("midasCloud", "legacyCloud"):
                cache = loaded[label]
                rows = cache.get("accounts")
                if isinstance(rows, dict) and cloud_key_matches(cache, record, account):
                    candidate = cloud_summary(rows.get(record.get("id")), now)
                    candidate["identityMatchedByCacheKey"] = candidate["present"]
                    candidates.append(candidate)
            if candidates:
                cloud = max(candidates, key=lambda item: item["fetchedAtUTC"] or "")
        else:
            quota["present"] = any(normalize_email(record.get("accountIdentity", {}).get("normalizedEmail")) == email
                                   for record in records if isinstance(record.get("accountIdentity"), dict))
            if quota["present"]:
                quota["error"] = "cached_identity_mismatch"
        present = sum(normalize_email(account.get("email")) == email for account in metadata)
        ready = bool(present and quota["identityMatched"] and not quota["hasError"] and quota["isFresh"] and
                     (quota["primary"] or quota["secondary"]) and cloud["identityMatchedByCacheKey"] and
                     cloud["isFresh"] and cloud["reported30DayTokens"] is not None and cloud["statsAsOf"] is not None)
        accounts.append({"email": email, "managedMetadataPresent": bool(present), "managedAccountCount": present,
                         "quota": quota, "cloud": cloud, "ready": ready})
    return {"schemaVersion": 1, "verifiedAtUTC": now.isoformat(), "configuration": configuration,
            "accounts": accounts, "issues": issues,
            "allExpectedAccountsReady": bool(accounts) and not issues and all(row["ready"] for row in accounts) and
            configuration.get("trackAllAccounts") is True and configuration.get("cloudUsageEnabled") is True}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-email", action="append", required=True)
    parser.add_argument("--wait", type=int, default=0)
    parser.add_argument("--home", type=Path, help="Alternate home for bounded fixture verification")
    arguments = parser.parse_args(argv)
    if not 0 <= arguments.wait <= 180:
        parser.error("--wait must be between 0 and 180")
    emails = list(dict.fromkeys(normalize_email(value) for value in arguments.expected_email))
    if not emails or len(emails) > 20 or any(not value or len(value) > 254 or "@" not in value for value in emails):
        parser.error("Provide between 1 and 20 valid expected email addresses")
    deadline = time.monotonic() + arguments.wait
    while True:
        receipt = make_receipt(arguments.home or Path.home(), emails, alternate_home=arguments.home is not None)
        if receipt["allExpectedAccountsReady"] or time.monotonic() >= deadline:
            print(json.dumps(receipt, separators=(",", ":"), allow_nan=False))
            return 0 if receipt["allExpectedAccountsReady"] else 2
        time.sleep(min(2, max(0, deadline - time.monotonic())))


if __name__ == "__main__":
    raise SystemExit(main())
