import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct AppSessionTests {
    @Test func `fixture nil selection cannot create live workers helpers or refresh timers`() async throws {
        var created = 0
        let model = try AppSession(
            options: LaunchOptions(arguments: ["--fixture", "finite"]),
            preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { created += 1; throw LiveBridgeFailure.unavailable },
            connectorFactory: { created += 1; throw LiveBridgeFailure.connectFailed },
            sleepUntil: { _ in Issue.record("Fixture launched a refresh timer") },
        )
        model.fixture = nil
        model.start()
        model.refresh()
        model.selectSubscription("synthetic")
        model.selectBundle(0)
        model.connect(reference: URL(fileURLWithPath: "/synthetic/reference"), resultURL: nil)
        await model.stop()
        #expect(model.isFixtureLaunch)
        #expect(model.snapshot == .notConnected)
        #expect(created == 0)
    }

    @Test func `startup restores once without refreshing an unconnected account`() async throws {
        let client = ModelTestClient()
        let model = try Self.model(client: client)
        model.start()
        model.start()
        try await Self.until { model.activity == .idle }
        #expect(client.requests == ["restore"])
        #expect(model.snapshot == .notConnected)
        #expect(!model.canRefresh)
        await model.stop()
        #expect(client.shutdowns == 1)
    }

    @Test func `startup publishes cached state before a coalesced refresh finishes`() async throws {
        let client = ModelTestClient(state: Self.connected())
        client.holdRefresh = true
        let model = try Self.model(client: client)
        model.start()
        try await Self.until { client.pendingRefresh != nil }
        #expect(model.snapshot == client.state.snapshot)
        #expect(model.activity == .refreshing)
        model.refresh()
        model.refresh()
        #expect(client.requests == ["restore", "refresh"])
        client.releaseRefresh(.success(client.state))
        try await Self.until { model.activity == .idle }
        #expect(model.bridgeError == nil)
        await model.stop()
    }

    @Test func `restored failure deadline schedules one refresh and preserves stale cache`() async throws {
        let deadline = LiveModelsTests.now.addingTimeInterval(120)
        var state = Self.connected()
        state.failure = .rateLimited
        state.nextRefreshAt = deadline
        let client = ModelTestClient(state: state)
        let sleeper = ModelTestSleeper()
        let model = try Self.model(client: client, sleeper: sleeper)
        model.start()
        try await Self.until { sleeper.deadlines.count == 2 }
        #expect(model.liveState.failure == .rateLimited)
        #expect(client.requests == ["restore"])
        #expect(sleeper.deadlines.contains(deadline))
        client.state.nextRefreshAt = nil
        sleeper.wake()
        try await Self.until { client.requests == ["restore", "refresh", "refreshPoints"] && model.activity == .idle }
        #expect(sleeper.deadlines.filter { $0 == deadline }.count == 1)
        await model.stop()
    }

    @Test func `terminal restored connection requires explicit connect`() async throws {
        for failure in [LiveFailure.reconnectRequired, .unauthorized] {
            var state = Self.connected()
            state.failure = failure
            state.nextRefreshAt = LiveModelsTests.now
            let client = ModelTestClient(state: state)
            let sleeper = ModelTestSleeper()
            let model = try Self.model(client: client, sleeper: sleeper)
            model.start()
            try await Self.until { model.activity == .idle }
            model.refresh()
            #expect(client.requests == ["restore"])
            #expect(!model.canRefresh)
            try await Self.until { sleeper.deadlines.count == 1 }
            #expect(sleeper.deadlines == [state.snapshot.expiresAt])
            await model.stop()
        }
    }

    @Test func `failed reconnect clears the old account and ignores its delayed refresh`() async throws {
        let client = ModelTestClient(state: Self.connected())
        client.holdRefresh = true
        let connector = ModelTestConnector(fails: true)
        let model = try Self.model(client: client, connector: connector)
        model.start()
        try await Self.until { client.pendingRefresh != nil }
        model.connect(reference: URL(fileURLWithPath: "/synthetic/reference"), resultURL: nil)
        #expect(model.liveState.connectionID == nil)
        #expect(model.snapshot.allowance == .unavailable)
        try await Self.until { model.activity == .idle }
        #expect(client.shutdowns == 1)
        #expect(connector.connects == 1)
        #expect(model.bridgeError == LiveBridgeFailure.connectFailed.message)
        client.releaseRefresh(.success(client.state))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(model.liveState.connectionID == nil)
        #expect(model.snapshot.allowance == .unavailable)
        #expect(client.requests == ["restore", "refresh"])
        model.refresh()
        #expect(!model.canRefresh)
        await model.stop()
    }

    @Test func `successful connect creates a new worker only after helper success`() async throws {
        let first = ModelTestClient()
        let second = ModelTestClient(state: Self.connected())
        let connector = ModelTestConnector(fails: false)
        var creations = 0
        let model = try AppSession(
            options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { creations += 1; return creations == 1 ? first : second },
            connectorFactory: { connector }, now: { LiveModelsTests.now },
        )
        model.start()
        try await Self.until { model.activity == .idle }
        let reference = URL(fileURLWithPath: "/synthetic/reference")
        let result = URL(fileURLWithPath: "/synthetic/proof/connect-result.json")
        model.connect(reference: reference, resultURL: result)
        try await Self.until { model.activity == .idle }
        #expect(first.shutdowns == 1)
        #expect(creations == 2)
        #expect(second.requests == ["restore", "refresh", "refreshPoints"])
        #expect(connector.reference == reference)
        #expect(connector.resultURL == result)
        #expect(model.liveState.connectionID == second.state.connectionID)
        await model.stop()
    }

    @Test func `worker failure preserves a stale snapshot with only a local expiry timer`() async throws {
        let client = ModelTestClient(state: Self.connected())
        client.holdRefresh = true
        let sleeper = ModelTestSleeper()
        let model = try Self.model(client: client, sleeper: sleeper)
        model.start()
        try await Self.until { client.pendingRefresh != nil }
        client.releaseRefresh(.failure(LiveBridgeFailure.invalidReply))
        try await Self.until { client.shutdowns == 1 && sleeper.deadlines.count == 1 }
        #expect(model.snapshot.allowance == client.state.snapshot.allowance)
        #expect(model.snapshot.freshness == .stale(lastUpdated: LiveModelsTests.now))
        #expect(model.bridgeError == LiveBridgeFailure.unavailable.message)
        #expect(sleeper.deadlines == [client.state.snapshot.expiresAt])
        await model.stop()
    }

    @Test func `stop cancels helper and suppresses its delayed successful receipt`() async throws {
        let connector = ModelTestConnector(fails: false)
        connector.holdConnect = true
        var creations = 0
        let model = try AppSession(
            options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { creations += 1; return ModelTestClient() },
            connectorFactory: { connector },
        )
        model.connect(reference: URL(fileURLWithPath: "/synthetic/reference"), resultURL: nil)
        try await Self.until { connector.pendingConnect != nil }
        await model.stop()
        #expect(connector.pendingConnect == nil)
        #expect(creations == 0)
        #expect(connector.cancels == 1)
        #expect(model.activity == .stopped)
    }

    @Test func `stopping before startup task runs never constructs a worker`() async throws {
        var creations = 0
        let model = try AppSession(
            options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { creations += 1; return ModelTestClient() },
        )
        model.start()
        await model.stop()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(creations == 0)
    }

    @Test func `worker failure after expiry discards allowance but retains last update`() async throws {
        var state = Self.connected()
        state.snapshot = UsageSnapshot(
            source: .live, subscriptionName: "Expired synthetic SIM",
            allowance: state.snapshot.allowance, expiresAt: LiveModelsTests.now,
            freshness: .current(lastUpdated: LiveModelsTests.now.addingTimeInterval(-300)),
        )
        let client = ModelTestClient(state: state)
        client.holdRefresh = true
        let model = try Self.model(client: client)
        model.start()
        try await Self.until { client.pendingRefresh != nil }
        client.releaseRefresh(.failure(LiveBridgeFailure.unavailable))
        try await Self.until { model.activity == .idle }
        #expect(model.snapshot.allowance == .unavailable)
        #expect(model.snapshot.subscriptionName == "Expired synthetic SIM")
        #expect(model.snapshot.freshness == .stale(lastUpdated: LiveModelsTests.now.addingTimeInterval(-300)))
        #expect(model.snapshot.errorMessage == LiveBridgeFailure.unavailable.message)
        #expect(!model.canSelectAccountData)
        await model.stop()
    }

    @Test func `stop waits for the old worker being retired by connect`() async throws {
        let client = ModelTestClient()
        let connector = ModelTestConnector(fails: false)
        let model = try Self.model(client: client, connector: connector)
        model.start()
        try await Self.until { model.activity == .idle }
        client.holdShutdown = true
        model.connect(reference: URL(fileURLWithPath: "/synthetic/reference"), resultURL: nil)
        try await Self.until { client.pendingShutdown != nil }
        var stopped = false
        let stop = Task { await model.stop(); stopped = true }
        try await Self.until { model.activity == .stopped }
        #expect(!stopped)
        client.pendingShutdown?.resume()
        client.pendingShutdown = nil
        await stop.value
        #expect(stopped)
        #expect(connector.connects == 0)
        #expect(client.shutdowns == 1)
    }
}

