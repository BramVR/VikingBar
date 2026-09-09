#!/usr/bin/env python3
"""Secret-free checks of the local credential wrapper."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True

SPEC = importlib.util.spec_from_file_location("proof_live", Path(__file__).with_name("proof-live.py"))
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class ProofRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        reference = Path(self.temp.name) / "reference.json"
        reference.write_text(json.dumps({"vault": "Codex Automation", "item_id": "syntheticitem",
                                         "fields": ["client_id", "username", "password"]}))
        self.environment = {"TMUX": "/synthetic/session", "BRAM_OP_SERVICE_ACCOUNT_TOKEN": "synthetic-service",
                            "VIKINGBAR_CREDENTIAL_REFERENCE": str(reference), "PATH": "/synthetic/bin"}
        self.credentials = {"client_id": "synthetic-client", "username": "synthetic-user",
                            "password": "synthetic-password"}
        self.receipt = {"schema_version": 1, "check": "auth-balance", "passed": True,
                        "password_grant": True, "refresh_grant": True, "scope_mismatch": True,
                        "subscription_count": 1, "balance_count": 1, "failure": None}
        self.calls = []

    def execute(self, command, **options):
        self.calls.append((command, options))
        if len(self.calls) == 1:
            data = {"fields": [{"label": key, "value": value} for key, value in self.credentials.items()]}
        else:
            data = self.receipt
        return subprocess.CompletedProcess(command, 0, json.dumps(data).encode(), b"")

    def run_proof(self, execute=None):
        with patch.object(RUNNER.shutil, "which", return_value="/synthetic/bin/op"), \
                patch.object(Path, "is_file", return_value=True):
            return RUNNER.run("auth-balance", self.environment, execute or self.execute)

    def test_direct_resume_dispatch_has_no_credential_bootstrap(self):
        module = Mock()
        module.run.return_value = {"check": "direct-connect-ui", "passed": True, "credential_reads_total": 1}
        module.UIFailure = RuntimeError
        with patch.object(RUNNER.importlib.util, "spec_from_file_location", return_value=Mock()), \
                patch.object(RUNNER.importlib.util, "module_from_spec", return_value=module), \
                patch.object(RUNNER.shutil, "which", side_effect=AssertionError("credential executable lookup")):
            self.assertEqual(RUNNER.run("direct-connect-ui-resume", {}), module.run.return_value)
        module.run.assert_called_once_with({}, direct_resume=True)

    def test_one_targeted_read_and_stdin_only_credentials(self):
        self.assertEqual(self.run_proof(), self.receipt)
        self.assertEqual(len(self.calls), 2)
        command, options = self.calls[0]
        self.assertEqual(command[1:], ["item", "get", "syntheticitem", "--vault", "Codex Automation",
                                      "--format", "json"])
        self.assertEqual(options["env"]["OP_SERVICE_ACCOUNT_TOKEN"], "synthetic-service")
        command, options = self.calls[1]
        self.assertEqual(json.loads(options["input"]), self.credentials)
        self.assertNotIn("TOKEN", " ".join(options["env"]))
        self.assertNotIn("synthetic-password", " ".join(command))

    def test_missing_context_fails_before_credential_access(self):
        for key in ("TMUX", "BRAM_OP_SERVICE_ACCOUNT_TOKEN", "VIKINGBAR_CREDENTIAL_REFERENCE"):
            with self.subTest(key=key):
                with patch.dict(self.environment, {key: ""}):
                    with self.assertRaises(RUNNER.ProofFailure):
                        self.run_proof()
        self.assertEqual(self.calls, [])

    def test_child_environments_exclude_loader_injection_and_isolate_credentials(self):
        runtime = {"PATH": "/synthetic/bin", "TMPDIR": "/synthetic/tmp",
                   "LANG": "en_US.UTF-8", "LC_ALL": "C"}
        injection = {key: "/synthetic/injection" for key in (
            "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
            "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH",
            "DYLD_VERSIONED_LIBRARY_PATH", "DYLD_VERSIONED_FRAMEWORK_PATH",
            "DYLD_ROOT_PATH", "LD_PRELOAD", "LD_LIBRARY_PATH", "LD_AUDIT",
            "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP",
        )}
        self.environment.update(runtime)
        self.environment.update(injection)
        self.environment["OP_SERVICE_ACCOUNT_TOKEN"] = "synthetic-stale-token"
        with patch.object(RUNNER.shutil, "which", return_value="/synthetic/bin/op") as which, \
                patch.object(Path, "is_file", return_value=True):
            self.assertEqual(RUNNER.run("auth-balance", self.environment, self.execute), self.receipt)
        which.assert_called_once_with("op", path=runtime["PATH"])
        self.assertEqual(len(self.calls), 2)
        for index, (command, options) in enumerate(self.calls):
            with self.subTest(child="op" if index == 0 else "cli"):
                expected = dict(runtime)
                if index == 0:
                    expected["OP_SERVICE_ACCOUNT_TOKEN"] = "synthetic-service"
                    self.assertEqual(command[0], "/synthetic/bin/op")
                    self.assertNotIn("input", options)
                else:
                    self.assertEqual(json.loads(options["input"]), self.credentials)
                self.assertEqual(options["env"], expected)
                for value in self.credentials.values():
                    self.assertNotIn(value, json.dumps(command))
                    self.assertNotIn(value, json.dumps(options["env"]))
                self.assertNotIn("synthetic-service", json.dumps(command))

    def test_missing_dependencies_fail_before_credential_access(self):
        with patch.object(RUNNER.shutil, "which", return_value=None):
            with self.assertRaisesRegex(RUNNER.ProofFailure, "one-password-cli-required"):
                RUNNER.run("auth-balance", self.environment, self.execute)
        with patch.object(RUNNER.shutil, "which", return_value="/synthetic/op"), \
                patch.object(Path, "is_file", return_value=False):
            with self.assertRaisesRegex(RUNNER.ProofFailure, "build-required"):
                RUNNER.run("auth-balance", self.environment, self.execute)
        self.assertEqual(self.calls, [])

    def test_unknown_check_never_reads_credentials(self):
        with self.assertRaises(RUNNER.ProofFailure):
            RUNNER.run("unknown", self.environment, self.execute)
        self.assertEqual(self.calls, [])

    def test_duplicate_missing_and_malformed_fields_fail(self):
        for fields in ([], [{"label": "client_id", "value": "a"}] * 2, [None]):
            with self.assertRaises(RUNNER.ProofFailure):
                RUNNER.extract_credentials(json.dumps({"fields": fields}))

    def test_failures_do_not_forward_upstream_text(self):
        secret = "synthetic-secret-sentinel"
        def fail(command, **_options):
            return subprocess.CompletedProcess(command, 1, secret.encode(), secret.encode())
        with self.assertRaisesRegex(RUNNER.ProofFailure, "^credential-read-failed$"):
            self.run_proof(fail)
        def cli_fail(command, **options):
            return self.execute(command, **options) if not self.calls else fail(command)
        with self.assertRaisesRegex(RUNNER.ProofFailure, "^api-proof-failed$"):
            self.run_proof(cli_fail)

    def test_receipt_rejects_extra_fields_and_incomplete_proof(self):
        for changes in ({"raw": "synthetic-private"}, {"passed": False}, {"balance_count": 0},
                        {"subscription_count": 2}, {"scope_mismatch": "read write"},
                        {"failure": "private-error"}, {"schema_version": True}):
            with self.subTest(changes=changes):
                with self.assertRaises(ValueError):
                    RUNNER.validate_receipt(dict(self.receipt, **changes))

    def test_cli_rejects_invalid_input_without_echoing_it(self):
        executable = Path(__file__).resolve().parent.parent / ".build/debug/vikingbar"
        for arguments, payload in ((["proof", "unknown"], b"synthetic-private"),
                                   (["proof", "auth-balance"], b"synthetic-private"),
                                   (["proof", "auth-balance"], b"x" * 65537),
                                   (["proof", "auth-balance"], b'{}')):
            with self.subTest(arguments=arguments, length=len(payload)):
                result = subprocess.run([str(executable), *arguments], input=payload,
                                        capture_output=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(json.loads(result.stdout)["passed"])
                self.assertNotIn(b"synthetic-private", result.stdout + result.stderr)

    def test_new_cli_routes_reject_input_before_live_access(self):
        executable = Path(__file__).resolve().parent.parent / ".build/debug/vikingbar"
        cases = [(["connect"], b"private-sentinel"), (["connect"], b"x" * 65537),
                 (["live", "--private-sentinel"], b""),
                 (["session"], b'{"command":"restore","password":"private-sentinel"}\n'),
                 (["session"], b'{"command":"selectSubscription"}\n'),
                 (["session"], b'{"command":"selectBundle","index":-1}\n'),
                 (["session"], b"x" * 65537 + b"\n")]
        for arguments, payload in cases:
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(executable), *arguments], input=payload,
                                        capture_output=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(json.loads(result.stdout)["passed"])
                self.assertNotIn(b"private-sentinel", result.stdout + result.stderr)

    def test_session_cancel_and_shutdown_need_no_production_state(self):
        executable = Path(__file__).resolve().parent.parent / ".build/debug/vikingbar"
        result = subprocess.run([str(executable), "session"],
                                input=b'{"command":"cancel"}\n{"command":"shutdown"}\n',
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(lines), 2)
        self.assertTrue(all(line["state"].get("connectionID") is None for line in lines))

    def test_entrypoint_redacts_unexpected_errors_and_timeouts(self):
        for error in (ValueError("synthetic-private"), subprocess.TimeoutExpired("private", 1),
                      OSError("private")):
            output = io.StringIO()
            with patch.object(RUNNER, "run", side_effect=error), contextlib.redirect_stdout(output):
                self.assertEqual(RUNNER.main(["auth-balance"], {}), 1)
            self.assertNotIn("private", output.getvalue())
            self.assertFalse(json.loads(output.getvalue())["passed"])


if __name__ == "__main__":
    unittest.main()
