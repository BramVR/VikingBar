import Foundation
import Testing
@testable import VikingBarCore

struct LiveSessionTests {
    @Test func `data access rejection renews once while permission denial does not renew`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: Self.credentials)
        await rig.transport.failNext(code: 401)
        let recovered = try await rig.session.refresh()
        #expect(recovered.snapshot.allowance == .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 75))
        #expect(await rig.transport.refreshInputs() == ["refresh-1"])
        await rig.transport.failNext(code: 403)
        await #expect(throws: LiveFailure.permissionDenied) { try await rig.session.refresh() }
        #expect(await rig.transport.refreshInputs() == ["refresh-1"])
    }

    @Test func `bootstrap persists only token and refresh shares one operation`() async throws {
        let rig = Rig()
        let connected = try await rig.session.bootstrap(credentials: Self.credentials)
        #expect(connected.connectionID != nil)
        #expect(await rig.transport.paths() == ["/mv/oauth2/token"])
        await rig.transport.pauseNext()
        let first = Task { try await rig.session.refresh() }
        await rig.transport.waitUntilPaused()
        let second = Task { try await rig.session.refresh() }
        await rig.transport.resume()
        let values = try await [first.value, second.value]
        #expect(values.allSatisfy { !$0.isRefreshing })
        #expect(values.allSatisfy { $0.snapshot.allowance == .finite(
            totalBytes: 100, usedBytes: 25, remainingBytes: 75,
        ) })
        #expect(await rig.transport.paths().count == 3)
        #expect(rig.store.saveCount == 1)
    }

    @Test func `rotated token saves before balance and relaunch uses replacement`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: Self.credentials)
        _ = try await rig.session.refresh(forceTokenRefresh: true)
        #expect(rig.store.saveCount == 3)
        let record = try #require(rig.store.load())
        let recordText = try #require(String(bytes: record, encoding: .utf8))
        #expect(recordText.contains("refresh-2"))
        let relaunched = rig.newSession()
        let restored = try await relaunched.restore()
        #expect(restored.balance != nil)
        #expect(restored.snapshot.freshness == .current(lastUpdated: LiveModelsTests.now))
        _ = try await relaunched.refresh()
        #expect(await rig.transport.refreshInputs() == ["refresh-1", "refresh-2"])
    }

    @Test func `failed replacement save leaves marker and prevents further token requests`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: Self.credentials)
        rig.store.failOnSave = 3
        await #expect(throws: LiveFailure.reconnectRequired) { try await rig.session.refresh(forceTokenRefresh: true) }
        let calls = await rig.transport.paths().count
        let relaunched = rig.newSession()
        await #expect(throws: LiveFailure.reconnectRequired) { try await relaunched.restore() }
        await #expect(throws: LiveFailure.reconnectRequired) { try await rig.session.refresh() }
        #expect(await rig.transport.paths().count == calls)
    }

    @Test func `failed pending save does not spend refresh token`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: Self.credentials)
        rig.store.failOnSave = 2
        await #expect(throws: LiveFailure.storage) { try await rig.session.refresh(forceTokenRefresh: true) }
        #expect(await rig.transport.paths().count == 1)
    }

    @Test func `ambiguous refresh outcome persists reconnect requirement across restart`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: Self.credentials)
        await rig.transport.failNext(code: 503)
        await #expect(throws: LiveFailure.reconnectRequired) { try await rig.session.refresh(forceTokenRefresh: true) }
        let relaunched = rig.newSession()
        await #expect(throws: LiveFailure.reconnectRequired) { try await relaunched.restore() }
        #expect(await rig.transport.paths().count == 2)
    }

    @Test func `balance failure retains successful values with backoff`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: Self.credentials)
        let good = try await rig.session.refresh()
        await rig.transport.failNext(code: 429)
        await #expect(throws: LiveFailure.rateLimited) { try await rig.session.refresh() }
        let failed = await rig.session.state()
        #expect(failed.snapshot.allowance == good.snapshot.allowance)
        #expect(failed.nextRefreshAt == LiveModelsTests.now.addingTimeInterval(30))
        if case .stale = failed.snapshot.freshness {} else {
            Issue.record("Successful balance must be stale")
        }
    }

    @Test func `explicit login discards earlier connection cache even for same SIM identifiers`() async throws {
        let clock = LiveTestClock()
        let rig = Rig(now: { clock.now() })
        let first = try await rig.session.bootstrap(credentials: Self.credentials)
        _ = try await rig.session.refresh()
        clock.advance(61)
        let second = try await rig.session.bootstrap(credentials: Self.credentials)
        #expect(first.connectionID != second.connectionID)
        #expect(second.balance == nil)
        let restored = try await rig.newSession().restore()
        #expect(restored.connectionID == second.connectionID)
        #expect(restored.balance == nil)
    }

    @Test func `sim selection drains old fetch before publishing selected SIM`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: Self.credentials)
        _ = try await rig.session.refresh()
        await rig.transport.pauseNext()
        let old = Task { try await rig.session.refresh() }
        await rig.transport.waitUntilPaused()
        let selected = Task { try await rig.session.selectSubscription(id: "sim-b") }
        await Task.yield()
        await rig.transport.resume()
        _ = try? await old.value
        let result = try await selected.value
        #expect(result.selectedSubscriptionID == "sim-b")
        #expect(result.snapshot.subscriptionName == "Second")
        #expect(await rig.transport.paths().last == "/mv/subscriptions/sim-b/balance")
    }

    @Test func `cancellation after receiving rotated token still saves replacement`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: Self.credentials)
        await rig.transport.pauseNext()
        let task = Task { try await rig.session.refresh(forceTokenRefresh: true) }
        await rig.transport.waitUntilPaused()
        await rig.session.cancel()
        await rig.transport.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        let record = try #require(rig.store.load())
        let recordText = try #require(String(bytes: record, encoding: .utf8))
        #expect(recordText.contains("refresh-2"))
        #expect(!recordText.contains("\"rotationPending\":true"))
        #expect(await rig.session.state().balance == nil)
    }

    @Test func `file lease is exclusive and releases without touching other paths`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = FileSessionLease(url: directory.appendingPathComponent("session.lock"))
        let second = FileSessionLease(url: directory.appendingPathComponent("session.lock"))
        let handle = try first.acquire()
        #expect(throws: LiveFailure.busy) { try second.acquire() }
        handle.release()
        let next = try second.acquire()
        next.release()
    }

    static let credentials = ProofCredentials(clientID: "test-client", username: "test-user", password: "test-password")
}
