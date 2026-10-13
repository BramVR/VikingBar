import Foundation
import os
import Testing
@testable import VikingBarCore

struct TelenetSavedRecoveryTests {
    @Test(arguments: ["session", "metadata", "lease"])
    func `saved home login propagates storage and lease failures before password exchange`(
        boundary: String,
    ) async throws {
        let rig = try HomeRig()
        let connected = try await self.connect(rig)
        rig.clock.advance(61)
        let session = RecoveryLoadFaultStore(base: rig.store, failedLoad: boundary == "session" ? 1 : nil)
        let metadata = RecoveryLoadFaultStore(base: rig.metadata, failedLoad: boundary == "metadata" ? 3 : nil)
        let lease = boundary == "lease" ? try rig.lease.acquire() : nil
        defer { lease?.release() }
        let restarted = TelenetHomeAccount(key: rig.key, transport: rig.transport, store: session,
                                           lease: rig.lease, cache: rig.cache, signInStore: metadata,
                                           rememberedStore: rig.secrets, now: { rig.clock.now })
        await #expect(throws: boundary == "lease" ? LiveFailure.busy : .storage) {
            try await restarted.savedSignIn(expected: #require(connected.signIn?.fence))
        }
        #expect(try AccountSignInPersistence(key: rig.key, store: rig.metadata,
                                             secrets: rig.secrets).load().fence == connected.signIn?.fence)
        #expect(await rig.transport.requests.filter { $0.url?.path == "/idp/idx/challenge/answer" }.count == 1)
    }

    @Test func `saved home login replaces malformed cookies with a remembered password`() async throws {
        let rig = try HomeRig()
        let connected = try await self.connect(rig)
        try rig.store.save(Data("malformed".utf8))
        rig.clock.advance(61)
        await rig.transport.enableLogin()
        let restarted = rig.account()
        try await restarted.savedSignIn(expected: #require(connected.signIn?.fence))
        let recovered = await restarted.state()
        #expect(recovered.connectionID != connected.connectionID)
        #expect(recovered.connectionSummary?.username == "reader")
        #expect(recovered.signIn?.remembered == .available)
        #expect(recovered.selectedHomeUsage?.downloaded?.totalGB == 60)
    }

    @Test func `malformed home cookies cannot bypass the persisted password budget`() async throws {
        let rig = try HomeRig()
        let connected = try await self.connect(rig)
        try rig.store.save(Data("malformed".utf8))
        await #expect(throws: LiveFailure.rateLimited) {
            try await rig.account().savedSignIn(expected: #require(connected.signIn?.fence))
        }
        let metadata = try AccountSignInPersistence(key: rig.key, store: rig.metadata, secrets: rig.secrets).load()
        #expect(metadata.nextPasswordAttemptAt == rig.clock.now.addingTimeInterval(60))
        #expect(metadata.summary?.username == "reader")
        #expect(await rig.transport.requests.filter { $0.url?.path == "/idp/idx/challenge/answer" }.count == 1)
    }

    @Test func `saved home login preserves valid cookie server cooldown`() async throws {
        let rig = try HomeRig()
        let connected = try await self.connect(rig)
        var record = try JSONDecoder().decode(TelenetSessionRecord.self, from: #require(rig.store.load()))
        record.serverRetryAfter = rig.clock.now.addingTimeInterval(3600)
        try rig.store.save(JSONEncoder().encode(record))
        rig.clock.advance(61)
        await #expect(throws: LiveFailure.rateLimited) {
            try await rig.account().savedSignIn(expected: #require(connected.signIn?.fence))
        }
        #expect(try AccountSignInPersistence(key: rig.key, store: rig.metadata,
                                             secrets: rig.secrets).load().nextPasswordAttemptAt ==
                rig.clock.now.addingTimeInterval(-1))
        #expect(await rig.transport.requests.filter { $0.url?.path == "/idp/idx/challenge/answer" }.count == 1)
    }

    @Test(arguments: ["retained", "removed", "account", "connection", "service"])
    func `saved home login restores only the matching available cached service`(cacheBinding: String) async throws {
        let rig = try HomeRig()
        let account = rig.account()
        _ = try await self.connect(rig, account: account)
        rig.clock.advance(61)
        let selected = ServiceKey(account: rig.key, kind: .home, providerID: "home-b")
        try await account.perform(.selectService(selected))
        let connected = await account.state()
        #expect(connected.account?.selectedService == selected)
        var cached = connected
        switch cacheBinding {
        case "removed": try await rig.transport.replaceServices(["home-a"])
        case "account":
            cached.account = AccountContext(key: FixtureAccounts.telenet, providerName: "Telenet",
                                            services: [], selectedService: selected, capabilities: .usageOnly)
        case "connection": cached.connectionID = ConnectionID()
        case "service":
            let foreignService = ServiceKey(account: FixtureAccounts.telenet, kind: .home, providerID: "home-b")
            cached.account = AccountContext(key: rig.key, providerName: "Telenet",
                                            services: [AccountService(key: foreignService, name: "Home internet")],
                                            selectedService: foreignService, capabilities: .usageOnly)
        default: break
        }
        rig.cache.save(cached)
        try rig.store.delete()
        rig.clock.advance(61)
        await rig.transport.enableLogin()
        let restarted = rig.account()
        try await restarted.perform(.restore)
        #expect(await restarted.state().connectionID == nil)
        try await restarted.savedSignIn(expected: #require(connected.signIn?.fence))
        let recovered = await restarted.state()
        let expected = ServiceKey(account: rig.key, kind: .home,
                                  providerID: cacheBinding == "retained" ? "home-b" : "home-a")
        #expect(recovered.connectionID != connected.connectionID)
        #expect(recovered.account?.selectedService == expected)
        #expect(recovered.selectedHomeUsage?.key == expected)
        #expect(recovered.selectedHomeUsage?.downloaded?.totalGB == 60)
        #expect(await rig.transport.requests.suffix(2).allSatisfy {
            $0.url?.path.contains("/\(expected.providerID)/") == true
        })
    }

    private func connect(_ rig: HomeRig, account: TelenetHomeAccount? = nil) async throws -> LiveSessionState {
        await rig.transport.enableLogin()
        let account = account ?? rig.account()
        _ = try await account.connect(credentials: .telenet(.init(username: "reader", password: "synthetic")),
                                      rememberPassword: true, expected: nil)
        return await account.state()
    }
}

private final class RecoveryLoadFaultStore: SessionStore, Sendable {
    private let base: any SessionStore
    private let failedLoad: Int?
    private let loads = OSAllocatedUnfairLock(initialState: 0)

    init(base: any SessionStore, failedLoad: Int?) {
        self.base = base
        self.failedLoad = failedLoad
    }

    func load() throws -> Data? {
        let count = self.loads.withLock { $0 += 1; return $0 }
        guard count != self.failedLoad else { throw LiveFailure.storage }
        return try self.base.load()
    }

    func save(_ data: Data) throws {
        try self.base.save(data)
    }

    func delete() throws {
        try self.base.delete()
    }
}
