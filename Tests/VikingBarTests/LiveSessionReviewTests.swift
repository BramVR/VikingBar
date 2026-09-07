import Foundation
import Testing
@testable import VikingBarCore

struct LiveSessionReviewTests {
    @Test func `superseded fetch cannot publish old account or overwrite new connection cache`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        _ = try await rig.session.refresh()
        await rig.transport.pauseNext(path: "/mv/subscriptions/sim-a/balance")
        let old = Task { try await rig.session.refresh() }
        await rig.transport.waitUntilPaused()
        let newer = rig.newSession()
        _ = try await newer.bootstrap(credentials: LiveSessionTests.credentials)
        let fresh = try await newer.refresh()
        await rig.transport.resume()
        await #expect(throws: LiveFailure.connectionChanged) { try await old.value }
        let superseded = await rig.session.state()
        #expect(superseded.connectionID == fresh.connectionID)
        #expect(superseded.snapshot.allowance == .unavailable)
        let restored = try await rig.newSession().restore()
        #expect(restored.connectionID == fresh.connectionID)
        #expect(restored.snapshot == fresh.snapshot)
        #expect(restored.failure == nil)
    }

    @Test func `old account failure cannot replace a newer connection cache`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        _ = try await rig.session.refresh()
        await rig.transport.pauseNext(path: "/mv/subscriptions/sim-a/balance")
        let old = Task { try await rig.session.refresh() }
        await rig.transport.waitUntilPaused()
        let newer = rig.newSession()
        _ = try await newer.bootstrap(credentials: LiveSessionTests.credentials)
        let fresh = try await newer.refresh()
        await rig.transport.failNext(code: 503)
        await rig.transport.resume()
        await #expect(throws: LiveFailure.serverUnavailable) { try await old.value }
        let restored = try await rig.newSession().restore()
        #expect(restored.connectionID == fresh.connectionID)
        #expect(restored.snapshot == fresh.snapshot)
        #expect(restored.failure == nil)
    }

    @Test func `known refresh failures remain stale with diagnostics after process restart`() async throws {
        for (code, failure) in [(429, LiveFailure.rateLimited), (503, .serverUnavailable), (401, .unauthorized)] {
            let rig = Rig()
            _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
            let fresh = try await rig.session.refresh()
            await rig.transport.failNext(code: code)
            await #expect(throws: failure) { try await rig.session.refresh() }
            let restored = try await rig.newSession().restore()
            #expect(restored.snapshot.allowance == fresh.snapshot.allowance)
            #expect(restored.snapshot.freshness == .stale(lastUpdated: LiveModelsTests.now))
            #expect(restored.failure == failure)
            #expect(restored.snapshot.errorMessage == failure.message)
        }
    }

    @Test func `local token expiration between subscription and balance requests renews once`() async throws {
        let clock = LiveTestClock()
        let rig = Rig(now: { clock.now() })
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        await rig.transport.actBeforeResponse(path: "/mv/subscriptions") { clock.advance(600) }
        let result = try await rig.session.refresh()
        #expect(result.snapshot.allowance == .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 75))
        #expect(await rig.transport.refreshInputs() == ["refresh-1"])
        #expect(result.failure == nil)
    }

    @Test func `repeated local expiration has one renewal bound and remains recoverable`() async throws {
        let clock = LiveTestClock()
        let rig = Rig(now: { clock.now() })
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        await rig.transport.actBeforeResponse(path: "/mv/subscriptions", count: 2) { clock.advance(600) }
        await #expect(throws: LiveFailure.tokenExpired) { try await rig.session.refresh() }
        #expect(await rig.transport.refreshInputs() == ["refresh-1"])
        let recovered = try await rig.session.refresh()
        #expect(recovered.failure == nil)
        #expect(await rig.transport.refreshInputs() == ["refresh-1", "refresh-2"])
    }

    @Test func `revoked authorization remains reconnect required after cache restore`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        _ = try await rig.session.refresh()
        await rig.transport.failNext(code: 401)
        await #expect(throws: LiveFailure.unauthorized) { try await rig.session.refresh() }
        let restarted = rig.newSession()
        _ = try await restarted.restore()
        await #expect(throws: LiveFailure.reconnectRequired) { try await restarted.refresh() }
        #expect(await rig.transport.refreshInputs().isEmpty)
    }

    @Test func `requested subscription is selected before any balance request`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        await rig.transport.setResponse(path: "/mv/subscriptions/sim-a/balance", json: "malformed unrelated balance")
        let requested = try await rig.session.refresh(subscriptionID: "sim-b")
        #expect(requested.selectedSubscriptionID == "sim-b")
        #expect(requested.snapshot.subscriptionName == "Second")
        #expect(await !rig.transport.paths().contains("/mv/subscriptions/sim-a/balance"))
        #expect(await rig.transport.paths().contains("/mv/subscriptions/sim-b/balance"))
    }

    @Test func `unknown requested subscription does not fetch a default balance`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        await #expect(throws: LiveFailure.invalidSelection) {
            try await rig.session.refresh(subscriptionID: "unknown-sim")
        }
        #expect(await !rig.transport.paths().contains(where: { $0.hasSuffix("/balance") }))
    }

    @Test func `selected bundle expiry updates success timing but preserves failure backoff`() async throws {
        for failureCode in [0, 429, 401] {
            let rig = Rig()
            _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
            let expires = LiveModelsTests.now.addingTimeInterval(60)
            let early = LiveModelsTests.bundle()
                .replacingOccurrences(of: "2027-01-01T00:00:00Z", with: ISO8601DateFormatter().string(from: expires))
            let json = "{\"bundles\":[\(LiveModelsTests.bundle()),\(early)]}"
            await rig.transport.setResponse(path: "/mv/subscriptions/sim-a/balance", json: json)
            let fresh = try await rig.session.refresh()
            #expect(fresh.nextRefreshAt == LiveModelsTests.now.addingTimeInterval(300))
            if failureCode != 0 {
                await rig.transport.failNext(code: failureCode)
                _ = try? await rig.session.refresh()
            }
            let before = await rig.session.state()
            let selected = try await rig.session.selectBundle(index: 1)
            #expect(selected.nextRefreshAt == (failureCode == 0 ? expires : before.nextRefreshAt))
        }
    }

    @Test func `bundle expiry invalidates recent cache and bounds next refresh`() async throws {
        let clock = LiveTestClock()
        let rig = Rig(now: { clock.now() })
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        let expires = clock.now().addingTimeInterval(60)
        let dateText = ISO8601DateFormatter().string(from: expires)
        let bundle = LiveModelsTests.bundle().replacingOccurrences(of: "2027-01-01T00:00:00Z", with: dateText)
        await rig.transport.setResponse(path: "/mv/subscriptions/sim-a/balance", json: "{\"bundles\":[\(bundle)]}")
        let fresh = try await rig.session.refresh()
        #expect(fresh.nextRefreshAt == expires)
        let recent = try await rig.newSession().restore()
        #expect(recent.nextRefreshAt == expires)
        clock.advance(61)
        let expired = try await rig.newSession().restore()
        #expect(expired.snapshot.allowance == .unavailable)
        #expect(expired.snapshot.freshness == .stale(lastUpdated: LiveModelsTests.now))
        #expect(expired.nextRefreshAt == clock.now())
    }
}

final class LiveTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = LiveModelsTests.now

    func now() -> Date {
        self.lock.withLock { self.date }
    }

    func advance(_ seconds: TimeInterval) {
        self.lock.withLock { self.date.addTimeInterval(seconds) }
    }
}
