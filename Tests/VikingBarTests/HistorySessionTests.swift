import Foundation
import Testing
@testable import VikingBarCore

struct HistorySessionTests {
    @Test func `history uses retained token after balance and cannot poison balance on error or retry`() async throws {
        let rig = try await Self.rig()
        let balance = await rig.session.state()
        #expect(balance.history == nil)
        #expect(await rig.transport.paths().count == 3)
        await rig.transport.failNext(code: 429)
        let result = try await rig.session.refreshHistory()
        #expect(result.history?.failure == .rateLimited)
        #expect(result.snapshot == balance.snapshot)
        #expect(result.failure == nil)
        #expect(result.nextRefreshAt == balance.nextRefreshAt)
        #expect(!result.isRefreshing)
        #expect(rig.store.saveCount == 1)
        let requests = await rig.transport.paths().count
        _ = try await rig.session.refreshHistory()
        #expect(await rig.transport.paths().count == requests)
    }

    @Test func `history retains successful samples marks errors stale and caches complete older days`() async throws {
        let clock = HistoryClock(Self.now)
        let rig = try await Self.rig(now: { clock.now })
        let initial = try await rig.session.refreshHistory()
        let history = try #require(initial.history)
        #expect(history.observations.count == 8)
        #expect(history.observations.allSatisfy { $0.bytes == 1 && !$0.isStale })
        #expect(await rig.transport.paths().count == 11)
        clock.advance(301)
        _ = try await rig.session.refreshHistory()
        #expect(await rig.transport.paths().count == 13)
        clock.advance(301)
        await rig.transport.failNext(code: 503)
        let failed = try await rig.session.refreshHistory()
        #expect(failed.history?.failure == .tokenExpired)
        #expect(failed.history?.observations.allSatisfy { $0.bytes == 1 && $0.isStale } == true)
        #expect(failed.snapshot == initial.snapshot)
        #expect(await rig.transport.paths().count == 13)
        #expect(rig.store.saveCount == 1)
    }

    @Test func `forced history bypasses cache but stays capped and never requests details`() async throws {
        let rig = try await Self.rig()
        _ = try await rig.session.refreshHistory()
        _ = try await rig.session.refreshHistory(force: true)
        #expect(await rig.transport.paths().count == 19)
        #expect(await rig.transport.paths().filter { $0.hasSuffix("/usage-summary") }.count == 16)
        let long = Rig()
        _ = try await long.session.bootstrap(credentials: LiveSessionTests.credentials)
        _ = try await long.session.refresh()
        await long.transport.setResponse(path: Self.summaryPath, json: "[\(UsageHistoryTests.row())]")
        let bounded = try await long.session.refreshHistory()
        #expect(bounded.history?.observations.count == 62)
        #expect(bounded.history?.truncated == true)
        #expect(await long.transport.paths().count == 65)
    }

    @Test func `cancelled history is drained before SIM selection and cannot overwrite newer balance`() async throws {
        let rig = try await Self.rig()
        await rig.transport.pauseNext(path: Self.summaryPath)
        let history = Task { try await rig.session.refreshHistory() }
        await rig.transport.waitUntilPaused()
        #expect(await rig.session.state().isRefreshing == false)
        let selecting = Task { try await rig.session.selectSubscription(id: "sim-b") }
        await Task.yield()
        await rig.transport.resume()
        _ = try? await history.value
        let selected = try await selecting.value
        #expect(selected.selectedSubscriptionID == "sim-b")
        #expect(selected.history == nil)
        #expect(selected.snapshot.subscriptionName == "Second")
        #expect(await rig.transport.paths().last == "/mv/subscriptions/sim-b/balance")
    }

