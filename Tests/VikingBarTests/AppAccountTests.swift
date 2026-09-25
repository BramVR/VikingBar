import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct AppAccountTests {
    @Test func `fixture switching shows target home and restores prior mobile after failure`() async throws {
        let app = try AppSession(options: LaunchOptions(arguments: ["--fixture", "finite"]),
                                 preferences: MenuBarPreferences(fileURL: nil), referenceDate: LiveModelsTests.now)
        let original = app.snapshot
        app.selectAccount(FixtureAccounts.home)
        #expect(app.snapshot.allowance == .unavailable)
        #expect(app.providerName == "Home fixture")
        #expect(!app.supportsPoints && !app.supportsInvoices)
        try await AppSessionTests.until { app.activity == .idle }
        #expect(app.selectedServiceKind == .home)
        #expect(app.subscriptions.map(\.title) == ["Example home 1", "Example home 2"])
        #expect(app.bundles.isEmpty)
        #expect(app.card.value == "980.00 GB")
        app.selectSubscription("second-service")
        try await AppSessionTests.until { app.activity == .idle }
        #expect(app.card.value == "960.00 GB")
        app.selectAccount(FixtureAccounts.failing)
        try await AppSessionTests.until { app.activity == .idle }
        #expect(app.snapshot.allowance == .unavailable)
        #expect(app.providerName == "Home fixture")
        app.selectAccount(FixtureAccounts.mobile)
        #expect(app.snapshot == original)
        try await AppSessionTests.until { app.activity == .idle }
        await app.stop()
    }

    @Test func `late old account reply cannot replace selected account with same connection ID`() async throws {
        let first = ModelTestClient(state: AppSessionTests.connected())
        var bState = first.state
        bState.account = AccountContext(key: FixtureAccounts.home, providerName: "Home fixture", services: [],
                                        selectedService: nil, capabilities: .usageOnly)
        bState.snapshot = .notConnected
        let second = ModelTestClient(state: bState)
        let directory = FixtureAccountDirectory()
        let app = try AppSession(options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
                                 clientFactory: { $0 == .legacy ? first : second }, accountDirectory: directory,
                                 now: { LiveModelsTests.now },
                                 sleepUntil: { _ in try await Task.sleep(for: .seconds(3600)) })
        app.start()
        try await AppSessionTests.until { app.activity == .idle }
        first.holdRefresh = true
        app.refresh()
        try await AppSessionTests.until { first.pendingRefresh != nil }
        app.selectAccount(FixtureAccounts.home)
        #expect(app.snapshot.allowance == .unavailable)
        try await AppSessionTests.until { app.activity == .idle }
        first.releaseRefresh(.success(first.state))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(app.selectedAccount == FixtureAccounts.home)
        #expect(app.liveState.account?.key == FixtureAccounts.home)
        #expect(app.snapshot.allowance == .unavailable)
        app.selectAccount(.legacy)
        #expect(app.snapshot.allowance == first.state.snapshot.allowance)
        first.holdRefresh = false
        try await AppSessionTests.until { app.activity == .idle }
        await app.stop()
    }

    @Test func `reference callback carries add intent after form dismissal`() throws {
        let app = try AppSession(options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil))
        app.addingAccount = true
        var addIntent: Bool?
        let form = ConnectionForm(session: app, resultURL: nil, reference: { addIntent = $0 },
                                  dismiss: { app.addingAccount = false })
        form.connectReference()
        #expect(app.addingAccount == false)
        #expect(addIntent == true)
    }

    @Test func `account selection disables overlapping catalog commits`() async throws {
        let directory = HeldAccountDirectory()
        let client = ModelTestClient(state: AppSessionTests.connected())
        let app = try AppSession(options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
                                 clientFactory: { _ in client }, accountDirectory: directory,
                                 now: { LiveModelsTests.now },
                                 sleepUntil: { _ in try await Task.sleep(for: .seconds(3600)) })
        app.start()
        try await AppSessionTests.until { app.activity == .idle }
        directory.hold = true
        app.selectAccount(FixtureAccounts.home)
        try await AppSessionTests.until { directory.pending != nil }
        app.selectAccount(FixtureAccounts.secondMobile)
        #expect(app.selectedAccount == FixtureAccounts.home)
        #expect(directory.selections == [FixtureAccounts.home])
        directory.release()
        try await AppSessionTests.until { app.activity == .idle }
        #expect(try await directory.snapshot().selected == FixtureAccounts.home)
        app.selectAccount(FixtureAccounts.secondMobile)
        try await AppSessionTests.until { app.activity == .idle }
        #expect(try await directory.snapshot().selected == FixtureAccounts.secondMobile)
        await app.stop()
    }

    @Test func `cancelled add during post-login restore returns to prior account`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = TestCatalogDirectory(catalog: AccountCatalog(root: root))
        let original = ModelTestClient(state: AppSessionTests.connected())
        let added = ModelTestClient(state: AppSessionTests.connected())
        added.holdRestore = true
        let connector = ModelTestConnector(fails: false)
        var target: AccountKey?
        let app = try AppSession(options: LaunchOptions(arguments: []),
                                 preferences: MenuBarPreferences(fileURL: nil),
                                 clientFactory: { $0 == .legacy ? original : added },
                                 connectorFactory: { target = $0; return connector }, accountDirectory: directory,
                                 now: { LiveModelsTests.now },
                                 sleepUntil: { _ in try await Task.sleep(for: .seconds(3600)) })
        app.start()
        try await AppSessionTests.until { app.activity == .idle }
        let previous = app.snapshot
        let attempt = try #require(app.connect(input: .reference(URL(fileURLWithPath: "/synthetic")),
                                               resultURL: nil, adding: true))
        try await AppSessionTests.until { added.pendingRestore != nil }
        #expect(app.isConnecting(attempt))
        #expect(app.selectedAccount == target)
        #expect(try await directory.snapshot().selected == target)
        #expect(await app.cancelConnection(attempt))
        #expect(app.activity == .idle)
        #expect(app.selectedAccount == .legacy)
        #expect(try await directory.snapshot().selected == .legacy)
        #expect(try await directory.snapshot().accounts.contains { $0.key == target })
        #expect(app.snapshot == previous)
        #expect(added.shutdowns == 1)
        #expect(app.bridgeError == nil)
        await app.stop()
    }

    @Test(arguments: [false, true])
    func `unsuccessful add restores a usable worker before returning idle`(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = TestCatalogDirectory(catalog: AccountCatalog(root: root))
        let original = ActiveAccountClient()
        let resumed = ActiveAccountClient()
        let connector = ModelTestConnector(fails: !cancel)
        connector.holdConnect = cancel
        var clients = 0
        let app = try AppSession(options: LaunchOptions(arguments: []),
                                 preferences: MenuBarPreferences(fileURL: nil),
                                 clientFactory: { _ in clients += 1; return clients == 1 ? original : resumed },
                                 connectorFactory: { _ in connector }, accountDirectory: directory,
                                 now: { LiveModelsTests.now },
                                 sleepUntil: { _ in try await Task.sleep(for: .seconds(3600)) })
        app.start()
        try await AppSessionTests.until { app.activity == .idle }
        let attempt = try #require(app.connect(input: .reference(URL(fileURLWithPath: "/synthetic")),
                                               resultURL: nil, adding: true))
        try await AppSessionTests.until { connector.connects == 1 }
        if cancel {
            #expect(await app.cancelConnection(attempt))
        }
        try await AppSessionTests.until { app.activity == .idle }
        #expect(clients == 2)
        #expect(original.stopped)
        #expect(resumed.restores == 1)
        #expect(app.canSelectAccountData)
        app.selectSubscription("second-sim")
        try await AppSessionTests.until { app.activity == .idle }
        #expect(app.selectedSubscriptionID == "second-sim")
        app.selectBundle(1)
        try await AppSessionTests.until { app.activity == .idle }
        #expect(app.selectedBundleIndex == 1)
        app.loadInvoices()
        try await AppSessionTests.until { resumed.invoices == 1 }
        #expect(app.bridgeError == nil)
        await app.stop()
    }

    @Test func `overlapping activation and refresh share one catalog read without stopping worker`() async throws {
        let directory = HeldSnapshotDirectory()
        let client = ModelTestClient(state: AppSessionTests.connected())
        var clients = 0
        let app = try AppSession(options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
                                 clientFactory: { _ in clients += 1; return client }, accountDirectory: directory,
                                 now: { LiveModelsTests.now },
                                 sleepUntil: { _ in try await Task.sleep(for: .seconds(3600)) })
        app.start()
        try await AppSessionTests.until { app.activity == .idle }
        directory.hold = true
        app.reloadAccounts()
        try await AppSessionTests.until { directory.pending != nil }
        app.reloadAccounts()
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        app.refresh()
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(directory.reads == 2)
        directory.release()
        try await AppSessionTests.until { app.activity == .idle }
        #expect(directory.reads == 2)
        #expect(client.shutdowns == 0)
        #expect(clients == 1)
        #expect(app.bridgeError == nil)
        #expect(client.requests.filter { $0 == "refresh" }.count == 2)
        await app.stop()
    }

    @Test func `failed and cancelled additions retain prior selection with retryable reserved slot`() async throws {
        for cancel in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = TestCatalogDirectory(catalog: AccountCatalog(root: root))
            let client = ModelTestClient(state: AppSessionTests.connected())
            let connector = ModelTestConnector(fails: !cancel)
            connector.holdConnect = cancel
            var target: AccountKey?
            let app = try AppSession(options: LaunchOptions(arguments: []),
                                     preferences: MenuBarPreferences(fileURL: nil), clientFactory: { _ in client },
                                     connectorFactory: { target = $0; return connector }, accountDirectory: directory,
                                     now: { LiveModelsTests.now },
                                     sleepUntil: { _ in try await Task.sleep(for: .seconds(3600)) })
            app.start()
            try await AppSessionTests.until { app.activity == .idle }
            app.addingAccount = true
            let attempt = try #require(app.connect(
                input: .reference(URL(fileURLWithPath: "/synthetic")),
                resultURL: nil,
            ))
            try await AppSessionTests.until { connector.connects == 1 }
            if cancel {
                _ = await app.cancelConnection(attempt)
            }
            try await AppSessionTests.until { app.activity == .idle }
            #expect(app.selectedAccount == .legacy)
            #expect(app.liveState.connectionID == client.state.connectionID)
            #expect(app.snapshot.freshness == client.state.snapshot.freshness)
            #expect(app.bridgeError == nil)
            #expect(cancel || app.connectionError != nil)
            let catalog = try await directory.snapshot()
            #expect(catalog.accounts.count == 2)
            #expect(catalog.selected == .legacy)
            #expect(target != .legacy)
            #expect(catalog.accounts.contains { $0.key == target })
            await app.stop()
        }
    }
}

