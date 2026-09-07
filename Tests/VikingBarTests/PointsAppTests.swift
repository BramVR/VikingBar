import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct PointsAppTests {
    @Test func `app publishes usage before points and preserves it after optional worker failure`() async throws {
        let client = ModelTestClient(state: AppSessionTests.connected())
        client.holdPoints = true
        let model = try AppSessionTests.model(client: client)
        model.start()
        try await AppSessionTests.until { client.pendingPoints != nil }
        #expect(client.requests == ["restore", "refresh", "refreshPoints"])
        #expect(model.snapshot == client.state.snapshot)
        #expect(model.bridgeError == nil)
        client.pendingPoints?.resume(throwing: LiveBridgeFailure.invalidReply)
        client.pendingPoints = nil
        try await AppSessionTests.until { model.activity == .idle }
        #expect(model.snapshot == client.state.snapshot)
        #expect(model.liveState.failure == nil)
        #expect(model.points.availableText == "Available: unavailable")
        #expect(model.points.balanceStatus.contains("Unavailable"))
        #expect(model.canRefresh)
        await model.stop()
    }

    @Test func `new connection ignores delayed optional points response`() async throws {
        let client = ModelTestClient(state: AppSessionTests.connected())
        client.state.points = FixtureState.finite.points(referenceDate: LiveModelsTests.now)
        client.holdPoints = true
        let model = try AppSessionTests.model(client: client, connector: ModelTestConnector(fails: true))
        model.start()
        try await AppSessionTests.until { client.pendingPoints != nil }
        model.connect(reference: URL(fileURLWithPath: "/synthetic/reference"), resultURL: nil)
        try await AppSessionTests.until { model.activity == .idle }
        client.pendingPoints?.resume(returning: client.state)
        client.pendingPoints = nil
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(model.liveState.connectionID == nil)
        #expect(model.liveState.points == nil)
        #expect(model.points.availableText == "Available: unavailable")
        await model.stop()
    }

    @Test func `expired or failed account points present stale without changing allowance`() {
        var state = AppSessionTests.connected()
        state.points = FixtureState.finite.points(referenceDate: LiveModelsTests.now)
        let fresh = state.points(at: LiveModelsTests.now)
        #expect(fresh?.balanceFreshness == .current(lastUpdated: LiveModelsTests.now))
        let expired = state.points(at: LiveModelsTests.now.addingTimeInterval(300))
        #expect(expired?.balanceFreshness == .stale(lastUpdated: LiveModelsTests.now))
        state.failure = .serverUnavailable
        let independent = state.points(at: LiveModelsTests.now)
        #expect(independent?.balanceFreshness == .current(lastUpdated: LiveModelsTests.now))
        #expect(independent?.balanceFailure == nil)
        state.failure = .unauthorized
        let failed = state.points(at: LiveModelsTests.now)
        #expect(failed?.balanceFreshness == .stale(lastUpdated: LiveModelsTests.now))
        #expect(failed?.balanceFailure == .unauthorized)
        #expect(failed?.historyFailure == .unauthorized)
    }
}
