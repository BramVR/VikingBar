import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

struct DirectConnectionProcessTests {
    @Test func `direct process receives only stdin credentials and writes a private fixed receipt`() async throws {
        let fixture = try NativeProcessFixture(script: """
        import json, os, sys
        assert sys.argv[1:] == ['connect'], 'unexpected arguments'
        forbidden = {'OP_SERVICE_ACCOUNT_TOKEN', 'BRAM_OP_SERVICE_ACCOUNT_TOKEN', 'DYLD_INSERT_LIBRARIES', 'PYTHONPATH'}
        assert not forbidden.intersection(os.environ), 'unexpected environment'
        data = json.load(sys.stdin)
        assert data == {'client_id': 'client', 'username': 'user', 'password': 'synthetic-password'}, 'invalid input'
        print(json.dumps({'schema_version': 1, 'check': 'connect', 'passed': True, 'connected': True}))
        """)
        defer { fixture.cleanup() }
        let credentials = try Self.credentials()
        let connector = AccountConnector(
            cliURL: fixture.executable,
            helperURL: fixture.directory.appending(path: "absent"),
        )
        let receipt = fixture.directory.appending(path: "receipt.json")
        let connecting = Task { try await connector.connect(input: .credentials(credentials), resultURL: receipt) }
        try await fixture.acknowledgeDirectConnection()
        try await connecting.value
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any]
        #expect(saved.map { Set($0.keys) } == ["schema_version", "check", "passed", "connected"])
        #expect(saved?["passed"] as? Bool == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: receipt.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(throws: LiveBridgeFailure.self) { try credentials.takePayload() }
    }

    @Test func `direct failure drops private error text and writes only a fixed failure code`() async throws {
        let fixture = try NativeProcessFixture(script: """
        import json, sys
        json.load(sys.stdin)
        print(json.dumps({'error': 'token-rejected', 'detail': 'private-marker'}))
        print('private-marker', file=sys.stderr)
        sys.exit(1)
        """)
        defer { fixture.cleanup() }
        let connector = AccountConnector(cliURL: fixture.executable, helperURL: fixture.executable)
        let receipt = fixture.directory.appending(path: "failure.json")
        let credentials = try Self.credentials()
        let connecting = Task { try await connector.connect(input: .credentials(credentials), resultURL: receipt) }
        try await fixture.acknowledgeDirectConnection()
        do {
            try await connecting.value
            Issue.record("Expected a rejected sign-in")
        } catch let failure as LiveBridgeFailure {
            #expect(failure.message == LiveBridgeFailure.bootstrap(.tokenRejected).message)
            #expect(!failure.message.contains("private-marker"))
        }
        let text = try String(contentsOf: receipt, encoding: .utf8)
        #expect(!text.contains("private-marker"))
        let saved = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(saved.map { Set($0.keys) } == ["passed", "error"])
        #expect(saved?["error"] as? String == "token-rejected")
    }

    @Test func `cancellation interrupts a full private input pipe and releases the payload`() async throws {
        let fixture = try NativeProcessFixture(script: """
        import pathlib, time
        pathlib.Path(__file__ + '.started').touch()
        time.sleep(60)
        """)
        defer { fixture.cleanup() }
        let connector = AccountConnector(cliURL: fixture.executable, helperURL: fixture.executable)
        let credentials = try ConnectionCredentials(
            clientID: "client", username: "user", password: String(repeating: "x", count: 65000),
        )
        let connecting = Task { try await connector.connect(input: .credentials(credentials), resultURL: nil) }
        try await fixture.waitUntilStarted()
        let started = ContinuousClock.now
        connecting.cancel()
        await connector.cancel()
        await #expect(throws: LiveBridgeFailure.self) { try await connecting.value }
        #expect(started.duration(to: .now) < .seconds(8))
        #expect(throws: LiveBridgeFailure.self) { try credentials.takePayload() }
    }

    @Test func `early child exit fails without terminating the app or retaining credentials`() async throws {
        let fixture = try NativeProcessFixture(script: "import sys; sys.exit(1)")
        defer { fixture.cleanup() }
        let connector = AccountConnector(cliURL: fixture.executable, helperURL: fixture.executable)
        let credentials = try ConnectionCredentials(
            clientID: "client", username: "user", password: String(repeating: "x", count: 65000),
        )
        await #expect(throws: LiveBridgeFailure.self) {
            try await connector.connect(input: .credentials(credentials), resultURL: nil)
        }
        #expect(throws: LiveBridgeFailure.self) { try credentials.takePayload() }
    }

    @Test func `direct receipt refuses to overwrite an existing file`() async throws {
        let fixture = try NativeProcessFixture(script: "raise RuntimeError('must not launch')")
        defer { fixture.cleanup() }
        let connector = AccountConnector(cliURL: fixture.executable, helperURL: fixture.executable)
        let receipt = fixture.directory.appending(path: "receipt.json")
        try "existing".write(to: receipt, atomically: true, encoding: .utf8)
        let credentials = try Self.credentials()
        await #expect(throws: LiveBridgeFailure.self) {
            try await connector.connect(input: .credentials(credentials), resultURL: receipt)
        }
        #expect(throws: LiveBridgeFailure.self) { try credentials.takePayload() }
        #expect(try String(contentsOf: receipt, encoding: .utf8) == "existing")
    }

    private static func credentials() throws -> ConnectionCredentials {
        try ConnectionCredentials(clientID: "client", username: "user", password: "synthetic-password")
    }
}
