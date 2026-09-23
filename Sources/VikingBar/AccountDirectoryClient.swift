import Foundation
import VikingBarCore

protocol AccountDirectoryClient: Sendable {
    func snapshot() async throws -> CatalogSnapshot
    func reserve(provider: ProviderID) async throws -> AccountEntry
    func select(_ key: AccountKey, replacing expected: AccountKey?) async throws
}

extension AccountDirectoryClient {
    func select(_ key: AccountKey) async throws {
        try await self.select(key, replacing: nil)
    }
}

struct ProcessAccountDirectory: AccountDirectoryClient {
    let executableURL: URL
    func snapshot() async throws -> CatalogSnapshot {
        try await self.run(["accounts", "list"])
    }

    func reserve(provider: ProviderID) async throws -> AccountEntry {
        try await self.run(["accounts", "add", "--provider", provider.rawValue])
    }

    func select(_ key: AccountKey, replacing expected: AccountKey?) async throws {
        let arguments = ["accounts", "select", key.id] + (expected.map { ["--if-selected", $0.id] } ?? [])
        let _: CatalogSnapshot = try await self.run(arguments)
    }

    private func run<Value: Decodable>(_ arguments: [String]) async throws -> Value {
        let child = try OwnedProcess.launch(executable: self.executableURL, arguments: arguments)
        try child.input.close()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            await child.stop()
        }
        defer { timeout.cancel() }
        do {
            var data = Data()
            while let chunk = try await OwnedProcess.readChunk(from: child.output, limit: 4096) {
                data.append(chunk)
                guard data.count <= 1_048_576 else { throw LiveBridgeFailure.invalidReply }
            }
            await child.finish()
            guard child.process.terminationStatus == 0 else { throw LiveBridgeFailure.unavailable }
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            await child.stop()
            throw error
        }
    }
}

actor FixtureAccountDirectory: AccountDirectoryClient {
    private var catalog = FixtureAccounts.catalog
    func snapshot() -> CatalogSnapshot {
        self.catalog
    }

    func reserve(provider _: ProviderID) throws -> AccountEntry {
        throw LiveFailure.requestDenied
    }

    func select(_ key: AccountKey, replacing expected: AccountKey?) throws {
        guard self.catalog.accounts.contains(where: { $0.key == key }) else { throw LiveFailure.invalidSelection }
        if expected == nil || self.catalog.selected == expected {
            self.catalog.selected = key
        }
    }
}

struct FixtureSessionClient: SessionClient {
    let session: any ProviderAccountSession
    // swiftlint:disable:next cyclomatic_complexity
    func request(_ request: SessionRequest) async throws -> LiveSessionState {
        let operation: AccountOperation = switch request {
        case .restore: .restore
        case .refresh: .refresh
        case .refreshPoints: .refreshPoints
        case .refreshInvoices: .refreshInvoices
        case .refreshHistory: .refreshHistory
        case .clearPaymentReview: .clearPaymentReview
        case .cancel, .shutdown: .cancel
        case let .downloadInvoice(id): .downloadInvoice(id)
        case let .reviewInvoicePayment(id): .reviewInvoicePayment(id)
        case let .selectService(key): .selectService(key)
        case let .selectSubscription(id):
            .selectService(ServiceKey(account: self.session.key, kind: .mobile, providerID: id))
        case let .selectBundle(index): .selectBundle(index)
        case let .configure(interval): .configure(interval)
        }
        do { try await self.session.perform(operation) } catch {
            let state = await self.session.state()
            guard state.account != nil else { throw error }
            return state
        }
        return await self.session.state()
    }

    func shutdown() async {
        await self.session.cancel()
    }
}
