import Foundation
import Testing
@testable import VikingBarCore

struct LiveSessionAccountTests {
    @Test func `balance cache omits the saved username`() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "account-cache-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "balance.json")
        let cache = FileBalanceCache(url: url)
        var state = LiveSessionState()
        let connectionID = ConnectionID()
        state.connectionID = connectionID
        state.connectionSummary = AccountConnectionSummary(clientID: "client", username: "private-username-marker")
        try cache.save(state)
        let data = try Data(contentsOf: url)
        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(!text.contains("private-username-marker"))
        #expect(try cache.load(connectionID: connectionID)?.connectionSummary == nil)
    }

    @Test func `connection summary survives cache restore from authoritative session record`() async throws {
        let rig = Rig()
        let credentials = ProofCredentials(
            clientID: "public-client", username: "connected-user", password: "private-marker",
        )
        let connected = try await rig.session.bootstrap(credentials: credentials)
        #expect(connected.connectionSummary == AccountConnectionSummary(
            clientID: "public-client", username: "connected-user",
        ))
        var cached = try await rig.session.refresh()
        cached.connectionSummary = AccountConnectionSummary(clientID: "stale-client", username: "stale-user")
        rig.cache.save(cached)
        let restored = try await rig.newSession().restore()
        #expect(restored.connectionSummary == connected.connectionSummary)
        let record = try #require(rig.store.load())
        let recordText = try #require(String(bytes: record, encoding: .utf8))
        #expect(recordText.contains("public-client"))
        #expect(recordText.contains("connected-user"))
        #expect(!recordText.contains("private-marker"))
    }

    @Test func `legacy stored session reports only its known public client`() async throws {
        let rig = Rig()
        let connectionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        try rig.store.save(Data("""
        {"version":1,"clientID":"legacy-client","connectionID":{"rawValue":"\(connectionID.uuidString)"},\
        "refreshToken":"legacy-refresh","generation":0,"rotationPending":false}
        """.utf8))
        let restored = try await rig.session.restore()
        #expect(restored.connectionSummary == AccountConnectionSummary(clientID: "legacy-client", username: nil))
    }
}
