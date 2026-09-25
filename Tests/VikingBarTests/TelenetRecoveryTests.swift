import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

struct TelenetRecoveryTests {
    @Test func `explicit reconnect replaces an invalid stored session with a usable connection`() async throws {
        let rig = try HomeRig()
        try rig.store.save(Data("invalid stored session".utf8))
        let account = rig.account()
        await #expect(throws: LiveFailure.reconnectRequired) { try await account.perform(.restore) }
        await rig.transport.enableLogin()
        let connection = try await account.connect(credentials: .telenet(TelenetCredentials(
            username: "reader", password: "correct",
        )))
        let connected = await account.state()
        #expect(connected.connectionID == connection)
        #expect(connected.failure == nil)
        #expect(connected.selectedHomeUsage?.downloaded?.totalGB == 60)
        let restored = rig.account()
        try await restored.perform(.restore)
        #expect(await restored.state().connectionID == connection)
        #expect(await restored.state().selectedHomeUsage == connected.selectedHomeUsage)
    }

    @Test func `failed reconnect from a fresh process preserves the last reading and connection`() async throws {
        let rig = try HomeRig()
        let first = rig.account()
        try await first.perform(.refresh)
        let previous = await first.state()
        rig.clock.advance(61)
        await rig.transport.fail(pathSuffix: "/userdetails", status: 500)
        let fresh = rig.account()
        await #expect(throws: LiveFailure.serverUnavailable) {
            try await fresh.connect(credentials: .telenet(TelenetCredentials(
                username: "synthetic",
                password: "synthetic",
            )))
        }
        let failed = await fresh.state()
        #expect(failed.connectionID == previous.connectionID)
        #expect(failed.selectedHomeUsage == previous.selectedHomeUsage)
        #expect(failed.failure == .serverUnavailable)
        #expect(try failed.snapshot.freshness == .stale(lastUpdated: #require(previous.selectedHomeUsage?.fetchedAt)))
        let restored = rig.account()
        try await restored.perform(.restore)
        #expect(await restored.state().connectionID == previous.connectionID)
        #expect(await restored.state().selectedHomeUsage == previous.selectedHomeUsage)
        #expect(await restored.state().snapshot.allowance == previous.snapshot.allowance)
    }

    @MainActor @Test func `failed replacement authorization keeps the stored session usable after its cooldown`(
    ) async throws {
        let rig = try HomeRig()
        let initial = rig.account()
        try await initial.perform(.refresh)
        let original = await initial.state()
        rig.clock.advance(61)
        await rig.transport.fail(pathSuffix: "/userdetails", status: 403)
        let replacement = rig.account()
        await #expect(throws: LiveFailure.unauthorized) {
            try await replacement.connect(credentials: .telenet(TelenetCredentials(
                username: "replacement",
                password: "wrong",
            )))
        }
        let rejected = await replacement.state()
        #expect(rejected.connectionID == original.connectionID)
        #expect(rejected.selectedHomeUsage == original.selectedHomeUsage)
        #expect(rejected.failure == original.failure)
        let client = ModelTestClient(state: rejected)
        let app = try AppSession(
            options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { _ in client }, accountDirectory: RecoveryAccountDirectory(key: rig.key),
            now: { rig.clock.now }, sleepUntil: { _ in try await Task.sleep(for: .seconds(3600)) },
        )
        app.start()
        try await AppSessionTests.until { app.activity == .idle }
        #expect(app.isConnected)
        #expect(app.canRefresh)
        await app.stop()
        let deadline = try #require(rejected.nextRefreshAt)
        rig.clock.advance(deadline.timeIntervalSince(rig.clock.now) + 1)
        await rig.transport.clearFailure()
        let restored = rig.account()
        try await restored.perform(.restore)
        try await restored.perform(.refresh)
        let refreshed = await restored.state()
        #expect(refreshed.connectionID == original.connectionID)
        #expect(refreshed.failure == nil)
        #expect(refreshed.selectedHomeUsage?.fetchedAt == rig.clock.now)
        #expect(await rig.transport.requests.suffix(4).allSatisfy {
            $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Cookie") == "session=synthetic"
        })
    }

    @Test(arguments: [true, false])
    func `explicit corrected login uses the minute floor after authentication failure`(
        storedFailure: Bool,
    ) async throws {
        let rig = try HomeRig()
        let account = rig.account()
        try await account.perform(.refresh)
        let original = await account.state()
        rig.clock.advance(61)
        if storedFailure {
            await rig.transport.fail(pathSuffix: "/usage", status: 401)
            await #expect(throws: LiveFailure.unauthorized) { try await account.perform(.refresh) }
        } else {
            await rig.transport.fail(pathSuffix: "/userdetails", status: 403)
            await #expect(throws: LiveFailure.unauthorized) {
                try await account.connect(credentials: .telenet(TelenetCredentials(
                    username: "reader",
                    password: "wrong",
                )))
            }
        }
        let recovery = rig.account()
        await #expect(throws: LiveFailure.rateLimited) {
            try await recovery.connect(credentials: .telenet(TelenetCredentials(
                username: "reader",
                password: "correct",
            )))
        }
        rig.clock.advance(61)
        await rig.transport.clearFailure()
        await rig.transport.enableLogin()
        let connection = try await recovery.connect(credentials: .telenet(TelenetCredentials(
            username: "reader",
            password: "correct",
        )))
        let recovered = await recovery.state()
        #expect(connection != original.connectionID)
        #expect(recovered.failure == nil)
        #expect(recovered.selectedHomeUsage?.fetchedAt == rig.clock.now)
        #expect(recovered.selectedHomeUsage?.downloaded?.totalGB == 60)
        #expect(await rig.transport.requests.filter { $0.url?.path == "/idp/idx/challenge/answer" }.count == 1)
    }

    @Test func `explicit reconnect retains the server retry deadline across processes`() async throws {
        let rig = try HomeRig()
        let account = rig.account()
        try await account.perform(.refresh)
        rig.clock.advance(61)
        await rig.transport.fail(pathSuffix: "/usage", status: 429, retry: "7200")
        await #expect(throws: LiveFailure.rateLimited) { try await account.perform(.refresh) }
        rig.clock.advance(61)
        let count = await rig.transport.requests.count
        let recovery = rig.account()
        await #expect(throws: LiveFailure.rateLimited) {
            try await recovery.connect(credentials: .telenet(TelenetCredentials(
                username: "reader",
                password: "correct",
            )))
        }
        #expect(await rig.transport.requests.count == count)
        rig.clock.advance(7140)
        await rig.transport.clearFailure()
        await rig.transport.enableLogin()
        _ = try await recovery.connect(credentials: .telenet(TelenetCredentials(
            username: "reader",
            password: "correct",
        )))
        #expect(await recovery.state().failure == nil)
        #expect(await recovery.state().selectedHomeUsage?.downloaded?.totalGB == 60)
    }
}

private struct RecoveryAccountDirectory: AccountDirectoryClient {
    let key: AccountKey
    func snapshot() async throws -> CatalogSnapshot {
        CatalogSnapshot(accounts: [AccountEntry(key: self.key, label: "Synthetic Telenet")], selected: self.key)
    }

    func select(_ key: AccountKey, replacing _: AccountKey?) async throws {
        guard key == self.key else { throw LiveFailure.invalidSelection }
    }

    func reserve(provider _: ProviderID) async throws -> AccountEntry {
        throw LiveFailure.invalidSelection
    }
}
