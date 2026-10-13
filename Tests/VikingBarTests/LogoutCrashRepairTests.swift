import Foundation
import os
import Testing
@testable import VikingBarCore

struct LogoutCrashRepairTests {
    @Test(arguments: [false, true])
    func `accepted login after logout survives persistent metadata commit failure`(
        storageRecovered: Bool,
    ) async throws {
        let rig = Rig()
        let metadata = PersistentMetadataFaultStore()
        func session() -> VikingSession {
            VikingSession(transport: rig.transport, store: rig.store, lease: rig.lease, cache: rig.cache,
                          signInStore: metadata, rememberedStore: rig.secrets, now: { rig.clock.now() })
        }
        let initial = session()
        let connected = try await initial.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials)
        let loggedOut = try await initial.logout(expected: #require(connected.signIn?.fence))
        let tombstone = try #require(loggedOut.signIn?.fence)
        rig.clock.advance(61)
        metadata.failAfterAdditionalSaves(2)
        let accepted = try await initial.bootstrapWithDiagnostics(credentials: .init(
            clientID: "replacement-public", username: "replacement-reader", password: "synthetic",
        ), expected: tombstone)
        let stored = try JSONDecoder().decode(StoredSession.self, from: #require(rig.store.load()))
        let persisted = try JSONDecoder().decode(AccountSignInRecord.self, from: #require(metadata.load()))
        #expect(accepted.connectionID == stored.connectionID)
        #expect(accepted.connectionID != connected.connectionID)
        #expect(accepted.connectionSummary?.username == "replacement-reader")
        #expect(accepted.failure == nil)
        #expect(accepted.signIn?.failure == .storage)
        #expect(try #require(stored.signInRevision) > persisted.revision)
        #expect(persisted.disposition == .loggedOut)
        if storageRecovered {
            metadata.allowWrites()
        }
        let restored = try await session().restore()
        #expect(restored.connectionID == accepted.connectionID)
        #expect(restored.connectionSummary?.username == "replacement-reader")
        #expect(restored.signIn?.remembered == .disabled)
        #expect(restored.signIn?.failure == (storageRecovered ? nil : .storage))
        #expect(rig.store.load() != nil)
        #expect(await rig.transport.paths() == ["/mv/oauth2/token", "/mv/oauth2/token"])
        metadata.allowWrites()
        let repaired = try await session().restore()
        #expect(repaired.connectionID == accepted.connectionID)
        #expect(repaired.signIn?.failure == nil)
        #expect(try JSONDecoder().decode(AccountSignInRecord.self, from: #require(metadata.load())).summary?.username
            == "replacement-reader")
    }

    @Test(arguments: [false, true])
    func `accepted home login after logout survives persistent metadata commit failure`(
        storageRecovered: Bool,
    ) async throws {
        let rig = try HomeRig()
        let metadata = PersistentMetadataFaultStore()
        func account() -> TelenetHomeAccount {
            TelenetHomeAccount(key: rig.key, transport: rig.transport, store: rig.store, lease: rig.lease,
                               cache: rig.cache, signInStore: metadata, rememberedStore: rig.secrets,
                               now: { rig.clock.now })
        }
        let initial = account()
        await rig.transport.enableLogin()
        let original = try await initial.connect(credentials: .telenet(.init(
            username: "reader",
            password: "synthetic",
        )))
        try await initial.logout(expected: #require(await initial.state().signIn?.fence))
        let tombstone = try #require(await initial.state().signIn?.fence)
        rig.clock.advance(61)
        metadata.failAfterAdditionalSaves(2)
        await rig.transport.enableLogin()
        let accepted = try await initial.connect(
            credentials: .telenet(.init(username: "replacement-reader", password: "synthetic")),
            rememberPassword: true, expected: tombstone,
        )
        let connected = await initial.state()
        #expect(accepted != original)
        #expect(connected.connectionSummary?.username == "replacement-reader")
        #expect(connected.selectedHomeUsage?.downloaded?.totalGB == 60)
        #expect(connected.failure == nil)
        #expect(connected.signIn?.failure == .storage)
        let requests = await rig.transport.requests.count
        if storageRecovered {
            metadata.allowWrites()
        }
        let restarted = account()
        try await restarted.perform(.restore)
        let restored = await restarted.state()
        #expect(restored.connectionID == accepted)
        #expect(restored.connectionSummary?.username == "replacement-reader")
        #expect(restored.selectedHomeUsage?.downloaded?.totalGB == 60)
        #expect(restored.signIn?.remembered == .disabled)
        #expect(restored.signIn?.failure == (storageRecovered ? nil : .storage))
        #expect(rig.store.load() != nil)
        #expect(await rig.transport.requests.count == requests)
        metadata.allowWrites()
        let repaired = account()
        try await repaired.perform(.restore)
        #expect(await repaired.state().connectionID == accepted)
        #expect(await repaired.state().signIn?.failure == nil)
        #expect(try JSONDecoder().decode(AccountSignInRecord.self, from: #require(metadata.load())).summary?.username
            == "replacement-reader")
    }

    @Test(arguments: [false, true])
    func `mobile logout rejects older and equal session revisions`(equalRevision: Bool) async throws {
        let rig = Rig()
        let connected = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials)
        rig.store.failDelete = true
        await #expect(throws: LiveFailure.storage) {
            try await rig.session.logout(expected: #require(connected.signIn?.fence))
        }
        let tombstone = try #require(await rig.session.state().signIn?.fence)
        if equalRevision {
            var record = try JSONDecoder().decode(StoredSession.self, from: #require(rig.store.load()))
            record.signInRevision = tombstone.revision
            try rig.store.save(JSONEncoder().encode(record))
        }
        rig.store.failDelete = false
        let restored = try await rig.newSession().restore()
        #expect(restored.connectionID == nil)
        #expect(restored.connectionSummary?.username == "test-user")
        #expect(rig.store.load() == nil)
        #expect(await rig.transport.paths() == ["/mv/oauth2/token"])
    }

    @Test(arguments: [false, true])
    func `home logout rejects older and equal session revisions`(equalRevision: Bool) async throws {
        let rig = try HomeRig()
        let initial = rig.account()
        await rig.transport.enableLogin()
        _ = try await initial.connect(credentials: .telenet(.init(username: "reader", password: "synthetic")))
        rig.store.failDelete = true
        await #expect(throws: LiveFailure.storage) {
            try await initial.logout(expected: #require(await initial.state().signIn?.fence))
        }
        let tombstone = try #require(await initial.state().signIn?.fence)
        if equalRevision {
            var record = try JSONDecoder().decode(TelenetSessionRecord.self, from: #require(rig.store.load()))
            record.signInRevision = tombstone.revision
            try rig.store.save(JSONEncoder().encode(record))
        }
        let requests = await rig.transport.requests.count
        rig.store.failDelete = false
        let restarted = rig.account()
        try await restarted.perform(.restore)
        #expect(await restarted.state().connectionID == nil)
        #expect(await restarted.state().connectionSummary?.username == "reader")
        #expect(rig.store.load() == nil)
        #expect(await rig.transport.requests.count == requests)
    }

    @Test func `failed mobile accepted session write cannot resurrect the session before logout`() async throws {
        let rig = Rig()
        let connected = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials)
        rig.store.failDelete = true
        await #expect(throws: LiveFailure.storage) {
            try await rig.session.logout(expected: #require(connected.signIn?.fence))
        }
        let tombstone = try #require(await rig.session.state().signIn?.fence)
        rig.clock.advance(61)
        rig.store.failOnSave = rig.store.saveCount + 1
        await #expect(throws: BootstrapFailure.keychainWrite) {
            try await rig.session.bootstrapWithDiagnostics(credentials: .init(
                clientID: "replacement-public", username: "replacement-reader", password: "synthetic",
            ), expected: tombstone)
        }
        rig.store.failDelete = false
        let restored = try await rig.newSession().restore()
        #expect(restored.connectionID == nil)
        #expect(restored.connectionSummary?.username == "test-user")
        #expect(rig.store.load() == nil)
        #expect(await rig.transport.paths() == ["/mv/oauth2/token", "/mv/oauth2/token"])
    }

