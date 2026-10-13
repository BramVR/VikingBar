import Foundation
import os
import Testing
@testable import VikingBarCore

extension SignInBoundaryFailureTests {
    @Test func `first mobile opt in keeps password cleanup durable when publication never recovers`() async throws {
        let rig = Rig()
        let metadata = RememberedPublicationFaultStore(base: rig.metadata, permanent: true)
        let secrets = SecretSaveCheckpointStore(base: rig.secrets, metadata: rig.metadata)
        rig.secrets.failDelete = true
        func session() -> VikingSession {
            VikingSession(transport: rig.transport, store: rig.store, lease: rig.lease, cache: rig.cache,
                          signInStore: metadata, rememberedStore: secrets, now: { rig.clock.now() })
        }
        let connected = try await session().bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                                     rememberPassword: true)
        #expect(connected.signIn?.remembered == .cleanupRequired)
        #expect(connected.signIn?.failure == .storage)
        let intent = try JSONDecoder().decode(AccountSignInRecord.self, from: #require(secrets.metadataAtSave))
        #expect(intent.remembered == .cleanupRequired)
        #expect(intent.credentialGeneration == nil)
        #expect(rig.secrets.load() != nil)
        #expect(try AccountSignInPersistence(key: .legacy, store: rig.metadata,
                                             secrets: rig.secrets).load().remembered == .cleanupRequired)
        let restored = try await session().restore()
        #expect(restored.connectionID == connected.connectionID)
        #expect(restored.connectionSummary?.username == "test-user")
        #expect(restored.signIn?.remembered == .cleanupRequired)
        metadata.allowWrites()
        rig.secrets.failDelete = false
        let cleaned = try await session().disableRememberedSignIn(expected: #require(restored.signIn?.fence))
        #expect(cleaned.signIn?.remembered == .disabled)
        #expect(rig.secrets.load() == nil)
        #expect(await rig.transport.paths() == ["/mv/oauth2/token"])
    }

    @Test func `first home opt in keeps password cleanup durable when publication never recovers`() async throws {
        let rig = try HomeRig()
        let metadata = RememberedPublicationFaultStore(base: rig.metadata, permanent: true)
        let secrets = SecretSaveCheckpointStore(base: rig.secrets, metadata: rig.metadata)
        rig.secrets.failDelete = true
        func account() -> TelenetHomeAccount {
            TelenetHomeAccount(key: rig.key, transport: rig.transport, store: rig.store, lease: rig.lease,
                               cache: rig.cache, signInStore: metadata, rememberedStore: secrets,
                               now: { rig.clock.now })
        }
        await rig.transport.enableLogin()
        let initial = account()
        let connection = try await initial.connect(
            credentials: .telenet(.init(username: "reader", password: "synthetic")),
            rememberPassword: true,
            expected: nil,
        )
        #expect(await initial.state().signIn?.remembered == .cleanupRequired)
        #expect(await initial.state().signIn?.failure == .storage)
        let intent = try JSONDecoder().decode(AccountSignInRecord.self, from: #require(secrets.metadataAtSave))
        #expect(intent.remembered == .cleanupRequired)
        #expect(intent.credentialGeneration == nil)
        #expect(rig.secrets.load() != nil)
        #expect(try AccountSignInPersistence(key: rig.key, store: rig.metadata,
                                             secrets: rig.secrets).load().remembered == .cleanupRequired)
        let requests = await rig.transport.requests.count
        let restarted = account()
        try await restarted.perform(.restore)
        let restored = await restarted.state()
        #expect(restored.connectionID == connection)
        #expect(restored.connectionSummary?.username == "reader")
        #expect(restored.signIn?.remembered == .cleanupRequired)
        metadata.allowWrites()
        rig.secrets.failDelete = false
        try await restarted.disableRememberedSignIn(expected: #require(restored.signIn?.fence))
        #expect(await restarted.state().signIn?.remembered == .disabled)
        #expect(rig.secrets.load() == nil)
        #expect(await rig.transport.requests.count == requests)
    }
}

private final class SecretSaveCheckpointStore: SessionStore, Sendable {
    private let base: MemorySessionStore
    private let metadata: MemorySessionStore
    private let checkpoint = OSAllocatedUnfairLock<Data?>(initialState: nil)

    init(base: MemorySessionStore, metadata: MemorySessionStore) {
        self.base = base
        self.metadata = metadata
    }

    var metadataAtSave: Data? {
        self.checkpoint.withLock { $0 }
    }

    func load() -> Data? {
        self.base.load()
    }

    func save(_ data: Data) throws {
        self.checkpoint.withLock { $0 = self.metadata.load() }
        try self.base.save(data)
    }

    func delete() throws {
        try self.base.delete()
    }
}

final class RememberedPublicationFaultStore: SessionStore, Sendable {
    private struct Failure {
        var publication = true
        var allWrites = false
    }

    private let base: MemorySessionStore
    private let permanent: Bool
    private let failure = OSAllocatedUnfairLock(initialState: Failure())

    init(base: MemorySessionStore, permanent: Bool = false) {
        self.base = base
        self.permanent = permanent
    }

    func allowWrites() {
        self.failure.withLock { $0 = Failure(publication: false, allWrites: false) }
    }

    func load() -> Data? {
        self.base.load()
    }

    func delete() throws {
        try self.base.delete()
    }

    func save(_ data: Data) throws {
        let record = try JSONDecoder().decode(AccountSignInRecord.self, from: data)
        try self.failure.withLock { failure in
            if failure.publication, record.remembered == .available {
                failure.publication = false
                failure.allWrites = self.permanent
                throw LiveFailure.storage
            }
            guard !failure.allWrites else { throw LiveFailure.storage }
            try self.base.save(data)
        }
    }
}
