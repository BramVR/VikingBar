import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct CompactBundleTests {
    @Test func `synthetic selections publish matching identity allowance and details`() throws {
        let model = try Self.model()
        #expect(model.snapshot == FixtureState.finite.snapshot(referenceDate: model.referenceDate))
        model.selectBundle(1)
        #expect(model.menu.remainingText == "4.00 GB")
        model.selectSubscription("travel")
        #expect(model.selectedBundleIndex == 0)
        #expect(model.snapshot.subscriptionName == "Travel SIM")
        #expect(model.menu.remainingText == "8.00 GB")
        #expect(model.menu.totalText == "10.00 GB total")
        #expect(model.bundleDescription == "Travel SIM monthly allowance")
        model.selectBundle(1)
        #expect(model.menu.remainingText == "1.00 GB")
        #expect(model.menu.totalText == "2.00 GB total")
        model.selectSubscription("example")
        #expect(model.menu.remainingText == "36.00 GB")
        model.selectSubscription("unknown")
        model.selectBundle(100)
        #expect(model.menu.remainingText == "36.00 GB")
    }

    @Test func `synthetic refresh is observable coalesced and preserves stale state`() async throws {
        let model = try Self.model()
        model.fixture = .stale
        let previous = model.snapshot
        model.refresh()
        #expect(model.activity == .refreshing)
        #expect(!model.canRefresh)
        #expect(!model.canSelectAccountData)
        model.refresh()
        model.selectSubscription("travel")
        try await Task.sleep(for: .milliseconds(3200))
        #expect(model.activity == .idle)
        #expect(model.snapshot.allowance == previous.allowance)
        #expect(model.snapshot.subscriptionName == "Example SIM")
        #expect(model.fixtureAccount.refreshCount == 1)
        #expect(model.snapshot.freshness == .stale(lastUpdated: model.referenceDate.addingTimeInterval(-86340)))
        #expect(model.menu.warningText != nil)
        await model.stop()
    }

    @Test func `worker startup failure retains credential free refresh recovery`() async throws {
        let model = try AppSession(
            options: LaunchOptions(arguments: []),
            preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { throw LiveBridgeFailure.unavailable },
            connectorFactory: {
                Issue.record("Retry must not bootstrap credentials"); throw LiveBridgeFailure.connectFailed
            },
        )
        model.start()
        for _ in 0 ..< 100 where model.activity != .idle {
            await Task.yield()
        }
        #expect(model.needsConnection)
        #expect(model.canRefresh)
        model.refresh()
        #expect(model.activity == .refreshing)
        for _ in 0 ..< 100 where model.activity != .idle {
            await Task.yield()
        }
        #expect(model.canRefresh)
        await model.stop()
    }

    @Test func `fixture appearance options reject live launches and malformed values`() throws {
        for value in ["light", "dark", "high-contrast-light", "high-contrast-dark"] {
            let options = try AppLaunchOptions(arguments: ["--fixture", "finite", "--fixture-appearance", value])
            #expect(options.fixtureAppearance?.rawValue == value)
            #expect(throws: (any Error).self) {
                try AppLaunchOptions(arguments: ["--fixture-appearance", value])
            }
        }
        let options = try AppLaunchOptions(arguments: ["--fixture", "finite", "--fixture-reduce-transparency"])
        #expect(options.fixtureReduceTransparency)
        #expect(throws: (any Error).self) { try AppLaunchOptions(arguments: ["--fixture-reduce-transparency"]) }
        #expect(throws: (any Error).self) {
            try AppLaunchOptions(arguments: ["--fixture", "finite", "--fixture-appearance", "purple"])
        }
    }

    @Test func `disconnected presentation exposes restore and connection failures`() async throws {
        let model = try AppSession(
            options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { throw LiveBridgeFailure.unavailable },
            connectorFactory: { throw LiveBridgeFailure.connectFailed },
        )
        model.start()
        #expect(model.connectionTitle == "Restoring account…")
        for _ in 0 ..< 100 where model.activity != .idle {
            await Task.yield()
        }
        #expect(model.connectionMessage == LiveBridgeFailure.unavailable.message)
        model.connect(reference: URL(fileURLWithPath: "/synthetic/reference"), resultURL: nil)
        #expect(model.connectionTitle == "Connecting…")
        for _ in 0 ..< 100 where model.activity != .idle {
            await Task.yield()
        }
        #expect(model.needsConnection)
        #expect(model.connectionMessage == LiveBridgeFailure.connectFailed.message)
        await model.stop()
    }

    @Test func `connected account without active bundles has an explicit unavailable selection`() async throws {
        var state = LiveSessionState()
        state.connectionID = ConnectionID()
        state.subscriptions = [MobileSubscription(id: "empty", displayName: "Empty SIM", type: "postpaid")]
        state.selectedSubscriptionID = "empty"
        state.balance = LiveBalance(bundles: [], regionality: nil, outOfBundleCost: nil)
        state.snapshot = UsageSnapshot(
            source: .live, subscriptionName: "Empty SIM", allowance: .unavailable,
            expiresAt: nil, freshness: .current(lastUpdated: LiveModelsTests.now),
        )
        let client = ModelTestClient(state: state)
        let model = try AppSessionTests.model(client: client)
        model.start()
        try await AppSessionTests.until { model.activity == .idle }
        #expect(!model.needsConnection)
        #expect(model.canSelectAccountData)
        #expect(model.bundles.isEmpty)
        #expect(!model.hasSelectableBundle)
        #expect(model.bundleSelectionLabel == "No active data bundle")
        #expect(model.menu.remainingText == "Unavailable")
        #expect(model.menu.percentageRemaining == nil)
        await model.stop()
    }

    private static func model() throws -> AppSession {
        try AppSession(
            options: LaunchOptions(arguments: ["--fixture", "finite"]),
            preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { Issue.record("Fixture created a live client"); throw LiveBridgeFailure.unavailable },
            connectorFactory: { Issue.record("Fixture created a connector"); throw LiveBridgeFailure.connectFailed },
        )
    }
}
