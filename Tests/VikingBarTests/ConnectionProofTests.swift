import Darwin
import Foundation
import Testing
@testable import VikingBarApp

struct ConnectionProofTests {
    @Test func `ownership candidate precedes credential input and remains after success`() async throws {
        let fixture = try NativeProcessFixture(script: """
        import json, pathlib, sys
        pathlib.Path(__file__ + '.started').touch()
        json.load(sys.stdin)
        pathlib.Path(__file__ + '.received').touch()
        print(json.dumps({'schema_version': 1, 'check': 'connect', 'passed': True, 'connected': True,
                          'connection_sha256': '7ac1b8d7010bb6cd3a3e84e7f90136b880bbc899e428ece49333372911ab9052'}))
        """)
        defer { fixture.cleanup() }
        let connector = AccountConnector(cliURL: fixture.executable, helperURL: fixture.executable)
        let result = fixture.directory.appending(path: "connect-result.json")
        let credentials = try Self.credentials()
        let connecting = Task { try await connector.connect(input: .credentials(credentials), resultURL: result) }
        try await fixture.waitUntilStarted()
        let candidate = try await fixture.directConnectionCandidate()
        #expect(Set(candidate.keys) == ["schema_version", "pid", "parentPID"])
        #expect(candidate["schema_version"] == 1)
        #expect(candidate["parentPID"] == getpid())
        #expect(try #require(candidate["pid"]) > 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.executable.path + ".received"))
        let path = fixture.directory.appending(path: "direct-connect-child.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        try await fixture.acknowledgeDirectConnection()
        try await connecting.value
        #expect(FileManager.default.fileExists(atPath: fixture.executable.path + ".received"))
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test func `cancel before ownership acknowledgement retains evidence without sending credentials`() async throws {
        let fixture = try NativeProcessFixture(script: """
        import pathlib, sys
        pathlib.Path(__file__ + '.started').touch()
        if sys.stdin.read():
            pathlib.Path(__file__ + '.received').touch()
        """)
        defer { fixture.cleanup() }
        let connector = AccountConnector(cliURL: fixture.executable, helperURL: fixture.executable)
        let result = fixture.directory.appending(path: "connect-result.json")
        let credentials = try Self.credentials()
        let connecting = Task { try await connector.connect(input: .credentials(credentials), resultURL: result) }
        try await fixture.waitUntilStarted()
        _ = try await fixture.directConnectionCandidate()
        let started = ContinuousClock.now
        connecting.cancel()
        await connector.cancel()
        await #expect(throws: LiveBridgeFailure.self) { try await connecting.value }
        #expect(started.duration(to: .now) < .seconds(8))
        #expect(!FileManager.default.fileExists(atPath: fixture.executable.path + ".received"))
        #expect(FileManager.default
            .fileExists(atPath: fixture.directory.appending(path: "direct-connect-child.json").path))
        #expect(FileManager.default.fileExists(atPath: result.path))
        #expect(throws: LiveBridgeFailure.self) { try credentials.takePayload() }
    }

    @Test func `child exit before acknowledgement fails promptly and preserves its candidate`() async throws {
        let fixture = try NativeProcessFixture(script: """
        import pathlib, sys
        pathlib.Path(__file__ + '.started').touch()
        sys.exit(1)
        """)
        defer { fixture.cleanup() }
        let connector = AccountConnector(cliURL: fixture.executable, helperURL: fixture.executable)
        let result = fixture.directory.appending(path: "connect-result.json")
        let credentials = try Self.credentials()
        let connecting = Task { try await connector.connect(input: .credentials(credentials), resultURL: result) }
        try await fixture.waitUntilStarted()
        let started = ContinuousClock.now
        await #expect(throws: LiveBridgeFailure.self) { try await connecting.value }
        #expect(started.duration(to: .now) < .seconds(8))
        _ = try await fixture.directConnectionCandidate()
        #expect(FileManager.default.fileExists(atPath: result.path))
        #expect(throws: LiveBridgeFailure.self) { try credentials.takePayload() }
    }

    @Test func `incorrect ownership acknowledgement fails without delivering credentials`() async throws {
        let fixture = try NativeProcessFixture(script: """
        import pathlib, sys
        if sys.stdin.read():
            pathlib.Path(__file__ + '.received').touch()
        """)
        defer { fixture.cleanup() }
        let connector = AccountConnector(cliURL: fixture.executable, helperURL: fixture.executable)
        let result = fixture.directory.appending(path: "connect-result.json")
        let credentials = try Self.credentials()
        let connecting = Task { try await connector.connect(input: .credentials(credentials), resultURL: result) }
        _ = try await fixture.directConnectionCandidate()
        let ack = fixture.directory.appending(path: "direct-connect-child-ready.json")
        try ConnectionProof.write(Data(#"{"schema_version":1,"pid":-1}"#.utf8), to: ack)
        await #expect(throws: LiveBridgeFailure.self) { try await connecting.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.executable.path + ".received"))
        #expect(FileManager.default.fileExists(atPath: result.path))
        #expect(throws: LiveBridgeFailure.self) { try credentials.takePayload() }
    }

    private static func credentials() throws -> ConnectionCredentials {
        try ConnectionCredentials(clientID: "client", username: "user", password: "synthetic-password")
    }
}

extension NativeProcessFixture {
    func directConnectionCandidate() async throws -> [String: Int32] {
        let url = self.directory.appending(path: "direct-connect-child.json")
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { throw LiveBridgeFailure.unavailable }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: url))
    }

    func acknowledgeDirectConnection() async throws {
        let candidate = try await self.directConnectionCandidate()
        let pid = try #require(candidate["pid"])
        let data = try JSONEncoder().encode(["schema_version": Int32(1), "pid": pid])
        try ConnectionProof.write(data, to: self.directory.appending(path: "direct-connect-child-ready.json"))
    }
}
