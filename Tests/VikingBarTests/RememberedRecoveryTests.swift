import Foundation
import Testing
@testable import VikingBarCore

struct RememberedRecoveryTests {
    @Test func `saved mobile login fetches the retained SIM without carrying previous usage`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                           rememberPassword: true)
        let original = try await rig.session.refresh(subscriptionID: "sim-b")
        rig.clock.advance(61)
        let recovered = try await rig.newSession().savedSignIn(expected: #require(original.signIn?.fence))
        #expect(recovered.connectionID != original.connectionID)
        #expect(recovered.selectedSubscriptionID == "sim-b")
        #expect(recovered.snapshot.allowance == .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 75))
        #expect(await rig.transport.paths().suffix(2) == ["/mv/subscriptions", "/mv/subscriptions/sim-b/balance"])
        rig.clock.advance(61)
        await rig.transport.failBalance(code: 503)
        let retry = rig.newSession()
        await #expect(throws: LiveFailure.serverUnavailable) {
            try await retry.savedSignIn(expected: #require(recovered.signIn?.fence))
        }
        let failed = await retry.state()
        #expect(failed.connectionID != recovered.connectionID)
        #expect(failed.selectedSubscriptionID == "sim-b")
        #expect(failed.balance == nil)
        #expect(failed.snapshot.allowance == .unavailable)
        #expect(failed.failure == .serverUnavailable)
    }

    @Test func `saved mobile login selects an available SIM when the old SIM is gone`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                           rememberPassword: true)
        let original = try await rig.session.refresh(subscriptionID: "sim-b")
        await rig.transport.setResponse(path: "/mv/subscriptions", json: #"[{"id":"sim-a","type":"postpaid"}]"#)
        rig.clock.advance(61)
        let recovered = try await rig.newSession().savedSignIn(expected: #require(original.signIn?.fence))
        #expect(recovered.selectedSubscriptionID == "sim-a")
        #expect(recovered.snapshot.allowance == .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 75))
    }

    @Test(arguments: [false, true])
    func `missing or corrupt password consumes a persistent bounded attempt`(corrupt: Bool) async throws {
        let rig = Rig()
        let connected = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                                       rememberPassword: true)
        _ = try await rig.session.refresh()
        if corrupt {
            try rig.secrets.save(Data("corrupt".utf8))
        } else {
            try rig.secrets.delete()
        }
        rig.clock.advance(61)
        let fence = try #require(connected.signIn?.fence)
        await #expect(throws: LiveFailure.savedSignInUnavailable) {
            try await rig.newSession().savedSignIn(expected: fence)
        }
        let restored = try await rig.newSession().restore()
        #expect(restored.signIn?.attemptPending == true)
        #expect(restored.signIn?.nextPasswordAttemptAt == rig.clock.now().addingTimeInterval(60))
        await #expect(throws: LiveFailure.rateLimited) { try await rig.newSession().savedSignIn(expected: fence) }
        #expect(restored.connectionID == connected.connectionID)
        #expect(await rig.transport.paths() == ["/mv/oauth2/token", "/mv/subscriptions",
                                                "/mv/subscriptions/sim-a/balance"])
    }

    @Test func `provider and slot bindings reject a password from another account`() throws {
        let secrets = MemorySessionStore()
        let owner = AccountSignInPersistence(key: .legacy, store: MemorySessionStore(), secrets: secrets)
        let setup = AccountConnectionSummary(clientID: "public", username: "reader")
        let connection = ConnectionID()
        var record = try owner.accept(setup: setup, connection: connection, expected: nil)
        try owner.remember(password: "synthetic", record: &record)
        for key in [FixtureAccounts.secondMobile, FixtureAccounts.telenet] {
            let other = AccountSignInPersistence(key: key, store: MemorySessionStore(), secrets: secrets)
            var copied = record
            copied = try other.accept(setup: setup, connection: connection, expected: nil)
            copied.remembered = .available
            copied.credentialGeneration = record.credentialGeneration
            try other.save(copied)
            #expect(throws: LiveFailure.savedSignInUnavailable) { try other.credentials(record: copied) }
            #expect(try owner.credentials(record: owner.load()).password == "synthetic")
        }
    }

    @Test func `mobile logout drains a late accepted password exchange before committing tombstone`() async throws {
        let rig = Rig()
        let first = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                                   rememberPassword: true)
        rig.clock.advance(61)
        await rig.transport.pauseNext(path: "/mv/oauth2/token")
        let pending = Task { try await rig.session.savedSignIn(expected: #require(first.signIn?.fence)) }
        await rig.transport.waitUntilPaused()
        let generation = await rig.session.generation
        let logout = Task { try await rig.session.logout(expected: #require(first.signIn?.fence)) }
        while await rig.session.generation == generation {
            await Task.yield()
        }
        await rig.transport.resume()
        await #expect(throws: CancellationError.self) { try await pending.value }
        let loggedOut = try await logout.value
        #expect(loggedOut.connectionID == nil)
        #expect(loggedOut.signIn?.remembered == .disabled)
        #expect(loggedOut.connectionSummary?.username == "test-user")
        #expect(try await rig.newSession().restore().connectionID == nil)
        #expect(rig.secrets.load() == nil)
        #expect(rig.store.load() == nil)
    }

    @Test func `telenet logout drains a late usage read and remains logged out across actors`() async throws {
        let rig = try HomeRig()
        await rig.transport.enableLogin()
        let account = rig.account()
        _ = try await account.connect(credentials: .telenet(.init(username: "reader", password: "synthetic")),
                                      rememberPassword: true, expected: nil)
        let connected = await account.state()
        rig.clock.advance(61)
        await rig.transport.pauseDaily()
        let pending = Task { try await account.perform(.refresh) }
        await rig.transport.waitUntilPaused()
        let generation = await account.generation
        let logout = Task { try await account.logout(expected: #require(connected.signIn?.fence)) }
        while await account.generation == generation {
            await Task.yield()
        }
        await rig.transport.resume()
        await #expect(throws: CancellationError.self) { try await pending.value }
        try await logout.value
        let restarted = rig.account()
        try await restarted.perform(.restore)
        let loggedOut = await restarted.state()
        #expect(loggedOut.connectionID == nil)
        #expect(loggedOut.signIn?.remembered == .disabled)
        #expect(loggedOut.connectionSummary?.username == "reader")
        #expect(loggedOut.homeUsage == nil)
        #expect(rig.store.load() == nil)
        #expect(rig.secrets.load() == nil)
    }
}
