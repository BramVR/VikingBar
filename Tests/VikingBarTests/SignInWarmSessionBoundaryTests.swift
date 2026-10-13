import Foundation
import os
import Testing
@testable import VikingBarCore

struct SignInWarmSessionBoundaryTests {
    @Test(arguments: WarmSessionLoss.allCases, [false, true])
    func `mobile successor setup clears prior usage when its session cannot load`(
        loss: WarmSessionLoss, restoring: Bool,
    ) async throws {
        let rig = Rig()
        let store = WarmSessionStore(base: rig.store)
        let session = VikingSession(transport: rig.transport, store: store, lease: rig.lease, cache: rig.cache,
                                    signInStore: rig.metadata, rememberedStore: rig.secrets,
                                    now: { rig.clock.now() })
        _ = try await session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials)
        let prior = try await session.refresh()
        #expect(prior.snapshot.allowance == .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 75))
        let persistence = AccountSignInPersistence(key: .legacy, store: rig.metadata, secrets: rig.secrets)
        let handle = try rig.lease.acquire()
        let successor = try persistence.accept(setup: .init(clientID: "public", username: "successor"),
                                               connection: ConnectionID(), expected: nil)
        try persistence.save(successor)
        handle.release()
        store.loss = loss
        var failure: LiveFailure?
        do {
            if restoring {
                _ = try await session.restore()
            } else {
                _ = try await session.refresh()
            }
        } catch {
            failure = try #require(error as? LiveFailure)
        }
        #expect(failure == loss.failure(restoring: restoring))
        let result = await session.state()
        #expect(result.connectionSummary == .init(clientID: "public", username: "successor"))
        #expect(result.signIn?.fence == successor.fence)
        #expect(result.connectionID == nil)
        #expect(result.snapshot.allowance == .unavailable)
        #expect(result.subscriptions.isEmpty)
        #expect(await session.token == nil)
        #expect(await rig.transport.paths() == ["/mv/oauth2/token", "/mv/subscriptions",
                                                "/mv/subscriptions/sim-a/balance"])
    }

    @Test(arguments: WarmSessionLoss.allCases, [false, true])
    func `home successor setup clears prior usage when its session cannot load`(
        loss: WarmSessionLoss, restoring: Bool,
    ) async throws {
        let rig = try HomeRig()
        let store = WarmSessionStore(base: rig.store)
        let account = TelenetHomeAccount(key: rig.key, transport: rig.transport, store: store, lease: rig.lease,
                                         cache: rig.cache, signInStore: rig.metadata, rememberedStore: rig.secrets,
                                         now: { rig.clock.now })
        await rig.transport.enableLogin()
        _ = try await account.connect(credentials: .telenet(.init(username: "reader", password: "synthetic")),
                                      rememberPassword: false, expected: nil)
        let prior = await account.state()
        #expect(prior.selectedHomeUsage?.downloaded?.totalGB == 60)
        let requests = await rig.transport.requests.count
        let persistence = AccountSignInPersistence(key: rig.key, store: rig.metadata, secrets: rig.secrets)
        let handle = try rig.lease.acquire()
        let successor = try persistence.accept(setup: .init(clientID: "", username: "successor"),
                                               connection: ConnectionID(), expected: nil)
        try persistence.save(successor)
        handle.release()
        store.loss = loss
        var failure: LiveFailure?
        do {
            try await account.perform(restoring ? .restore : .refresh)
        } catch {
            failure = try #require(error as? LiveFailure)
        }
        #expect(failure == loss.failure(restoring: restoring))
        let result = await account.state()
        #expect(result.connectionSummary == .init(clientID: "", username: "successor"))
        #expect(result.signIn?.fence == successor.fence)
        #expect(result.connectionID == nil)
        #expect(result.snapshot.allowance == .unavailable)
        #expect(result.selectedHomeUsage == nil)
        #expect(result.account?.services.isEmpty == true)
        #expect(await rig.transport.requests.count == requests)
    }
}

enum WarmSessionLoss: CaseIterable, Sendable {
    case missing, malformed, inaccessible

    func failure(restoring: Bool) -> LiveFailure? {
        switch self {
        case .missing: restoring ? nil : .notConnected
        case .malformed: .reconnectRequired
        case .inaccessible: .storage
        }
    }
}

private final class WarmSessionStore: SessionStore, Sendable {
    private let base: any SessionStore
    private let lost = OSAllocatedUnfairLock<WarmSessionLoss?>(initialState: nil)

    init(base: any SessionStore) {
        self.base = base
    }

    var loss: WarmSessionLoss? {
        get { self.lost.withLock { $0 } }
        set { self.lost.withLock { $0 = newValue } }
    }

    func load() throws -> Data? {
        switch self.loss {
        case .missing: return nil
        case .malformed: return Data("malformed".utf8)
        case .inaccessible: throw LiveFailure.storage
        case nil: return try self.base.load()
        }
    }

    func save(_ data: Data) throws {
        try self.base.save(data)
    }

    func delete() throws {
        try self.base.delete()
    }
}
