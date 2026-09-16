"""Synthetic stored-session invoice proof checks; never launch the live CLI."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("invoice_proof_runner", ROOT / "Scripts/proof-live.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class InvoiceProofTests(unittest.TestCase):
    def setUp(self):
        self.receipt = {"schema_version": 1, "check": "invoices", "passed": True,
                        "invoice_count": 1, "empty": False, "truncated": False,
                        "metadata_matches": True, "presentation_matches": True, "pdf_downloaded": True}
        self.calls = []
        self.environment = {"PATH": "/synthetic/bin", "TMPDIR": "/synthetic/tmp",
                            "LANG": "en_IE.UTF-8", "LC_ALL": "C"}
        guards = contextlib.ExitStack()
        self.addCleanup(guards.close)
        self.binary = guards.enter_context(patch.object(Path, "is_file", return_value=True))
        for target in ("run", "Popen"):
            guards.enter_context(patch.object(subprocess, target, side_effect=AssertionError("real process forbidden")))
        guards.enter_context(patch.object(RUNNER.os, "system", side_effect=AssertionError("shell forbidden")))
        guards.enter_context(patch.object(RUNNER.shutil, "which", side_effect=AssertionError("op lookup forbidden")))
        guards.enter_context(patch.object(RUNNER, "credential_reference",
                                         side_effect=AssertionError("credential access forbidden")))
        guards.enter_context(patch.object(RUNNER, "extract_credentials",
                                         side_effect=AssertionError("credential access forbidden")))

    def execute(self, command, **options):
        self.calls.append((command, options))
        return subprocess.CompletedProcess(command, 0, json.dumps(self.receipt).encode(), b"synthetic-private-stderr")

    def run_proof(self, execute=None, environment=None):
        return RUNNER.run("invoices", self.environment if environment is None else environment,
                          self.execute if execute is None else execute)

    def entrypoint(self, execute=None):
        dispatch = RUNNER.run
        output = io.StringIO()
        errors = io.StringIO()
        def injected_run(check, environment):
            return dispatch(check, environment, self.execute if execute is None else execute)
        with patch.object(RUNNER, "run", side_effect=injected_run), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            result = RUNNER.main(["invoices"], self.environment)
        self.assertEqual(errors.getvalue(), "")
        self.assertNotIn("synthetic-private", output.getvalue())
        return result, json.loads(output.getvalue())

    def test_stored_session_dispatch_needs_no_bootstrap_or_viewer(self):
        self.assertEqual(self.run_proof(environment={}), self.receipt)
        self.assertEqual(self.calls, [([str(ROOT / ".build/debug/vikingbar"), "proof", "invoices"],
                                      {"env": {}, "capture_output": True, "timeout": 180, "check": False})])

    def test_payment_evidence_passes_private_witness_by_stdin_and_returns_only_flags(self):
        witness = b'{"invoiceID":"inv-1","invoiceNumber":"2026-10","reference":"+++123/4567/89002+++","invoiceDate":"2026-09-01","dueDate":"2026-09-15"}'
        receipt = {"schema_version": 1, "check": "payment-evidence", "passed": True,
                   "endpoint_matches": True, "pdf_downloaded": True}
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "witness.json"
            path.write_bytes(witness)
            path.chmod(0o600)
            environment = dict(self.environment, VIKINGBAR_PAYMENT_EVIDENCE=str(path))

            def execute(command, **options):
                self.calls.append((command, options))
                return subprocess.CompletedProcess(command, 0, json.dumps(receipt).encode(), b"private")

            self.assertEqual(RUNNER.run("payment-evidence", environment, execute), receipt)
        command, options = self.calls[-1]
        self.assertEqual(command[1:], ["proof", "payment-evidence"])
        self.assertEqual(options["input"], witness)
        self.assertNotIn("VIKINGBAR_PAYMENT_EVIDENCE", options["env"])
        self.assertNotIn("inv-1", json.dumps(receipt))

    def test_payment_evidence_requires_private_bounded_witness(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "witness.json"
            path.write_text("{}")
            path.chmod(0o644)
            with self.assertRaisesRegex(RUNNER.ProofFailure, "^private-payment-evidence-required$"):
                RUNNER.run("payment-evidence", {"VIKINGBAR_PAYMENT_EVIDENCE": str(path)}, self.execute)
        self.assertEqual(self.calls, [])

    def test_child_environment_strips_credentials_and_injection(self):
        allowed = dict(self.environment)
        for key in ("HOME", "TMUX", "BRAM_OP_SERVICE_ACCOUNT_TOKEN", "OP_SERVICE_ACCOUNT_TOKEN",
                    "VIKINGBAR_CREDENTIAL_REFERENCE", "VIKINGBAR_PASSWORD", "GITHUB_TOKEN", "GH_TOKEN",
                    "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
                    "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH", "DYLD_ROOT_PATH",
                    "DYLD_VERSIONED_LIBRARY_PATH", "DYLD_VERSIONED_FRAMEWORK_PATH", "LD_PRELOAD",
                    "LD_LIBRARY_PATH", "LD_AUDIT", "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP"):
            self.environment[key] = "synthetic-private-" + key
        self.assertEqual(self.run_proof(), self.receipt)
        self.assertEqual(len(self.calls), 1)
        command, options = self.calls[0]
        self.assertEqual(options["env"], allowed)
        self.assertNotIn("input", options)
        self.assertNotIn("synthetic-private", json.dumps([command, options]))

    def test_missing_binary_fails_before_any_process(self):
        self.binary.return_value = False
        with self.assertRaisesRegex(RUNNER.ProofFailure, "^build-required$"):
            self.run_proof()
        self.assertEqual(self.calls, [])

    def test_empty_pdf_and_truncated_success_receipts(self):
        for count, truncated in ((0, False), (1, False), (100, False), (100, True)):
            with self.subTest(count=count, truncated=truncated):
                self.receipt.update(invoice_count=count, empty=count == 0, truncated=truncated,
                                    pdf_downloaded=count > 0)
                self.assertEqual(self.entrypoint(), (0, self.receipt))
        self.assertEqual(len(self.calls), 4)
        self.assertTrue(all(command[1:] == ["proof", "invoices"] for command, _ in self.calls))

    def test_receipt_requires_every_key_and_rejects_private_extensions(self):
        for key in self.receipt:
            with self.subTest(missing=key):
                value = dict(self.receipt)
                del value[key]
                with self.assertRaises(ValueError):
                    RUNNER.validate_invoice_receipt(value)
        for key in ("raw", "invoice_id", "invoice_number", "file_url", "authorization", "error", "skipped"):
            with self.subTest(extra=key), self.assertRaises(ValueError):
                RUNNER.validate_invoice_receipt(dict(self.receipt, **{key: "synthetic-private"}))
        for value in (None, [], "synthetic-private", 1, True):
            with self.subTest(value=value), self.assertRaises(ValueError):
                RUNNER.validate_invoice_receipt(value)

    def test_receipt_rejects_wrong_types_ranges_and_incomplete_proof(self):
        invalid = {
            "schema_version": (True, 1.0, 0, 2, "1", None),
            "check": ("auth-balance", "synthetic-private", None),
            "invoice_count": (True, False, 1.0, -1, 101, "1", None),
            "passed": (False, 1, "true", None),
            "metadata_matches": (False, 1, "true", None),
            "presentation_matches": (False, 1, "true", None),
            "empty": (0, 1, "false", None),
            "truncated": (0, 1, "false", None),
            "pdf_downloaded": (0, 1, "true", None),
        }
        for key, values in invalid.items():
            for value in values:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    RUNNER.validate_invoice_receipt(dict(self.receipt, **{key: value}))

    def test_count_empty_pdf_and_truncation_must_agree(self):
        for count in (0, 1, 99, 100):
            for empty in (False, True):
                for pdf in (False, True):
                    for truncated in (False, True):
                        receipt = dict(self.receipt, invoice_count=count, empty=empty,
                                       pdf_downloaded=pdf, truncated=truncated)
                        valid = empty == (count == 0) and pdf == (count > 0) and (not truncated or count == 100)
                        with self.subTest(count=count, empty=empty, pdf=pdf, truncated=truncated):
                            if valid:
                                self.assertEqual(RUNNER.validate_invoice_receipt(receipt), receipt)
                            else:
                                with self.assertRaises(ValueError):
                                    RUNNER.validate_invoice_receipt(receipt)

    def test_nonzero_process_never_accepts_success_or_forwards_private_output(self):
        for payload in (json.dumps(self.receipt).encode(), b"synthetic-private-provider-error"):
            def fail(command, **_options):
                return subprocess.CompletedProcess(command, 1, payload, b"synthetic-private-stderr")
            self.assertEqual(self.entrypoint(fail), (1, {"passed": False, "error": "invoices-proof-failed"}))

    def test_malformed_or_private_receipt_fails_closed(self):
        for payload in (b"", b"synthetic-private", b"{}", b"null", b"[]",
                        b'{"passed":false,"error":"synthetic-private"}',
                        json.dumps(dict(self.receipt, raw="synthetic-private")).encode(),
                        json.dumps(dict(self.receipt, pdf_downloaded=False)).encode(),
                        json.dumps(self.receipt).encode() + b"\nsynthetic-private"):
            def malformed(command, **_options):
                return subprocess.CompletedProcess(command, 0, payload, b"synthetic-private-stderr")
            self.assertEqual(self.entrypoint(malformed), (1, {"passed": False, "error": "invalid-proof-receipt"}))

    def test_timeouts_and_exceptions_are_redacted_without_retry(self):
        cases = ((subprocess.TimeoutExpired("synthetic-private-command", 180,
                                          output=b"synthetic-private", stderr=b"synthetic-private"), "dependency-failed"),
                 (subprocess.CalledProcessError(1, "synthetic-private", output=b"synthetic-private"), "dependency-failed"),
                 (OSError("synthetic-private-path"), "dependency-failed"),
                 (ValueError("synthetic-private-unexpected"), "runner-failed"))
        for error, diagnostic in cases:
            calls = []
            def fail(command, **options):
                calls.append((command, options))
                raise error
            with self.subTest(error=type(error).__name__):
                self.assertEqual(self.entrypoint(fail), (1, {"passed": False, "error": diagnostic}))
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0][0][1:], ["proof", "invoices"])


if __name__ == "__main__":
    unittest.main()
