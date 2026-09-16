import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CODES = {
    "credential-input", "local-filesystem", "session-busy", "token-network", "token-rejected", "token-response",
    "token-rate-limited", "token-server", "keychain-write", "connect-cancelled", "connect-failed",
}
CREDENTIALS = b'{"client_id":"synthetic-client","username":"synthetic-user","password":"synthetic-password"}'


class ConnectDiagnosticsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        source = Path(cls.directory.name) / "ConnectTest.swift"
        source.write_text(DRIVER)
        cls.executable = Path(cls.directory.name) / "connect-test"
        objects = sorted((ROOT / ".build/debug/VikingBarCore.build").glob("*.swift.o"))
        if not objects:
            raise AssertionError("swift build must precede the synthetic CLI diagnostic check")
        result = subprocess.run([
            "swiftc", "-parse-as-library", "-I", str(ROOT / ".build/debug/Modules"),
            str(ROOT / "Sources/VikingBarCLI/LiveCommands.swift"),
            str(ROOT / "Sources/VikingBarCLI/BalanceOracle.swift"),
            str(ROOT / "Sources/VikingBarCLI/PointsOracle.swift"), str(source), *map(str, objects),
            "-o", str(cls.executable),
        ], capture_output=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stderr.decode())

    def receipt(self, mode, credentials=CREDENTIALS):
        result = subprocess.run([str(self.executable), mode], input=credentials, capture_output=True, timeout=10)
        self.assertEqual(result.stderr, b"")
        return result.returncode, json.loads(result.stdout)

    def test_all_codes_are_exact_fixed_failure_receipts(self):
        for code in CODES:
            with self.subTest(code=code):
                exit_code, receipt = self.receipt(code)
                self.assertEqual(exit_code, 1)
                self.assertEqual(receipt, {"passed": False, "error": code})

    def test_unknown_raw_errors_use_only_the_fixed_fallback(self):
        exit_code, receipt = self.receipt("raw-error")
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt, {"passed": False, "error": "connect-failed"})

    def test_malformed_credentials_and_arguments_never_construct_a_session(self):
        for credentials in [b"", b"PRIVATE_NOT_JSON", b"{}", b'{"client_id":"","username":"x","password":"y"}',
                            b"x" * 65537]:
            with self.subTest(length=len(credentials)):
                exit_code, receipt = self.receipt("must-not-construct", credentials)
                self.assertEqual(exit_code, 1)
                self.assertEqual(receipt, {"passed": False, "error": "credential-input"})
        exit_code, receipt = self.receipt("bad-arguments")
        self.assertEqual(exit_code, 1)
        self.assertEqual(receipt, {"passed": False, "error": "credential-input"})

    def test_success_receipt_binds_the_stored_connection(self):
        exit_code, receipt = self.receipt("success")
        self.assertEqual(exit_code, 0)
        self.assertEqual(receipt, {"schema_version": 1, "check": "connect", "passed": True, "connected": True,
                                   "connection_sha256":
                                       "7ac1b8d7010bb6cd3a3e84e7f90136b880bbc899e428ece49333372911ab9052"})


DRIVER = r'''
import Foundation
import VikingBarCore

// The command compiles against this local actor; it cannot construct the production session.
actor VikingSession {
    static func production(transport: any ProofHTTPTransport = EphemeralProofTransport()) throws -> VikingSession {
        if ["must-not-construct", "bad-arguments"].contains(CommandLine.arguments[1]) {
            fatalError("Synthetic factory must remain unreachable")
        }
        if CommandLine.arguments[1] == "local-filesystem" { throw Self.privateError() }
        return VikingSession()
    }

    func bootstrapWithDiagnostics(credentials: ProofCredentials) async throws -> LiveSessionState {
        let mode = CommandLine.arguments[1]
        if mode == "success" {
            let raw = #"{"connectionID":{"rawValue":"00000000-0000-0000-0000-000000000001"},"subscriptions":[],"snapshot":{"source":{"notConnected":{}},"subscriptionName":"No account connected","allowance":{"unavailable":{}},"freshness":{"unavailable":{}}},"isRefreshing":false,"scopeMismatch":false}"#
            return try! JSONDecoder().decode(LiveSessionState.self, from: Data(raw.utf8))
        }
        if let failure = BootstrapFailure(rawValue: mode) { throw failure }
        throw Self.privateError()
    }

    func restore() throws -> LiveSessionState { LiveSessionState() }
    func refresh(subscriptionID: String? = nil, forceTokenRefresh: Bool = false) async throws -> LiveSessionState {
        LiveSessionState()
    }
    func refreshHistory() async throws -> LiveSessionState { LiveSessionState() }
    func refreshInvoices() async throws -> LiveSessionState { LiveSessionState() }
    func downloadInvoice(id: String) async throws -> LiveSessionState { LiveSessionState() }
    func clearInvoiceDocument() {}
    func selectBundle(index: Int) throws -> LiveSessionState { LiveSessionState() }
    func refreshPoints(forceTokenRefresh: Bool = false) async throws -> LiveSessionState { LiveSessionState() }
    func state() -> LiveSessionState { LiveSessionState() }
    static func privateError() -> NSError {
        NSError(domain: "DO_NOT_EXPORT", code: 9191, userInfo: [NSLocalizedDescriptionKey: "DO_NOT_EXPORT"])
    }
}

@main struct VikingBarCLI {
    static func main() async {
        let arguments = CommandLine.arguments[1] == "bad-arguments" ? ["connect", "extra"] : ["connect"]
        await self.connect(arguments: arguments)
    }
}
'''