    @Test func `history merge requires connection SIM bundle cycle and exact balance revision`() async throws {
        let rig = try await Self.rig()
        let old = try await rig.session.refreshHistory()
        var newer = try await rig.session.refresh()
        let balance = newer.snapshot
        #expect(newer.historyRevision != old.historyRevision)
        let mergedOld = newer.mergeHistory(from: old)
        #expect(mergedOld == false)
        #expect(newer.snapshot == balance)
        var wrongSIM = old
        wrongSIM.selectedSubscriptionID = "sim-b"
        var target = old
        let mergedSIM = target.mergeHistory(from: wrongSIM)
        #expect(mergedSIM == false)
        var wrongConnection = old
        wrongConnection.connectionID = ConnectionID()
        let mergedConnection = target.mergeHistory(from: wrongConnection)
        #expect(mergedConnection == false)
        var wrongBundle = old
        wrongBundle.selectedBundleIndex = 1
        let mergedBundle = target.mergeHistory(from: wrongBundle)
        #expect(mergedBundle == false)
        let mergedCurrent = target.mergeHistory(from: old)
        #expect(mergedCurrent == true)
    }

    @Test func `another process token rotation becomes history failure without altering balance`() async throws {
        let rig = try await Self.rig()
        let original = await rig.session.state()
        let other = rig.newSession()
        _ = try await other.restore()
        _ = try await other.refresh()
        let optional = try await rig.session.refreshHistory()
        #expect(optional.history?.failure == .connectionChanged)
        #expect(optional.snapshot == original.snapshot)
        #expect(optional.failure == original.failure)
        #expect(optional.nextRefreshAt == original.nextRefreshAt)
    }

    @Test func `midnight replans partial days before five minute retry period ends`() async throws {
        let clock = HistoryClock(UsageHistoryTests.date("2026-09-08T23:59:00+02:00"))
        let rig = try await Self.rig(now: { clock.now })
        let before = try await rig.session.refreshHistory()
        clock.advance(120)
        let after = try await rig.session.refreshHistory()
        #expect(after.history?.observations.count == (before.history?.observations.count ?? 0) + 1)
        #expect(after.history?.observations.last?.interval.dayStart == HistoryPlan.calendar.startOfDay(for: clock.now))
        #expect(after.history?.observations.dropLast().last?.interval.isCompleteDay == true)
    }

