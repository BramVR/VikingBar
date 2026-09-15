import Foundation
import Testing
@testable import VikingBarCore

struct RefreshIntervalTests {
    @Test func `configured interval controls publish restore and selection deadlines`() async throws {
        let rig = Rig()
        _ = await rig.session.configure(refreshInterval: .fifteenMinutes)
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        let good = try await rig.session.refresh()
        let expected = min(LiveModelsTests.now.addingTimeInterval(900), good.snapshot.expiresAt ?? .distantFuture)
        #expect(good.nextRefreshAt == expected)
        #expect(try await rig.session.selectBundle(index: 0).nextRefreshAt == expected)
        let restarted = rig.newSession()
        _ = await restarted.configure(refreshInterval: .fifteenMinutes)
        #expect(try await restarted.restore().nextRefreshAt == expected)
    }

    @Test func `interval changes preserve failure retry and next success uses new interval`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        _ = try await rig.session.refresh()
        await rig.transport.failNext(code: 429)
        await #expect(throws: LiveFailure.rateLimited) { try await rig.session.refresh() }
        let failed = await rig.session.state()
        let configured = await rig.session.configure(refreshInterval: .oneHour)
        #expect(configured.nextRefreshAt == failed.nextRefreshAt)
        #expect(configured.failure == .rateLimited)
        let good = try await rig.session.refresh()
        #expect(good.nextRefreshAt == min(LiveModelsTests.now.addingTimeInterval(3600),
                                          good.snapshot.expiresAt ?? .distantFuture))
    }

    @Test func `success deadline clamps to selected expiry across restore and selection`() async throws {
        let rig = Rig()
        let expiry = LiveModelsTests.now.addingTimeInterval(20)
        let bundle = LiveModelsTests.bundle().replacingOccurrences(
            of: "2027-01-01T00:00:00Z", with: ISO8601DateFormatter().string(from: expiry),
        )
        await rig.transport.setResponse(path: "/mv/subscriptions/sim-a/balance", json: "{\"bundles\":[\(bundle)]}")
        _ = await rig.session.configure(refreshInterval: .oneHour)
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        #expect(try await rig.session.refresh().nextRefreshAt == expiry)
        #expect(try await rig.session.selectBundle(index: 0).nextRefreshAt == expiry)
        let restarted = rig.newSession()
        _ = await restarted.configure(refreshInterval: .oneHour)
        #expect(try await restarted.restore().nextRefreshAt == expiry)
    }

    @Test func `inflight token rotation completes with latest interval`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        await rig.transport.pauseNext()
        let refresh = Task { try await rig.session.refresh(forceTokenRefresh: true) }
        await rig.transport.waitUntilPaused()
        _ = await rig.session.configure(refreshInterval: .thirtyMinutes)
        await rig.transport.resume()
        let state = try await refresh.value
        #expect(state.nextRefreshAt == LiveModelsTests.now.addingTimeInterval(1800))
        #expect(rig.store.saveCount == 3)
        #expect(await rig.transport.refreshInputs() == ["refresh-1"])
    }

    @Test func `selected SIM restores within connection and does not enter a new connection`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        _ = try await rig.session.refresh()
        _ = try await rig.session.selectSubscription(id: "sim-b")
        let restarted = rig.newSession()
        #expect(try await restarted.restore().selectedSubscriptionID == "sim-b")
        #expect(try await restarted.refresh().selectedSubscriptionID == "sim-b")
        _ = try await restarted.bootstrap(credentials: LiveSessionTests.credentials)
        let fresh = try await rig.newSession().restore()
        #expect(fresh.selectedSubscriptionID == nil)
        #expect(fresh.balance == nil)
    }
}