    @Test func `failed home accepted session write cannot resurrect the session before logout`() async throws {
        let rig = try HomeRig()
        let initial = rig.account()
        await rig.transport.enableLogin()
        _ = try await initial.connect(credentials: .telenet(.init(username: "reader", password: "synthetic")))
        rig.store.failDelete = true
        await #expect(throws: LiveFailure.storage) {
            try await initial.logout(expected: #require(await initial.state().signIn?.fence))
        }
        let tombstone = try #require(await initial.state().signIn?.fence)
        rig.clock.advance(61)
        rig.store.failOnSave = rig.store.saveCount + 2
        await rig.transport.enableLogin()
        await #expect(throws: LiveFailure.storage) {
            try await initial.connect(
                credentials: .telenet(.init(username: "replacement-reader", password: "synthetic")),
                rememberPassword: false,
                expected: tombstone,
            )
        }
        let requests = await rig.transport.requests.count
        rig.store.failDelete = false
        let restarted = rig.account()
        try await restarted.perform(.restore)
        #expect(await restarted.state().connectionID == nil)
        #expect(await restarted.state().connectionSummary?.username == "reader")
        #expect(rig.store.load() == nil)
        #expect(await rig.transport.requests.count == requests)
    }
}

extension LogoutCrashRepairTests {
    @Test func `accepted mobile session retains old password cleanup across persistent metadata failure`(
    ) async throws {
        let rig = Rig()
        let metadata = PersistentMetadataFaultStore()
        func session() -> VikingSession {
            VikingSession(transport: rig.transport, store: rig.store, lease: rig.lease, cache: rig.cache,
                          signInStore: metadata, rememberedStore: rig.secrets, now: { rig.clock.now() })
        }
        let initial = session()
        let first = try await initial.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                               rememberPassword: true)
        rig.clock.advance(61)
        metadata.failAfterAdditionalSaves(2)
        let accepted = try await initial.bootstrapWithDiagnostics(credentials: .init(
            clientID: "replacement-public", username: "replacement-reader", password: "synthetic",
        ), expected: first.signIn?.fence)
        let restored = try await session().restore()
        #expect(restored.connectionID == accepted.connectionID)
        #expect(restored.connectionSummary?.username == "replacement-reader")
        #expect(restored.signIn?.remembered == .cleanupRequired)
        #expect(restored.signIn?.failure == .storage)
        #expect(rig.secrets.load() != nil)
        metadata.allowWrites()
        let repaired = try await session().restore()
        let cleaned = try await session().disableRememberedSignIn(expected: #require(repaired.signIn?.fence))
        #expect(cleaned.signIn?.remembered == .disabled)
        #expect(rig.secrets.load() == nil)
    }

