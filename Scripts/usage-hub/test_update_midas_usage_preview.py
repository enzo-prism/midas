"""Run updater Python against synthetic apps only; all process/signing/open calls are stubbed."""

import contextlib
import errno
import hashlib
import io
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


class PreviewUpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="midas-preview-update-tests-")
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.home = self.root / "synthetic-home"
        self.home.mkdir(mode=0o700)
        self.source = self.root / "New preview build.app"
        self.destination = self.home / "Applications/Midas Tailscale Preview.app"
        self.old_binary = b"synthetic old Midas executable"
        self.new_binary = b"synthetic new Midas executable"
        self.write_app(self.destination, self.old_binary, b"old sealed resources")
        self.write_app(self.source, self.new_binary, b"new sealed resources")
        self.support = self.home / "Library/Application Support/Midas/usage-sync"
        self.support.mkdir(mode=0o700, parents=True)
        self.connection = self.support / "hub-connection.json"
        self.connection.write_bytes(b'{"credential":"synthetic-private-sync-credential"}')
        self.connection.chmod(0o600)
        self.history = self.support / "hub-state.json"
        self.history.write_bytes(b'{"fixture":true,"tokens":600,"estimatedUSD":0.0014}')
        self.history.chmod(0o600)
        self.preferences = self.home / "Library/Preferences/com.designprism.midas.debug.plist"
        self.preferences.parent.mkdir(mode=0o700, parents=True)
        self.preferences.write_bytes(plistlib.dumps({"midasUsageSyncEnabled": True, "fixtureOnly": True}))
        self.preferences.chmod(0o600)
        self.private_before = {path: (path.read_bytes(), path.stat().st_mode & 0o777)
                               for path in (self.connection, self.history, self.preferences)}
        self.script = Path(__file__).resolve().parents[1] / "update_midas_usage_preview.sh"
        source = self.script.read_text()
        self.embedded = source.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        preview = str(self.destination / "Contents/MacOS/Midas")
        self.processes = {
            2101: preview,
            2102: preview + " --synthetic-debug-flag",
            3101: str(self.home / "Applications/Midas.app/Contents/MacOS/Midas"),
            3102: preview + "-unrelated",
            3103: str(self.source / "Contents/MacOS/Midas"),
            3104: "/usr/bin/python3 --description '" + preview + "'",
        }
        self.signals = []
        self.commands = []
        self.identical_build_reopen = False
        self.output = io.StringIO()

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def write_app(path, binary, sealed_resources, resource=b"synthetic resource"):
        for subdirectory in ("MacOS", "_CodeSignature", "Resources"):
            (path / "Contents" / subdirectory).mkdir(mode=0o700, parents=True, exist_ok=True)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.designprism.midas.debug", "CFBundleExecutable": "Midas",
            "CFBundleShortVersionString": "fixture-1",
        }))
        (path / "Contents/MacOS/Midas").write_bytes(binary)
        (path / "Contents/_CodeSignature/CodeResources").write_bytes(sealed_resources)
        (path / "Contents/Resources/fixture.txt").write_bytes(resource)

    @staticmethod
    def digest(path):
        value = hashlib.sha256()
        for name in ("Contents/MacOS/Midas", "Contents/Info.plist", "Contents/_CodeSignature/CodeResources"):
            value.update((path / name).read_bytes())
        return value.hexdigest()

    def run_command(self, arguments, **kwargs):
        # Unexpected commands fail the test instead of reaching any real external process.
        self.commands.append(tuple(arguments))
        executable = arguments[0]
        if executable == "/bin/ps":
            self.assertEqual(arguments, ["/bin/ps", "-axo", "pid=,command="])
            terminated = {pid for pid, _ in self.signals}
            output = "\n".join(str(pid) + " " + command for pid, command in self.processes.items()
                               if pid not in terminated)
            return subprocess.CompletedProcess(arguments, 0, stdout=output, stderr="")
        if executable == "/usr/bin/codesign":
            self.assertEqual(arguments[1:4], ["--verify", "--deep", "--strict"])
            app = Path(arguments[-1])
            self.assertTrue(app.is_relative_to(self.root))
            self.assertTrue((app / "Contents/Info.plist").is_file())
            self.assertTrue(kwargs.get("check"))
            return subprocess.CompletedProcess(arguments, 0)
        if executable == "/usr/bin/open":
            expected = ["/usr/bin/open", str(self.destination)] if self.identical_build_reopen else [
                "/usr/bin/open", "-n", str(self.destination)]
            self.assertEqual(arguments, expected)
            self.assertTrue(self.destination.exists())
            self.assertTrue(kwargs.get("check"))
            return subprocess.CompletedProcess(arguments, 0)
        raise AssertionError("Unexpected external command blocked by fixture")

    def signal_process(self, pid, kind):
        self.assertIn(pid, self.processes)
        self.assertEqual(kind, signal.SIGTERM)
        self.signals.append((pid, kind))

    def execute(self, rename=None):
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(Path, "home", return_value=self.home))
            stack.enter_context(mock.patch.object(sys, "argv", ["synthetic-updater", str(self.source)]))
            stack.enter_context(mock.patch("subprocess.run", side_effect=self.run_command))
            stack.enter_context(mock.patch("os.kill", side_effect=self.signal_process))
            stack.enter_context(mock.patch("os.umask", return_value=0o077))
            stack.enter_context(mock.patch("time.sleep"))
            stack.enter_context(contextlib.redirect_stdout(self.output))
            if rename is not None:
                stack.enter_context(mock.patch.object(Path, "rename", autospec=True, side_effect=rename))
            exec(compile(self.embedded, str(self.script), "exec"), {"__name__": "__main__"})

    def assert_private_state_unchanged(self):
        for path, (contents, mode) in self.private_before.items():
            self.assertEqual(path.read_bytes(), contents)
            self.assertEqual(path.stat().st_mode & 0o777, mode)
        self.assertNotIn("synthetic-private-sync-credential", self.output.getvalue())

    def test_app_only_update_preserves_connection_history_preferences_and_verified_backup(self):
        old_hash = self.digest(self.destination)
        new_hash = self.digest(self.source)
        self.execute()
        self.assertEqual(self.digest(self.destination), new_hash)
        backup = self.destination.parent / ("Midas Tailscale Preview-backup-" + old_hash[:12] + ".app")
        self.assertTrue(backup.is_dir())
        self.assertEqual(self.digest(backup), old_hash)
        self.assertEqual((backup / "Contents/MacOS/Midas").read_bytes(), self.old_binary)
        self.assertEqual(self.digest(self.source), new_hash)
        self.assertEqual(sum(command[0] == "/usr/bin/open" for command in self.commands), 1)
        self.assertTrue(any(command[0] == "/usr/bin/codesign" and ".Midas-preview-stage-" in command[-1]
                            for command in self.commands))
        self.assert_private_state_unchanged()

    def test_only_exact_preview_processes_are_signaled_and_stable_midas_keeps_running(self):
        self.execute()
        self.assertEqual({pid for pid, _ in self.signals}, {2101, 2102})
        self.assertTrue({3101, 3102, 3103, 3104}.isdisjoint(pid for pid, _ in self.signals))
        self.assert_private_state_unchanged()

    def test_existing_backup_collision_refuses_all_installation_and_process_mutations(self):
        old_hash = self.digest(self.destination)
        backup = self.destination.parent / ("Midas Tailscale Preview-backup-" + old_hash[:12] + ".app")
        backup.mkdir(mode=0o700)
        marker = backup / "preserve-this-existing-backup"
        marker.write_bytes(b"existing backup fixture")
        with self.assertRaises(SystemExit) as caught:
            self.execute()
        self.assertIn("already exists", str(caught.exception))
        self.assertEqual(self.digest(self.destination), old_hash)
        self.assertEqual(marker.read_bytes(), b"existing backup fixture")
        self.assertEqual(self.signals, [])
        self.assertFalse(any(command[0] == "/usr/bin/open" for command in self.commands))
        self.assertEqual(list(self.destination.parent.glob(".Midas-preview-stage-*.app")), [])
        self.assert_private_state_unchanged()

    def test_injected_stage_rename_failure_restores_original_installed_app(self):
        old_hash = self.digest(self.destination)
        original_rename = Path.rename
        attempted_replacement = []

        def rename(path, destination):
            path, destination = Path(path), Path(destination)
            self.assertTrue(path.is_relative_to(self.root) and destination.is_relative_to(self.root))
            if path.name.startswith(".Midas-preview-stage-") and destination == self.destination:
                attempted_replacement.append(True)
                raise OSError(errno.EIO, "Synthetic rename failure")
            return original_rename(path, destination)

        with self.assertRaises(OSError) as caught:
            self.execute(rename=rename)
        self.assertEqual(caught.exception.errno, errno.EIO)
        self.assertEqual(attempted_replacement, [True])
        self.assertEqual(self.digest(self.destination), old_hash)
        self.assertEqual((self.destination / "Contents/MacOS/Midas").read_bytes(), self.old_binary)
        self.assertEqual(len(list(self.destination.parent.glob(".Midas-preview-stage-*.app"))), 1)
        self.assertEqual(list(self.destination.parent.glob("Midas Tailscale Preview-backup-*.app")), [])
        self.assertFalse(any(command[0] == "/usr/bin/open" for command in self.commands))
        self.assert_private_state_unchanged()

    def test_same_main_binary_with_new_sealed_resources_still_updates(self):
        (self.source / "Contents/MacOS/Midas").write_bytes(self.old_binary)
        (self.source / "Contents/Resources/fixture.txt").write_bytes(b"new image/resource fixture")
        expected = self.digest(self.source)
        self.assertNotEqual(expected, self.digest(self.destination))
        self.execute()
        self.assertEqual(self.digest(self.destination), expected)
        self.assertEqual((self.destination / "Contents/Resources/fixture.txt").read_bytes(), b"new image/resource fixture")
        self.assertEqual((self.destination / "Contents/MacOS/Midas").read_bytes(), self.old_binary)
        self.assertEqual(len(list(self.destination.parent.glob("Midas Tailscale Preview-backup-*.app"))), 1)
        self.assert_private_state_unchanged()

    def test_identical_build_reopen_is_idempotent_and_never_starts_duplicate_writer(self):
        (self.source / "Contents/MacOS/Midas").write_bytes(self.old_binary)
        (self.source / "Contents/_CodeSignature/CodeResources").write_bytes(b"old sealed resources")
        old_hash = self.digest(self.destination)
        self.assertEqual(self.digest(self.source), old_hash)
        self.identical_build_reopen = True
        with self.assertRaises(SystemExit) as caught:
            self.execute()
        self.assertEqual(caught.exception.code, 0)
        self.assertEqual(self.digest(self.destination), old_hash)
        self.assertEqual(self.signals, [])
        self.assertEqual(list(self.destination.parent.glob(".Midas-preview-stage-*.app")), [])
        self.assertEqual(list(self.destination.parent.glob("Midas Tailscale Preview-backup-*.app")), [])
        opens = [command for command in self.commands if command[0] == "/usr/bin/open"]
        self.assertEqual(opens, [("/usr/bin/open", str(self.destination))])
        self.assertNotIn("-n", opens[0])
        self.assertFalse(any(command[0] == "/bin/ps" for command in self.commands))
        self.assert_private_state_unchanged()


if __name__ == "__main__":
    unittest.main()
