import Foundation
import VikingBarCore

struct SignInFixtureRecord: Codable {
    var summary: AccountConnectionSummary
    var revision: UInt64 = 1
    var connectionID: ConnectionID? = FixtureAccounts.sharedConnection
    var remembered = false
}

@MainActor
final class SignInFixtureStore {
    private struct Records: Codable {
        var version = 1
        var selected = FixtureAccounts.mobile
        var accounts: [String: SignInFixtureRecord] = [:]
    }

    private let store: any SessionStore
    private var records = Records()

    init(url: URL) throws {
        self.store = FileAccountSignInStore(url: url)
        if let data = try self.store.load() {
            let loaded = try JSONDecoder().decode(Records.self, from: data)
            guard loaded.version == 1, FixtureAccounts.signInCatalog.accounts.contains(where: {
                $0.key == loaded.selected
            }) else { throw LiveFailure.storage }
            self.records = loaded
        }
    }

    var selected: AccountKey {
        self.records.selected
    }

    func record(_ key: AccountKey) -> SignInFixtureRecord {
        self.records.accounts[key.id] ?? SignInFixtureRecord(summary: AccountConnectionSummary(
            clientID: key.provider == .mobileVikings ? "demo-public-client" : "",
            username: "alex@example.invalid",
        ))
    }

    func save(_ record: SignInFixtureRecord, key: AccountKey) throws {
        self.records.accounts[key.id] = record
        try self.store.save(JSONEncoder().encode(self.records))
    }

    func select(_ key: AccountKey) throws {
        self.records.selected = key
        try self.store.save(JSONEncoder().encode(self.records))
    }
}

extension AppSession {
    func applySignInFixture() {
        guard let store = self.signInFixtureStore else { return }
        let record = store.record(self.selectedAccount)
        self.liveState.installSignInFixture(summary: record.summary, revision: record.revision,
                                            connection: record.connectionID, remembered: record.remembered)
        if self.usesMobileFixture {
            self.fixture = record.connectionID == nil ? nil : .finite
        }
    }

    func connectSignInFixture(_ input: AccountConnectionInput) -> ConnectionAttempt? {
        guard let store = self.signInFixtureStore, case let .credentials(credentials) = input else { return nil }
        defer { credentials.discard() }
        guard !self.addingAccount, self.activity != .stopped else { return nil }
        do {
            let request = try AccountConnectionRequest.decode(
                credentials.takePayload(),
                for: self.selectedAccount.provider,
            )
            let summary: AccountConnectionSummary = switch request.credentials {
            case let .mobileVikings(value): .init(clientID: value.clientID, username: value.username)
            case let .telenet(value): .init(clientID: "", username: value.username)
            case .fixture: throw ProofFailure.invalidInput
            }
            var record = store.record(self.selectedAccount)
            record.summary = summary
            record.revision &+= 1
            record.connectionID = ConnectionID()
            record.remembered = request.rememberPassword
            try store.save(record, key: self.selectedAccount)
            self.applySignInFixture()
            return self.newFixtureConnectionAttempt()
        } catch { return nil }
    }

    func performSignInFixture(_ action: SignInAction) {
        guard let store = self.signInFixtureStore else { return }
        do {
            var record = store.record(self.selectedAccount)
            record.revision &+= 1
            switch action {
            case .savedSignIn:
                guard record.remembered else { return }
                record.connectionID = ConnectionID()
            case .disableRememberedSignIn: record.remembered = false
            case .logout:
                record.remembered = false
                record.connectionID = nil
            }
            try store.save(record, key: self.selectedAccount)
            self.applySignInFixture()
            self.onPresentationChange?()
        } catch {}
    }
}