struct TestCatalogDirectory: AccountDirectoryClient {
    let catalog: AccountCatalog
    func snapshot() async throws -> CatalogSnapshot {
        try self.catalog.snapshot()
    }

    func select(_ key: AccountKey, replacing expected: AccountKey?) async throws {
        try self.catalog.select(key, replacing: expected)
    }

    func reserve(provider: ProviderID) async throws -> AccountEntry {
        try self.catalog.reserve(provider: provider, label: "Test account")
    }
}

@MainActor
private final class HeldAccountDirectory: AccountDirectoryClient {
    var catalog = FixtureAccounts.catalog
    var hold = false
    var pending: CheckedContinuation<Void, Never>?
    var selections: [AccountKey] = []
    func snapshot() async throws -> CatalogSnapshot {
        self.catalog
    }

    func reserve(provider _: ProviderID) async throws -> AccountEntry {
        throw LiveFailure.requestDenied
    }

    func select(_ key: AccountKey, replacing expected: AccountKey?) async throws {
        self.selections.append(key)
        if self.hold {
            await withCheckedContinuation { self.pending = $0 }
        }
        if expected == nil || self.catalog.selected == expected {
            self.catalog.selected = key
        }
    }

    func release() {
        self.hold = false
        self.pending?.resume()
        self.pending = nil
    }
}

