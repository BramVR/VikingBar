import Foundation
import Testing
@testable import VikingBarCore

struct LiveSessionIsolationTests {
    @Test func `bundle selection survives provider reordering by unique metadata`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        let first = LiveModelsTests.bundle()
        let second = LiveModelsTests.bundle(total: "50", used: "10", remaining: "40")
            .replacingOccurrences(of: "\"Data\"", with: "\"Bonus\"")
        await rig.transport.setResponse(
            path: "/mv/subscriptions/sim-a/balance",
            json: "{\"bundles\":[\(first),\(second)]}",
        )
        _ = try await rig.session.refresh()
        _ = try await rig.session.selectBundle(index: 1)
        await rig.transport.setResponse(
            path: "/mv/subscriptions/sim-a/balance",
            json: "{\"bundles\":[\(second),\(first)]}",
        )
        let state = try await rig.session.refresh()
        #expect(state.selectedBundleIndex == 0)
        #expect(state.snapshot.allowance == .finite(totalBytes: 50, usedBytes: 10, remainingBytes: 40))
    }

    @Test func `removed SIM followed by balance error cannot retain old identity`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        _ = try await rig.session.refresh()
        await rig.transport.setResponse(path: "/mv/subscriptions", json: """
        [{"id":"sim-b","type":"prepaid","sim":{"alias":"Second"}}]
        """)
        await rig.transport.failBalance(code: 503)
        await #expect(throws: LiveFailure.serverUnavailable) { try await rig.session.refresh() }
        let state = await rig.session.state()
        #expect(state.selectedSubscriptionID == "sim-b")
        #expect(state.snapshot.subscriptionName == "Second")
        #expect(state.snapshot.allowance == .unavailable)
        #expect(state.balance == nil)
    }

    @Test func `another process rotation invalidates in memory token generation`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        let other = rig.newSession()
        _ = try await other.restore()
        _ = try await other.refresh()
        _ = try await rig.session.refresh()
        #expect(await rig.transport.refreshInputs() == ["refresh-1", "refresh-2"])
    }

    @Test func `another process cannot read or rotate while token exchange holds lease`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        await rig.transport.pauseNext()
        let operation = Task { try await rig.session.refresh(forceTokenRefresh: true) }
        await rig.transport.waitUntilPaused()
        let other = rig.newSession()
        await #expect(throws: LiveFailure.busy) { try await other.restore() }
        await #expect(throws: LiveFailure.busy) { try await other.refresh() }
        await rig.transport.resume()
        _ = try await operation.value
        #expect(await rig.transport.refreshInputs() == ["refresh-1"])
    }

    @Test func `cache freshness expires without an API call`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        _ = try await rig.session.refresh()
        let afterExpiry = VikingSession(
            transport: rig.transport, store: rig.store, lease: rig.lease, cache: rig.cache,
            now: { LiveModelsTests.now.addingTimeInterval(301) },
        )
        let calls = await rig.transport.paths().count
        let state = try await afterExpiry.restore()
        #expect(state.snapshot.freshness == .stale(lastUpdated: LiveModelsTests.now))
        #expect(await rig.transport.paths().count == calls)
    }

    @Test func `file cache stores only same connection with private permissions`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        let state = try await rig.session.refresh()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cache.json")
        let cache = FileBalanceCache(url: url)
        try cache.save(state)
        var cachedState = state
        cachedState.connectionSummary = nil
        #expect(try cache.load(connectionID: #require(state.connectionID)) == cachedState)
        #expect(try cache.load(connectionID: ConnectionID()) == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let stored = try String(contentsOf: url, encoding: .utf8)
        #expect(!stored.contains("refresh_token"))
        #expect(!stored.contains("test-password"))
    }

    @Test func `no active data bundles stays unavailable after successful response`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        await rig.transport.setResponse(path: "/mv/subscriptions/sim-a/balance", json: "{\"bundles\":[]}")
        let state = try await rig.session.refresh()
        #expect(state.snapshot.allowance == .unavailable)
        #expect(state.selectedBundleIndex == nil)
        #expect(state.snapshot.freshness == .current(lastUpdated: LiveModelsTests.now))
    }
}
