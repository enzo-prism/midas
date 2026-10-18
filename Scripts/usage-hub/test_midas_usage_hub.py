#!/usr/bin/env python3
"""Isolated synthetic tests. Never reads real logs, credentials, accounts, or network devices."""

import contextlib
import copy
import http.client
import io
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
import unittest
from unittest import mock
import uuid

import midas_usage_hub as hub


class HubTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="midas-hub-tests-")
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.store = hub.Store.initialize(self.root / "state")
        self.one = self.enroll("Mac mini")
        self.two = self.enroll("Spark")

    def tearDown(self):
        self.temporary.cleanup()

    def enroll(self, name):
        path = self.root / (str(uuid.uuid4()) + ".json")
        self.store.add_device(name, "http://127.0.0.1:8766", path)
        return json.loads(path.read_bytes())

    def publication(self, config=None, tokens=100, offset=0, event_id="a" * 64):
        config = config or self.one
        at = time.time() - hub.APPLE_EPOCH - 600 + offset
        return {
            "schemaVersion": 1, "workspaceID": config["workspaceID"], "deviceID": config["deviceID"],
            "deviceName": config["deviceName"], "publishedAt": at, "excludedRecords": 0, "accountDays": [],
            "events": [{"id": event_id, "provider": "codex", "observedAt": at, "day": hub.day_for(at),
                        "values": {"tokens": tokens, "costUSD": 0.05, "tokenMix": {"inputTokens": tokens},
                                   "provenance": "listPriceEstimate", "unpricedRequests": 0,
                                   "estimatedRequests": 1, "model": "gpt-5"}}],
        }

    def exchange(self, config, publication):
        return self.store.exchange(config["credential"], publication)

    def assert_hub_error(self, status, operation):
        with self.assertRaises(hub.HubError) as caught:
            operation()
        self.assertEqual(caught.exception.status, status)

    def test_three_devices_converge_and_duplicate_uploads_are_idempotent(self):
        three = self.enroll("MacBook")
        publications = [self.publication(self.one, 100), self.publication(self.two, 200), self.publication(three, 300)]
        for config, publication in zip((self.one, self.two, three), publications):
            self.exchange(config, publication)
        for config, publication in zip((self.one, self.two, three), publications):
            self.exchange(config, publication)
            result = self.exchange(config, None)
            self.assertFalse(result["publicationSucceeded"])
            self.assertEqual(len(result["publications"]), 3)
            self.assertEqual(sum(p["events"][0]["values"]["tokens"] for p in result["publications"]), 600)
        self.assertEqual(hub.Store(self.root / "state").exchange(self.one["credential"], None), result)

    def test_same_event_copied_between_devices_is_preserved_for_shared_ledger_dedup(self):
        one = self.publication(self.one)
        two = copy.deepcopy(one)
        two["deviceID"], two["deviceName"] = self.two["deviceID"], self.two["deviceName"]
        self.exchange(self.one, one)
        result = self.exchange(self.two, two)
        self.assertEqual(len(result["publications"]), 2)
        self.assertEqual({p["events"][0]["id"] for p in result["publications"]}, {"a" * 64})

    def test_tokens_cannot_write_other_device_or_name(self):
        self.assert_hub_error(403, lambda: self.exchange(self.one, self.publication(self.two)))
        publication = self.publication()
        publication["deviceName"] = "Other Mac"
        self.assert_hub_error(403, lambda: self.exchange(self.one, publication))
        self.assertEqual(self.exchange(self.one, None)["publications"], [])

    def test_revoke_disables_reads_and_writes_but_preserves_history(self):
        self.exchange(self.one, self.publication())
        self.store.revoke(self.one["deviceID"])
        self.assert_hub_error(401, lambda: self.store.workspace(self.one["credential"]))
        self.assert_hub_error(401, lambda: self.exchange(self.one, None))
        self.assert_hub_error(401, lambda: self.exchange(self.one, self.publication()))
        self.assertEqual(len(self.exchange(self.two, None)["publications"]), 1)

    def test_snapshot_time_is_monotonic_and_collisions_do_not_replace_history(self):
        publication = self.publication()
        self.exchange(self.one, publication)
        stale = copy.deepcopy(publication)
        stale["publishedAt"] -= 1
        collision = copy.deepcopy(publication)
        collision["events"][0]["values"]["tokens"] += 1
        self.assert_hub_error(409, lambda: self.exchange(self.one, stale))
        self.assert_hub_error(409, lambda: self.exchange(self.one, collision))
        self.assertEqual(self.exchange(self.one, None)["publications"], [publication])
        newer = copy.deepcopy(collision)
        newer["publishedAt"] += 1
        self.assertEqual(self.exchange(self.one, newer)["publications"], [newer])

    def test_invalid_schema_fields_are_rejected_and_never_stored(self):
        mutations = (
            lambda p: p.update(prompt="private text"),
            lambda p: p.update(schemaVersion=2),
            lambda p: p.update(workspaceID=str(uuid.uuid4())),
            lambda p: p.update(publishedAt=time.time() - hub.APPLE_EPOCH + 301),
            lambda p: p["events"][0].update(id="session-raw"),
            lambda p: p["events"][0].update(day="2026-02-30"),
            lambda p: p["events"][0].update(observedAt=-hub.APPLE_EPOCH - 1),
            lambda p: p["events"][0].update(provider="cursor"),
            lambda p: p["events"][0]["values"].update(tokens=True),
            lambda p: p["events"][0]["values"].update(tokens=-1),
            lambda p: p["events"][0]["values"].update(tokens=1_000_000_000_001),
            lambda p: p["events"][0]["values"].update(costUSD=float("nan")),
            lambda p: p["events"][0]["values"].update(model="raw account text"),
            lambda p: p["events"][0]["values"].update(transcript="private text"),
            lambda p: p["events"][0]["values"]["tokenMix"].update(outputTokens=False),
        )
        for mutation in mutations:
            publication = self.publication()
            mutation(publication)
            with self.assertRaises(hub.HubError):
                self.exchange(self.one, publication)
        self.assertEqual(self.exchange(self.one, None)["publications"], [])

    def test_local_inference_is_explicitly_unpriced(self):
        publication = self.publication()
        values = publication["events"][0]["values"]
        publication["events"][0]["provider"] = "localInference"
        values.update(provenance="unknown", costUSD=None, unpricedRequests=1, estimatedRequests=0, model=None)
        result = self.exchange(self.one, publication)
        self.assertEqual(result["publications"], [publication])
        values["costUSD"] = 0.1
        with self.assertRaises(hub.HubError):
            self.exchange(self.one, publication)

    def test_exact_public_spark_model_is_allowed_but_remote_prices_remain_rejected(self):
        publication = self.publication()
        event = publication["events"][0]
        event["provider"] = "localInference"
        values = event["values"]
        values.update(provenance="unknown", costUSD=None, unpricedRequests=1, estimatedRequests=0,
                      model="Qwen/Qwen3.8-Flash-Next")
        self.assertEqual(self.exchange(self.one, publication)["publications"], [publication])
        for model in ["Qwen/private-path", "Qwen/Qwen3.8-Flash-Next/private", "/private/model"]:
            bad = copy.deepcopy(publication)
            bad["events"][0]["values"]["model"] = model
            with self.subTest(model=model), self.assertRaises(hub.HubError):
                self.exchange(self.one, bad)
        for field in ["costUSD", "apiEquivalentCostUSD"]:
            bad = copy.deepcopy(publication)
            bad["events"][0]["values"][field] = 0.0001
            with self.subTest(field=field), self.assertRaises(hub.HubError):
                self.exchange(self.one, bad)

    def test_duplicate_events_and_accounts_are_rejected(self):
        publication = self.publication()
        publication["events"] *= 2
        self.assert_hub_error(400, lambda: self.exchange(self.one, publication))
        publication = self.publication()
        event = publication["events"][0]
        account = {"accountScope": "b" * 64, "provider": "cursor", "day": event["day"],
                   "observedAt": event["observedAt"], "values": event["values"]}
        publication["accountDays"] = [account, account]
        self.assert_hub_error(400, lambda: self.exchange(self.one, publication))

    def test_exchange_record_and_size_limits_roll_back_uploaded_snapshot(self):
        first = self.publication()
        self.exchange(self.one, first)
        second = self.publication(self.two)
        with mock.patch.object(hub, "MAX_EXCHANGE_RECORDS", 1):
            self.assert_hub_error(413, lambda: self.exchange(self.two, second))
        with mock.patch.object(hub, "MAX_EXCHANGE_BYTES", 10):
            self.assert_hub_error(413, lambda: self.exchange(self.two, second))
        self.assertEqual(self.exchange(self.one, None)["publications"], [first])

    def test_corrupt_snapshot_does_not_hide_healthy_peers(self):
        one = self.publication()
        self.exchange(self.one, one)
        self.exchange(self.two, self.publication(self.two))
        with self.store.connect() as connection:
            connection.execute("UPDATE devices SET snapshot=? WHERE id=?", (b"broken", self.two["deviceID"]))
        result = self.exchange(self.one, None)
        self.assertEqual(result["publications"], [one])
        self.assertEqual(result["rejectedFiles"], 1)

    def test_enrollment_secrets_are_hashed_and_files_private_without_stdout(self):
        with self.store.connect() as connection:
            row = connection.execute("SELECT token_hash FROM devices WHERE id=?", (self.one["deviceID"],)).fetchone()
        self.assertNotEqual(row[0], self.one["credential"])
        self.assertEqual(row[0], hub.token_digest(self.one["credential"]))
        output = self.root / "private.json"
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            result = hub.main(["--state-dir", str(self.root / "state"), "add-device", "--name", "CLI test",
                               "--public-url", "https://mini.example.ts.net", "--output", str(output)])
        self.assertEqual(result, 0)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / "state").stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.store.path.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(json.loads(output.read_bytes())["credential"], stdout.getvalue())

    def test_enrollment_never_overwrites_existing_file_or_enrolls_failed_device(self):
        output = self.root / "existing.json"
        output.write_bytes(b"preserve")
        with self.assertRaises(FileExistsError):
            self.store.add_device("Collision", "http://localhost:8766", output)
        self.assertEqual(output.read_bytes(), b"preserve")
        with self.store.connect() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM devices").fetchone()[0], 2)

    def test_state_symlinks_and_world_readable_directories_are_rejected(self):
        link = self.root / "link"
        link.symlink_to(self.root / "state")
        self.assert_hub_error(400, lambda: hub.Store(link))
        (self.root / "state").chmod(0o755)
        self.assert_hub_error(400, lambda: hub.Store(self.root / "state"))
        (self.root / "state").chmod(0o700)

    def test_reinitialization_never_replaces_existing_database(self):
        before = self.store.workspace(self.one["credential"])
        with self.assertRaises(FileExistsError):
            hub.Store.initialize(self.root / "state")
        self.assertEqual(self.store.workspace(self.one["credential"]), before)

    def test_endpoint_restrictions(self):
        for valid in ("https://mini.tail123.ts.net", "http://127.0.0.1:8766", "http://localhost:123", "http://[::1]:1"):
            self.assertTrue(hub.validate_endpoint(valid))
        for invalid in ("http://mini.tail.ts.net", "https://evil.test", "https://ts.net", "https://a.ts.net.evil.test",
                        "https://a.ts.net/?secret=x", "https://token@a.ts.net", "http://192.168.1.4:8766"):
            self.assert_hub_error(400, lambda: hub.validate_endpoint(invalid))

    def test_workspace_uuid_case_is_semantic_and_external_state_paths_are_rejected(self):
        publication = self.publication()
        publication["workspaceID"] = publication["workspaceID"].lower()
        publication["deviceID"] = publication["deviceID"].lower()
        self.assertTrue(self.exchange(self.one, publication)["publicationSucceeded"])
        for path in ("/Volumes/PortableSSD/private", "/mnt/external/private", "/media/private"):
            self.assert_hub_error(400, lambda: hub.private_directory(Path(path)))

    def test_json_rejects_duplicate_keys_nonfinite_numbers_and_unknown_payloads(self):
        for data in (b'{"x":1,"x":2}', b'{"costUSD":NaN}', b'{"costUSD":Infinity}', b'bad'):
            self.assert_hub_error(400, lambda: hub.parse_json(data))


