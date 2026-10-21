"""Isolated lifecycle and doctor fixtures. No real launchd, accounts, or network devices."""
import copy
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest import mock

import midas_sync_manage as manage
import midas_usage_hub as hub


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="midas-manager-tests-")
        self.root = Path(self.temp.name).resolve()
        self.root.chmod(0o700)
        self.support = self.root / "Midas"
        self.support.mkdir(mode=0o700)
        sync = self.support / "usage-sync"
        sync.mkdir(mode=0o700)
        self.device = str(uuid.uuid4()).upper()
        self.peer = str(uuid.uuid4()).upper()
        self.workspace = str(uuid.uuid4()).upper()
        self.connection = {"endpoint": "http://127.0.0.1:8766", "deviceID": self.device,
                           "deviceName": "Private fixture label", "workspaceID": self.workspace,
                           "credential": "PRIVATE-FIXTURE-" + "a" * 48}
        self.write_json(sync / "hub-connection.json", self.connection)
        self.remote = {"protocolVersion": 2, "hubVersion": "fixture", "workspace": {"id": self.workspace},
                       "checkedAt": manage.now(),
                       "devices": [{"deviceID": self.device, "revision": 4, "eventCount": 8, "accountDayCount": 0, "supportsReceipts": True},
                                   {"deviceID": self.peer, "revision": 3, "eventCount": 9, "accountDayCount": 0, "supportsReceipts": True}],
                       "receipts": [{"deviceID": self.device, "checkedAt": manage.now(), "appliedRevisions": {self.device: 4, self.peer: 3}}, {"deviceID": self.peer, "checkedAt": manage.now(),
                                     "appliedRevisions": {self.device: 4, self.peer: 3}}]}
        self.app = self.root / "Midas.app"
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.designprism.midas", "CFBundleShortVersionString": "fixture", "CFBundleVersion": "131"}))

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def write_json(path, value):
        path.write_bytes(manage.canonical(value))
        path.chmod(0o600)

    def receipt(self, **overrides):
        result = {"outboxPending": False, "lastPublishedAt": manage.now(), "lastReceivedAt": manage.now(),
                  "syncState": {"checkedAt": manage.now(), "acceptedLocalRevision": 4,
                                "appliedRevisions": {self.device: 4, self.peer: 3}}}
        result.update(overrides)
        self.write_json(self.support / "usage-sync/sync-receipt.json", result)

    def doctor(self):
        with mock.patch.object(manage, "manifest", return_value=(self.remote, 2)):
            return manage.doctor(self.support, app_path=self.app)

    def test_cached_device_names_do_not_prove_sync(self):
        self.write_json(self.support / "usage-sync/hub-state.json", {"publications": [{"deviceName": x} for x in ["Mac mini", "MacBook Pro", "Spark local runtime"]]})
        report = self.doctor()
        self.assertEqual(report["status"], "pending")
        self.assertEqual(report["code"], "receipt_unavailable")
        rendered = json.dumps(report)
        self.assertNotIn(self.connection["credential"], rendered)
        self.assertNotIn(self.connection["deviceName"], rendered)

    def test_fresh_durable_checkpoint_is_healthy_and_production_identity(self):
        self.receipt()
        report = self.doctor()
        self.assertEqual(report["status"], "healthy")
        self.assertEqual(report["appVersion"], "fixture")
        self.assertTrue(report["allReceiptCapableDevicesCaughtUp"])

    def test_stale_pending_or_incomplete_receipts_are_not_healthy(self):
        self.receipt(outboxPending=True)
        self.assertEqual(self.doctor()["code"], "upload_pending")
        self.receipt(syncState={"checkedAt": manage.now() - 900, "acceptedLocalRevision": 4,
                                "appliedRevisions": {self.device: 4, self.peer: 3}})
        self.assertEqual(self.doctor()["code"], "local_receipt_stale")
        self.receipt(syncState={"checkedAt": manage.now(), "acceptedLocalRevision": 4,
                                "appliedRevisions": {self.device: 4, self.peer: 2}})
        self.assertEqual(self.doctor()["code"], "checkpoint_pending")

    def test_first_missing_peer_receipt_is_not_caught_up(self):
        self.receipt()
        self.remote["receipts"] = self.remote["receipts"][:1]
        self.assertFalse(self.doctor()["allReceiptCapableDevicesCaughtUp"])
        with mock.patch.object(manage, "manifest", return_value=(self.remote, 2)):
            report = manage.doctor(self.support, app_path=self.app, required_device_ids=[self.device, self.peer])
        self.assertFalse(report["requiredDevicesCaughtUp"])

    def test_stale_peer_heartbeat_does_not_prove_current_sync(self):
        self.receipt()
        self.remote["receipts"][1]["checkedAt"] = manage.now() - 900
        self.assertFalse(self.doctor()["allReceiptCapableDevicesCaughtUp"])
        with mock.patch.object(manage, "manifest", return_value=(self.remote, 2)):
            report = manage.doctor(self.support, app_path=self.app, required_device_ids=[self.device, self.peer])
        self.assertFalse(report["requiredDevicesCaughtUp"])

    def test_partial_resource_copy_is_rejected(self):
        resources = self.root / "resources"
        resources.mkdir()
        for name in ("midas_usage_hub.py", "midas_sync_manage.py"):
            (resources / name).write_text("pass\n")
        self.write_json(resources / "resource-manifest.json", {"schemaVersion": 1, "sources": {}})
        with self.assertRaises(manage.ManageError) as caught:
            manage.verify_resources(resources)
        self.assertEqual(caught.exception.code, "resource_verification_failed")

    def test_offline_report_never_claims_health(self):
        self.receipt()
        with mock.patch.object(manage, "manifest", side_effect=AssertionError("network called")):
            self.assertEqual(manage.doctor(self.support, online=False, app_path=self.app)["status"], "unchecked")

    def test_wrong_app_and_unsafe_connection_fail_closed(self):
        info = self.app / "Contents/Info.plist"
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.example.wrong"}))
        with self.assertRaises(manage.ManageError) as caught:
            self.doctor()
        self.assertEqual(caught.exception.code, "wrong_app_identity")
        path = self.support / "usage-sync/hub-connection.json"
        path.chmod(0o644)
        with self.assertRaises(manage.ManageError):
            manage.validated_connection(path)

    def test_redirect_never_forwards_credentials(self):
        with self.assertRaises(manage.ManageError) as caught:
            manage.NoRedirect().redirect_request(None, None, 302, "redirect", {}, "https://other.ts.net/")
        self.assertEqual(caught.exception.code, "redirect_rejected")

    def prepare_hub(self):
        root = self.support / "usage-hub"
        root.mkdir(mode=0o700)
        (root / "bin").mkdir(mode=0o700)
        store = hub.Store.initialize(root / "state")
        source = Path(hub.__file__).resolve()
        target = root / "bin/midas_usage_hub.py"
        target.write_bytes(source.read_bytes())
        target.chmod(0o700)
        agents = self.root / "LaunchAgents"
        agents.mkdir(mode=0o755)
        plist = agents / (manage.LABEL + ".plist")
        payload = {"Label": manage.LABEL, "ProgramArguments": [sys.executable, "-B", str(target), "--state-dir", str(root / "state"), "serve", "--bind", "127.0.0.1", "--port", "8766"]}
        plist.write_bytes(plistlib.dumps(payload))
        plist.chmod(0o600)
        runtime = self.root / "runtime"
        (runtime / "bin").mkdir(mode=0o700, parents=True)
        binary = runtime / "bin/python3"
        binary.write_text("#!/bin/sh\nexec " + "'" + sys.executable.replace("'", "'\\''") + "'" + ' "$@"\n')
        binary.chmod(0o700)
        return root, store, source, target, runtime, plist

    def test_upgrade_preserves_database_and_installs_private_runtime(self):
        root, store, source, target, runtime, plist = self.prepare_hub()
        with store.connect() as c:
            before_workspace = hub.Store.workspace_in(c)
        calls = []
        result = manage.upgrade(root, source, runtime, plist, restart=lambda *args: calls.append(args), health=lambda: None)
        self.assertEqual(result["status"], "healthy")
        self.assertEqual(len(calls), 1)
        payload = plistlib.loads(plist.read_bytes())
        self.assertTrue(payload["ProgramArguments"][0].startswith(str(root / "runtimes")))
        self.assertFalse("codex" in payload["ProgramArguments"][0].lower())
        with store.connect() as c:
            self.assertEqual(hub.Store.workspace_in(c), before_workspace)
            self.assertEqual(c.execute("PRAGMA integrity_check").fetchone()[0], "ok")
        self.assertEqual(len(list((root / "backups").glob("*/hub.sqlite3"))), 1)
        self.assertEqual(target.read_bytes(), source.read_bytes())

    def test_failed_health_rolls_back_code_and_service_without_replacing_live_database(self):
        root, store, source, target, runtime, plist = self.prepare_hub()
        before_source, before_plist = target.read_bytes(), plist.read_bytes()
        db_inode = store.path.stat().st_ino
        calls = []
        def failed_health():
            with store.connect() as c:
                c.execute("CREATE TABLE IF NOT EXISTS fixture_accepted_after_upgrade(value TEXT)")
                c.execute("INSERT INTO fixture_accepted_after_upgrade VALUES ('preserve')")
            raise manage.ManageError("injected_health_failure")
        with self.assertRaises(manage.ManageError) as caught:
            manage.upgrade(root, source, runtime, plist, restart=lambda *args: calls.append(args), health=failed_health)
        self.assertEqual(caught.exception.code, "upgrade_rolled_back")
        self.assertEqual(len(calls), 2)
        self.assertEqual(target.read_bytes(), before_source)
        self.assertEqual(plist.read_bytes(), before_plist)
        self.assertEqual(store.path.stat().st_ino, db_inode)
        with store.connect() as c:
            self.assertEqual(c.execute("SELECT value FROM fixture_accepted_after_upgrade").fetchone()[0], "preserve")

    def test_runtime_external_symlink_and_public_listener_rejected(self):
        root, store, source, target, runtime, plist = self.prepare_hub()
        (runtime / "leak").symlink_to(self.root)
        with self.assertRaises(manage.ManageError):
            manage.runtime_digest(runtime)
        payload = plistlib.loads(plist.read_bytes())
        payload["ProgramArguments"][-3] = "0.0.0.0"
        plist.write_bytes(plistlib.dumps(payload))
        with self.assertRaises(manage.ManageError):
            manage.service_payload(plist, root)


if __name__ == "__main__":
    unittest.main()
