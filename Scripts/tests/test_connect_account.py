import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("connect_account", Path(__file__).parents[1] / "connect-account.py")
CONNECT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CONNECT)


class ConnectAccountTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.reference = Path(self.temp.name) / "reference.json"
        self.reference.write_text(json.dumps({"vault": "Codex Automation", "item_id": "synthetic",
                                              "fields": ["client_id", "username", "password"]}))
        self.cli = Path(self.temp.name) / "vikingbar"
        self.cli.touch()
        self.environment = {"TMUX": "synthetic", "PATH": "/synthetic", "BRAM_OP_SERVICE_ACCOUNT_TOKEN": "secret",
                            "DYLD_INSERT_LIBRARIES": "injection", "PYTHONPATH": "injection", "HOME": "/private"}
        self.receipt = {"schema_version": 1, "check": "connect", "passed": True, "connected": True}

    def test_exactly_one_read_and_cli_stdin_isolation(self):
        calls = []
        def execute(command, **kwargs):
            calls.append((command, kwargs))
            value = ({"fields": [{"label": key, "value": "synthetic-" + key}
                                  for key in ("client_id", "username", "password")]}
                     if len(calls) == 1 else self.receipt)
            return subprocess.CompletedProcess(command, 0, json.dumps(value).encode(), b"private-error")
        with patch.object(CONNECT.shutil, "which", return_value="/synthetic/op"):
            result = CONNECT.inside(self.cli, self.reference, self.environment, execute)
        self.assertEqual(result, self.receipt)
        self.assertEqual(calls[0][0], ["/synthetic/op", "item", "get", "synthetic", "--vault", "Codex Automation",
                                        "--format", "json"])
        self.assertEqual(calls[0][1]["env"], {"PATH": "/synthetic", "OP_SERVICE_ACCOUNT_TOKEN": "secret"})
        self.assertEqual(calls[1][0], [str(self.cli), "connect"])
        self.assertEqual(calls[1][1]["env"], {"PATH": "/synthetic"})
        self.assertEqual(json.loads(calls[1][1]["input"])["password"], "synthetic-password")

    def test_supervisor_uses_private_tmux_server_and_exact_cleanup(self):
        calls = []
        def execute(command, **kwargs):
            calls.append((command, kwargs))
            if "new-session" in command:
                shell = command[-1]
                import shlex
                child = shlex.split(shell.split("; exec ", 1)[1])
                CONNECT.write_receipt(child[child.index("--result") + 1], self.receipt)
            output = f"12345 12346 {command[2]}".encode() if "new-session" in command else b""
            return subprocess.CompletedProcess(command, 0, output, b"")
        with patch.object(CONNECT.shutil, "which", return_value="/synthetic/tmux"):
            ownership = {}
            self.assertEqual(CONNECT.supervise(self.cli, self.reference, self.environment, execute,
                                               ownership=ownership), self.receipt)
        self.assertEqual(len(calls), 2)
        start, cleanup = calls[0][0], calls[1][0]
        self.assertEqual(start[:5], cleanup[:5])
        self.assertEqual(start[1], "-L")
        self.assertTrue(start[2].startswith("vikingbar-connect-"))
        self.assertEqual(cleanup[-3:], ["kill-session", "-t", "=" + start[2]])
        self.assertIn('source "$HOME/.profile" >/dev/null 2>&1', start[-1])
        self.assertEqual(calls[0][1]["env"], {"PATH": "/synthetic"})
        self.assertNotIn("secret", json.dumps(calls))
        self.assertEqual(ownership["serverPID"], 12345)
        self.assertEqual(ownership["panePID"], 12346)
        self.assertEqual(ownership["session"], start[2])
        self.assertTrue(ownership["cleanupAttempted"])
        self.assertEqual(ownership["cleanupReturncode"], 0)

    def test_cli_failure_stage_survives_without_private_output(self):
        def execute(command, **_kwargs):
            if command[0] == "/synthetic/op":
                value = {"fields": [{"label": key, "value": "synthetic-" + key}
                                    for key in ("client_id", "username", "password")]}
                return subprocess.CompletedProcess(command, 0, json.dumps(value).encode(), b"")
            return subprocess.CompletedProcess(command, 1, b'{"passed":false,"error":"token-network"}',
                                               b"private-provider-sentinel")
        with patch.object(CONNECT.shutil, "which", return_value="/synthetic/op"):
            with self.assertRaisesRegex(CONNECT.ConnectFailure, "^token-network$"):
                CONNECT.inside(self.cli, self.reference, self.environment, execute)

    def test_supervisor_preserves_allowlisted_inner_failure(self):
        def execute(command, **_kwargs):
            if "new-session" in command:
                import shlex
                child = shlex.split(command[-1].split("; exec ", 1)[1])
                CONNECT.write_receipt(child[child.index("--result") + 1],
                                      {"passed": False, "error": "credential-read-failed"})
            return subprocess.CompletedProcess(command, 0, b"", b"")
        with patch.object(CONNECT.shutil, "which", return_value="/synthetic/tmux"):
            with self.assertRaisesRegex(CONNECT.ConnectFailure, "^credential-read-failed$"):
                CONNECT.supervise(self.cli, self.reference, self.environment, execute)

    def test_cleanup_failure_does_not_replace_the_inner_failure(self):
        def execute(command, **_kwargs):
            if "kill-session" in command:
                raise subprocess.TimeoutExpired(command, 10, stderr=b"private-cleanup-sentinel")
            import shlex
            child = shlex.split(command[-1].split("; exec ", 1)[1])
            CONNECT.write_receipt(child[child.index("--result") + 1],
                                  {"passed": False, "error": "token-rejected"})
            return subprocess.CompletedProcess(command, 0, b"", b"")
        with patch.object(CONNECT.shutil, "which", return_value="/synthetic/tmux"):
            with self.assertRaisesRegex(CONNECT.ConnectFailure, "^token-rejected$"):
                CONNECT.supervise(self.cli, self.reference, self.environment, execute)

    def test_failure_receipts_reject_raw_text_extra_fields_and_boolean_coercion(self):
        for value in ({"passed": False, "error": "private-sentinel"},
                      {"passed": False, "error": "token-network", "raw": "private-sentinel"},
                      {"passed": 0, "error": "token-network"},
                      {"passed": False, "error": ["token-network"]}):
            self.assertIsNone(CONNECT.failure_code(value))
        self.assertIsNone(CONNECT.failure_code({"passed": False, "error": "credential-read-failed"},
                                              CONNECT.CLI_FAILURE_CODES))

    def test_credential_timeout_and_missing_fields_are_distinct(self):
        for result, code in ((subprocess.TimeoutExpired("op", 60, stderr=b"private-sentinel"),
                              "credential-read-timeout"),
                             (subprocess.CompletedProcess("op", 0, b'{"fields":[]}', b"private-sentinel"),
                              "invalid-credential-fields")):
            def execute(*_args, **_kwargs):
                if isinstance(result, Exception):
                    raise result
                return result
            with patch.object(CONNECT.shutil, "which", return_value="/synthetic/op"):
                with self.assertRaisesRegex(CONNECT.ConnectFailure, "^" + code + "$"):
                    CONNECT.inside(self.cli, self.reference, self.environment, execute)

    def test_timeout_cleans_own_session(self):
        calls = []
        def execute(command, **kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, b"", b"")
        ticks = iter([0, 200])
        with patch.object(CONNECT.shutil, "which", return_value="/synthetic/tmux"):
            with self.assertRaisesRegex(CONNECT.ConnectFailure, "connect-timeout"):
                CONNECT.supervise(self.cli, self.reference, self.environment, execute, clock=lambda: next(ticks))
        self.assertEqual(calls[-1][-3:], ["kill-session", "-t", "=" + calls[0][2]])

    def test_interrupted_supervisor_cleans_its_exact_session(self):
        calls = []
        def execute(command, **_kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, b"", b"")
        def interrupt(_seconds):
            raise CONNECT.ConnectFailure("connect-cancelled")
        with patch.object(CONNECT.shutil, "which", return_value="/synthetic/tmux"):
            with self.assertRaisesRegex(CONNECT.ConnectFailure, "connect-cancelled"):
                CONNECT.supervise(self.cli, self.reference, self.environment, execute, sleep=interrupt)
        self.assertEqual(calls[-1][-3:], ["kill-session", "-t", "=" + calls[0][2]])

    def test_no_context_no_op_and_errors_are_redacted(self):
        with self.assertRaises(CONNECT.ConnectFailure):
            CONNECT.inside(self.cli, self.reference, {}, lambda *_args, **_kwargs: self.fail("op called"))
        output = io.StringIO()
        with patch.object(CONNECT, "supervise", side_effect=ValueError("private-sentinel")), \
                contextlib.redirect_stdout(output):
            code = CONNECT.main(["--cli", str(self.cli), "--reference", str(self.reference)], {})
        self.assertEqual(code, 1)
        self.assertNotIn("private-sentinel", output.getvalue())

    def test_receipts_are_exclusive_private_and_reject_extra_fields(self):
        target = Path(self.temp.name) / "result.json"
        CONNECT.write_receipt(target, self.receipt)
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            CONNECT.write_receipt(target, self.receipt)
        for value in (dict(self.receipt, raw="private"), dict(self.receipt, schema_version=True),
                      dict(self.receipt, connected=False), dict(self.receipt, passed=1)):
            with self.assertRaises(CONNECT.ConnectFailure):
                CONNECT.validate_receipt(value)


if __name__ == "__main__":
    unittest.main()
