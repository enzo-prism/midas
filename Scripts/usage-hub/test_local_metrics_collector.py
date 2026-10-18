"""Synthetic numeric-only runtime tests. No real runtime, provider, or tailnet access."""

import copy
import http.server
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock
import urllib.error

import local_metrics_collector as collector
import midas_usage_hub as hub


class LocalMetricsCollectorTests(unittest.TestCase):
    now = 1792065600.0  # 2026-10-15 12:00 UTC

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="midas-local-metrics-tests-")
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        with mock.patch.object(collector.time, "time", return_value=self.now):
            self.store = hub.Store.initialize(self.root / "hub")
            path = self.root / "connection.json"
            self.store.add_device("Spark local runtime", "http://127.0.0.1:8766", path)
            self.config = collector.read_private(path)
            self.workspace = self.store.workspace(self.config["credential"])
        collector.ensure_directory(self.root / "collector")
        self.state_path = self.root / "collector/numeric-state.json"

    def tearDown(self):
        self.temporary.cleanup()

    def state(self):
        return {"workspace": copy.deepcopy(self.workspace), "deviceID": self.config["deviceID"],
                "events": [], "counters": {}, "excludedRecords": 0}

    def metrics(self, prompt=100, output=20, requests=2, process=None):
        process = self.now - 1000 if process is None else process
        lines = [f"process_start_time_seconds {process}",
                 f'vllm:prompt_tokens_total{{model_name="PRIVATE_MODEL",engine="0"}} {prompt}',
                 f'vllm:generation_tokens_total{{model_name="PRIVATE_MODEL",engine="0"}} {output}']
        if requests is not None:
            lines += [f'vllm:request_success_total{{model_name="PRIVATE_MODEL",engine="0",finished_reason="stop"}} {requests}',
                      'vllm:request_success_total{model_name="PRIVATE_MODEL",engine="0",finished_reason="length"} 0']
        return "\n".join(lines) + "\n"

    def sample(self, state, prompt, output, requests, at, process=None):
        collector.sample(state, self.workspace, self.config,
                         collector.parse_metrics(self.metrics(prompt, output, requests, process)), at)

    def test_baseline_then_numeric_delta_with_stable_unpriced_identity(self):
        state = self.state()
        self.sample(state, 100, 20, 2, self.now)
        self.assertEqual(state["events"], [])
        self.sample(state, 160, 30, 3, self.now + 180)
        event = state["events"][0]
        self.assertEqual(event["values"]["tokens"], 70)
        self.assertEqual(event["values"]["requests"], 1)
        self.assertEqual(event["values"]["provenance"], "unknown")
        self.assertNotIn("costUSD", event["values"])
        self.assertNotIn("apiEquivalentCostUSD", event["values"])
        self.assertNotIn("model", event["values"])
        identity = event["id"]
        self.sample(state, 180, 40, 4, self.now + 360)
        self.assertEqual(state["events"][0]["id"], identity)
        self.assertEqual(state["events"][0]["values"]["tokens"], 100)
        serialized = json.dumps(state)
        self.assertNotIn("PRIVATE_MODEL", serialized)
        self.assertNotIn(self.config["credential"], serialized)
        hub.validate_publication(state["pending"], self.workspace["id"], self.config["deviceID"],
                                 self.config["deviceName"], now=self.now + 360)

    def cached_metrics(self, prompt=100, output=20, requests=2, cached=50):
        text = self.metrics(prompt, output, requests)
        if cached is not None:
            text += f'vllm:prompt_tokens_cached_total{{model_name="PRIVATE_MODEL",engine="0"}} {cached}\n'
        # This older metric counts cache lookup hits, not billed cached tokens. It must be ignored.
        return text + 'vllm:prefix_cache_hits_total{model_name="PRIVATE_MODEL",engine="0"} 999999\n'

    def cached_sample(self, state, prompt, output, requests, cached, at,
                      public_model="Qwen/Qwen3.8-Flash-Next", alias="PRIVATE_MODEL"):
        collector.sample(state, self.workspace, self.config,
                         collector.parse_metrics(self.cached_metrics(prompt, output, requests, cached),
                                                 alias, public_model), at)

    def test_verified_model_and_cached_subset_are_published_without_raw_runtime_labels(self):
        state = self.state()
        self.cached_sample(state, 100, 20, 2, 50, self.now)
        self.cached_sample(state, 200, 40, 3, 120, self.now + 180)
        values = state["events"][0]["values"]
        self.assertEqual(values["model"], "Qwen/Qwen3.8-Flash-Next")
        self.assertEqual(values["tokens"], 120)
        self.assertEqual(values["tokenMix"], {"inputTokens": 100, "outputTokens": 20, "cacheReadTokens": 70})
        self.assertEqual(values["provenance"], "unknown")
        self.assertNotIn("costUSD", values)
        self.assertNotIn("PRIVATE_MODEL", json.dumps(state))
        self.assertNotIn("999999", json.dumps(state))
        collector.validate_state(state, self.config, self.now + 180)
        self.cached_sample(state, 200, 40, 3, 120, self.now + 360)
        self.assertEqual(state["events"][0]["values"], values)

    def test_legacy_history_is_retained_and_mapping_upgrade_establishes_a_new_baseline(self):
        state = self.state()
        self.sample(state, 100, 20, 2, self.now)
        self.sample(state, 107, 21, 3, self.now + 180)
        legacy = copy.deepcopy(state["events"][0])
        self.cached_sample(state, 117, 23, 4, 50, self.now + 360)
        self.assertEqual(state["events"], [legacy])
        self.cached_sample(state, 137, 25, 5, 60, self.now + 540)
        self.assertEqual(len(state["events"]), 2)
        self.assertIn(legacy, state["events"])
        known = next(e for e in state["events"] if e["values"].get("model"))
        self.assertEqual(known["values"]["tokens"], 22)
        self.assertEqual(known["values"]["tokenMix"]["cacheReadTokens"], 10)
        self.assertNotEqual(legacy["id"], known["id"])

    def test_cache_reset_missing_or_excess_delta_preserves_tokens_without_assumed_price(self):
        for cached in [10, None, 1000]:
            with self.subTest(cached=cached):
                state = self.state()
                self.cached_sample(state, 100, 20, 2, 50, self.now)
                self.cached_sample(state, 110, 22, 3, cached, self.now + 180)
                values = state["events"][0]["values"]
                self.assertEqual(values["tokens"], 12)
                self.assertNotIn("model", values)
                self.assertNotIn("cacheReadTokens", values["tokenMix"])
                self.cached_sample(state, 120, 24, 4, 15 if cached == 10 else 1005, self.now + 360)
                collector.validate_state(state, self.config, self.now + 360)

    def test_unknown_alias_is_unpriced_and_public_identity_changes_rebaseline(self):
        state = self.state()
        self.cached_sample(state, 100, 20, 2, 50, self.now, alias="different-alias")
        self.cached_sample(state, 110, 22, 3, 55, self.now + 180, alias="different-alias")
        self.assertNotIn("model", state["events"][0]["values"])
        self.cached_sample(state, 120, 24, 4, 60, self.now + 360)
        self.assertEqual(len(state["events"]), 1)
        self.assertEqual(state["excludedRecords"], 1)
        self.cached_sample(state, 130, 26, 5, 65, self.now + 540)
        self.assertEqual(len(state["events"]), 2)

    def test_cache_counter_duplicate_series_and_invalid_mapping_are_rejected(self):
        cached = self.cached_metrics()
        line = next(line for line in cached.splitlines() if "prompt_tokens_cached_total" in line)
        with self.assertRaises(ValueError):
            collector.parse_metrics(cached + line + "\n")
        for alias, model in [("PRIVATE_MODEL", None), (None, "Qwen/Qwen3.8-Flash-Next"),
                             ("PRIVATE_MODEL", "/private/model/path"),
                             ("bad\nalias", "Qwen/Qwen3.8-Flash-Next")]:
            with self.subTest(alias=alias, model=model), self.assertRaises(ValueError):
                collector.parse_metrics(cached, alias, model)

    def test_resets_higher_restart_long_gap_midnight_and_clock_reversal_rebaseline(self):
        variants = [
            (10, 2, 1, self.now + 180, self.now - 1000),
            (1000, 200, 20, self.now + 180, self.now + 10),
            (120, 25, 3, self.now + 1000, self.now - 1000),
            (120, 25, 3, self.now - 10, self.now - 1000),
        ]
        for prompt, output, requests, at, process in variants:
            with self.subTest(at=at, process=process):
                state = self.state()
                self.sample(state, 100, 20, 2, self.now)
                self.sample(state, prompt, output, requests, at, process)
                self.assertEqual(state["events"], [])
                self.assertEqual(state["excludedRecords"], 1)
                self.assertGreater(state["pending"]["publishedAt"], self.now - collector.REFERENCE_EPOCH)
        state = self.state()
        midnight = self.now + 12 * 3600
        self.sample(state, 100, 20, 2, midnight - 90)
        self.sample(state, 110, 22, 3, midnight + 90)
        self.assertEqual(state["events"], [])
        self.assertEqual(state["excludedRecords"], 1)

    def test_absent_requests_are_unknown_and_disappeared_series_rebaseline(self):
        state = self.state()
        self.sample(state, 100, 20, None, self.now)
        self.sample(state, 120, 30, None, self.now + 180)
        self.assertNotIn("requests", state["events"][0]["values"])
        self.assertEqual(state["events"][0]["values"]["tokens"], 30)

    def test_invalid_duplicate_oversized_and_missing_process_metrics_rejected(self):
        valid = self.metrics()
        invalid = [valid + valid.splitlines()[1] + "\n", valid.replace(" 100\n", " NaN\n"),
                   valid.replace(" 100\n", " -1\n"), valid.replace(" 100\n", " 1000000000001\n"),
                   "\n".join(valid.splitlines()[1:]), valid.replace('engine="0"', 'engine="0",engine="1"')]
        for text in invalid:
            with self.subTest(text=text[:60]), self.assertRaises(ValueError):
                collector.parse_metrics(text)

    def test_durable_before_upload_outage_restart_retry_and_lost_ack(self):
        clock = [self.now]
        text = [self.metrics()]
        offline = [False]
        lose_ack = [False]
        verified = []

        def request(config, path, value=None, post=False):
            if path == "/v1/workspace":
                if offline[0]:
                    raise OSError("synthetic hub outage")
                return self.store.workspace(config["credential"])
            persisted = collector.read_private(self.state_path)
            self.assertEqual(persisted["pending"], value)
            verified.append(copy.deepcopy(value))
            if offline[0]:
                raise OSError("synthetic hub outage")
            result = self.store.exchange(config["credential"], value)
            if lose_ack[0]:
                raise OSError("synthetic lost acknowledgement")
            return result

        def open_metrics(*args, **kwargs):
            if isinstance(text[0], Exception):
                raise text[0]
            return io.BytesIO(text[0].encode())

        opener = mock.Mock()
        opener.open.side_effect = open_metrics
        with mock.patch.object(collector, "request_json", side_effect=request), \
             mock.patch.object(collector.urllib.request, "build_opener", return_value=opener), \
             mock.patch.object(collector.time, "time", side_effect=lambda: clock[0]):
            collector.collect_once(self.config, self.state_path, "http://127.0.0.1:11434/metrics")
            clock[0] += 180
            offline[0] = True
            text[0] = self.metrics(150, 30, 3)
            with self.assertRaises(OSError):
                collector.collect_once(self.config, self.state_path, "http://127.0.0.1:11434/metrics")
            self.assertEqual(collector.read_private(self.state_path)["events"][0]["values"]["tokens"], 60)
            clock[0] += 180
            offline[0] = False
            text[0] = OSError("synthetic runtime outage")
            result = collector.collect_once(self.config, self.state_path, "http://127.0.0.1:11434/metrics")
            self.assertFalse(result["sampleSucceeded"])
            self.assertTrue(result["publicationSucceeded"])
            self.assertEqual(verified[-1], verified[-2])
            clock[0] += 180
            text[0] = self.metrics(170, 40, 4)
            lose_ack[0] = True
            with self.assertRaises(OSError):
                collector.collect_once(self.config, self.state_path, "http://127.0.0.1:11434/metrics")
            lose_ack[0] = False
            text[0] = OSError("synthetic runtime outage")
            collector.collect_once(self.config, self.state_path, "http://127.0.0.1:11434/metrics")
            self.assertEqual(verified[-1], verified[-2])
        self.assertEqual(self.state_path.stat().st_mode & 0o777, 0o600)

    def test_first_hub_outage_has_no_fake_workspace_and_first_metrics_outage_caches_enrollment(self):
        with mock.patch.object(collector, "request_json", side_effect=OSError("synthetic hub outage")):
            with self.assertRaises(OSError):
                collector.collect_once(self.config, self.state_path, "http://127.0.0.1:11434/metrics")
        self.assertFalse(self.state_path.exists())
        opener = mock.Mock()
        opener.open.side_effect = OSError("synthetic runtime outage")
        with mock.patch.object(collector, "request_json", return_value=self.workspace), \
             mock.patch.object(collector.urllib.request, "build_opener", return_value=opener):
            with self.assertRaises(OSError):
                collector.collect_once(self.config, self.state_path, "http://127.0.0.1:11434/metrics")
        persisted = collector.read_private(self.state_path)
        self.assertEqual(persisted["workspace"], self.workspace)
        self.assertNotIn("pending", persisted)

    def test_private_state_rejects_permissions_links_and_endpoint_mistakes(self):
        collector.save_private(self.state_path, self.state())
        self.state_path.chmod(0o644)
        with self.assertRaises(ValueError):
            collector.read_private(self.state_path)
        self.state_path.chmod(0o600)
        link = self.root / "alias.json"
        link.symlink_to(self.state_path)
        with self.assertRaises(ValueError):
            collector.read_private(link)
        for url in ["http://example.com/metrics", "http://127.0.0.1:11434/prompts",
                    "http://user:secret@127.0.0.1/metrics", "http://127.0.0.1/metrics?secret=1"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                collector.validate_endpoint(url, metrics=True)

    def test_hub_redirect_is_not_followed(self):
        visited = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                visited.append(self.path)
                self.send_response(302)
                self.send_header("Location", "/credential-destination")
                self.end_headers()

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        config = dict(self.config, endpoint=f"http://127.0.0.1:{server.server_port}")
        try:
            with self.assertRaises(urllib.error.HTTPError):
                collector.request_json(config, "/v1/workspace")
            self.assertEqual(visited, ["/v1/workspace"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