    @Test func `accepted home session retains old password cleanup across persistent metadata failure`() async throws {
        let rig = try HomeRig()
        let metadata = PersistentMetadataFaultStore()
        func account() -> TelenetHomeAccount {
            TelenetHomeAccount(key: rig.key, transport: rig.transport, store: rig.store, lease: rig.lease,
                               cache: rig.cache, signInStore: metadata, rememberedStore: rig.secrets,
                               now: { rig.clock.now })
        }
        let initial = account()
        await rig.transport.enableLogin()
        _ = try await initial.connect(credentials: .telenet(.init(username: "reader", password: "synthetic")),
                                      rememberPassword: true, expected: nil)
        let first = await initial.state()
        rig.clock.advance(61)
        metadata.failAfterAdditionalSaves(2)
        await rig.transport.enableLogin()
        let accepted = try await initial.connect(
            credentials: .telenet(.init(username: "replacement-reader", password: "synthetic")),
            rememberPassword: false, expected: first.signIn?.fence,
        )
        let restarted = account()
        try await restarted.perform(.restore)
        let restored = await restarted.state()
        #expect(restored.connectionID == accepted)
        #expect(restored.connectionSummary?.username == "replacement-reader")
        #expect(restored.signIn?.remembered == .cleanupRequired)
        #expect(restored.signIn?.failure == .storage)
        #expect(rig.secrets.load() != nil)
        metadata.allowWrites()
        try await restarted.perform(.restore)
        try await restarted.disableRememberedSignIn(expected: #require(await restarted.state().signIn?.fence))
        #expect(await restarted.state().signIn?.remembered == .disabled)
        #expect(rig.secrets.load() == nil)
    }
}

private final class PersistentMetadataFaultStore: SessionStore, Sendable {
    private struct State {
        var data: Data?
        var saves = 0
        var failAfter: Int?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func failAfterAdditionalSaves(_ count: Int) {
        self.state.withLock { $0.failAfter = $0.saves + count }
    }

    func allowWrites() {
        self.state.withLock { $0.failAfter = nil }
    }

    func load() -> Data? {
        self.state.withLock { $0.data }
    }

    func delete() {
        self.state.withLock { $0.data = nil }
    }

    func save(_ data: Data) throws {
        try self.state.withLock {
            $0.saves += 1
            if let limit = $0.failAfter, $0.saves > limit {
                throw LiveFailure.storage
            }
            $0.data = data
        }
    }
}
