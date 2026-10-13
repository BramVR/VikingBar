import Foundation
import Testing
@testable import VikingBarCore

struct AccountSignInTests {
    @Test func `logout tombstone retains setup and prevents older session repair`() throws {
        let metadata = MemorySessionStore()
        let secrets = MemorySessionStore()
        let persistence = AccountSignInPersistence(key: .legacy, store: metadata, secrets: secrets)
        let setup = AccountConnectionSummary(clientID: "public", username: "first@example.invalid")
        let connection = ConnectionID()
        var record = try persistence.accept(setup: setup, connection: connection, expected: nil)
        try persistence.remember(password: "test-password", record: &record)
        #expect(try persistence.credentials(record: record).summary == setup)
        let tombstone = try persistence.cleanup(persistence.logout(expected: record.fence))
        #expect(tombstone.summary == setup)
        #expect(tombstone.presentation.remembered == .disabled)
        let restored = try persistence.reconcile(summary: setup, connection: connection, revision: record.revision)
        #expect(restored.disposition == .loggedOut)
        #expect(restored.fence.connectionID == nil)
    }

    @Test func `accepted username change cannot reuse prior remembered password`() throws {
        let persistence = AccountSignInPersistence(key: .legacy, store: MemorySessionStore(),
                                                   secrets: MemorySessionStore())
        var first = try persistence.accept(setup: .init(clientID: "public", username: "old"),
                                           connection: ConnectionID(), expected: nil)
        try persistence.remember(password: "old-password", record: &first)
        let replacement = try persistence.accept(setup: .init(clientID: "public", username: "new"),
                                                 connection: ConnectionID(), expected: first.fence)
        #expect(replacement.summary?.username == "new")
        #expect(replacement.presentation.remembered == .cleanupRequired)
        #expect(throws: LiveFailure.savedSignInUnavailable) { try persistence.credentials(record: replacement) }
    }
}

