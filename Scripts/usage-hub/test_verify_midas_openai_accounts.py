"""Verify synthetic, private account caches; never use real accounts or provider files."""

import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "verify_midas_openai_accounts.py"
SPEC = importlib.util.spec_from_file_location("verify_midas_openai_accounts", SCRIPT)
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class OpenAIAccountReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="midas-account-receipt-")
        self.home = Path(self.temporary.name).resolve()
        self.support = self.home / "Library/Application Support"
        self.now = dt.datetime(2026, 10, 17, 20, 0, tzinfo=dt.timezone.utc)
        self.apple_now = self.now.timestamp() - VERIFIER.APPLE_EPOCH
        self.emails = ["first@synthetic.test", "second@synthetic.test"]
        self.ids = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"]
        self.metadata = {"version": 3, "accounts": [
            {"id": identifier, "email": email, "workspaceAccountID": "workspace-" + str(index),
             "authFingerprint": "fingerprint-" + str(index), "managedHomePath": "/never/open/this/home"}
            for index, (identifier, email) in enumerate(zip(self.ids, self.emails))]}
        self.snapshots = {"version": 1, "records": [
            {"id": email, "accountIdentity": {
                "normalizedEmail": email, "storedAccountID": self.ids[index],
                "workspaceAccountID": "workspace-" + str(index), "authFingerprint": "fingerprint-" + str(index)},
             "snapshot": {"identity": {"providerID": "codex", "accountEmail": email}, "accountEmail": email,
                          "primary": {"usedPercent": 10 + index, "windowMinutes": 300},
                          "secondary": {"usedPercent": 30 + index, "windowMinutes": 10080},
                          "updatedAt": self.apple_now}}
            for index, email in enumerate(self.emails)]}
        self.cloud = {"signature": ";".join(email + "|workspace-" + str(index) + "|" + self.ids[index]
                                           for index, email in enumerate(self.emails)),
                      "accounts": {email: {"fetchedAt": self.apple_now, "statsAsOf": "2026-10-17T19:00:00Z",
                                           "days": [{"date": "2026-10-17", "tokens": 1000 + index * 500}],
                                           "models": [], "modelUnits": "credits"}
                                   for index, email in enumerate(self.emails)}}
        self.flush()
        self.configuration = mock.patch.object(VERIFIER, "read_configuration", return_value={
            "trackAllAccounts": True, "cloudUsageEnabled": True})
        self.configuration.start()
        self.addCleanup(self.configuration.stop)
        self.addCleanup(self.temporary.cleanup)

    def write(self, relative, value):
        path = self.support / relative
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_text(json.dumps(value))
        path.chmod(0o600)
        return path

    def flush(self):
        self.write("Midas/managed-codex-accounts.json", self.metadata)
        self.write("Midas/codex-account-snapshots.json", self.snapshots)
        self.write("CodexBar/midas-cloud-usage.json", self.cloud)

    def receipt(self):
        return VERIFIER.make_receipt(self.home, self.emails, now=self.now, alternate_home=True)

    def test_two_accounts_have_distinct_correct_identity_matched_data(self):
        result = self.receipt()
        self.assertTrue(result["allExpectedAccountsReady"])
        self.assertEqual([row["quota"]["primary"]["usedPercent"] for row in result["accounts"]], [10, 11])
        self.assertEqual([row["cloud"]["reported30DayTokens"] for row in result["accounts"]], [1000, 1500])
        self.assertTrue(all(row["cloud"]["identityMatchedByCacheKey"] for row in result["accounts"]))
        output = json.dumps(result)
        for secret in ("workspace-", "fingerprint-", self.ids[0], "/never/open", "accessToken"):
            self.assertNotIn(secret, output)

    def test_missing_second_account_cannot_borrow_first_rows(self):
        self.metadata["accounts"] = self.metadata["accounts"][:1]
        self.flush()
        result = self.receipt()
        self.assertFalse(result["allExpectedAccountsReady"])
        self.assertTrue(result["accounts"][0]["ready"])
        self.assertFalse(result["accounts"][1]["managedMetadataPresent"])
        self.assertFalse(result["accounts"][1]["quota"]["identityMatched"])
        self.assertIsNone(result["accounts"][1]["cloud"]["reported30DayTokens"])

    def test_crossed_snapshot_identity_is_rejected(self):
        self.snapshots["records"][1]["snapshot"]["identity"]["accountEmail"] = self.emails[0]
        self.flush()
        result = self.receipt()
        self.assertFalse(result["allExpectedAccountsReady"])
        self.assertEqual(result["accounts"][1]["quota"]["error"], "cached_identity_mismatch")
        self.assertIsNone(result["accounts"][1]["quota"]["primary"])

    def test_crossed_metadata_binding_and_cloud_signature_are_rejected(self):
        for field in ("storedAccountID", "workspaceAccountID"):
            with self.subTest(field=field):
                original = self.snapshots["records"][1]["accountIdentity"][field]
                self.snapshots["records"][1]["accountIdentity"][field] = "different-account"
                self.flush()
                self.assertFalse(self.receipt()["accounts"][1]["ready"])
                self.snapshots["records"][1]["accountIdentity"][field] = original
        self.cloud["signature"] = self.emails[1] + "|workspace-1|" + self.ids[0]
        self.flush()
        self.assertFalse(self.receipt()["accounts"][1]["cloud"]["identityMatchedByCacheKey"])
        self.cloud["signature"] = self.emails[1] + "|different-workspace|" + self.ids[1]
        self.flush()
        self.assertFalse(self.receipt()["accounts"][1]["cloud"]["identityMatchedByCacheKey"])

    def test_oauth_fingerprint_rotation_preserves_stable_account_binding(self):
        for record in self.snapshots["records"]:
            record["accountIdentity"]["authFingerprint"] = "rotated-runtime-fingerprint"
        self.flush()
        result = self.receipt()
        self.assertTrue(result["allExpectedAccountsReady"])
        self.assertTrue(all(row["quota"]["credentialFingerprintChanged"] for row in result["accounts"]))
        self.assertNotIn("rotated-runtime-fingerprint", json.dumps(result))
        record = self.snapshots["records"][1]
        for container, key, crossed in (
                (record["accountIdentity"], "storedAccountID", self.ids[0]),
                (record["accountIdentity"], "workspaceAccountID", "different-workspace"),
                (record["accountIdentity"], "normalizedEmail", self.emails[0]),
                (record["snapshot"], "accountEmail", self.emails[0]),
                (record["snapshot"]["identity"], "accountEmail", self.emails[0])):
            with self.subTest(key=key):
                original = container[key]
                container[key] = crossed
                self.flush()
                self.assertFalse(self.receipt()["accounts"][1]["ready"])
                container[key] = original

    def test_stale_missing_and_unknown_cloud_are_not_ready(self):
        account = self.cloud["accounts"][self.emails[1]]
        account["fetchedAt"] = self.apple_now - 901
        self.flush()
        self.assertFalse(self.receipt()["accounts"][1]["cloud"]["isFresh"])
        account["fetchedAt"] = self.apple_now
        account["days"] = []
        self.flush()
        self.assertIsNone(self.receipt()["accounts"][1]["cloud"]["reported30DayTokens"])
        del self.cloud["accounts"][self.emails[1]]
        self.flush()
        self.assertFalse(self.receipt()["allExpectedAccountsReady"])

    def test_quota_staleness_errors_and_disabled_configuration_fail_ready(self):
        self.snapshots["records"][1]["snapshot"]["updatedAt"] = self.apple_now - 901
        self.flush()
        self.assertFalse(self.receipt()["allExpectedAccountsReady"])
        self.snapshots["records"][1]["snapshot"]["updatedAt"] = self.apple_now
        self.snapshots["records"][1]["error"] = "do not echo secret accessToken credential"
        self.flush()
        receipt = self.receipt()
        self.assertFalse(receipt["allExpectedAccountsReady"])
        self.assertNotIn("secret", json.dumps(receipt))
        self.snapshots["records"][1].pop("error")
        self.flush()
        with mock.patch.object(VERIFIER, "read_configuration", return_value={
                "trackAllAccounts": False, "cloudUsageEnabled": True}):
            self.assertFalse(self.receipt()["allExpectedAccountsReady"])

    def test_midas_cloud_cache_supported_and_newest_matching_snapshot_used(self):
        self.write("Midas/midas-cloud-usage.json", self.cloud)
        (self.support / "CodexBar/midas-cloud-usage.json").unlink()
        self.assertTrue(self.receipt()["allExpectedAccountsReady"])

    def test_unsafe_permissions_symlink_owner_and_oversize_are_rejected(self):
        path = self.support / "Midas/codex-account-snapshots.json"
        path.chmod(0o640)
        self.assertIn("quotaSnapshots:not_private_owned_file", self.receipt()["issues"])
        path.chmod(0o600)
        with mock.patch.object(VERIFIER.os, "getuid", return_value=os.getuid() + 1):
            self.assertFalse(self.receipt()["allExpectedAccountsReady"])
        real = path.with_suffix(".saved")
        path.rename(real)
        path.symlink_to(real)
        self.assertIn("quotaSnapshots:unsafe_or_unreadable_path", self.receipt()["issues"])
        path.unlink()
        real.rename(path)
        with path.open("wb") as output:
            output.truncate(VERIFIER.MAX_FILE_BYTES + 1)
        self.assertIn("quotaSnapshots:file_too_large", self.receipt()["issues"])

    def test_reader_never_opens_authentication_logs_or_network(self):
        real_open = VERIFIER.os.open
        opened = []
        def guarded_open(path, *args, **kwargs):
            opened.append(str(path))
            self.assertNotIn("auth.json", str(path))
            self.assertNotIn("sessions", str(path))
            self.assertNotIn("credential", str(path))
            return real_open(path, *args, **kwargs)
        with mock.patch.object(VERIFIER.os, "open", side_effect=guarded_open), mock.patch(
                "socket.socket", side_effect=AssertionError("No network permitted")):
            self.assertTrue(self.receipt()["allExpectedAccountsReady"])
        self.assertEqual(set(name for name in opened if name.endswith(".json")), {
            "managed-codex-accounts.json", "codex-account-snapshots.json", "midas-cloud-usage.json"})

    def test_defaults_reads_only_two_expected_keys(self):
        self.configuration.stop()
        calls = []
        def defaults(command, **kwargs):
            calls.append(command)
            self.assertEqual(command[:3], ["/usr/bin/defaults", "read", "com.designprism.midas.debug"])
            self.assertIn(command[3], ("midasTrackAllAccounts", "midasCloudUsageEnabled"))
            return subprocess.CompletedProcess(command, 0, stdout="1\n", stderr="")
        with mock.patch.object(VERIFIER.subprocess, "run", side_effect=defaults):
            self.assertEqual(VERIFIER.read_configuration(self.home), {
                "trackAllAccounts": True, "cloudUsageEnabled": True})
        self.assertEqual(len(calls), 2)

    def test_cli_prints_one_final_json_and_exit_matches_readiness(self):
        for ready in (False, True):
            with self.subTest(ready=ready), mock.patch.object(VERIFIER, "make_receipt", return_value={
                    "allExpectedAccountsReady": ready}), contextlib.redirect_stdout(io.StringIO()) as output:
                status = VERIFIER.main(["--expected-email", self.emails[0], "--home", str(self.home)])
                self.assertEqual(status, 0 if ready else 2)
                self.assertEqual(len(output.getvalue().splitlines()), 1)
                self.assertEqual(json.loads(output.getvalue())["allExpectedAccountsReady"], ready)

    def test_wait_is_bounded_and_emits_only_the_final_receipt(self):
        with (
                mock.patch.object(VERIFIER, "make_receipt", return_value={"allExpectedAccountsReady": False}),
                mock.patch.object(VERIFIER.time, "monotonic", side_effect=[0, 0, 0, 2, 2, 3]),
                mock.patch.object(VERIFIER.time, "sleep") as sleep,
                contextlib.redirect_stdout(io.StringIO()) as output):
            status = VERIFIER.main(["--expected-email", self.emails[0], "--wait", "3", "--home", str(self.home)])
        self.assertEqual(status, 2)
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [2, 1])
        self.assertEqual(len(output.getvalue().splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
