import Foundation
import os
import Testing
@testable import VikingBarCore

struct SignInReservationTests {
    @Test func `reserved mobile password honors provider backoff recorded before dispatch`() async throws {
        let rig = Rig()
        let connected = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                                       rememberPassword: true)
        let fence = try #require(connected.signIn?.fence)
        rig.clock.advance(61)
        let deadline = rig.clock.now().addingTimeInterval(7200)
        let lease = DispatchReservationLease(base: rig.lease) {
            let persistence = AccountSignInPersistence(key: .legacy, store: rig.metadata, secrets: rig.secrets)
            var record = try persistence.load()
            record.nextRenewalAt = deadline
            record.nextPasswordAttemptAt = deadline
            try persistence.save(record)
        }
        let delayed = VikingSession(transport: rig.transport, store: rig.store, lease: lease, cache: rig.cache,
                                    signInStore: rig.metadata, rememberedStore: rig.secrets, now: { rig.clock.now() })
        await #expect(throws: LiveFailure.rateLimited) { try await delayed.savedSignIn(expected: fence) }
        let restarted = try await rig.newSession().restore()
        #expect(restarted.connectionID == connected.connectionID)
        #expect(restarted.signIn?.nextPasswordAttemptAt == deadline)
        #expect(restarted.signIn?.attemptPending == true)
        #expect(await rig.transport.paths() == ["/mv/oauth2/token"])
    }

    @Test func `newer persisted mobile reservation stops delayed password dispatch`() async throws {
        let rig = Rig()
        let connected = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                                       rememberPassword: true)
        let fence = try #require(connected.signIn?.fence)
        rig.clock.advance(61)
        let lease = DispatchReservationLease(base: rig.lease) {
            rig.clock.advance(61)
            try rig.secrets.delete()
            let persistence = AccountSignInPersistence(key: .legacy, store: rig.metadata, secrets: rig.secrets)
            _ = try persistence.reservePasswordAttempt(expected: fence, now: rig.clock.now())
        }
        let delayed = VikingSession(transport: rig.transport, store: rig.store, lease: lease, cache: rig.cache,
                                    signInStore: rig.metadata, rememberedStore: rig.secrets, now: { rig.clock.now() })
        await #expect(throws: LiveFailure.connectionChanged) { try await delayed.savedSignIn(expected: fence) }
        let restarted = try await rig.newSession().restore()
        #expect(restarted.connectionID == connected.connectionID)
        #expect(restarted.signIn?.nextPasswordAttemptAt == rig.clock.now().addingTimeInterval(60))
        #expect(restarted.signIn?.attemptPending == true)
        #expect(await rig.transport.paths() == ["/mv/oauth2/token"])
    }

    @Test func `newer persisted home reservation stops delayed password dispatch`() async throws {
        let rig = try HomeRig()
        await rig.transport.enableLogin()
        let initial = rig.account()
        _ = try await initial.connect(credentials: .telenet(.init(username: "reader", password: "synthetic")),
                                      rememberPassword: true, expected: nil)
        let connected = await initial.state()
        let fence = try #require(connected.signIn?.fence)
        let requestCount = await rig.transport.requests.count
        rig.clock.advance(61)
        let lease = DispatchReservationLease(base: rig.lease) {
            rig.clock.advance(61)
            try rig.secrets.delete()
            let persistence = AccountSignInPersistence(key: rig.key, store: rig.metadata, secrets: rig.secrets)
            _ = try persistence.reservePasswordAttempt(expected: fence, now: rig.clock.now)
        }
        let delayed = TelenetHomeAccount(key: rig.key, transport: rig.transport, store: rig.store,
                                         lease: lease, cache: rig.cache, signInStore: rig.metadata,
                                         rememberedStore: rig.secrets, now: { rig.clock.now })
        await #expect(throws: LiveFailure.connectionChanged) { try await delayed.savedSignIn(expected: fence) }
        let restarted = rig.account()
        try await restarted.perform(.restore)
        let restored = await restarted.state()
        #expect(restored.connectionID == connected.connectionID)
        #expect(restored.signIn?.nextPasswordAttemptAt == rig.clock.now.addingTimeInterval(60))
        #expect(await rig.transport.requests.count == requestCount)
    }
}

private final class DispatchReservationLease: SessionLease, Sendable {
    private let base: any SessionLease
    private let count = OSAllocatedUnfairLock(initialState: 0)
    private let beforeDispatch: @Sendable () throws -> Void

    init(base: any SessionLease, beforeDispatch: @escaping @Sendable () throws -> Void) {
        self.base = base
        self.beforeDispatch = beforeDispatch
    }

    func acquire() throws -> any SessionLeaseHandle {
        let count = self.count.withLock { $0 += 1; return $0 }
        if count == 2 {
            try self.beforeDispatch()
        }
        return try self.base.acquire()
    }
}
