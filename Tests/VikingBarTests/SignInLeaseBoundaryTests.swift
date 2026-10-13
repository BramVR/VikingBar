import Foundation
import os
import Testing
@testable import VikingBarCore

struct SignInLeaseBoundaryTests {
    @Test(arguments: [false, true])
    func `mobile password removal cannot mix a successor fence with prior usage`(alreadyReplaced: Bool) async throws {
        let rig = Rig()
        let lease = ReplacementOnReleaseLease()
        let session = VikingSession(transport: rig.transport, store: rig.store, lease: lease, cache: rig.cache,
                                    signInStore: rig.metadata, rememberedStore: rig.secrets,
                                    now: { rig.clock.now() })
        _ = try await session.bootstrapWithDiagnostics(
            credentials: LiveSessionTests.credentials,
            rememberPassword: true,
        )
        let prior = try await session.refresh()
        let fence = try #require(prior.signIn?.fence)
        let successor = ConnectionID()
        let persistence = AccountSignInPersistence(key: .legacy, store: rig.metadata, secrets: rig.secrets)
        let replace: @Sendable () throws -> Void = {
            let handle = try lease.acquire()
            defer { handle.release() }
            let record = try persistence.accept(setup: .init(clientID: "public", username: "successor"),
                                                connection: successor, expected: nil)
            try persistence.save(record)
        }
        if alreadyReplaced {
            try replace()
            await #expect(throws: LiveFailure.connectionChanged) {
                try await session.disableRememberedSignIn(expected: fence)
            }
        } else {
            lease.onRelease(replace)
            _ = try await session.disableRememberedSignIn(expected: fence)
        }
        let result = await session.state()
        #expect(try persistence.load().summary?.username == "successor")
        if alreadyReplaced {
            #expect(result.connectionID == successor)
            #expect(result.signIn?.fence.connectionID == successor)
            #expect(result.connectionSummary?.username == "successor")
            #expect(result.snapshot.allowance == .unavailable)
        } else {
            #expect(result.connectionID == prior.connectionID)
            #expect(result.signIn?.fence.connectionID == prior.connectionID)
            #expect(result.connectionSummary?.username == "test-user")
            #expect(result.snapshot.allowance == .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 75))
        }
        #expect(await rig.transport.paths() == ["/mv/oauth2/token", "/mv/subscriptions",
                                                "/mv/subscriptions/sim-a/balance"])
    }

    @Test(arguments: [false, true])
    func `home password removal cannot mix a successor fence with prior usage`(alreadyReplaced: Bool) async throws {
        let rig = try HomeRig()
        let lease = ReplacementOnReleaseLease()
        let account = TelenetHomeAccount(key: rig.key, transport: rig.transport, store: rig.store, lease: lease,
                                         cache: rig.cache, signInStore: rig.metadata, rememberedStore: rig.secrets,
                                         now: { rig.clock.now })
        await rig.transport.enableLogin()
        _ = try await account.connect(credentials: .telenet(.init(username: "reader", password: "synthetic")),
                                      rememberPassword: true, expected: nil)
        let prior = await account.state()
        let requests = await rig.transport.requests.count
        let fence = try #require(prior.signIn?.fence)
        let successor = ConnectionID()
        let persistence = AccountSignInPersistence(key: rig.key, store: rig.metadata, secrets: rig.secrets)
        let replace: @Sendable () throws -> Void = {
            let handle = try lease.acquire()
            defer { handle.release() }
            let record = try persistence.accept(setup: .init(clientID: "", username: "successor"),
                                                connection: successor, expected: nil)
            try persistence.save(record)
        }
        if alreadyReplaced {
            try replace()
            await #expect(throws: LiveFailure.connectionChanged) {
                try await account.disableRememberedSignIn(expected: fence)
            }
        } else {
            lease.onRelease(replace)
            try await account.disableRememberedSignIn(expected: fence)
        }
        let result = await account.state()
        #expect(try persistence.load().summary?.username == "successor")
        if alreadyReplaced {
            #expect(result.connectionID == successor)
            #expect(result.signIn?.fence.connectionID == successor)
            #expect(result.connectionSummary?.username == "successor")
            #expect(result.selectedHomeUsage == nil)
        } else {
            #expect(result.connectionID == prior.connectionID)
            #expect(result.signIn?.fence.connectionID == prior.connectionID)
            #expect(result.connectionSummary?.username == "reader")
            #expect(result.selectedHomeUsage?.downloaded?.totalGB == 60)
        }
        #expect(await rig.transport.requests.count == requests)
    }
}

private final class ReplacementOnReleaseLease: SessionLease, SessionLeaseHandle, Sendable {
    private let base = MemoryLease()
    private let action = OSAllocatedUnfairLock<(@Sendable () throws -> Void)?>(initialState: nil)

    func onRelease(_ action: @escaping @Sendable () throws -> Void) {
        self.action.withLock { $0 = action }
    }

    func acquire() throws -> any SessionLeaseHandle {
        _ = try self.base.acquire()
        return self
    }

    func release() {
        self.base.release()
        let action = self.action.withLock { action in
            let result = action
            action = nil
            return result
        }
        do { try action?() } catch { Issue.record(error) }
    }
}
