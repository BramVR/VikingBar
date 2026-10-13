import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct ReferenceSelectionTests {
    @Test func `reference selection cannot follow another disconnected slot with an identical fence`() async throws {
        let directory = ReferenceSelectionDirectory()
        let connector = ModelTestConnector(fails: true)
        var targets: [AccountKey] = []
        var disconnected = LiveSessionState()
        disconnected.installSignInFixture(summary: .init(clientID: "public", username: "reader"), revision: 4,
                                          connection: nil, remembered: false)
        let client = ModelTestClient(state: disconnected)
        let app = try AppSession(options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
                                 clientFactory: { _ in client },
                                 connectorFactory: { targets.append($0); return connector },
                                 accountDirectory: directory)
        app.liveState = disconnected
        app.start()
        try await AppSessionTests.until { app.activity == .idle }
        let intent = app.referenceIntent(rememberPassword: true)
        #expect(intent.account == .legacy)
        #expect(intent.provider == .mobileVikings)
        app.selectAccount(FixtureAccounts.secondMobile)
        try await AppSessionTests.until { app.activity == .idle }
        #expect(app.liveState.signIn?.fence == intent.expected)
        #expect(app.selectedAccount == FixtureAccounts.secondMobile)
        let reference = URL(fileURLWithPath: "/synthetic/reference")
        #expect(app.connect(reference: reference, intent: intent, resultURL: nil) == nil)
        #expect(targets == [])
        #expect(directory.reservations == [])
        let current = app.referenceIntent(rememberPassword: false)
        _ = try #require(app.connect(reference: reference, intent: current, resultURL: nil))
        try await AppSessionTests.until { app.activity == .idle }
        #expect(targets == [FixtureAccounts.secondMobile])
        #expect(connector.connects == 1)
        await app.stop()
    }

    @Test(arguments: [false, true])
    func `reference add selection stops before reservation when provider or add mode changed`(
        modeChanged: Bool,
    ) async throws {
        let directory = ReferenceSelectionDirectory()
        let connector = ModelTestConnector(fails: true)
        var targets: [AccountKey] = []
        let client = ModelTestClient()
        let app = try AppSession(options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
                                 clientFactory: { _ in client },
                                 connectorFactory: { targets.append($0); return connector },
                                 accountDirectory: directory)
        app.addingAccount = true
        app.addingProvider = .mobileVikings
        let intent = app.referenceIntent(rememberPassword: true)
        app.addingAccount = false
        #expect(intent.adding)
        #expect(intent.provider == .mobileVikings)
        if modeChanged {
            app.addingAccount = true
        } else {
            app.addingProvider = .telenet
        }
        let reference = URL(fileURLWithPath: "/synthetic/reference")
        #expect(app.connect(reference: reference, intent: intent, resultURL: nil) == nil)
        #expect(directory.reservations == [])
        #expect(targets == [])
        #expect(app.activity == .idle)
        app.addingAccount = false
        app.addingProvider = .mobileVikings
        _ = try #require(app.connect(reference: reference, intent: intent, resultURL: nil))
        try await AppSessionTests.until { app.activity == .idle }
        #expect(directory.reservations == [.mobileVikings])
        #expect(targets == [directory.added])
        #expect(connector.connects == 1)
        await app.stop()
    }
}

@MainActor
private final class ReferenceSelectionDirectory: AccountDirectoryClient {
    private var catalog = CatalogSnapshot(accounts: [AccountEntry(key: .legacy, label: "First"),
                                                     AccountEntry(key: FixtureAccounts.secondMobile, label: "Second")],
                                          selected: .legacy)
    let added = AccountKey(provider: .mobileVikings)
    var reservations: [ProviderID] = []

    func snapshot() async throws -> CatalogSnapshot {
        self.catalog
    }

    func select(_ key: AccountKey, replacing _: AccountKey?) async throws {
        self.catalog.selected = key
    }

    func reserve(provider: ProviderID) async throws -> AccountEntry {
        self.reservations.append(provider)
        let entry = AccountEntry(key: self.added, label: "Added")
        self.catalog.accounts.append(entry)
        return entry
    }
}
