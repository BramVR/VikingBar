import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("balance_ui_cleanup", ROOT / "Scripts/balance-ui-proof.py")
UI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UI)


def identity(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "pid=,ppid=,lstart=,command="],
                            capture_output=True, text=True, check=False, timeout=5,
                            env={"PATH": os.defpath, "LC_ALL": "C"})
    if result.returncode == 1 and not result.stdout.strip():
        return []
    row = result.stdout.strip().split(None, 7)
    if result.returncode or len(row) != 8 or row[0] != str(pid):
        raise AssertionError("synthetic fixture identity unavailable")
    return row


class BalanceUICleanupTests(unittest.TestCase):
    def test_inspection_failure_cleans_app_and_blocked_worker_but_not_lookalike(self):
        with tempfile.TemporaryDirectory(prefix="vikingbar-cleanup-test-") as directory:
            root = Path(directory)
            source = root / "fixture.c"
            source.write_text(FIXTURE)
            executable = root / "synthetic-app"
            subprocess.run(["clang", str(source), "-o", str(executable)], capture_output=True, check=True, timeout=30)
            cli = root / "synthetic-cli"
            cli.write_bytes(executable.read_bytes())
            cli.chmod(0o700)
            proof = UI.NativeProof.__new__(UI.NativeProof)
            proof.directory, proof.executable, proof.cli = root, executable, cli
            proof.executable_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
            proof.environment, proof.reference, proof.screens = {}, "synthetic-reference", []
            proof.process = proof.launch_record = proof.identity = None
            proof.launches, proof.workers = [], []
            worker_pid = None
            worker_identity = None
            lookalike = subprocess.Popen([str(cli), "session"], stdout=subprocess.DEVNULL)
            lookalike_identity = None
            def inspection_failure(*_args):
                UI.wait_for(lambda: (root / "worker-pid").exists(), bool, seconds=5)
                recorded = json.loads((root / "workers.json").read_text())
                self.assertEqual(recorded[0]["pid"], int((root / "worker-pid").read_text()))
                raise UI.UIFailure("synthetic-inspection-failed")
            proof.inspect = inspection_failure
            try:
                lookalike_identity = UI.wait_for(lambda: identity(lookalike.pid),
                                                lambda row: len(row) == 8 and row[7] == str(cli) + " session",
                                                seconds=5)
                with self.assertRaisesRegex(UI.UIFailure, "synthetic-inspection-failed"):
                    proof.launch(first=True)
                worker_pid = int((root / "worker-pid").read_text())
                worker_identity = identity(worker_pid)
                self.assertEqual(worker_identity[1], str(proof.process.pid))
                with patch.object(proof, "run", side_effect=UI.UIFailure("synthetic-no-native-ui")):
                    proof.cleanup()
                receipt = json.loads((root / "cleanup.json").read_text())
                self.assertTrue(receipt["exited"])
                self.assertIsNotNone(proof.process.poll())
                self.assertFalse(identity(worker_pid), "cleanup claimed success with an orphan worker")
                self.assertIsNone(lookalike.poll())
            finally:
                if worker_pid is None and proof.process is not None and proof.process.poll() is None:
                    UI.wait_for(lambda: (root / "worker-pid").exists(), bool, seconds=5)
                    worker_pid = int((root / "worker-pid").read_text())
                    worker_identity = identity(worker_pid)
                    self.assertEqual(worker_identity[1], str(proof.process.pid))
                if proof.process is not None and proof.process.poll() is None:
                    self.assertEqual(identity(proof.process.pid)[1], str(os.getpid()))
                    proof.process.terminate()
                    proof.process.wait(timeout=5)
                if worker_pid and identity(worker_pid):
                    current = identity(worker_pid)
                    self.assertEqual(current[0], worker_identity[0])
                    self.assertEqual(current[2:], worker_identity[2:])
                    self.assertIn(current[1], (str(proof.process.pid), "1"))
                    os.kill(worker_pid, signal.SIGTERM)
                    UI.wait_for(lambda: identity(worker_pid), lambda row: not row, seconds=5)
                if lookalike.poll() is None:
                    if lookalike_identity is None:
                        lookalike_identity = identity(lookalike.pid)
                        self.assertEqual(lookalike_identity[1], str(os.getpid()))
                    self.assertEqual(identity(lookalike.pid), lookalike_identity)
                    lookalike.terminate()
                    lookalike.wait(timeout=5)


class CleanupIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.proof = UI.NativeProof.__new__(UI.NativeProof)
        self.proof.directory = Path(self.temporary.name)
        self.proof.launches, self.proof.workers = [], []
        self.proof.run = Mock(side_effect=UI.UIFailure("synthetic-no-native-ui"))
        self.worker = {"pid": 12346, "parentPID": 12345, "startTime": "Mon Sep 7 08:00:00 2026",
                       "command": "/synthetic/cli session", "cliSHA256": "synthetic-hash",
                       "identity": "12346 12345 Mon Sep 7 08:00:00 2026 /synthetic/cli session"}

    def app(self, pid=12345):
        process = Mock(pid=pid, args=["synthetic-app"])
        process.poll.return_value = None
        def exited(**_kwargs):
            process.poll.return_value = 0
        process.wait.side_effect = exited
        record = {"pid": pid, "parentPID": os.getpid(), "arguments": process.args,
                  "startedAt": "synthetic-start", "executableSHA256": "old-hash",
                  "workerOwnershipEstablished": True}
        self.proof.launches.append((process, record))
        return process, record

    def test_launch_identity_failure_still_cleans_recorded_child(self):
        proof = self.proof
        proof.executable = proof.directory / "synthetic-app"
        proof.executable_hash, proof.environment, proof.reference = "original-hash", {}, "synthetic-reference"
        child, _record = self.app()
        proof.launches = []
        def launch(arguments, **_kwargs):
            child.args = arguments
            return child
        with patch.object(UI.subprocess, "Popen", side_effect=launch), \
                patch.object(UI, "process_identity", side_effect=UI.UIFailure("synthetic-identity-failed")):
            with self.assertRaisesRegex(UI.UIFailure, "synthetic-identity-failed"):
                proof.launch(first=True)
        with patch.object(UI, "process_identity", return_value=None):
            with self.assertRaisesRegex(UI.UIFailure, "cleanup-worker-ownership-unverified"):
                proof.cleanup()
        self.assertFalse(json.loads((proof.directory / "cleanup.json").read_text())["exited"])
        child.terminate.assert_called_once()
        child.kill.assert_not_called()
        record = json.loads((proof.directory / "cleanup-process.json").read_text())
        self.assertEqual(record["pid"], child.pid)
        self.assertEqual(record["parentPID"], os.getpid())
        self.assertTrue(record["startedAt"])

    def test_missing_startup_worker_fails_before_ui_and_never_claims_verified_cleanup(self):
        for parent_exited in (False, True):
            with self.subTest(parent_exited=parent_exited):
                proof = self.proof
                proof.executable = proof.directory / "synthetic-app"
                proof.cli = proof.directory / "synthetic-cli"
                proof.cli.write_bytes(b"synthetic")
                proof.executable_hash, proof.environment, proof.reference = "synthetic-hash", {}, "synthetic"
                proof.inspect = Mock()
                child, _record = self.app()
                proof.launches = []
                def launch(arguments, **_kwargs):
                    child.args = arguments
                    return child
                def missing_worker(*_args, **_kwargs):
                    if parent_exited:
                        child.poll.return_value = 0
                    return []
                with patch.object(UI.subprocess, "Popen", side_effect=launch), \
                        patch.object(UI, "process_identity", return_value={"identity": "synthetic app"}), \
                        patch.object(proof, "capture_worker", side_effect=missing_worker):
                    with self.assertRaisesRegex(UI.UIFailure, "runtime-worker-identity-mismatch"):
                        proof.launch(first=True)
                proof.inspect.assert_not_called()
                self.assertFalse(proof.workers)
                with patch.object(UI, "process_identity", return_value=None), \
                        patch.object(proof, "capture_worker", return_value=[]), patch.object(UI.os, "kill") as kill:
                    with self.assertRaisesRegex(UI.UIFailure, "cleanup-worker-ownership-unverified"):
                        proof.cleanup()
                kill.assert_not_called()
                self.assertEqual(child.terminate.call_count, 0 if parent_exited else 1)
                receipt = json.loads((proof.directory / "cleanup.json").read_text())
                self.assertFalse(receipt["exited"])
                self.assertEqual(receipt["error"], "cleanup-worker-ownership-unverified")

    def test_cleanup_kills_owned_child_after_termination_timeout(self):
        child, _record = self.app()
        def wait(**_kwargs):
            if child.wait.call_count == 1:
                raise subprocess.TimeoutExpired(child.args, 10)
            child.poll.return_value = -9
        child.wait.side_effect = wait
        with patch.object(UI, "process_identity", return_value=None):
            self.proof.cleanup()
        child.terminate.assert_called_once()
        child.kill.assert_called_once()
        self.assertEqual(child.wait.call_count, 2)

    def test_cleanup_rejects_an_unowned_process_and_writes_failure(self):
        child, record = self.app()
        record["parentPID"] = 99999
        with self.assertRaisesRegex(UI.UIFailure, "cleanup-ownership-unverified"):
            self.proof.cleanup()
        child.terminate.assert_not_called()
        self.assertFalse(json.loads((self.proof.directory / "cleanup.json").read_text())["exited"])

    def test_cleanup_reaps_all_launches_and_workers_when_evidence_write_fails(self):
        first, _record = self.app()
        second, _record = self.app(22345)
        self.proof.workers = [self.worker]
        with patch.object(UI, "process_identity", return_value=None), \
                patch.object(UI, "private_write", side_effect=OSError("synthetic disk full")), \
                patch.object(self.proof, "stop_worker") as stop:
            with self.assertRaises(OSError):
                self.proof.cleanup()
        for child in (first, second):
            child.terminate.assert_called_once()
            child.wait.assert_called_once_with(timeout=10)
        stop.assert_called_once_with(self.worker)

    def test_cleanup_handles_artifact_changed_without_rereading_binary(self):
        child, record = self.app()
        record["identity"] = "synthetic original app"
        self.proof.workers = [self.worker]
        with patch.object(self.proof, "capture_worker", return_value=[]), \
                patch.object(UI, "process_identity", return_value=None), \
                patch.object(Path, "read_bytes", side_effect=AssertionError("must use retained ownership")):
            self.proof.cleanup()
        child.terminate.assert_called_once()
        self.assertTrue(json.loads((self.proof.directory / "cleanup.json").read_text())["exited"])

    def test_changed_start_time_means_original_exited_without_signalling_replacement(self):
        self.proof.workers = [self.worker]
        with patch.object(UI, "process_identity", return_value=dict(self.worker, startTime="different")), \
                patch.object(UI.os, "kill") as kill:
            self.proof.cleanup()
        kill.assert_not_called()
        self.assertTrue(json.loads((self.proof.directory / "cleanup.json").read_text())["exited"])

    def test_changed_command_or_unexpected_parent_fails_closed(self):
        for altered in (dict(self.worker, command="unrelated"), dict(self.worker, parentPID=55555)):
            with self.subTest(altered=altered):
                self.proof.workers = [self.worker]
                with patch.object(UI, "process_identity", return_value=altered), patch.object(UI.os, "kill") as kill:
                    with self.assertRaisesRegex(UI.UIFailure, "cleanup-worker-identity-changed"):
                        self.proof.cleanup()
                kill.assert_not_called()
                receipt = json.loads((self.proof.directory / "cleanup.json").read_text())
                self.assertFalse(receipt["exited"])
                self.assertEqual(receipt["error"], "cleanup-worker-identity-changed")

    def test_worker_term_then_kill_rechecks_identity_and_accepts_reparenting(self):
        orphan = dict(self.worker, parentPID=1)
        with patch.object(UI, "process_identity", side_effect=[orphan, orphan, orphan, None]), \
                patch.object(UI.time, "monotonic", side_effect=[0, 4, 4]), patch.object(UI.os, "kill") as kill:
            self.proof.stop_worker(self.worker)
        self.assertEqual(kill.call_args_list, [unittest.mock.call(12346, signal.SIGTERM),
                                              unittest.mock.call(12346, signal.SIGKILL)])

    def test_worker_identity_change_before_kill_prevents_escalation(self):
        with patch.object(UI, "process_identity", side_effect=[self.worker, self.worker,
                                                               dict(self.worker, command="changed")]), \
                patch.object(UI.time, "monotonic", side_effect=[0, 4]), patch.object(UI.os, "kill") as kill:
            with self.assertRaisesRegex(UI.UIFailure, "cleanup-worker-identity-changed"):
                self.proof.stop_worker(self.worker)
        kill.assert_called_once_with(12346, signal.SIGTERM)

    def test_ps_missing_differs_from_failed_or_malformed_inspection(self):
        with patch.object(UI.subprocess, "run", return_value=Mock(returncode=1, stdout=b"")):
            self.assertIsNone(UI.process_identity(12346))
        for result in (Mock(returncode=2, stdout=b""), Mock(returncode=0, stdout=b"garbage"),
                       Mock(returncode=1, stdout=b"garbage")):
            with patch.object(UI.subprocess, "run", return_value=result):
                with self.assertRaisesRegex(UI.UIFailure, "cleanup-process-inspection-failed"):
                    UI.process_identity(12346)

    def test_inspection_timeout_writes_false_receipt_without_signalling_worker(self):
        self.proof.workers = [self.worker]
        with patch.object(UI, "process_identity", side_effect=subprocess.TimeoutExpired("ps", 5)), \
                patch.object(UI.os, "kill") as kill:
            with self.assertRaises(subprocess.TimeoutExpired):
                self.proof.cleanup()
        kill.assert_not_called()
        self.assertFalse(json.loads((self.proof.directory / "cleanup.json").read_text())["exited"])

    def test_runtime_worker_requires_exact_bundled_cli_and_parent_and_retains_replacements(self):
        process, launch = self.app()
        parent = dict(self.worker, pid=12345, parentPID=os.getpid(), identity="synthetic parent")
        launch.update(identity=parent["identity"], cli="/synthetic/cli", cliSHA256="synthetic-hash")
        for worker in (self.worker, dict(self.worker, pid=22346, startTime="later")):
            with patch.object(UI.subprocess, "run", return_value=Mock(returncode=0, stdout=str(worker["pid"]).encode())), \
                    patch.object(UI, "process_identity", side_effect=[parent, worker]):
                self.assertEqual(len(self.proof.capture_worker(process, launch)), 1)
        self.assertEqual(len(self.proof.workers), 2)
        for invalid in (dict(self.worker, parentPID=99999), dict(self.worker, command="/unrelated/cli session"),
                        dict(self.worker, command=self.worker["command"] + " --fixture finite")):
            with patch.object(UI.subprocess, "run", return_value=Mock(returncode=0, stdout=b"12346")), \
                    patch.object(UI, "process_identity", side_effect=[parent, invalid]):
                self.assertEqual(self.proof.capture_worker(process, launch), [])
        self.assertEqual(len(self.proof.workers), 2)

    def test_native_quit_uses_bounded_commands_before_parent_fallback(self):
        child, launch = self.app()
        launch["identity"] = "synthetic app"
        self.proof.run = Mock(side_effect=[b'{"elements":[{"AXIdentifier":"vikingbar.quit"}]}', b'{}'])
        with patch.object(self.proof, "capture_worker", return_value=[]), \
                patch.object(UI, "process_identity", return_value={"identity": "synthetic app"}):
            self.proof.cleanup()
        child.terminate.assert_not_called()
        child.wait.assert_called_once_with(timeout=3)
        self.assertTrue(all(call.kwargs["timeout"] == 2 for call in self.proof.run.call_args_list))


FIXTURE = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "session") == 0) {
        for (;;) pause();
    }
    char cli[4096], receipt[4096];
    snprintf(cli, sizeof(cli), "%s/synthetic-cli", argv[2]);
    snprintf(receipt, sizeof(receipt), "%s/worker-pid", argv[2]);
    pid_t worker = fork();
    if (worker == 0) {
        execl(cli, cli, "session", NULL);
        _exit(2);
    }
    FILE *file = fopen(receipt, "w");
    fprintf(file, "%d", worker);
    fclose(file);
    for (;;) pause();
}
'''


if __name__ == "__main__":
    unittest.main()
