import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

struct NativeProcessTests {
    @Test func `native pipe client drains canceled reply before its acknowledgement`() async throws {
        let fixture = try NativeProcessFixture(script: """
        import json, pathlib, sys
        state = json.loads('\(Self.stateJSON())')
        def reply(index):
            state['selectedBundleIndex'] = index
            print(json.dumps({'schemaVersion': 1, 'state': state}), flush=True)
        pending = False
        for line in sys.stdin:
            request = json.loads(line)
            command = request['command']
            if command == 'refresh':
                pending = True
                pathlib.Path(__file__ + '.started').touch()
                continue
            if command == 'cancel':
                if pending: reply(1)
                pending = False
                reply(2)
            else:
                reply(request.get('index', 0))
            if command == 'shutdown': break
        """)
        defer { fixture.cleanup() }
        let client = SessionProcessClient(executableURL: fixture.executable)
        let refreshing = Task { try await client.request(.refresh) }
        try await fixture.waitUntilStarted()
        let cancellation = try await client.request(.cancel)
        #expect(try await refreshing.value.selectedBundleIndex == 1)
        #expect(cancellation.selectedBundleIndex == 2)
        #expect(try await client.request(.selectBundle(7)).selectedBundleIndex == 7)
        await client.shutdown()
        await client.shutdown()
        await #expect(throws: LiveBridgeFailure.self) { try await client.request(.restore) }
    }

    @Test func `invalid oversized unsupported and truncated worker replies fail closed`() async throws {
        for script in try [
            "print('not-json', flush=True)",
            "print('{\"schemaVersion\":2,\"state\":\(Self.stateJSON())}', flush=True)",
            "import sys; sys.stdout.write('x' * 1048577); sys.stdout.flush()",
            "import sys; sys.stdout.write('{'); sys.stdout.flush()",
        ] {
            let fixture = try NativeProcessFixture(script: "import sys\nsys.stdin.readline()\n" + script)
            defer { fixture.cleanup() }
            let client = SessionProcessClient(executableURL: fixture.executable)
            await #expect(throws: LiveBridgeFailure.self) { try await client.request(.restore) }
            await client.shutdown()
        }
    }

    @Test func `owned worker ignoring shutdown is stopped within a bounded interval`() async throws {
        let fixture = try NativeProcessFixture(script: """
        import pathlib, signal, sys, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        sys.stdin.readline()
        pathlib.Path(__file__ + '.started').touch()
        time.sleep(60)
        """)
        defer { fixture.cleanup() }
        let client = SessionProcessClient(executableURL: fixture.executable)
        let request = Task { try await client.request(.restore) }
        try await fixture.waitUntilStarted()
        let started = ContinuousClock.now
        await client.shutdown()
        #expect(started.duration(to: .now) < .seconds(8))
        await #expect(throws: LiveBridgeFailure.self) { try await request.value }
    }

    @Test func `connector accepts only the fixed receipt and cancels its own helper`() async throws {
        for extra in ["", ", 'private': 'synthetic'"] {
            let fixture = try NativeProcessFixture(script: """
            import json
            print(json.dumps({'schema_version': 1, 'check': 'connect', 'passed': True, 'connected': True\(extra)}))
            """)
            defer { fixture.cleanup() }
            let connector = AccountConnector(cliURL: fixture.executable, helperURL: fixture.executable)
            if extra.isEmpty {
                try await connector.connect(reference: fixture.executable, resultURL: nil)
            } else {
                await #expect(throws: LiveBridgeFailure.self) {
                    try await connector.connect(reference: fixture.executable, resultURL: nil)
                }
            }
        }
        let fixture = try NativeProcessFixture(script: """
        import pathlib, time
        pathlib.Path(__file__ + '.started').touch()
        time.sleep(60)
        """)
        defer { fixture.cleanup() }
        let connector = AccountConnector(cliURL: fixture.executable, helperURL: fixture.executable)
        let connecting = Task { try await connector.connect(reference: fixture.executable, resultURL: nil) }
        try await fixture.waitUntilStarted()
        await connector.cancel()
        await #expect(throws: LiveBridgeFailure.self) { try await connecting.value }
    }

    @Test func `child environment excludes credential and loader variables`() {
        let result = LiveServiceEnvironment.sanitized([
            "PATH": "/usr/bin", "BRAM_OP_SERVICE_ACCOUNT_TOKEN": "synthetic",
            "OP_SERVICE_ACCOUNT_TOKEN": "synthetic", "DYLD_INSERT_LIBRARIES": "synthetic", "PYTHONPATH": "synthetic",
        ])
        #expect(result == ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin"])
    }

    @Test func `concurrent connector cancellation signals the helper only once`() async throws {
        let fixture = try NativeProcessFixture(script: """
        import pathlib, signal, sys, time
        signals = 0
        def terminate(*_args):
            global signals
            signals += 1
            pathlib.Path(__file__ + '.signals').write_text(str(signals))
            pathlib.Path(__file__ + '.terminating').touch()
            time.sleep(0.5)
            sys.exit(1)
        signal.signal(signal.SIGTERM, terminate)
        pathlib.Path(__file__ + '.started').touch()
        time.sleep(60)
        """)
        defer { fixture.cleanup() }
        let connector = AccountConnector(cliURL: fixture.executable, helperURL: fixture.executable)
        let connecting = Task { try await connector.connect(reference: fixture.executable, resultURL: nil) }
        try await fixture.waitUntilStarted()
        connecting.cancel()
        try await fixture.waitUntilStarted(suffix: "terminating")
        await connector.cancel()
        await #expect(throws: LiveBridgeFailure.self) { try await connecting.value }
        let signals = try String(contentsOfFile: fixture.executable.path + ".signals", encoding: .utf8)
        #expect(signals == "1")
    }

    private static func stateJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try #require(String(data: encoder.encode(LiveSessionState()), encoding: .utf8))
    }
}

private struct NativeProcessFixture {
    let directory: URL
    let executable: URL

    init(script: String) throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.executable = self.directory.appendingPathComponent("worker.py")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: false)
        try ("#!/usr/bin/python3\n" + script + "\n").write(to: self.executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.executable.path)
    }

    func waitUntilStarted(suffix: String = "started") async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: self.executable.path + "." + suffix) {
            guard ContinuousClock.now < deadline else { throw LiveBridgeFailure.unavailable }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.directory)
    }
}