struct RememberedSessionTests {
    @Test func `provider saved sign in returns its recovered balance without another refresh`() async throws {
        let rig = Rig()
        let first = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                                   rememberPassword: true)
        rig.clock.advance(61)
        let provider = MobileVikingsAccount(key: .legacy, session: rig.newSession())
        try await provider.perform(.savedSignIn(#require(first.signIn?.fence)))
        let recovered = await provider.state()
        #expect(recovered.connectionID != first.connectionID)
        #expect(recovered.snapshot.allowance == .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 75))
        #expect(await rig.transport.paths() == ["/mv/oauth2/token", "/mv/oauth2/token", "/mv/subscriptions",
                                                "/mv/subscriptions/sim-a/balance"])
    }

    @Test func `legacy home restore supplies logout fence without discovering a username`() async throws {
        let rig = try HomeRig()
        let account = rig.account()
        try await account.perform(.restore)
        let restored = await account.state()
        #expect(restored.connectionSummary == .init(clientID: "", username: nil))
        #expect(restored.signIn?.remembered == .disabled)
        let fence = try #require(restored.signIn?.fence)
        #expect(fence.connectionID == restored.connectionID)
        try await account.perform(.logout(fence))
        let restarted = rig.account()
        try await restarted.perform(.restore)
        #expect(await restarted.state().signIn?.fence == .init(revision: fence.revision + 1, connectionID: nil))
        #expect(await restarted.state().connectionSummary == .init(clientID: "", username: nil))
        #expect(rig.store.load() == nil)
        #expect(await rig.transport.requests.count == 0)
    }

    @Test func `remembered login keeps its bound password and attempt floor across actors`() async throws {
        let clock = LiveTestClock()
        let rig = Rig(now: { clock.now() })
        let first = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                                   rememberPassword: true)
        #expect(first.signIn?.remembered == .available)
        let restored = try await rig.newSession().restore()
        #expect(restored.connectionSummary?.username == "test-user")
        let fence = try #require(restored.signIn?.fence)
        await #expect(throws: LiveFailure.rateLimited) { try await rig.newSession().savedSignIn(expected: fence) }
        clock.advance(61)
        let replacement = try await rig.newSession().savedSignIn(expected: fence)
        #expect(replacement.connectionID != first.connectionID)
        #expect(replacement.signIn?.remembered == .available)
        #expect(replacement.snapshot.allowance == .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 75))
        #expect(await rig.transport.paths() == ["/mv/oauth2/token", "/mv/oauth2/token", "/mv/subscriptions",
                                                "/mv/subscriptions/sim-a/balance"])
        #expect(throws: LiveFailure.connectionChanged) { try AccountSignInPersistence(
            key: .legacy, store: rig.metadata, secrets: rig.secrets,
        ).checked(fence) }
    }

    @Test func `accepted connection stays usable when remembered storage cannot commit`() async throws {
        for boundary in [1, 2] {
            let rig = Rig()
            if boundary == 1 {
                rig.secrets.failOnSave = 1
            } else {
                rig.metadata.failOnSave = 5
            }
            let connected = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                                           rememberPassword: true)
            #expect(connected.connectionSummary?.username == "test-user")
            #expect(connected.signIn?.remembered == .disabled)
            #expect(connected.signIn?.failure == .storage)
            #expect(rig.secrets.saveCount == 1)
            let usable = try await rig.session.refresh()
            #expect(usable.snapshot.allowance == .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 75))
            let restarted = try await rig.newSession().restore()
            #expect(restarted.signIn?.remembered == .disabled)
            #expect(restarted.connectionID == connected.connectionID)
        }
    }

    @Test func `session commit and metadata commit faults cannot restore the wrong accepted setup`() async throws {
        let clock = LiveTestClock()
        let rig = Rig(now: { clock.now() })
        let first = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                                   rememberPassword: true)
        clock.advance(61)
        rig.store.failOnSave = 2
        await #expect(throws: BootstrapFailure.keychainWrite) {
            try await rig.session.bootstrapWithDiagnostics(credentials: .init(clientID: "other", username: "other",
                                                                              password: "synthetic"),
                                                           rememberPassword: true, expected: first.signIn?.fence)
        }
        let restored = try await rig.newSession().restore()
        #expect(restored.connectionSummary?.username == "test-user")
        #expect(restored.connectionID == first.connectionID)
        #expect(restored.signIn?.remembered == .cleanupRequired)
        #expect(rig.secrets.load() != nil)
        let cleaned = try await rig.newSession().disableRememberedSignIn(expected: #require(restored.signIn?.fence))
        #expect(cleaned.signIn?.remembered == .disabled)
        #expect(rig.secrets.load() == nil)

        let accepted = Rig()
        accepted.metadata.failOnSave = 3
        let result = try await accepted.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                                         rememberPassword: false)
        #expect(result.connectionSummary?.username == "test-user")
        #expect(try await accepted.newSession().restore().connectionID == result.connectionID)
    }

    @Test func `logout tombstone wins over failed secret and session deletion across relaunch`() async throws {
        let rig = Rig()
        let connected = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                                       rememberPassword: true)
        _ = try await rig.session.refresh()
        rig.secrets.failDelete = true
        rig.store.failDelete = true
        await #expect(throws: LiveFailure.storage) {
            try await rig.session.logout(expected: #require(connected.signIn?.fence))
        }
        #expect(try rig.cache.load(connectionID: #require(connected.connectionID)) == nil)
        let calls = await rig.transport.paths().count
        let restarted = try await rig.newSession().restore()
        #expect(restarted.connectionID == nil)
        #expect(restarted.connectionSummary?.username == "test-user")
        #expect(restarted.signIn?.remembered == .cleanupRequired)
        await #expect(throws: LiveFailure.notConnected) { try await rig.newSession().refresh() }
        #expect(await rig.transport.paths().count == calls)
        rig.secrets.failDelete = false
        rig.store.failDelete = false
        let cleaned = try await rig.newSession().restore()
        #expect(cleaned.signIn?.remembered == .disabled)
        #expect(rig.secrets.load() == nil)
        #expect(rig.store.load() == nil)
    }

    @Test func `new explicit login can supersede a durable logout fence`() async throws {
        let clock = LiveTestClock()
        let rig = Rig(now: { clock.now() })
        let first = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                                   rememberPassword: true)
        let loggedOut = try await rig.session.logout(expected: #require(first.signIn?.fence))
        clock.advance(61)
        let replacement = try await rig.session.bootstrapWithDiagnostics(credentials: .init(
            clientID: "public", username: "new-reader", password: "synthetic",
        ), rememberPassword: false, expected: loggedOut.signIn?.fence)
        let restarted = try await rig.newSession().restore()
        #expect(restarted.connectionID == replacement.connectionID)
        #expect(restarted.connectionID != first.connectionID)
        #expect(restarted.connectionSummary?.username == "new-reader")
        #expect(restarted.signIn?.remembered == .disabled)
    }

    @Test func `telenet remembered sign in preserves service and honors the persisted failure cooldown`() async throws {
        let rig = try HomeRig()
        await rig.transport.enableLogin()
        let account = rig.account()
        _ = try await account.connect(credentials: .telenet(.init(username: "reader", password: "synthetic")),
                                      rememberPassword: true, expected: nil)
        rig.clock.advance(61)
        try await account.perform(.refreshService("home-b"))
        let original = await account.state()
        rig.clock.advance(61)
        await rig.transport.fail(pathSuffix: "/usage", status: 503, retry: "172800")
        await #expect(throws: LiveFailure.serverUnavailable) { try await account.perform(.refresh) }
        let fence = try #require(original.signIn?.fence)
        await #expect(throws: LiveFailure.rateLimited) { try await rig.account().savedSignIn(expected: fence) }
        rig.clock.advance(172_801)
        await rig.transport.clearFailure()
        await rig.transport.enableLogin()
        let restarted = rig.account()
        try await restarted.savedSignIn(expected: fence)
        let recovered = await restarted.state()
        #expect(recovered.account?.selectedService?.providerID == "home-b")
        #expect(recovered.connectionID != original.connectionID)
        #expect(recovered.signIn?.remembered == .available)
        #expect(recovered.connectionSummary?.username == "reader")
    }
}