class HTTPTests(HubTests):
    def setUp(self):
        super().setUp()
        self.server = hub.HubServer(("127.0.0.1", 0), self.store)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        super().tearDown()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        headers = headers if headers is not None else {"Authorization": "Bearer " + self.one["credential"]}
        if body is not None and "Content-Type" not in headers:
            headers["Content-Type"] = "application/json"
        connection.request(method, path, body, headers)
        response = connection.getresponse()
        status, data, returned_headers = response.status, response.read(), dict(response.getheaders())
        connection.close()
        return status, json.loads(data), returned_headers

    def test_http_workspace_and_exchange_round_trip(self):
        status, workspace, headers = self.request("GET", "/v1/workspace")
        self.assertEqual(status, 200)
        self.assertEqual(workspace["id"], self.one["workspaceID"])
        self.assertEqual(headers["Cache-Control"], "no-store")
        publication = self.publication()
        status, result, _ = self.request("POST", "/v1/exchange", hub.canonical(publication))
        self.assertEqual(status, 200)
        self.assertTrue(result["publicationSucceeded"])
        self.assertEqual(result["publications"], [publication])
        self.assertEqual(self.request("POST", "/v1/exchange", b"null")[1]["publications"], [publication])

    def test_http_auth_origin_query_paths_and_oversized_body_rejected(self):
        self.assertEqual(self.request("GET", "/v1/workspace", headers={})[0], 401)
        self.assertEqual(self.request("GET", "/v1/workspace?credential=x")[0], 404)
        self.assertEqual(self.request("GET", "/v1/exchange")[0], 404)
        auth = {"Authorization": "Bearer " + self.one["credential"]}
        self.assertEqual(self.request("GET", "/v1/workspace", headers={**auth, "Origin": "https://evil.test"})[0], 403)
        self.assertEqual(self.request("POST", "/v1/exchange", b"null", {**auth, "Content-Type": "text/plain"})[0], 415)
        self.assertEqual(self.request("POST", "/v1/exchange", b"", {**auth, "Content-Type": "application/json",
                              "Content-Length": str(hub.MAX_PUBLICATION_BYTES + 1)})[0], 413)

    def test_concurrent_distinct_device_uploads_are_transactional(self):
        configs = [self.enroll("Synthetic " + str(i)) for i in range(6)]
        failures = []

        def upload(config):
            try:
                headers = {"Authorization": "Bearer " + config["credential"], "Content-Type": "application/json"}
                status, _, _ = self.request("POST", "/v1/exchange", hub.canonical(self.publication(config)), headers)
                if status != 200:
                    failures.append(status)
            except Exception as error:
                failures.append(type(error).__name__)

        threads = [threading.Thread(target=upload, args=(config,)) for config in configs]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=10)
        self.assertEqual(failures, [])
        self.assertEqual(len(self.exchange(self.one, None)["publications"]), len(configs))


if __name__ == "__main__":
    unittest.main()
