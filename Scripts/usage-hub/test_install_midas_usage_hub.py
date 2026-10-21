"""Installer fixtures use private temporary directories; never touches the actual user's hub or launchd."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

import midas_usage_hub as hub


@unittest.skipIf(sys.version_info < (3, 10), "Installer requires a maintained Python 3.10+ runtime")
class HubInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="midas-hub-install-tests-")
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.repository = Path(__file__).resolve().parents[2]
        self.script = self.repository / "Scripts/install_midas_usage_hub.sh"
        self.source = self.repository / "Scripts/usage-hub/midas_usage_hub.py"
        self.install = self.root / "install"
        self.agents = self.root / "LaunchAgents"
        self.logs = self.root / "logs"
        self.service = self.agents / "com.designprism.midas.usage-hub.plist"
        # CI toolcache executables may belong to another account or be group writable.
        # Exercise the real production guard with an owned 700 binary rather than
        # relaxing it. The lib link supports relocatable Linux/standalone-Python
        # loaders and their stdlib; this is an isolated fixture, not a shipped runtime.
        interpreter = self.root / "interpreter"
        (interpreter / "bin").mkdir(parents=True, mode=0o700)
        self.python = interpreter / "bin/python3"
        shutil.copyfile(Path(sys.executable).resolve(), self.python)
        self.python.chmod(0o700)
        (interpreter / "lib").symlink_to(Path(sys.base_prefix) / "lib", target_is_directory=True)

    def tearDown(self):
        self.temporary.cleanup()

    def run_installer(self, *arguments):
        return subprocess.run(
            ["bash", str(self.script), "--python", str(self.python), "--source", str(self.source),
             "--install-root", str(self.install), "--launch-agents-dir", str(self.agents),
             "--log-dir", str(self.logs), *arguments],
            capture_output=True, text=True, timeout=30,
        )

    def test_explicit_initialization_prepares_verified_inactive_private_hub(self):
        result = self.run_installer("--initialize")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("inactive", result.stdout)
        self.assertNotIn("credential", result.stdout)
        payload = plistlib.loads(self.service.read_bytes())
        self.assertEqual(payload["Label"], "com.designprism.midas.usage-hub")
        self.assertTrue(payload["RunAtLoad"])
        self.assertTrue(payload["KeepAlive"])
        self.assertEqual(payload["ProgramArguments"][-4:], ["--bind", "127.0.0.1", "--port", "8766"])
        self.assertEqual(Path(payload["ProgramArguments"][0]), self.python)
        self.assertNotIn("tailscale", " ".join(payload["ProgramArguments"]).lower())
        copied = self.install / "bin/midas_usage_hub.py"
        self.assertEqual(copied.read_bytes(), self.source.read_bytes())
        self.assertEqual(hashlib.sha256(copied.read_bytes()).digest(), hashlib.sha256(self.source.read_bytes()).digest())
        for directory in (self.install, self.install / "state", self.install / "bin", self.agents, self.logs):
            self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        for file in (self.service, self.logs / "usage-hub.log", self.install / "state/hub.sqlite3"):
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        self.assertEqual(copied.stat().st_mode & 0o777, 0o700)
        store = hub.Store(self.install / "state")
        with store.connect() as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM devices").fetchone()[0], 0)

    def test_explicit_runtime_is_copied_to_midas_owned_versioned_directory(self):
        runtime = self.root / "runtime"
        (runtime / "bin").mkdir(parents=True)
        binary = runtime / "bin/python3"
        binary.write_text("#!/bin/sh\nexec '" + str(self.python).replace("'", "'\\''") + "' \"$@\"\n")
        binary.chmod(0o700)
        result = self.run_installer("--initialize", "--runtime-root", str(runtime))
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = plistlib.loads(self.service.read_bytes())
        installed = Path(payload["ProgramArguments"][0])
        self.assertTrue(installed.is_relative_to(self.install / "runtimes"))
        self.assertEqual(installed.read_bytes(), binary.read_bytes())
        self.assertIn("-I", payload["ProgramArguments"])

    def test_writable_interpreter_is_rejected_without_creating_state(self):
        unsafe = self.python.with_name("unsafe-python3")
        shutil.copyfile(self.python, unsafe)
        unsafe.chmod(0o777)
        result = self.run_installer("--initialize", "--python", str(unsafe))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runtime must be an owned internal executable", result.stderr)
        self.assertFalse((self.install / "state/hub.sqlite3").exists())
        self.assertFalse(self.service.exists())

    def test_missing_initialize_does_not_create_database_or_service(self):
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--initialize", result.stderr)
        self.assertFalse((self.install / "state/hub.sqlite3").exists())
        self.assertFalse(self.service.exists())

    def test_existing_state_is_preserved_and_can_prepare_first_service(self):
        self.install.mkdir(mode=0o700)
        store = hub.Store.initialize(self.install / "state")
        with store.connect() as connection:
            workspace = hub.Store.workspace_in(connection)
        before = store.path.read_bytes()
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(store.path.read_bytes(), before)
        with store.connect() as connection:
            self.assertEqual(hub.Store.workspace_in(connection), workspace)

    def test_existing_database_is_never_reinitialized(self):
        self.install.mkdir(mode=0o700)
        store = hub.Store.initialize(self.install / "state")
        before = store.path.read_bytes()
        result = self.run_installer("--initialize")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(store.path.read_bytes(), before)
        self.assertFalse(self.service.exists())
        self.assertFalse((self.install / "bin/midas_usage_hub.py").exists())

    def test_existing_service_or_installation_is_never_overwritten(self):
        self.agents.mkdir(mode=0o700)
        self.service.write_bytes(b"existing service")
        result = self.run_installer("--initialize")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.service.read_bytes(), b"existing service")
        self.assertFalse((self.install / "state/hub.sqlite3").exists())

    def test_adopts_existing_workspace_without_exposing_metadata(self):
        workspace = {
            "schemaVersion": 1, "id": "6B329302-A41D-4B52-BC44-11554126EC86",
            "identitySalt": "workspace-private-salt-" + "a" * 64, "createdAt": 100,
        }
        file = self.root / "workspace.json"
        file.write_bytes(hub.canonical(workspace))
        file.chmod(0o600)
        result = self.run_installer("--initialize", "--workspace-file", str(file), "--port", "8767")
        self.assertEqual(result.returncode, 0, result.stderr)
        store = hub.Store(self.install / "state")
        with store.connect() as connection:
            self.assertEqual(hub.Store.workspace_in(connection), workspace)
        self.assertNotIn(workspace["identitySalt"], result.stdout + result.stderr)
        self.assertNotIn(workspace["id"], result.stdout + result.stderr)
        self.assertEqual(plistlib.loads(self.service.read_bytes())["ProgramArguments"][-1], "8767")

    def test_workspace_requires_explicit_initialization_and_private_permissions(self):
        workspace = self.root / "workspace.json"
        workspace.write_text("{}")
        workspace.chmod(0o644)
        no_init = self.run_installer("--workspace-file", str(workspace))
        self.assertNotEqual(no_init.returncode, 0)
        result = self.run_installer("--initialize", "--workspace-file", str(workspace))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.service.exists())
        self.assertFalse((self.install / "state/hub.sqlite3").exists())

    def test_external_roots_and_ancestor_links_are_rejected(self):
        result = self.run_installer("--initialize", "--install-root", "/Volumes/PortableSSD/test-hub")
        self.assertNotEqual(result.returncode, 0)
        linked = self.root / "linked"
        real = self.root / "real"
        real.mkdir(mode=0o700)
        linked.symlink_to(real)
        result = self.run_installer("--initialize", "--install-root", str(linked / "child"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((real / "child").exists())

    def test_existing_shared_launch_agents_permissions_are_preserved(self):
        self.agents.mkdir(mode=0o755)
        self.agents.chmod(0o755)
        result = self.run_installer("--initialize")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.agents.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.service.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
