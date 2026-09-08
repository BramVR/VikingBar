import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct HistoryAppSessionTests {
    @Test func `balance becomes idle while optional history waits and merges only matching history`() async throws {
        let client = try HistoryModelClient()
        let model = try Self.model(client: client)
        model.start()
        try await AppSessionTests.until { client.pendingHistory != nil }
        let balance = model.snapshot
        #expect(model.activity == .idle)
        #expect(model.canRefresh)
        #expect(model.canSelectAccountData)
        #expect(model.isHistoryLoading)
        var reply = client.state
        reply.snapshot = .notConnected
        client.releaseHistory(reply)
        try await AppSessionTests.until { !model.isHistoryLoading }
        #expect(model.snapshot == balance)
        #expect(model.liveState.history == reply.history)
        await model.stop()
    }

    @Test func `foreground refresh waits for canceled history and cancel reply before sending new command`(
    ) async throws {
        let client = try HistoryModelClient()
        let model = try Self.model(client: client)
        model.start()
        try await AppSessionTests.until { client.pendingHistory != nil }
        let old = client.state
        model.refresh()
        try await AppSessionTests.until { client.pendingCancel != nil }
        #expect(client.requests == ["restore", "refresh", "refreshPoints", "refreshHistory", "cancel"])
        #expect(model.activity == .refreshing)
        client.state.historyRevision = UUID()
        client.state.history = nil
        client.state.snapshot = UsageSnapshot(
            source: .live, subscriptionName: "Updated", allowance: .finite(
                totalBytes: 100, usedBytes: 50, remainingBytes: 50,
            ), expiresAt: old.snapshot.expiresAt, freshness: old.snapshot.freshness,
        )
        client.releaseHistory(old)
        client.releaseCancel()
        try await AppSessionTests.until { client.requests.count == 7 }
        #expect(client.requests == [
            "restore",
            "refresh",
            "refreshPoints",
            "refreshHistory",
            "cancel",
            "refresh",
            "refreshHistory",
        ])
        #expect(model.snapshot.subscriptionName == "Updated")
        #expect(model.liveState.history == nil)
        client.releaseHistory(old)
        try await AppSessionTests.until { !model.isHistoryLoading }
        #expect(model.liveState.history == nil)
        #expect(model.snapshot.subscriptionName == "Updated")
        await model.stop()
    }

    @Test func `optional worker error cannot change allowance freshness or disable balance controls`() async throws {
        let client = try HistoryModelClient()
        let model = try Self.model(client: client)
        model.start()
        try await AppSessionTests.until { client.pendingHistory != nil }
        let balance = model.snapshot
        client.pendingHistory?.resume(throwing: LiveBridgeFailure.unavailable)
        client.pendingHistory = nil
        try await AppSessionTests.until { !model.isHistoryLoading }
        #expect(model.snapshot == balance)
        #expect(model.bridgeError == nil)
        #expect(model.historyError != nil)
        #expect(model.canRefresh)
        #expect(model.canSelectAccountData)
        await model.stop()
    }

    @Test(arguments: [false, true])
    func `first refresh or SIM selection replaces a dead history worker without losing known data`(
        selection: Bool,
    ) async throws {
        let failed = try HistoryModelClient()
        let healthy = try HistoryModelClient()
        healthy.state = failed.state
        healthy.state.history = nil
        var creations = 0
        let sleeper = ModelTestSleeper()
        let model = try AppSession(
            options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { creations += 1; return creations == 1 ? failed : healthy },
            now: { LiveModelsTests.now }, sleepUntil: { try await sleeper.sleep(until: $0) },
        )
        model.start()
        try await AppSessionTests.until { failed.pendingHistory != nil }
        let known = model.liveState
        failed.stopped = true
        failed.pendingHistory?.resume(throwing: LiveBridgeFailure.stopped)
        failed.pendingHistory = nil
        try await AppSessionTests.until { !model.isHistoryLoading }
        #expect(model.liveState == known)
        #expect(model.canRefresh)
        #expect(model.canSelectAccountData)
        let oldRequests = failed.requests
        if selection {
            model.selectSubscription("sim-b")
        } else {
            model.refresh()
        }
        try await AppSessionTests.until { model.activity == .idle }
        #expect(creations == 2)
        #expect(failed.shutdowns == 1)
        #expect(failed.requests == oldRequests)
        #expect(healthy.requests.prefix(2) == ["restore", selection ? "selection" : "refresh"])
        #expect(model.bridgeError == nil)
        if selection {
            #expect(model.liveState.selectedSubscriptionID == "sim-b")
            #expect(model.liveState.history == nil)
        } else {
            #expect(model.snapshot == known.snapshot)
            #expect(model.liveState.history == known.history)
        }
        await model.stop()
    }

    private static func model(client: HistoryModelClient) throws -> AppSession {
        let sleeper = ModelTestSleeper()
        return try AppSession(
            options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { client }, now: { LiveModelsTests.now },
            sleepUntil: { try await sleeper.sleep(until: $0) },
        )
    }
}

@MainActor
private final class HistoryModelClient: SessionClient {
    var state: LiveSessionState
    var requests: [String] = []
    var pendingHistory: CheckedContinuation<LiveSessionState, any Error>?
    var pendingCancel: CheckedContinuation<LiveSessionState, any Error>?
    var stopped = false
    var shutdowns = 0

    init() throws {
        var state = LiveSessionState()
        state.connectionID = ConnectionID()
        state.subscriptions = [MobileSubscription(id: "sim-a", displayName: "Synthetic", type: "postpaid")]
        state.selectedSubscriptionID = "sim-a"
        try state.publish(LiveAPI.decodeBalance(Data(LiveModelsTests.balanceJSON.utf8)), at: LiveModelsTests.now)
        state.history = UsageHistory(
            context: state.historyContext!, observations: [], attemptedAt: LiveModelsTests.now,
        )
        self.state = state
    }

    func request(_ request: SessionRequest) async throws -> LiveSessionState {
        guard !self.stopped else { throw LiveBridgeFailure.stopped }
        switch request {
        case .restore: self.requests.append("restore")
        case .refresh: self.requests.append("refresh")
        case .refreshPoints: self.requests.append("refreshPoints")
        case .refreshHistory:
            self.requests.append("refreshHistory")
            return try await withCheckedThrowingContinuation { self.pendingHistory = $0 }
        case .cancel:
            self.requests.append("cancel")
            return try await withCheckedThrowingContinuation { self.pendingCancel = $0 }
        case let .selectSubscription(id):
            self.requests.append("selection")
            self.state.selectedSubscriptionID = id
            self.state.historyRevision = UUID()
            self.state.history = nil
        default: self.requests.append("selection")
        }
        return self.state
    }

    func releaseHistory(_ reply: LiveSessionState) {
        self.pendingHistory?.resume(returning: reply)
        self.pendingHistory = nil
    }

    func releaseCancel() {
        self.pendingCancel?.resume(returning: self.state)
        self.pendingCancel = nil
    }

    func shutdown() async {
        self.stopped = true
        self.shutdowns += 1
        self.pendingHistory?.resume(throwing: CancellationError())
        self.pendingHistory = nil
        self.releaseCancel()
    }
}
