import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct AppSessionExpiryTests {
    @Test(arguments: [false, true])
    func `live allowance expires during startup and manual refresh without another request`(
        manualRefresh: Bool,
    ) async throws {
        let client = ModelTestClient(state: AppSessionTests.connected())
        client.holdRefresh = !manualRefresh
        let sleeper = ModelTestSleeper()
        var now = LiveModelsTests.now
        let model = try Self.model(client: client, sleeper: sleeper, now: { now })
        var presented: [UsageSnapshot] = []
        model.onPresentationChange = { [weak model] in model.map { presented.append($0.snapshot) } }
        model.start()
        if manualRefresh {
            try await AppSessionTests.until { model.activity == .idle }
            client.holdRefresh = true
            model.refresh()
        }
        try await AppSessionTests.until { client.pendingRefresh != nil && !sleeper.deadlines.isEmpty }
        let beforeExpiry = presented.count
        let requests = client.requests
        now = try #require(client.state.snapshot.expiresAt)
        sleeper.wakeAll()
        try await AppSessionTests.until { presented.count == beforeExpiry + 1 }
        #expect(presented.last?.allowance == .unavailable)
        #expect(model.snapshot.freshness == .stale(lastUpdated: LiveModelsTests.now))
        #expect(model.activity == .refreshing)
        #expect(model.bridgeError == nil)
        model.refresh()
        #expect(client.requests == requests)
        client.releaseRefresh(.success(client.state))
        try await AppSessionTests.until { model.activity == .idle }
        #expect(model.snapshot.allowance == .unavailable)
        #expect(model.canRefresh)
        await model.stop()
    }

    @Test(arguments: [LiveFailure.reconnectRequired, .unauthorized])
    func `terminal connection allowance also expires without starting a worker request`(
        failure: LiveFailure,
    ) async throws {
        var state = AppSessionTests.connected()
        state.failure = failure
        let client = ModelTestClient(state: state)
        let sleeper = ModelTestSleeper()
        var now = LiveModelsTests.now
        let model = try Self.model(client: client, sleeper: sleeper, now: { now })
        var presented: UsageSnapshot?
        model.onPresentationChange = { [weak model] in presented = model?.snapshot }
        model.start()
        try await AppSessionTests.until { model.activity == .idle && !sleeper.deadlines.isEmpty }
        now = try #require(state.snapshot.expiresAt)
        sleeper.wakeAll()
        try await AppSessionTests.until { presented?.allowance == .unavailable }
        #expect(model.liveState.failure == failure)
        #expect(client.requests == ["restore"])
        #expect(!model.canRefresh)
        await model.stop()
    }

    @Test(arguments: ["replacement", "connect", "stop"])
    func `superseded expiry timers cannot change the visible account`(action: String) async throws {
        let client = ModelTestClient(state: AppSessionTests.connected())
        let sleeper = ModelTestSleeper()
        sleeper.ignoresCancellation = true
        let model = try Self.model(client: client, sleeper: sleeper, now: { LiveModelsTests.now })
        var updates = 0
        model.onPresentationChange = { updates += 1 }
        model.start()
        try await AppSessionTests
            .until { model.activity == .idle && model.activeOptional == nil && !sleeper.deadlines.isEmpty }
        if action == "replacement" {
            client.state.snapshot = UsageSnapshot(
                source: .live, subscriptionName: "Replacement SIM", allowance: .unlimited(usedBytes: 1),
                expiresAt: nil, freshness: .current(lastUpdated: LiveModelsTests.now),
            )
            model.refresh()
            try await AppSessionTests.until { model.activity == .idle && model.activeOptional == nil }
        } else if action == "connect" {
            model.connect(reference: URL(fileURLWithPath: "/synthetic/reference"), resultURL: nil)
            try await AppSessionTests.until { model.activity == .idle && model.activeOptional == nil }
        } else {
            await model.stop()
        }
        let snapshot = model.snapshot
        let beforeWake = updates
        sleeper.wakeAll()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(updates == beforeWake)
        #expect(model.snapshot == snapshot)
        await model.stop()
    }

    private static func model(
        client: ModelTestClient, sleeper: ModelTestSleeper, now: @escaping () -> Date,
    ) throws -> AppSession {
        try AppSession(
            options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { client }, connectorFactory: { ModelTestConnector(fails: true) },
            now: now, sleepUntil: { try await sleeper.sleep(until: $0) },
        )
    }
}
