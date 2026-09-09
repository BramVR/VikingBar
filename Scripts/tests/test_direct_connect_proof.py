import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("direct_balance_ui", ROOT / "Scripts/balance-ui-proof.py")
UI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UI)


class DirectConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.reference = self.directory / "reference.json"
        self.reference.write_text(json.dumps({"vault": "Codex Automation", "item_id": "synthetic",
                                              "fields": ["client_id", "username", "password"]}))
        self.config = self.directory / "config.json"
        self.now = datetime.datetime(2026, 9, 8, tzinfo=datetime.timezone.utc)
        self.value = {"schema_version": 1, "check": "direct-connect-ui", "source_sha256": "synthetic-source",
                      "credential_reference_sha256": hashlib.sha256(self.reference.read_bytes()).hexdigest(),
                      "expires_at": "2026-09-08T00:30:00Z", "tmux_session": "approved-synthetic",
                      "credential_slot": "synthetic-credential-slot", "mac_ui_slot": "synthetic-mac-slot"}
        self.environment = {"VIKINGBAR_DIRECT_CONNECT_CONFIG": str(self.config),
                            "VIKINGBAR_CREDENTIAL_REFERENCE": str(self.reference), "TMUX": "synthetic-tmux",
                            "BRAM_OP_SERVICE_ACCOUNT_TOKEN": "synthetic-token",
                            "VIKINGBAR_CREDENTIAL_SLOT": self.value["credential_slot"],
                            "VIKINGBAR_MAC_UI_SLOT": self.value["mac_ui_slot"],
                            "VIKINGBAR_SLOT_BINDINGS_EXPIRES_AT": self.value["expires_at"]}
        self.write_config()

    def write_config(self):
        self.config.write_text(json.dumps(self.value))
        self.config.chmod(0o600)
        self.environment["VIKINGBAR_DIRECT_CONNECT_CONFIG_SHA256"] = hashlib.sha256(self.config.read_bytes()).hexdigest()

    def validate(self):
        with patch.object(UI, "source_digest", return_value="synthetic-source"):
            return UI.direct_configuration(self.environment, self.now)

    def test_matching_private_reviewed_configuration(self):
        self.assertEqual(self.validate(), self.value)

    def test_missing_stale_or_changed_configuration_fails_before_runtime(self):
        for key in tuple(self.environment):
            environment = dict(self.environment)
            del environment[key]
            with self.subTest(key=key), patch.object(UI, "source_digest", return_value="synthetic-source"):
                with self.assertRaisesRegex(UI.UIFailure, "direct-proof-configuration-required"):
                    UI.direct_configuration(environment, self.now)
        for key, value in (("schema_version", True), ("check", "balance-ui"), ("source_sha256", "changed"),
                           ("credential_reference_sha256", "changed"), ("expires_at", "2026-09-08T00:00:00Z"),
                           ("expires_at", "2026-09-08T02:00:00Z"), ("credential_slot", ""), ("mac_ui_slot", "")):
            before = dict(self.value)
            self.value[key] = value
            self.write_config()
            with self.subTest(key=key, value=value), self.assertRaises(UI.UIFailure):
                self.validate()
            self.value = before
        self.write_config()
        self.config.chmod(0o644)
        with self.assertRaises(UI.UIFailure):
            self.validate()

    def test_slot_bindings_reject_inactive_mismatching_and_expired_values(self):
        for key, variable in (("credential_slot", "VIKINGBAR_CREDENTIAL_SLOT"),
                              ("mac_ui_slot", "VIKINGBAR_MAC_UI_SLOT")):
            for invalid in ("INACTIVE", " inactive ", "PENDING", "DISABLED", "NONE"):
                old_value, old_binding = self.value[key], self.environment[variable]
                self.value[key] = self.environment[variable] = invalid
                self.write_config()
                with self.subTest(key=key, invalid=invalid), self.assertRaises(UI.UIFailure):
                    self.validate()
                self.value[key], self.environment[variable] = old_value, old_binding
            self.write_config()
            self.environment[variable] = "different-active-slot"
            with self.assertRaises(UI.UIFailure):
                self.validate()
            self.environment[variable] = self.value[key]
        self.environment["VIKINGBAR_SLOT_BINDINGS_EXPIRES_AT"] = "2026-09-08T00:29:00Z"
        with self.assertRaises(UI.UIFailure):
            self.validate()
        self.value["expires_at"] = self.environment["VIKINGBAR_SLOT_BINDINGS_EXPIRES_AT"] = "2026-09-07T23:59:00Z"
        self.write_config()
        with self.assertRaises(UI.UIFailure):
            self.validate()

    def test_configuration_hash_is_required_even_when_json_matches(self):
        self.config.write_text(self.config.read_text() + "\n")
        with self.assertRaises(UI.UIFailure):
            self.validate()

    def test_unconfigured_direct_proof_never_builds_launches_or_reads_credentials(self):
        with patch.object(UI.subprocess, "run") as execute, patch.object(UI.NativeProof, "perform") as perform:
            with self.assertRaises(UI.UIFailure):
                UI.run({}, direct_connect=True)
        execute.assert_not_called()
        perform.assert_not_called()


class DirectInputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.proof = UI.NativeProof.__new__(UI.NativeProof)
        self.proof.directory = Path(self.temporary.name)
        self.proof.reference = "synthetic-reference"
        self.proof.environment = {"PATH": "/synthetic", "BRAM_OP_SERVICE_ACCOUNT_TOKEN": "synthetic-token",
                                  "TMUX": "synthetic", "PASSWORD": "must-not-inherit", "DYLD_INSERT_LIBRARIES": "bad"}
        self.proof.process = type("Process", (), {"pid": 123})()
        self.proof.launch_record = {"pid": 123}
        self.proof.screens = [{"bounds": {"x": 0, "y": 0, "width": 1000, "height": 800}}]
        self.form = {"elements": [{"AXRole": "AXPopover", "frame": [[100, 24], [500, 700]]}]
                     + [{"AXIdentifier": "vikingbar.connect." + key, "frame": [[120, 100], [200, 20]]}
                        for key in ("client-id", "username", "password", "submit", "cancel")],
                     "windows": [{"kCGWindowNumber": 42,
                                  "kCGWindowBounds": {"X": 100, "Y": 24, "Width": 500, "Height": 700}}]}
        self.form["elements"][3].update(AXRole="AXTextField", AXSubrole="AXSecureTextField")
        self.tree = {"elements": [{"AXIdentifier": "vikingbar.connect.direct"}]}
        self.credential = {"client_id": "synthetic-client", "username": "synthetic-user", "password": "SECRET-SENTINEL"}
        self.receipt = {"schema_version": 1, "check": "connect", "passed": True, "connected": True}

    def exercise(self, failure=None, fill_stdout=b'{"filled":true}'):
        calls = []
        def execute(command, **kwargs):
            calls.append((command, kwargs))
            if command[0] == "/synthetic/op":
                raw = {"fields": [{"label": key, "value": value} for key, value in self.credential.items()]}
                return subprocess.CompletedProcess(command, 0, json.dumps(raw).encode())
            if failure:
                raise subprocess.TimeoutExpired(command, 10, output=b"SECRET-SENTINEL")
            if fill_stdout == b'{"filled":true}':
                UI.private_write(self.proof.directory / "connect-result.json", self.receipt)
            return subprocess.CompletedProcess(command, 0, fill_stdout)
        with patch.object(UI, "direct_configuration"), \
                patch.object(UI.CONNECT, "reference_at", return_value={"item_id": "synthetic", "vault": "Codex Automation"}), \
                patch.object(UI.shutil, "which", return_value="/synthetic/op"), \
                patch.object(UI.subprocess, "run", side_effect=execute), \
                patch.object(self.proof, "inspect", return_value=self.form) as inspect, \
                patch.object(self.proof, "press") as press, patch.object(self.proof, "verify_process"), \
                patch.object(self.proof, "capture_direct_child", return_value={"pid": 456}) as capture, \
                patch.object(self.proof, "worker_present", return_value=False):
            if failure:
                with self.assertRaisesRegex(UI.UIFailure, "^native-direct-input-failed$"):
                    self.proof.connect_direct(self.tree)
            elif fill_stdout != b'{"filled":true}':
                with self.assertRaisesRegex(UI.UIFailure, "^native-direct-fill-failed$"):
                    self.proof.connect_direct(self.tree)
                self.assertEqual(press.call_count, 1)
            else:
                self.proof.connect_direct(self.tree)
            if not failure and fill_stdout == b'{"filled":true}':
                capture.assert_called_once_with(self.proof.launch_record, acknowledge=True, seconds=10)
                self.assertTrue(self.proof.launch_record["connectOwnershipRequired"])
            self.assertEqual(inspect.call_count, 1)
            self.assertEqual(press.call_args_list[0].args, ("vikingbar.connect.direct",))
        return calls

    def test_single_external_read_and_private_pipe_without_secret_arguments_or_environment(self):
        calls = self.exercise()
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][0][1:], ["item", "get", "synthetic", "--vault", "Codex Automation", "--format", "json"])
        self.assertEqual(json.loads(calls[1][1]["input"]), self.credential)
        for command, kwargs in calls:
            self.assertNotIn("SECRET-SENTINEL", json.dumps(command))
            self.assertNotIn("SECRET-SENTINEL", json.dumps(kwargs["env"]))
            self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
        self.assertEqual(calls[0][1]["env"], {"PATH": "/synthetic", "OP_SERVICE_ACCOUNT_TOKEN": "synthetic-token"})
        self.assertEqual(calls[1][1]["env"], {"PATH": "/synthetic"})
        for path in self.proof.directory.iterdir():
            self.assertNotIn("SECRET-SENTINEL", path.read_text())

    def test_input_timeout_has_only_fixed_diagnostic_and_no_artifact(self):
        self.exercise(failure=True)
        self.assertEqual(list(self.proof.directory.iterdir()), [])

    def test_malformed_fill_output_never_leaks_secret_or_submits(self):
        for output in (b"SECRET-SENTINEL", b'{"filled":true,"private":"SECRET-SENTINEL"}',
                       b'{"filled":true}\nSECRET-SENTINEL'):
            with self.subTest(output=output):
                self.exercise(fill_stdout=output)
                self.assertEqual(list(self.proof.directory.iterdir()), [])

    def test_unmatched_form_fails_before_credential_read(self):
        self.form["elements"].pop()
        with patch.object(self.proof, "inspect", return_value=self.form), patch.object(self.proof, "press"), \
                patch.object(UI.subprocess, "run") as execute:
            with self.assertRaisesRegex(UI.UIFailure, "native-direct-form-not-visible"):
                self.proof.connect_direct(self.tree)
        execute.assert_not_called()

    def test_runtime_rejects_wrong_tmux_session_and_missing_exec_denial(self):
        self.proof.executable = Path("/synthetic/VikingBarApp")
        self.proof.cli = Path("/synthetic/vikingbar")
        for session_name, denial_exit, expected in ((b"wrong", 1, "direct-proof-tmux-mismatch"),
                                                    (("approved " + str(UI.os.getpid())).encode(), 0, "direct-proof-exec-restriction-failed")):
            results = [subprocess.CompletedProcess([], 0, session_name),
                       subprocess.CompletedProcess([], denial_exit, b"")]
            with self.subTest(expected=expected), \
                    patch.object(UI, "direct_configuration", return_value={"tmux_session": "approved"}), \
                    patch.object(UI.shutil, "which", return_value="/synthetic/tmux"), \
                    patch.object(UI.Path, "is_file", return_value=True), \
                    patch.object(UI.subprocess, "run", side_effect=results) as execute, \
                    patch.object(self.proof, "run") as allow_probe:
                with self.assertRaisesRegex(UI.UIFailure, expected):
                    self.proof.prepare_direct()
                allow_probe.assert_not_called()
                self.assertFalse(any("op" == Path(call.args[0][0]).name for call in execute.call_args_list))

    def test_preflight_requires_pane_ancestry_and_both_sandbox_probes(self):
        self.proof.executable = Path("/synthetic/VikingBarApp")
        self.proof.cli = Path("/synthetic/vikingbar")
        self.proof.environment["VIKINGBAR_DIRECT_CONNECT_CONFIG_SHA256"] = "synthetic-config-hash"
        cases = [
            ("descendant", [(0, b"222"), (0, b"111")], 1, None, None),
            ("unrelated-pane", [(0, b"1")], 1, None, "direct-proof-tmux-mismatch"),
            ("missing-parent", [(1, b"")], 1, None, "direct-proof-tmux-mismatch"),
            ("malformed-parent", [(0, b"SECRET-SENTINEL")], 1, None, "direct-proof-tmux-mismatch"),
            ("ancestry-cycle", [(0, b"333")] * 64, 1, None, "direct-proof-tmux-mismatch"),
            ("denial-missing", [(0, b"111")], 0, None, "direct-proof-exec-restriction-failed"),
            ("allow-failed", [(0, b"111")], 1, UI.UIFailure("proof-command-failed"), "proof-command-failed"),
        ]
        for name, parents, denial_exit, allow_error, expected in cases:
            calls = []
            remaining_parents = iter(parents)
            def execute(command, **kwargs):
                calls.append(command)
                self.assertNotIn("BRAM_OP_SERVICE_ACCOUNT_TOKEN", kwargs["env"])
                self.assertNotIn("OP_SERVICE_ACCOUNT_TOKEN", kwargs["env"])
                if command[0] == "/synthetic/tmux":
                    return subprocess.CompletedProcess(command, 0, b"approved 111")
                if command[0] == "/bin/ps":
                    code, output = next(remaining_parents)
                    return subprocess.CompletedProcess(command, code, output)
                self.assertEqual(command[0], "/usr/bin/sandbox-exec")
                self.assertEqual(command[-1], "/usr/bin/true")
                return subprocess.CompletedProcess(command, denial_exit, b"")
            config = {"tmux_session": "approved", "source_sha256": "synthetic-source"}
            with self.subTest(name=name), \
                    patch.object(UI, "direct_configuration", return_value=config), \
                    patch.object(UI.shutil, "which", return_value="/synthetic/tmux"), \
                    patch.object(UI.Path, "is_file", return_value=True), \
                    patch.object(UI.os, "getpid", return_value=333), \
                    patch.object(UI.subprocess, "run", side_effect=execute), \
                    patch.object(self.proof, "run", side_effect=allow_error) as allow_probe, \
                    patch.object(UI, "private_write") as write:
                if expected:
                    with self.assertRaisesRegex(UI.UIFailure, "^" + expected + "$"):
                        self.proof.prepare_direct()
                    write.assert_not_called()
                else:
                    self.proof.prepare_direct()
                    write.assert_called_once()
                    self.assertIs(write.call_args.args[1]["processExecRestricted"], True)
                    self.assertEqual([call[2] for call in calls if call[0] == "/bin/ps"], ["333", "222"])
                if expected == "direct-proof-tmux-mismatch":
                    self.assertFalse(any(call[0] == "/usr/bin/sandbox-exec" for call in calls))
                if expected in {"direct-proof-tmux-mismatch", "direct-proof-exec-restriction-failed"}:
                    allow_probe.assert_not_called()
                else:
                    allow_probe.assert_called_once_with([
                        "/usr/bin/sandbox-exec", "-p", UI.direct_sandbox(self.proof.executable, self.proof.cli),
                        str(self.proof.cli), "--fixture", "finite"])

    def test_exec_policy_allows_only_exact_app_and_cli(self):
        policy = UI.direct_sandbox(Path('/synthetic/VikingBarApp'), Path('/synthetic/vikingbar'))
        self.assertEqual(policy, '(version 1)(allow default)(deny process-exec)'
                         '(allow process-exec (literal "/synthetic/VikingBarApp") (literal "/synthetic/vikingbar"))')
        self.assertNotIn('subpath', policy)
        self.assertNotIn('op"', policy)
        self.assertNotIn('tmux', policy)


class DirectChildOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.proof = UI.NativeProof.__new__(UI.NativeProof)
        self.proof.directory = Path(self.temporary.name)
        self.proof.cli = self.proof.directory / "synthetic-cli"
        self.proof.cli.write_bytes(b"synthetic executable")
        self.proof.environment = {"PATH": "/poisoned-path", "BRAM_OP_SERVICE_ACCOUNT_TOKEN": "SECRET-SENTINEL",
                                  "OP_SERVICE_ACCOUNT_TOKEN": "SECRET-SENTINEL", "DYLD_INSERT_LIBRARIES": "bad"}
        self.proof.workers = []
        self.app = Mock(pid=123, args=["synthetic-app"])
        self.app.poll.return_value = None
        self.app.wait.side_effect = lambda **_kwargs: setattr(self.app.poll, "return_value", 0)
        self.launch = {"pid": 123, "parentPID": UI.os.getpid(), "arguments": self.app.args,
                       "identity": "synthetic app", "cli": str(self.proof.cli),
                       "cliSHA256": hashlib.sha256(self.proof.cli.read_bytes()).hexdigest(),
                       "workerOwnershipEstablished": True, "connectOwnershipRequired": True}
        self.proof.launches = [(self.app, self.launch)]
        self.worker = {"pid": 456, "parentPID": 123, "startTime": "Tue Sep 8 10:00:00 2026",
                       "command": str(self.proof.cli) + " connect", "identity": "synthetic connect child"}
        UI.private_write(self.proof.directory / "direct-connect-child.json",
                         {"schema_version": 1, "pid": 456, "parentPID": 123})

    def establish(self):
        publish = UI.private_publish
        def checked_publish(path, value):
            recorded = json.loads((self.proof.directory / "workers.json").read_text())
            self.assertEqual(recorded[0]["startTime"], self.worker["startTime"])
            self.assertEqual(recorded[0]["command"], self.worker["command"])
            self.assertEqual(recorded[0]["cliSHA256"], self.launch["cliSHA256"])
            publish(path, value)
        with patch.object(UI, "process_identity", return_value=dict(self.worker)), \
                patch.object(UI, "private_publish", side_effect=checked_publish):
            self.proof.capture_direct_child(self.launch, acknowledge=True)

    def test_child_identity_is_persisted_before_atomic_input_ack(self):
        self.establish()
        ready = self.proof.directory / "direct-connect-child-ready.json"
        self.assertEqual(json.loads(ready.read_text()), {"schema_version": 1, "pid": 456})
        self.assertEqual(ready.stat().st_mode & 0o777, 0o600)
        self.assertTrue(self.launch["connectOwnershipEstablished"])
        with self.assertRaises(FileExistsError):
            UI.private_publish(ready, {"schema_version": 1, "pid": 999})
        self.assertEqual(json.loads(ready.read_text())["pid"], 456)

    def test_missing_or_malformed_candidate_never_acknowledges_input(self):
        path = self.proof.directory / "direct-connect-child.json"
        for candidate in (None, {"schema_version": 1, "pid": True, "parentPID": 123},
                          {"schema_version": 1, "pid": 456, "parentPID": 999},
                          {"schema_version": 1, "pid": 456, "parentPID": 123, "raw": "SECRET-SENTINEL"}):
            if candidate is None:
                path.unlink()
            else:
                UI.private_write(path, candidate)
            with self.subTest(candidate=candidate), patch.object(UI, "process_identity") as inspect:
                with self.assertRaisesRegex(UI.UIFailure, "^direct-child-ownership-unverified$"):
                    self.proof.capture_direct_child(self.launch, acknowledge=True)
                inspect.assert_not_called()
            self.assertFalse((self.proof.directory / "direct-connect-child-ready.json").exists())

    def test_app_exit_before_first_child_inspection_cannot_claim_cleanup_or_signal_reused_pid(self):
        self.app.poll.return_value = 0
        for current in (None, dict(self.worker, parentPID=1), dict(self.worker, command="unrelated")):
            with self.subTest(current=current), patch.object(UI, "process_identity", return_value=current), \
                    patch.object(UI.os, "kill") as kill:
                with self.assertRaisesRegex(UI.UIFailure, "^direct-child-ownership-unverified$"):
                    self.proof.cleanup()
                kill.assert_not_called()
            self.assertFalse(json.loads((self.proof.directory / "cleanup.json").read_text())["exited"])

    def test_recorded_connect_child_is_reaped_on_cancel_failure_and_forced_app_stop(self):
        self.establish()
        for outcome in ("cancel", "failure", "forced-stop"):
            self.app.poll.return_value = None if outcome == "forced-stop" else 0
            self.app.terminate.reset_mock()
            alive = True
            def inspect(pid):
                if pid == self.app.pid:
                    return {"identity": self.launch["identity"]}
                return dict(self.worker, parentPID=1) if alive else None
            def signal_child(pid, _signal):
                nonlocal alive
                self.assertEqual(pid, 456)
                alive = False
            with self.subTest(outcome=outcome), patch.object(UI, "process_identity", side_effect=inspect), \
                    patch.object(UI.os, "kill", side_effect=signal_child) as kill, \
                    patch.object(self.proof, "capture_worker", return_value=[]), \
                    patch.object(self.proof, "run", side_effect=UI.UIFailure("no-native-ui")):
                self.proof.cleanup()
                kill.assert_called_once_with(456, UI.signal.SIGTERM)
            self.assertEqual(self.app.terminate.call_count, int(outcome == "forced-stop"))
            self.assertTrue(json.loads((self.proof.directory / "cleanup.json").read_text())["exited"])

    def test_process_helpers_use_exact_tools_and_never_inherit_service_tokens(self):
        session = dict(self.worker, pid=789, command=str(self.proof.cli) + " session")
        with patch.dict(UI.os.environ, self.proof.environment), \
                patch.object(UI.subprocess, "run", return_value=Mock(returncode=0, stdout=b"456 789")) as execute, \
                patch.object(UI, "process_identity", side_effect=[{"identity": self.launch["identity"]},
                                                                 dict(self.worker), session]):
            self.assertEqual(self.proof.capture_worker(self.app, self.launch), [session])
            self.assertEqual(execute.call_args.args[0], ["/usr/bin/pgrep", "-P", "123"])
            self.assertEqual(execute.call_args.kwargs["env"], {"PATH": UI.os.defpath, "LC_ALL": "C"})
        self.assertEqual({worker["command"] for worker in self.proof.workers},
                         {str(self.proof.cli) + " connect", str(self.proof.cli) + " session"})
        with patch.dict(UI.os.environ, self.proof.environment), \
                patch.object(UI.subprocess, "run", return_value=Mock(returncode=1, stdout=b"")) as execute:
            UI.process_identity(456)
            self.assertEqual(execute.call_args.args[0][0], "/bin/ps")
            self.assertEqual(execute.call_args.kwargs["env"], {"PATH": UI.os.defpath, "LC_ALL": "C"})
        with patch.object(UI.subprocess, "run", return_value=Mock(returncode=0, stdout=b"synthetic")) as execute:
            self.proof.run(["synthetic-command"])
            self.assertEqual(execute.call_args.kwargs["env"], {"PATH": "/poisoned-path"})
        self.proof.executable = Path("/synthetic/app")
        self.proof.direct = {}
        with patch.object(UI, "direct_configuration"), \
                patch.object(UI.subprocess, "Popen", side_effect=UI.UIFailure("captured-launch")) as launch:
            with self.assertRaisesRegex(UI.UIFailure, "captured-launch"):
                self.proof.launch(first=True)
            self.assertEqual(launch.call_args.kwargs["env"], {"PATH": "/poisoned-path"})



if __name__ == "__main__":
    unittest.main()
