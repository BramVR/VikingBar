import Foundation
import Testing
@testable import VikingBarCore

struct LiveSessionCacheFailureTests {
    @Test func `pending rotation restores last success while requiring reconnect`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        let successful = try await rig.session.refresh()
        await rig.transport.failNext(code: 503)
        await #expect(throws: LiveFailure.reconnectRequired) {
            try await rig.session.refresh(forceTokenRefresh: true)
        }
        let restarted = rig.newSession()
        await #expect(throws: LiveFailure.reconnectRequired) { try await restarted.restore() }
        let restored = await restarted.state()
        #expect(restored.snapshot.allowance == successful.snapshot.allowance)
        #expect(restored.failure == .reconnectRequired)
        #expect(restored.nextRefreshAt == nil)
        #expect(restored.snapshot.freshness == .stale(lastUpdated: LiveModelsTests.now))
    }

    @Test func `failed refresh invalidates expired finite and unlimited bundles without losing diagnostics`(
    ) async throws {
        for total in ["100", "-1"] {
            let clock = LiveTestClock()
            let rig = Rig(now: { clock.now() })
            _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
            let expiry = ISO8601DateFormatter().string(from: clock.now().addingTimeInterval(60))
            let bundle = LiveModelsTests.bundle(total: total)
                .replacingOccurrences(of: "2027-01-01T00:00:00Z", with: expiry)
            await rig.transport.setResponse(path: "/mv/subscriptions/sim-a/balance", json: "{\"bundles\":[\(bundle)]}")
            _ = try await rig.session.refresh()
            clock.advance(61)
            await rig.transport.failBalance(code: 503)
            await #expect(throws: LiveFailure.serverUnavailable) { try await rig.session.refresh() }
            let failed = await rig.session.state()
            #expect(failed.snapshot.allowance == .unavailable)
            #expect(failed.snapshot.freshness == .stale(lastUpdated: LiveModelsTests.now))
            #expect(failed.failure == .serverUnavailable)
            #expect(failed.snapshot.errorMessage == LiveFailure.serverUnavailable.message)
            #expect(failed.nextRefreshAt == clock.now().addingTimeInterval(30))
            #expect(failed.balance?.bundles[0].total == Decimal(string: total))
            let restored = try await rig.newSession().restore()
            #expect(restored.snapshot == failed.snapshot)
            #expect(restored.nextRefreshAt == failed.nextRefreshAt)
        }
    }

    @Test func `first subscription request failure restores its diagnostic and retry deadline`() async throws {
        let clock = LiveTestClock()
        let rig = Rig(now: { clock.now() })
        let connected = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        await rig.transport.failNext(code: 503)
        await #expect(throws: LiveFailure.serverUnavailable) { try await rig.session.refresh() }
        let failed = await rig.session.state()
        #expect(failed.selectedSubscriptionID == nil)
        #expect(failed.balance == nil)
        clock.advance(10)
        let restored = try await rig.newSession().restore()
        #expect(restored.connectionID == connected.connectionID)
        #expect(restored.failure == .serverUnavailable)
        #expect(restored.snapshot == failed.snapshot)
        #expect(restored.nextRefreshAt == failed.nextRefreshAt)
        #expect(restored.selectedSubscriptionID == nil)
        #expect(restored.balance == nil)
    }

    @Test func `unselected failure cache rejects balances and allowance figures from unrelated SIMs`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        await rig.transport.failNext(code: 503)
        _ = try? await rig.session.refresh()
        let failed = await rig.session.state()
        let connectionID = try #require(failed.connectionID)
        #expect(failed.canRestore(connectionID: connectionID))
        #expect(!failed.canRestore(connectionID: ConnectionID()))
        var withBalance = failed
        withBalance.balance = try LiveAPI.decodeBalance(Data("{\"bundles\":[\(LiveModelsTests.bundle())]}".utf8))
        #expect(!withBalance.canRestore(connectionID: connectionID))
        var withAllowance = failed
        withAllowance.snapshot = UsageSnapshot(
            source: .live, subscriptionName: "Other SIM", allowance: .unlimited(usedBytes: 1), expiresAt: nil,
            freshness: .unavailable, errorMessage: LiveFailure.serverUnavailable.message,
        )
        #expect(!withAllowance.canRestore(connectionID: connectionID))
        var withSelection = failed
        withSelection.selectedBundleIndex = 0
        #expect(!withSelection.canRestore(connectionID: connectionID))
        var withoutFailure = failed
        withoutFailure.failure = nil
        #expect(!withoutFailure.canRestore(connectionID: connectionID))
    }

    @Test func `restore preserves capped pending already due and terminal retry deadlines`() async throws {
        for failureCode in [503, 401] {
            let clock = LiveTestClock()
            let rig = Rig(now: { clock.now() })
            _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
            _ = try await rig.session.refresh()
            for _ in 0 ..< (failureCode == 503 ? 7 : 1) {
                await rig.transport.failNext(code: failureCode)
                _ = try? await rig.session.refresh()
            }
            let failed = await rig.session.state()
            let expected = failureCode == 503 ? clock.now().addingTimeInterval(1800) : nil
            #expect(failed.nextRefreshAt == expected)
            let requests = await rig.transport.paths().count
            clock.advance(10)
            let pending = try await rig.newSession().restore()
            #expect(pending.nextRefreshAt == expected)
            #expect(pending.failure == failed.failure)
            clock.advance(1800)
            let due = try await rig.newSession().restore()
            #expect(due.nextRefreshAt == expected)
            #expect(due.failure == failed.failure)
            #expect(await rig.transport.paths().count == requests)
        }
    }
}