extension AppSessionTests {
    @Test func `failed worker allowance expires locally and notifies presentation without another request`(
    ) async throws {
        let client = ModelTestClient(state: Self.connected())
        client.holdRefresh = true
        let sleeper = ModelTestSleeper()
        var now = LiveModelsTests.now
        let model = try AppSession(
            options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { client }, now: { now }, sleepUntil: { try await sleeper.sleep(until: $0) },
        )
        var presentations: [UsageSnapshot] = []
        model.onPresentationChange = { [weak model] in model.map { presentations.append($0.snapshot) } }
        model.start()
        try await Self.until { client.pendingRefresh != nil }
        client.releaseRefresh(.failure(LiveBridgeFailure.unavailable))
        try await Self.until { model.activity == .idle && sleeper.deadlines.count == 1 }
        let beforeExpiry = presentations.count
        #expect(model.snapshot.allowance == client.state.snapshot.allowance)
        now = try #require(client.state.snapshot.expiresAt)
        sleeper.wake()
        try await Self.until { presentations.count == beforeExpiry + 1 }
        #expect(presentations.last?.allowance == .unavailable)
        #expect(model.snapshot.allowance == .unavailable)
        #expect(model.snapshot.freshness == .stale(lastUpdated: LiveModelsTests.now))
        #expect(model.bridgeError == LiveBridgeFailure.unavailable.message)
        #expect(client.requests == ["restore", "refresh"])
        #expect(model.canRefresh)
        await model.stop()
    }

    static func model(
        client: ModelTestClient,
        connector: ModelTestConnector = ModelTestConnector(fails: false),
        sleeper: ModelTestSleeper = ModelTestSleeper(),
    ) throws -> AppSession {
        try AppSession(
            options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { client }, connectorFactory: { connector }, now: { LiveModelsTests.now },
            sleepUntil: { try await sleeper.sleep(until: $0) },
        )
    }

    static func connected() -> LiveSessionState {
        var state = LiveSessionState()
        state.connectionID = ConnectionID()
        state.snapshot = UsageSnapshot(
            source: .live, subscriptionName: "Synthetic SIM",
            allowance: .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 75),
            expiresAt: LiveModelsTests.now.addingTimeInterval(1000),
            freshness: .current(lastUpdated: LiveModelsTests.now),
        )
        return state
    }

    static func until(_ predicate: () -> Bool) async throws {
        for _ in 0 ..< 1000 {
            if predicate() {
                return
            }
            await Task.yield()
        }
        try #require(predicate(), "Model did not reach the expected state")
    }
}