@MainActor
private final class ActiveAccountClient: SessionClient {
    var current = AppSessionTests.connected()
    var stopped = false
    var restores = 0
    var invoices = 0
    func request(_ request: SessionRequest) async throws -> LiveSessionState {
        guard !self.stopped else { throw LiveBridgeFailure.stopped }
        switch request {
        case .restore: self.restores += 1
        case let .selectSubscription(id): self.current.selectedSubscriptionID = id
        case let .selectBundle(index): self.current.selectedBundleIndex = index
        case .refreshInvoices: self.invoices += 1
        default: break
        }
        return self.current
    }

    func shutdown() async {
        self.stopped = true
    }
}

@MainActor
private final class HeldSnapshotDirectory: AccountDirectoryClient {
    var reads = 0
    var hold = false
    var pending: CheckedContinuation<Void, Never>?
    func snapshot() async throws -> CatalogSnapshot {
        self.reads += 1
        guard self.pending == nil else { throw LiveFailure.busy }
        if self.hold {
            await withCheckedContinuation { self.pending = $0 }
        }
        return FixtureAccounts.catalog
    }

    func reserve(provider _: ProviderID) async throws -> AccountEntry {
        throw LiveFailure.requestDenied
    }

    func select(_: AccountKey, replacing _: AccountKey?) async throws {
        throw LiveFailure.requestDenied
    }

    func release() {
        self.hold = false
        self.pending?.resume()
        self.pending = nil
    }
}
