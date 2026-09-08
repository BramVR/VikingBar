import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

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
                            "BRAM_OP_SERVICE_ACCOUNT_TOKEN": "synthetic-token"}
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
        self.proof.screens = [{"bounds": {"x": 0, "y": 0, "width": 1000, "height": 800}}]
        self.form = {"elements": [{"AXRole": "AXPopover", "frame": [[100, 24], [500, 700]]}]
                     + [{"AXIdentifier": "vikingbar.connect." + key, "frame": [[120, 100], [200, 20]]}
                        for key in ("client-id", "username", "password", "submit", "cancel")],
                     "windows": [{"kCGWindowBounds": {"X": 100, "Y": 24, "Width": 500, "Height": 700}}]}
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
                patch.object(self.proof, "press") as press, patch.object(self.proof, "verify_process"):
            if failure:
                with self.assertRaisesRegex(UI.UIFailure, "^native-direct-input-failed$"):
                    self.proof.connect_direct(self.tree)
            elif fill_stdout != b'{"filled":true}':
                with self.assertRaisesRegex(UI.UIFailure, "^native-direct-fill-failed$"):
                    self.proof.connect_direct(self.tree)
                self.assertEqual(press.call_count, 1)
            else:
                self.proof.connect_direct(self.tree)
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
                if command[0] == "/synthetic/tmux":
                    return subprocess.CompletedProcess(command, 0, b"approved 111")
                if command[0] == "ps":
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
                    self.assertEqual([call[2] for call in calls if call[0] == "ps"], ["333", "222"])
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


if __name__ == "__main__":
    unittest.main()
