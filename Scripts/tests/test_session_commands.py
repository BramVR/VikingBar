"""Exercise production session framing with an injected, suspended session."""

import json
from pathlib import Path
import select
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SessionCommandTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="vikingbar-session-test-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.executable = Path(cls.temp.name) / "session-driver"
        build = ROOT / ".build/debug"
        sources = [ROOT / "Scripts/tests/session-command-driver.swift"]
        sources.extend(ROOT / "Sources/VikingBarCLI" / name for name in (
            "SessionCommands.swift", "LiveCommands.swift", "BalanceOracle.swift", "HistoryOracle.swift"))
        objects = list((build / "VikingBarCore.build").glob("*.swift.o"))
        if not objects:
            raise AssertionError("Run swift build before session tests")
        compiled = subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library",
                                   "-I", str(build / "Modules"), *map(str, sources), *map(str, objects),
                                   "-o", str(cls.executable)], cwd=ROOT, capture_output=True, text=True)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)

    def start(self):
        process = subprocess.Popen([str(self.executable)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.addCleanup(self.stop, process)
        return process

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
        for pipe in (process.stdin, process.stdout, process.stderr):
            if pipe is not None:
                pipe.close()

    def line(self, pipe):
        self.assertTrue(select.select([pipe], [], [], 3)[0], "session did not respond while refresh was pending")
        return pipe.readline()

    @staticmethod
    def send(process, command):
        process.stdin.write(json.dumps(command).encode() + b"\n")

    def refreshing(self):
        process = self.start()
        self.send(process, {"command": "refresh"})
        self.assertEqual(self.line(process.stderr), b"refresh-started\n")
        return process

    def test_cancel_interrupts_refresh_and_next_command_still_runs_in_order(self):
        process = self.refreshing()
        self.send(process, {"command": "cancel"})
        first = json.loads(self.line(process.stdout))
        second = json.loads(self.line(process.stdout))
        self.assertEqual(first["error"], "session-command-failed")
        self.assertNotIn("error", second)
        self.send(process, {"command": "selectBundle", "index": 7})
        third = json.loads(self.line(process.stdout))
        self.assertEqual(third["state"]["selectedBundleIndex"], 7)
        self.send(process, {"command": "shutdown"})
        self.assertNotIn("error", json.loads(self.line(process.stdout)))
        self.assertEqual(process.wait(timeout=3), 0)

    def test_shutdown_interrupts_refresh_and_drains_ordered_responses(self):
        process = self.refreshing()
        self.send(process, {"command": "shutdown"})
        self.assertEqual(json.loads(self.line(process.stdout))["error"], "session-command-failed")
        self.assertNotIn("error", json.loads(self.line(process.stdout)))
        self.assertEqual(process.wait(timeout=3), 0)

    def test_eof_interrupts_refresh(self):
        process = self.refreshing()
        process.stdin.close()
        self.assertEqual(json.loads(self.line(process.stdout))["error"], "session-command-failed")
        self.assertEqual(process.wait(timeout=3), 0)

    def test_invalid_command_interrupts_refresh_and_error_follows_its_response(self):
        process = self.refreshing()
        self.send(process, {"command": "restore", "password": "private-sentinel"})
        self.assertEqual(json.loads(self.line(process.stdout))["error"], "session-command-failed")
        failure = self.line(process.stdout)
        self.assertEqual(json.loads(failure)["error"], "invalid-session-command")
        self.assertNotIn(b"private-sentinel", failure)
        self.assertEqual(process.wait(timeout=3), 1)

    def test_cancel_skips_queued_operations(self):
        process = self.refreshing()
        self.send(process, {"command": "selectBundle", "index": 7})
        self.send(process, {"command": "cancel"})
        replies = [json.loads(self.line(process.stdout)) for _ in range(3)]
        self.assertEqual([reply.get("error") for reply in replies],
                         ["session-command-failed", "session-command-failed", None])
        self.assertTrue(all(reply["state"].get("selectedBundleIndex") is None for reply in replies))
        self.send(process, {"command": "shutdown"})
        self.line(process.stdout)
        self.assertEqual(process.wait(timeout=3), 0)
