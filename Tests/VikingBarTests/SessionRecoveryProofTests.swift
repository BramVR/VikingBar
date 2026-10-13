import Foundation
import Testing
@testable import VikingBarCLI
@testable import VikingBarCore

struct SessionRecoveryProofTests {
    @Test func `mobile proof observes password expiry and rejected refresh on the real token path`() async throws {
        let base = RecoveryTokenResponses()
        let transport = MobileRecoveryTransport(deadline: Date().addingTimeInterval(60), delayAccess: false, base: base)
        var password = try ProofEndpoint.token.request()
        password.httpBody = Data("grant_type=password".utf8)
        let accepted = try await transport.send(password)
        #expect(accepted.statusCode == 200)
        #expect(await transport.passwordGrants == 1)
        #expect(try #require(await transport.expiry).timeIntervalSinceNow > 3500)
        var refresh = try ProofEndpoint.token.request()
        refresh.httpBody = Data("grant_type=refresh_token".utf8)
        let rejected = try await transport.send(refresh)
        #expect(rejected.statusCode == 400)
        #expect(await transport.refreshGrants == 1)
        #expect(await transport.rejectedGrant == true)
    }

    @Test func `exercise accepts only its private prepared account root`() throws {
        let fixture = try RecoveryRootFixture()
        defer { fixture.remove() }
        let prepared = try RecoveryInput(check: "mobile-remembered-sign-in", data: fixture.input(phase: "prepare"))
        try prepared.storage.prepare()
        try prepared.publishOwnership()
        let exercise = try RecoveryInput(check: "mobile-remembered-sign-in", data: fixture.input(phase: "exercise"))
        #expect(exercise.key == fixture.key)
        #expect(exercise.storage.directory.path == fixture.root.path + "/accounts/mobile-vikings/"
            + fixture.key.slot.uuidString.lowercased())
        #expect(exercise.phase == "exercise")
        #expect(throws: ProofFailure.invalidInput) {
            try RecoveryInput(check: "mobile-remembered-sign-in", data: fixture.input(phase: "prepare"))
        }
        #expect(throws: LiveFailure.storage) { try prepared.publishOwnership() }
    }

    @Test(arguments: ["missing", "foreign-account", "foreign-root", "public-marker", "public-root", "symlink-marker"])
    func `all later proof phases reject unowned storage before provider creation`(damage: String) throws {
        let fixture = try RecoveryRootFixture()
        defer { fixture.remove() }
        let prepared = try RecoveryInput(check: "mobile-remembered-sign-in", data: fixture.input(phase: "prepare"))
        try prepared.storage.prepare()
        if damage != "missing" {
            try prepared.publishOwnership()
        }
        let marker = fixture.root.appendingPathComponent("session-recovery-owner.json")
        switch damage {
        case "foreign-account", "foreign-root":
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
            if damage == "foreign-root" {
                object["root"] = fixture.parent.path
            } else {
                object["account"] = ["provider": "telenet", "slot": fixture.key.slot.uuidString]
            }
            try JSONSerialization.data(withJSONObject: object).write(to: marker)
        case "public-marker": try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: marker.path,
            )
        case "public-root": try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.root.path,
            )
        case "symlink-marker":
            let moved = fixture.parent.appendingPathComponent("other-marker.json")
            try FileManager.default.moveItem(at: marker, to: moved)
            try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: moved)
        default: break
        }
        for phase in ["exercise", "inspect", "disable", "logout"] {
            #expect(throws: (any Error).self) {
                try RecoveryInput(check: "mobile-remembered-sign-in", data: fixture.input(phase: phase))
            }
        }
    }
}

private actor RecoveryTokenResponses: ProofHTTPTransport {
    func send(_ request: URLRequest) -> ProofHTTPResponse {
        if request.httpBody == Data("grant_type=password".utf8) {
            return ProofHTTPResponse(statusCode: 200, data: Data(#"{"expires_in":3600}"#.utf8))
        }
        return ProofHTTPResponse(statusCode: 400, data: Data(#"{"error":"invalid_grant"}"#.utf8))
    }
}

private struct RecoveryRootFixture {
    let key = AccountKey(provider: .mobileVikings)
    let parent: URL
    let root: URL

    init() throws {
        self.parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("recovery-test-" + UUID().uuidString, isDirectory: true)
        self.root = self.parent.appendingPathComponent("session-recovery-" + self.key.slot.uuidString.lowercased(),
                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: self.parent, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    func input(phase: String) throws -> Data {
        var object: [String: Any] = ["account": self.key.id, "root": self.root.path, "phase": phase,
                                     "timeout_seconds": 60]
        if phase == "exercise" {
            object["credentials"] = ["client_id": "public", "username": "synthetic", "password": "synthetic"]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.parent)
    }
}
