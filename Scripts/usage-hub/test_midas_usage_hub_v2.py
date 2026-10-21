#!/usr/bin/env python3
"""Private temporary SQLite fixtures only; no real accounts or usage data."""
import copy
import contextlib
import gzip
import hashlib
import http.client
import json
import sqlite3
import threading
import time
import unittest
import uuid
from unittest import mock

import midas_usage_hub as hub
import test_midas_usage_hub as fixtures


class V2Tests(unittest.TestCase):
    setUp = fixtures.HubTests.setUp
    tearDown = fixtures.HubTests.tearDown
    enroll = fixtures.HubTests.enroll
    publication = fixtures.HubTests.publication
    exchange = fixtures.HubTests.exchange
    assert_hub_error = fixtures.HubTests.assert_hub_error

    def stage(self, publication, expected=0, config=None, upload_id=None):
        config = config or self.one
        pages = hub.page_records(publication)
        specification = {"uploadID": upload_id or str(uuid.uuid4()).upper(), "expectedRevision": expected,
                         "header": hub.publication_header(publication),
                         "pages": [hub.page_descriptor(raw) for raw in pages]}
        result = self.store.upload_start(config["credential"], specification)
        for raw, descriptor in zip(pages, specification["pages"]):
            if descriptor["digest"] in result["missingDigests"]:
                self.store.upload_page(config["credential"], specification["uploadID"], descriptor["digest"], raw)
        return specification, pages

    def commit(self, publication, expected=0, config=None):
        config = config or self.one
        specification, pages = self.stage(publication, expected, config)
        return self.store.upload_commit(config["credential"], {"uploadID": specification["uploadID"]}), specification, pages

    def test_additive_migration_has_verified_original_backup(self):
        # Construct the exact pre-v2 layout; exchange itself now performs migration.
        publication = self.publication()
        raw = hub.canonical(publication)
        with self.store.connect() as connection:
            connection.execute("UPDATE devices SET snapshot=?,digest=?,published=?,record_count=1 WHERE id=?",
                               (raw, hashlib.sha256(raw).hexdigest(), publication["publishedAt"], self.one["deviceID"]))
        manifest = self.store.manifest(self.one["credential"])
        self.assertEqual(manifest["devices"][0]["eventCount"], 1)
        backups = list((self.store.directory / "backups").glob("*.sqlite3"))
        self.assertEqual(len(backups), 1)
        with contextlib.closing(sqlite3.connect(backups[0])) as connection:
            self.assertEqual(connection.execute("PRAGMA quick_check").fetchone()[0], "ok")
            self.assertEqual(connection.execute("SELECT snapshot FROM devices WHERE id=?", (self.one["deviceID"],)).fetchone()[0], raw)
            self.assertEqual(connection.execute("SELECT count(*) FROM sqlite_master WHERE name='v2_heads'").fetchone()[0], 0)
        self.store.ensure_v2()
        self.assertEqual(len(list((self.store.directory / "backups").glob("*.sqlite3"))), 1)

    def test_no_change_and_heartbeats_do_not_advance_revision(self):
        publication = self.publication()
        receipt, _, pages = self.commit(publication)
        changed = copy.deepcopy(publication)
        changed["publishedAt"] += 1
        second, _, new_pages = self.commit(changed, 1)
        self.assertEqual(pages, new_pages)
        self.assertEqual(second["revision"], receipt["revision"])
        self.store.applied_receipt(self.two["credential"], {"appliedRevisions": {self.one["deviceID"]: 1}})
        manifest = self.store.manifest(self.one["credential"])
        self.assertEqual(manifest["devices"][0]["revision"], 1)
        self.assertTrue(manifest["devices"][0]["supportsReceipts"])
        self.assertEqual(manifest["receipts"][0]["appliedRevisions"], {self.one["deviceID"]: 1})

    def test_lost_commit_reply_is_idempotent_after_new_head(self):
        publication = self.publication()
        first, specification, _ = self.commit(publication)
        publication = copy.deepcopy(publication)
        publication["events"][0]["values"]["tokens"] += 1
        publication["publishedAt"] += 1
        second, _, _ = self.commit(publication, 1)
        self.assertEqual(second["revision"], 2)
        self.assertEqual(self.store.upload_commit(self.one["credential"], {"uploadID": specification["uploadID"]}), first)
        retry = self.store.upload_start(self.one["credential"], specification)
        self.assertTrue(retry["committed"])
        self.assertEqual(retry["receipt"], first)
        changed = copy.deepcopy(specification)
        changed["expectedRevision"] = 2
        self.assert_hub_error(409, lambda: self.store.upload_start(self.one["credential"], changed))

    def test_stale_restore_and_partial_scan_preserve_head(self):
        publication = self.publication()
        self.commit(publication)
        self.assert_hub_error(409, lambda: self.stage(publication, 0))
        omitted = dict(publication, events=[])
        specification, _ = self.stage(omitted, 1)
        self.assert_hub_error(409, lambda: self.store.upload_commit(self.one["credential"], {"uploadID": specification["uploadID"]}))
        self.assertEqual(self.store.manifest(self.one["credential"])["devices"][0]["eventCount"], 1)
        # A competing stage cannot overwrite a newer head at commit time either.
        staged, _ = self.stage(publication, 1)
        larger = copy.deepcopy(publication)
        larger["events"][0]["values"]["tokens"] += 1
        self.commit(larger, 1)
        self.assert_hub_error(409, lambda: self.store.upload_commit(self.one["credential"], {"uploadID": staged["uploadID"]}))

    def test_same_identity_regression_rejected_explicit_price_correction_allowed(self):
        publication = self.publication()
        self.commit(publication)
        lower = copy.deepcopy(publication)
        lower["events"][0]["values"]["tokens"] -= 1
        specification, _ = self.stage(lower, 1)
        self.assert_hub_error(409, lambda: self.store.upload_commit(self.one["credential"], {"uploadID": specification["uploadID"]}))
        correction = copy.deepcopy(publication)
        correction["events"][0]["values"]["costUSD"] = 0.001
        correction["events"][0]["values"]["pricingRevision"] = 1
        receipt, _, _ = self.commit(correction, 1)
        self.assertEqual(receipt["revision"], 2)
        old = self.exchange(self.two, None)["publications"][0]
        self.assertEqual(old["events"][0]["values"]["costUSD"], 0.001)
        self.assertEqual(old["events"][0]["values"]["pricingRevision"], 1)

    def test_old_canonical_rows_cannot_be_dropped_by_age(self):
        publication = self.publication()
        event = publication["events"][0]
        event["observedAt"] -= 800 * 86400
        event["day"] = hub.day_for(event["observedAt"])
        self.commit(publication)
        specification, _ = self.stage(dict(publication, events=[]), 1)
        self.assert_hub_error(409, lambda: self.store.upload_commit(self.one["credential"], {"uploadID": specification["uploadID"]}))

    def test_page_integrity_authentication_scope_and_limits(self):
        publication = self.publication()
        specification, pages = self.stage(publication)
        digest = specification["pages"][0]["digest"]
        self.assert_hub_error(400, lambda: self.store.upload_page(self.one["credential"], specification["uploadID"], digest, pages[0] + b" "))
        self.assert_hub_error(403, lambda: self.store.upload_page(self.two["credential"], specification["uploadID"], digest, pages[0]))
        self.assert_hub_error(401, lambda: self.store.manifest("invalid"))
        bad = copy.deepcopy(specification)
        bad["uploadID"] = str(uuid.uuid4()).upper()
        bad["pages"][0]["byteCount"] = hub.V2_PAGE_BYTES + 1
        self.assert_hub_error(400, lambda: self.store.upload_start(self.one["credential"], bad))
        self.store.upload_commit(self.one["credential"], {"uploadID": specification["uploadID"]})
        with self.store.connect() as connection:
            connection.execute("UPDATE v2_pages SET body=? WHERE digest=?", (b"{}", digest))
        self.assert_hub_error(503, lambda: self.store.get_page(self.one["credential"], self.one["deviceID"], 1, digest))

    def test_legacy_updates_cannot_erase_canonical_history(self):
        publication = self.publication()
        self.commit(publication)
        fresh = self.publication(tokens=200, offset=2, event_id="b" * 64)
        self.exchange(self.one, fresh)
        head = self.store.manifest(self.one["credential"])["devices"][0]
        self.assertEqual(head["eventCount"], 2)
        with self.store.connect() as connection:
            full = self.store._publication_in(connection, self.store._head_in(connection, self.one["deviceID"]))
        self.assertEqual({row["id"] for row in full["events"]}, {"a" * 64, "b" * 64})

    def test_legacy_projection_keeps_baseline_money_and_rollup_ids(self):
        publication = self.publication(tokens=100)
        legacy = copy.deepcopy(publication["events"][0])
        legacy["id"] = hub.rollup_id(publication["deviceID"], legacy["provider"], legacy["day"], legacy["values"])
        publication["events"][0]["values"]["tokens"] = 200
        publication["events"][0]["values"]["costUSD"] = 0.01
        publication["events"].append(legacy)
        self.commit(publication)
        # Fine token coverage alone must not discard higher historical money.
        old = self.exchange(self.two, None)["publications"][0]
        self.assertEqual(len(old["events"]), 1)
        self.assertEqual(old["events"][0]["values"]["tokens"], 100)
        self.assertEqual(old["events"][0]["values"]["costUSD"], 0.05)
        self.assertEqual(self.store.manifest(self.one["credential"])["devices"][0]["eventCount"], 2)
        self.assertFalse(self.store.manifest(self.one["credential"])["devices"][0]["legacyViewStale"])

    def test_large_canonical_four_devices_are_paged_and_v1_bounded(self):
        configurations = [self.one, self.two, self.enroll("MacBook"), self.enroll("Fourth")]
        # More than v1's 100k records in one canonical head and >250k workspace records.
        for index, config in enumerate(configurations):
            publication = self.publication(config)
            template = publication["events"][0]
            count = 100_001 if index == 0 else 50_001
            publication["events"] = [dict(template, id=hashlib.sha256(str(number).encode()).hexdigest()) for number in range(count)]
            receipt, specification, pages = self.commit(publication, config=config)
            self.assertGreater(len(pages), 1)
            self.assertTrue(all(len(raw) <= hub.V2_PAGE_BYTES for raw in pages))
            for raw, descriptor in zip(pages, specification["pages"]):
                self.assertEqual(self.store.get_page(config["credential"], config["deviceID"], receipt["revision"], descriptor["digest"]), raw)
        manifest = self.store.manifest(self.one["credential"])
        self.assertEqual(len(manifest["devices"]), 4)
        self.assertEqual(sum(head["eventCount"] for head in manifest["devices"]), 250_004)
        legacy = self.exchange(self.one, None)
        self.assertEqual(sum(len(p["events"]) for p in legacy["publications"]), 4)
        self.assertTrue(all(not head["legacyViewStale"] for head in manifest["devices"]))

    def test_revision_leases_expire_without_deleting_current_data(self):
        publication = self.publication()
        _, old_spec, old_pages = self.commit(publication)
        self.store.manifest(self.one["credential"])
        publication = copy.deepcopy(publication)
        publication["events"][0]["values"]["tokens"] += 1
        self.commit(publication, 1)
        future = time.time() + hub.V2_REVISION_TTL + 1
        with mock.patch.object(hub.time, "time", return_value=future):
            with self.store.connect() as connection:
                self.store._prune_v2_in(connection, force=True)
        self.assert_hub_error(410, lambda: self.store.get_page(self.one["credential"], self.one["deviceID"], 1, old_spec["pages"][0]["digest"]))
        manifest = self.store.manifest(self.one["credential"])
        self.assertEqual(manifest["devices"][0]["revision"], 2)
        # Applied revision vectors outlive the page-resume lease.
        self.store.applied_receipt(self.two["credential"], {"appliedRevisions": {self.one["deviceID"]: 1}})
        with self.store.connect() as connection:
            self.assertIsNone(connection.execute("SELECT 1 FROM v2_pages WHERE digest=?", (old_spec["pages"][0]["digest"],)).fetchone())

    def test_pairing_requires_local_approval_secret_and_rate_limit(self):
        value = {"deviceName": "New Mac", "requestID": str(uuid.uuid4()).upper(),
                 "requestSecret": "a" * 40, "endpoint": "https://synthetic.tailnet.ts.net"}
        requested = self.store.pairing_request(value)
        status = {key: value[key] for key in ("requestID", "requestSecret")}
        self.assertEqual(self.store.pairing_status(status)["status"], "pending")
        self.assert_hub_error(403, lambda: self.store.pairing_approve(value["requestID"], "999999" if requested["code"] != "999999" else "000000"))
        self.assert_hub_error(401, lambda: self.store.pairing_status(dict(status, requestSecret="b" * 40)))
        self.store.pairing_approve(value["requestID"], requested["code"])
        approved = self.store.pairing_status(status)
        self.assertEqual(approved["status"], "approved")
        self.store.workspace(approved["connection"]["credential"])
        self.assertNotIn("credential", str(self.store.pairing_list()))
        self.store.revoke(approved["connection"]["deviceID"])
        self.assert_hub_error(401, lambda: self.store.workspace(approved["connection"]["credential"]))
        for _ in range(4):
            self.store.pairing_request(dict(value, requestID=str(uuid.uuid4()).upper()))
        self.assert_hub_error(429, lambda: self.store.pairing_request(dict(value, requestID=str(uuid.uuid4()).upper())))
        with mock.patch.object(hub.time, "time", return_value=time.time() + hub.PAIRING_TTL + 1):
            self.assertEqual(self.store.pairing_status(status)["status"], "expired")

    def test_record_preference_matches_swift_timestamp_then_quality(self):
        old = self.publication()["events"][0]
        newer = copy.deepcopy(old)
        newer["observedAt"] += 1
        newer["values"].pop("costUSD")
        self.assertTrue(hub.prefer_record(newer, old))
        same_time = copy.deepcopy(old)
        same_time["values"]["apiEquivalentCostUSD"] = 0.1
        self.assertTrue(hub.prefer_record(same_time, old))
        same_time["values"]["provenance"] = "vendorBilled"
        self.assertTrue(hub.prefer_record(same_time, old, account=True))
        correction = copy.deepcopy(old)
        correction["values"]["pricingRevision"] = 1
        correction["values"].pop("costUSD")
        self.assertTrue(hub.prefer_record(correction, old))
        hub.validate_values(correction["values"])
        correction["values"]["pricingRevision"] = -1
        self.assert_hub_error(400, lambda: hub.validate_values(correction["values"]))

    def test_http_manifest_gzip_and_no_decompression_bomb_request(self):
        publication = self.publication()
        template = publication["events"][0]
        publication["events"] = [dict(template, id=hashlib.sha256(str(n).encode()).hexdigest()) for n in range(500)]
        receipt, specification, pages = self.commit(publication)
        server = hub.HubServer(("127.0.0.1", 0), self.store)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            connection = http.client.HTTPConnection(*server.server_address, timeout=5)
            connection.request("GET", "/v2/manifest")
            response = connection.getresponse()
            self.assertEqual(response.status, 401)
            response.read()
            digest = specification["pages"][0]["digest"]
            connection.request("GET", f'/v2/pages/{self.one["deviceID"]}/{receipt["revision"]}/{digest}',
                               headers={"Authorization": "Bearer " + self.one["credential"], "Accept-Encoding": "gzip"})
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.getheader("Content-Encoding"), "gzip")
            self.assertEqual(gzip.decompress(response.read()), pages[0])
            connection.request("POST", "/v2/upload/start", body=gzip.compress(b"x" * (2 * 1024 * 1024)),
                               headers={"Authorization": "Bearer " + self.one["credential"],
                                        "Content-Type": "application/json", "Content-Encoding": "gzip"})
            response = connection.getresponse()
            self.assertEqual(response.status, 415)
            response.read()
            connection.close()
        finally:
            server.shutdown()
            server.server_close()
            worker.join()


if __name__ == "__main__":
    unittest.main()
