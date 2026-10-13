import Foundation
import os
import Testing
@testable import VikingBarCore

struct SignInBoundaryFailureTests {
    @Test(arguments: [false, true])
    func `mobile lost session keeps setup and password removal available`(inaccessible: Bool) async throws {
        let rig = Rig()
        let connected = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                                       rememberPassword: true)
        let persistence = AccountSignInPersistence(key: .legacy, store: rig.metadata, secrets: rig.secrets)
        var metadata = try persistence.load()
        metadata.remembered = .cleanupRequired
        metadata.credentialGeneration = nil
        try persistence.save(metadata)
        try rig.store.save(Data("malformed".utf8))
        let store = UnavailableLoadStore(base: rig.store)
        store.failLoad = inaccessible
        let restarted = VikingSession(transport: rig.transport, store: store, lease: rig.lease, cache: rig.cache,
                                      signInStore: rig.metadata, rememberedStore: rig.secrets,
                                      now: { rig.clock.now() })
        await #expect(throws: inaccessible ? LiveFailure.storage : .reconnectRequired) {
            try await restarted.restore()
        }
        let lost = await restarted.state()
        #expect(lost.connectionSummary == .init(clientID: "test-client", username: "test-user"))
        #expect(lost.signIn?.fence == connected.signIn?.fence)
        #expect(lost.signIn?.remembered == .cleanupRequired)
        let cleaned = try await restarted.disableRememberedSignIn(expected: #require(lost.signIn?.fence))
        #expect(cleaned.signIn?.remembered == .disabled)
        #expect(rig.secrets.load() == nil)
        #expect(await rig.transport.paths() == ["/mv/oauth2/token"])
    }

    @Test(arguments: [false, true])
    func `home lost session keeps setup and password removal available`(inaccessible: Bool) async throws {
        let rig = try HomeRig()
        await rig.transport.enableLogin()
        let account = rig.account()
        _ = try await account.connect(credentials: .telenet(.init(username: "reader", password: "synthetic")),
                                      rememberPassword: true, expected: nil)
        let connected = await account.state()
        let requests = await rig.transport.requests.count
        let persistence = AccountSignInPersistence(key: rig.key, store: rig.metadata, secrets: rig.secrets)
        var metadata = try persistence.load()
        metadata.remembered = .cleanupRequired
        metadata.credentialGeneration = nil
        try persistence.save(metadata)
        try rig.store.save(Data("malformed".utf8))
        let store = UnavailableLoadStore(base: rig.store)
        store.failLoad = inaccessible
        let restarted = TelenetHomeAccount(key: rig.key, transport: rig.transport, store: store,
                                           lease: rig.lease, cache: rig.cache, signInStore: rig.metadata,
                                           rememberedStore: rig.secrets, now: { rig.clock.now })
        await #expect(throws: inaccessible ? LiveFailure.storage : .reconnectRequired) {
            try await restarted.perform(.restore)
        }
        let lost = await restarted.state()
        #expect(lost.connectionSummary == .init(clientID: "", username: "reader"))
        #expect(lost.signIn?.fence == connected.signIn?.fence)
        #expect(lost.signIn?.remembered == .cleanupRequired)
        try await restarted.disableRememberedSignIn(expected: #require(lost.signIn?.fence))
        #expect(await restarted.state().signIn?.remembered == .disabled)
        #expect(rig.secrets.load() == nil)
        #expect(await rig.transport.requests.count == requests)
    }

    @Test(arguments: [false, true])
    func `mobile publication failure exposes failed secret cleanup without losing accepted usage`(
        deletionFails: Bool,
    ) async throws {
        let rig = Rig()
        let metadata = RememberedPublicationFaultStore(base: rig.metadata)
        rig.secrets.failDelete = deletionFails
        let session = VikingSession(transport: rig.transport, store: rig.store, lease: rig.lease, cache: rig.cache,
                                    signInStore: metadata, rememberedStore: rig.secrets, now: { rig.clock.now() })
        let connected = try await session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                                   rememberPassword: true)
        #expect(connected.signIn?.remembered == (deletionFails ? .cleanupRequired : .disabled))
        #expect(connected.signIn?.failure == .storage)
        #expect(connected.connectionSummary?.username == "test-user")
        #expect((rig.secrets.load() != nil) == deletionFails)
        let usable = try await rig.session.refresh()
        #expect(usable.snapshot.allowance == .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 75))
        let restored = try await rig.newSession().restore()
        #expect(restored.connectionID == connected.connectionID)
        #expect(restored.signIn?.remembered == (deletionFails ? .cleanupRequired : .disabled))
        if deletionFails {
            rig.secrets.failDelete = false
            let cleaned = try await rig.session.disableRememberedSignIn(expected: #require(restored.signIn?.fence))
            #expect(cleaned.connectionID == connected.connectionID)
            #expect(cleaned.signIn?.remembered == .disabled)
            #expect(rig.secrets.load() == nil)
        }
    }

    @Test(arguments: [false, true])
    func `home publication failure exposes failed secret cleanup without losing accepted usage`(
        deletionFails: Bool,
    ) async throws {
        let rig = try HomeRig()
        let metadata = RememberedPublicationFaultStore(base: rig.metadata)
        rig.secrets.failDelete = deletionFails
        await rig.transport.enableLogin()
        let account = TelenetHomeAccount(key: rig.key, transport: rig.transport, store: rig.store, lease: rig.lease,
                                         cache: rig.cache, signInStore: metadata, rememberedStore: rig.secrets,
                                         now: { rig.clock.now })
        let connection = try await account.connect(
            credentials: .telenet(.init(username: "reader", password: "synthetic")),
            rememberPassword: true, expected: nil,
        )
        let connected = await account.state()
        #expect(connected.signIn?.remembered == (deletionFails ? .cleanupRequired : .disabled))
        #expect(connected.signIn?.failure == .storage)
        #expect(connected.connectionSummary?.username == "reader")
        #expect(connected.selectedHomeUsage?.downloaded?.totalGB == 60)
        #expect((rig.secrets.load() != nil) == deletionFails)
        let restarted = rig.account()
        try await restarted.perform(.restore)
        let restored = await restarted.state()
        #expect(restored.connectionID == connection)
        #expect(restored.signIn?.remembered == (deletionFails ? .cleanupRequired : .disabled))
        if deletionFails {
            rig.secrets.failDelete = false
            try await restarted.disableRememberedSignIn(expected: #require(restored.signIn?.fence))
            #expect(await restarted.state().connectionID == connection)
            #expect(await restarted.state().signIn?.remembered == .disabled)
            #expect(rig.secrets.load() == nil)
        }
    }

    @Test func `home session write failure retains prior password cleanup after relaunch`() async throws {
        let rig = try HomeRig()
        await rig.transport.enableLogin()
        let initial = rig.account()
        _ = try await initial.connect(credentials: .telenet(.init(username: "reader", password: "synthetic")),
                                      rememberPassword: true, expected: nil)
        let first = await initial.state()
        rig.clock.advance(61)
        rig.store.failOnSave = rig.store.saveCount + 2
        await rig.transport.enableLogin()
        await #expect(throws: LiveFailure.storage) {
            try await initial.connect(credentials: .telenet(.init(username: "replacement", password: "synthetic")),
                                      rememberPassword: false, expected: first.signIn?.fence)
        }
        let restarted = rig.account()
        try await restarted.perform(.restore)
        let restored = await restarted.state()
        #expect(restored.connectionID == first.connectionID)
        #expect(restored.connectionSummary?.username == "reader")
        #expect(restored.signIn?.remembered == .cleanupRequired)
        #expect(rig.secrets.load() != nil)
        try await restarted.disableRememberedSignIn(expected: #require(restored.signIn?.fence))
        #expect(await restarted.state().signIn?.remembered == .disabled)
        #expect(rig.secrets.load() == nil)
    }

    @Test(arguments: [false, true])
    func `token failure remains diagnostic when its annotation cannot load or save`(loadFails: Bool) async throws {
        let rig = Rig()
        let metadata = UnavailableLoadStore(base: rig.metadata)
        let session = VikingSession(transport: rig.transport, store: rig.store, lease: rig.lease, cache: rig.cache,
                                    signInStore: metadata, rememberedStore: rig.secrets, now: { rig.clock.now() })
        if loadFails {
            await rig.transport.actBeforeResponse(path: "/mv/oauth2/token") { metadata.failLoad = true }
            await rig.transport.setResponse(path: "/mv/oauth2/token", json: #"{"error":"invalid_grant"}"#)
        } else {
            rig.metadata.failOnSave = 2
            await rig.transport.failNext(code: 503)
        }
        await #expect(throws: loadFails ? BootstrapFailure.tokenResponse : .tokenServer) {
            try await session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials)
        }
        metadata.failLoad = false
        #expect(try AccountSignInPersistence(key: .legacy, store: metadata,
                                             secrets: rig.secrets).load().attemptPending == true)
        #expect(rig.store.load() == nil)
        #expect(await rig.transport.paths() == ["/mv/oauth2/token"])
    }

    @Test func `stale mobile logout cannot cancel a blocked successor refresh`() async throws {
        let rig = Rig()
        let first = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials)
        rig.clock.advance(61)
        let replacement = try await rig.session.bootstrapWithDiagnostics(
            credentials: .init(clientID: "public", username: "replacement", password: "synthetic"),
            expected: first.signIn?.fence,
        )
        await rig.transport.pauseNext(path: "/mv/subscriptions")
        let refresh = Task { try await rig.session.refresh() }
        await rig.transport.waitUntilPaused()
        let generation = await rig.session.generation
        let finished = OSAllocatedUnfairLock(initialState: false)
        let logout = Task {
            defer { finished.withLock { $0 = true } }
            return try await rig.session.logout(expected: #require(first.signIn?.fence))
        }
        while await rig.session.generation == generation, !finished.withLock({ $0 }) {
            await Task.yield()
        }
        await rig.transport.resume()
        await #expect(throws: LiveFailure.connectionChanged) { try await logout.value }
        let refreshed = try await refresh.value
        #expect(refreshed.connectionID == replacement.connectionID)
        #expect(refreshed.connectionSummary?.username == "replacement")
        #expect(refreshed.snapshot.allowance == .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 75))
        #expect(refreshed.signIn?.fence == replacement.signIn?.fence)
    }

    @Test func `stale home logout cannot cancel a blocked successor refresh`() async throws {
        let rig = try HomeRig()
        await rig.transport.enableLogin()
        let account = rig.account()
        _ = try await account.connect(credentials: .telenet(.init(username: "reader", password: "synthetic")),
                                      rememberPassword: false, expected: nil)
        let first = await account.state()
        rig.clock.advance(61)
        await rig.transport.enableLogin()
        let connection = try await account.connect(
            credentials: .telenet(.init(username: "replacement", password: "synthetic")),
            rememberPassword: false, expected: first.signIn?.fence,
        )
        let replacement = await account.state()
        rig.clock.advance(61)
        await rig.transport.pauseDaily()
        let refresh = Task { try await account.perform(.refresh) }
        await rig.transport.waitUntilPaused()
        let generation = await account.generation
        let finished = OSAllocatedUnfairLock(initialState: false)
        let logout = Task {
            defer { finished.withLock { $0 = true } }
            try await account.logout(expected: #require(first.signIn?.fence))
        }
        while await account.generation == generation, !finished.withLock({ $0 }) {
            await Task.yield()
        }
        await rig.transport.resume()
        await #expect(throws: LiveFailure.connectionChanged) { try await logout.value }
        try await refresh.value
        let refreshed = await account.state()
        #expect(refreshed.connectionID == connection)
        #expect(refreshed.connectionSummary?.username == "replacement")
        #expect(refreshed.selectedHomeUsage?.downloaded?.totalGB == 60)
        #expect(refreshed.selectedHomeUsage?.fetchedAt == rig.clock.now)
        #expect(refreshed.signIn?.fence == replacement.signIn?.fence)
    }
}

private final class UnavailableLoadStore: SessionStore, Sendable {
    private let base: any SessionStore
    private let unavailable = OSAllocatedUnfairLock(initialState: false)

    init(base: any SessionStore) {
        self.base = base
    }

    var failLoad: Bool {
        get { self.unavailable.withLock { $0 } }
        set { self.unavailable.withLock { $0 = newValue } }
    }

    func load() throws -> Data? {
        guard !self.failLoad else { throw LiveFailure.storage }
        return try self.base.load()
    }

    func save(_ data: Data) throws {
        try self.base.save(data)
    }

    func delete() throws {
        try self.base.delete()
    }
}