    @Test func `fractional clocks produce observation boundaries identical to transmitted UTC values`() async throws {
        let now = Self.now.addingTimeInterval(0.123456)
        let rig = try await Self.rig(now: { now })
        let result = try await rig.session.refreshHistory()
        let observations = try #require(result.history?.observations)
        let requests = await rig.transport.recordedRequests().filter { $0.url?.path == Self.summaryPath }
        #expect(requests.count == observations.count)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        for (request, observation) in zip(requests, observations) {
            let url = try #require(request.url)
            let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let from = try #require(parts.queryItems?.first(where: { $0.name == "from_date" })?.value)
            let until = try #require(parts.queryItems?.first(where: { $0.name == "until_date" })?.value)
            #expect(formatter.date(from: from) == observation.interval.start)
            #expect(formatter.date(from: until) == observation.interval.end)
            #expect(request.timeoutInterval <= 10)
        }
        #expect(observations.last?.interval.end == Self.now)
    }

    @Test func `restored cache discards history from another SIM while preserving valid balance`() async throws {
        let rig = try await Self.rig()
        var state = try await rig.session.refreshHistory()
        let history = try #require(state.history)
        let context = history.context
        state.history = UsageHistory(
            context: HistoryContext(
                connectionID: context.connectionID, subscriptionID: "sim-b", bundleIndex: context.bundleIndex,
                bundle: context.bundle, revision: context.revision,
            ), observations: history.observations, attemptedAt: history.attemptedAt,
        )
        #expect(state.matchingHistory == nil)
        rig.cache.save(state)
        let restored = try await rig.newSession().restore()
        #expect(restored.snapshot == state.snapshot)
        #expect(restored.history == nil)
        #expect(restored.selectedSubscriptionID == "sim-a")
    }

    @Test func `provider error marks only the failed sample stale with unchanged allowance`() async throws {
        let rig = try await Self.rig()
        let initial = try await rig.session.refreshHistory()
        await rig.transport.failNext(code: 503)
        let failed = try await rig.session.refreshHistory(force: true)
        #expect(failed.history?.failure == .serverUnavailable)
        #expect(failed.history?.observations.first?.isStale == true)
        #expect(failed.history?.observations.dropFirst().allSatisfy { $0.bytes == 1 && !$0.isStale } == true)
        #expect(failed.snapshot == initial.snapshot)
        #expect(failed.nextRefreshAt == initial.nextRefreshAt)
        #expect(failed.failure == nil)
        #expect(HistoryPresentation(history: failed.history, now: Self.now).forecast == nil)
    }

    @Test func `a bounded failed attempt preserves progress for the next attempt`() async throws {
        let clock = HistoryClock(Self.now)
        let rig = try await Self.rig(now: { clock.now })
        await rig.transport.failNext(code: 503, after: 2)
        let partial = try await rig.session.refreshHistory()
        #expect(partial.history?.failure == .serverUnavailable)
        #expect(partial.history?.observations.prefix(2).allSatisfy { $0.bytes == 1 && !$0.isStale } == true)
        #expect(await rig.transport.paths().count == 6)
        clock.advance(301)
        let complete = try await rig.session.refreshHistory()
        #expect(complete.history?.failure == nil)
        #expect(complete.history?.observations.allSatisfy { $0.bytes == 1 && !$0.isStale } == true)
        #expect(await rig.transport.paths().count == 12)
    }

    @Test func `failed partial day refresh retains the original interval and amount until replacement`() async throws {
        let clock = HistoryClock(Self.now)
        let rig = try await Self.rig(now: { clock.now })
        let initial = try await rig.session.refreshHistory()
        let oldToday = try #require(initial.history?.observations.last)
        clock.advance(301)
        await rig.transport.failNext(code: 503, after: 1)
        let failed = try await rig.session.refreshHistory()
        let retained = try #require(failed.history?.observations.last)
        #expect(retained.interval == oldToday.interval)
        #expect(retained.bytes == oldToday.bytes)
        #expect(retained.fetchedAt == oldToday.fetchedAt)
        #expect(retained.isStale)
        let recovered = try await rig.session.refreshHistory(force: true)
        #expect(recovered.history?.observations.last?.interval.end == clock.now)
        #expect(recovered.history?.observations.last?.isStale == false)
    }

    @Test func `empty summary is missing with a fetch receipt rather than confirmed zero`() async throws {
        let rig = try await Self.rig()
        await rig.transport.setResponse(path: Self.summaryPath, json: "[]")
        let result = try await rig.session.refreshHistory()
        #expect(result.history?.observations.allSatisfy { $0.bytes == nil && $0.fetchedAt != nil } == true)
        #expect(HistoryPresentation(history: result.history, now: Self.now).forecast == nil)
        #expect(result.failure == nil)
    }

    private static let now = UsageHistoryTests.date("2026-09-08T12:00:00+02:00")
    private static let summaryPath = "/mv/subscriptions/sim-a/usage-summary"

    private static func rig(now: @escaping @Sendable () -> Date = { Self.now }) async throws -> Rig {
        let rig = Rig(now: now)
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        let bundle = LiveModelsTests.bundle()
            .replacingOccurrences(of: "2026-01-01T00:00:00Z", with: "2026-08-31T22:00:00Z")
            .replacingOccurrences(of: "2027-01-01T00:00:00Z", with: "2026-09-30T22:00:00Z")
        await rig.transport.setResponse(path: "/mv/subscriptions/sim-a/balance", json: "{\"bundles\":[\(bundle)]}")
        await rig.transport.setResponse(path: Self.summaryPath, json: "[\(UsageHistoryTests.row())]")
        _ = try await rig.session.refresh()
        return rig
    }
}

private final class HistoryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ date: Date) {
        self.value = date
    }

    var now: Date {
        self.lock.withLock { self.value }
    }

    func advance(_ seconds: TimeInterval) {
        self.lock.withLock { self.value.addTimeInterval(seconds) }
    }
}
