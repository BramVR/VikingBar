import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct AppSettingsTests {
    @Test func `initial interval reaches worker before restore`() async throws {
        let preferences = MenuBarPreferences(fileURL: nil)
        preferences.setRefreshInterval(.thirtyMinutes)
        let client = ModelTestClient()
        let model = try AppSession(options: LaunchOptions(arguments: []), preferences: preferences,
                                   clientFactory: { client })
        model.start()
        try await AppSessionTests.until { model.activity == .idle }
        #expect(client.requests == ["configure-1800", "restore"])
        await model.stop()
    }

    @Test func `busy interval changes send latest value after refresh without cancellation`() async throws {
        let client = ModelTestClient(state: AppSessionTests.connected())
        client.holdRefresh = true
        let model = try AppSessionTests.model(client: client)
        model.start()
        try await AppSessionTests.until { client.pendingRefresh != nil }
        model.refreshInterval = .fifteenMinutes
        model.refreshInterval = .oneHour
        model.didWake()
        #expect(client.requests == ["restore", "refresh"])
        #expect(client.shutdowns == 0)
        client.releaseRefresh(.success(client.state))
        try await AppSessionTests.until { model.activity == .idle }
        #expect(client.requests.filter { $0 != "refreshPoints" } == ["restore", "refresh", "configure-3600"])
        await model.stop()
    }

    @Test func `wake honors future retry coalesces busy refresh and ignores stopped state`() async throws {
        let client = ModelTestClient(state: AppSessionTests.connected())
        client.state.failure = .rateLimited
        client.state.nextRefreshAt = LiveModelsTests.now.addingTimeInterval(30)
        let model = try AppSessionTests.model(client: client)
        model.start()
        try await AppSessionTests.until { model.activity == .idle }
        model.didWake()
        #expect(client.requests == ["restore"])
        await model.stop()
        model.didWake()
        #expect(client.requests == ["restore"])

        let due = ModelTestClient(state: AppSessionTests.connected())
        due.state.failure = .rateLimited
        due.state.nextRefreshAt = LiveModelsTests.now
        due.holdRefresh = true
        let active = try AppSessionTests.model(client: due)
        active.start()
        try await AppSessionTests.until { due.pendingRefresh != nil }
        active.didWake()
        active.didWake()
        #expect(due.requests.filter { $0 != "refreshPoints" } == ["restore", "refresh"])
        due.state.nextRefreshAt = LiveModelsTests.now.addingTimeInterval(300)
        due.releaseRefresh(.success(due.state))
        try await AppSessionTests.until { active.activity == .idle }
        active.didWake()
        #expect(due.requests.filter { $0 != "refreshPoints" } == ["restore", "refresh"])
        await active.stop()
    }

    @Test func `idle due wake refreshes once and fixture wake never creates a client`() async throws {
        var now = LiveModelsTests.now
        let client = ModelTestClient(state: AppSessionTests.connected())
        client.state.failure = .rateLimited
        client.state.nextRefreshAt = now.addingTimeInterval(30)
        let sleeper = ModelTestSleeper()
        let model = try AppSession(options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
                                   clientFactory: { client }, now: { now },
                                   sleepUntil: { try await sleeper.sleep(until: $0) })
        model.start()
        try await AppSessionTests.until { model.activity == .idle }
        now = now.addingTimeInterval(31)
        client.holdRefresh = true
        model.didWake()
        model.didWake()
        try await AppSessionTests.until { client.pendingRefresh != nil }
        #expect(client.requests == ["restore", "refresh"])
        client.state.nextRefreshAt = now.addingTimeInterval(300)
        client.releaseRefresh(.success(client.state))
        try await AppSessionTests.until { model.activity == .idle }
        await model.stop()
        let fixture = try AppSession(options: LaunchOptions(arguments: ["--fixture", "finite"]),
                                     preferences: MenuBarPreferences(fileURL: nil),
                                     clientFactory: { Issue.record("Fixture created worker"); return client })
        fixture.didWake()
        fixture.refreshInterval = .oneHour
        #expect(fixture.activity == .idle)
        #expect(fixture.loginItemStatus == .unavailable)
        await fixture.stop()
    }

    @Test func `configuration request has exact bounded wire shape`() throws {
        let data = try JSONEncoder().encode(SessionRequest.configure(.fifteenMinutes))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["command", "refreshInterval"])
        #expect(object["command"] as? String == "configure")
        #expect(object["refreshInterval"] as? Int == 900)
    }
}
