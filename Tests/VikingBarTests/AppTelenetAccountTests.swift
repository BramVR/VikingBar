import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct AppTelenetAccountTests {
    @Test func `home card presents downloaded traffic separately from policy counter`() async throws {
        let app = try AppSession(
            options: LaunchOptions(arguments: ["--fixture", "finite"]),
            preferences: MenuBarPreferences(fileURL: nil), referenceDate: LiveModelsTests.now,
        )
        app.selectAccount(FixtureAccounts.home)
        try await AppSessionTests.until { app.activity == .idle }
        let first = try #require(app.homeUsagePresentation)
        #expect(first.policyCounterText == "Policy counter 20 GB")
        #expect(first.allocationText == "Allowance 1000 GB")
        #expect(first.downloadedText == "Downloaded 60 GB")
        #expect(first.peakText == "Peak 15 GB")
        #expect(first.offPeakText == "Off-peak 45 GB")
        let firstIdentity = try #require(HistoryCompanionContent(session: app)).identity
        #expect(app.historyPresentation.days.count == 30)

        app.refresh()
        try await AppSessionTests.until { app.activity == .idle }
        #expect(HistoryCompanionContent(session: app)?.identity == firstIdentity)

        app.selectSubscription("second-service")
        try await AppSessionTests.until { app.activity == .idle }
        #expect(HistoryCompanionContent(session: app)?.identity != firstIdentity)
        let second = try #require(app.homeUsagePresentation)
        #expect(second.policyCounterText == "Policy counter 40 GB")
        #expect(second.downloadedText == "Downloaded 90 GB")
        #expect(second.peakText == "Peak 30 GB")
        #expect(second.offPeakText == "Off-peak 60 GB")
        await app.stop()
    }

    @Test func `manual refresh restores a missing worker without waiting for the hourly deadline`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = AccountCatalog(root: root)
        let entry = try catalog.reserve(provider: .telenet, label: "Synthetic home")
        try catalog.select(entry.key)
        let state = try Self.state(key: entry.key, fetchedAt: LiveModelsTests.now)
        let usage = try #require(state.selectedHomeUsage)
        let initial = ModelTestClient(state: state)
        let restored = ModelTestClient(state: state)
        initial.holdRefresh = true
        restored.holdRefresh = true
        var creations = 0
        let app = try AppSession(
            options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { _ in creations += 1; return creations == 1 ? initial : restored },
            accountDirectory: TestCatalogDirectory(catalog: catalog),
            now: { LiveModelsTests.now.addingTimeInterval(61) },
            sleepUntil: { _ in try await Task.sleep(for: .seconds(3600)) },
        )
        app.start()
        try await AppSessionTests.until { app.activity == .idle }
        #expect(initial.requests == ["restore"])
        app.refresh()
        try await AppSessionTests.until { initial.pendingRefresh != nil }
        initial.releaseRefresh(.failure(LiveBridgeFailure.unavailable))
        try await AppSessionTests.until { app.client == nil && app.activity == .idle }
        app.refresh()
        try await AppSessionTests.until { restored.pendingRefresh != nil }
        #expect(restored.requests == ["restore", "refresh"])
        restored.releaseRefresh(.success(state))
        try await AppSessionTests.until { app.activity == .idle }
        #expect(app.liveState.selectedHomeUsage == usage)
        #expect(app.bridgeError == nil)
        await app.stop()
    }

    @Test(arguments: [true, false])
    func `automatic refresh reloads a newer shared deadline with the existing worker`(wake: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = AccountCatalog(root: root)
        let entry = try catalog.reserve(provider: .telenet, label: "Synthetic home")
        try catalog.select(entry.key)
        let client = try ModelTestClient(state: Self.state(key: entry.key, fetchedAt: LiveModelsTests.now))
        let sleeper = ModelTestSleeper()
        var now = LiveModelsTests.now
        var creations = 0
        let app = try AppSession(
            options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { _ in creations += 1; return client },
            accountDirectory: TestCatalogDirectory(catalog: catalog),
            now: { now }, sleepUntil: { try await sleeper.sleep(until: $0) },
        )
        app.start()
        try await AppSessionTests.until { app.activity == .idle && sleeper.deadlines.count == 1 }
        let externalFetch = LiveModelsTests.now.addingTimeInterval(3480)
        client.state = try Self.state(key: entry.key, fetchedAt: externalFetch)
        now = LiveModelsTests.now.addingTimeInterval(3600)
        if wake {
            app.didWake()
        } else {
            sleeper.wake()
        }
        try await AppSessionTests.until { app.activity == .idle && client.requests.count == 2 }
        #expect(client.requests == ["restore", "restore"])
        #expect(creations == 1)
        #expect(app.liveState.selectedHomeUsage?.fetchedAt == externalFetch)
        #expect(app.liveState.nextRefreshAt == LiveModelsTests.now.addingTimeInterval(7080))
        now = LiveModelsTests.now.addingTimeInterval(7080)
        client.holdRefresh = true
        app.didWake()
        try await AppSessionTests.until { client.pendingRefresh != nil }
        try client.releaseRefresh(.success(Self.state(key: entry.key, fetchedAt: now)))
        try await AppSessionTests.until { app.activity == .idle }
        #expect(client.requests == ["restore", "restore", "restore", "refresh"])
        #expect(app.liveState.selectedHomeUsage?.fetchedAt == now)
        await app.stop()
    }

    @Test func `add account reserves the provider chosen in the form`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = TestCatalogDirectory(catalog: AccountCatalog(root: root))
        let client = ModelTestClient(state: AppSessionTests.connected())
        let connector = ModelTestConnector(fails: true)
        let app = try AppSession(
            options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { _ in client }, connectorFactory: { _ in connector }, accountDirectory: directory,
            now: { LiveModelsTests.now }, sleepUntil: { _ in try await Task.sleep(for: .seconds(3600)) },
        )
        app.start()
        try await AppSessionTests.until { app.activity == .idle }
        app.addingAccount = true
        app.addingProvider = .telenet
        _ = try #require(app.connect(input: .reference(URL(fileURLWithPath: "/synthetic")), resultURL: nil))
        try await AppSessionTests.until { connector.connects == 1 }
        try await AppSessionTests.until { app.activity == .idle }
        let snapshot = try await directory.snapshot()
        #expect(snapshot.accounts.count == 2)
        #expect(snapshot.accounts.last?.key.provider == .telenet)
        #expect(snapshot.selected == .legacy)
        await app.stop()
    }

    private static func state(key account: AccountKey, fetchedAt: Date) throws -> LiveSessionState {
        let key = ServiceKey(account: account, kind: .home, providerID: "home-a")
        let usage = try HomeUsageDecoder.decode(
            TelenetHomePayload(
                cycle: HomeUsageTests.cycle,
                usage: HomeUsageTests.usage(),
                dailyUsage: HomeUsageTests.daily,
            ),
            key: key, connectionID: HomeUsageTests.connection, fetchedAt: fetchedAt,
        )
        var state = LiveSessionState()
        state.connectionID = usage.connectionID
        state.account = AccountContext(key: account, providerName: "Telenet", services: [],
                                       selectedService: key, capabilities: .usageOnly)
        state.homeUsage = usage
        state.snapshot = usage.snapshot()
        state.nextRefreshAt = fetchedAt.addingTimeInterval(3600)
        return state
    }
}
