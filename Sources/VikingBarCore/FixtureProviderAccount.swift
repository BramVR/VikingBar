import Foundation

/// Explicit synthetic registrations. Production never registers these factories.
public enum FixtureAccounts {
    public static let mobile = AccountKey.legacy
    public static let sharedConnection = ConnectionID(rawValue: AccountKey.legacy.slot)
    public static let secondMobile = AccountKey(
        provider: .mobileVikings, slot: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
    )
    public static let home = AccountKey(
        provider: .fixtureHome, slot: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
    )
    public static let failing = AccountKey(
        provider: .fixtureHome, slot: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
    )
    public static var catalog: CatalogSnapshot {
        CatalogSnapshot(accounts: [
            AccountEntry(key: self.mobile, label: "Demo · Mobile Vikings"),
            AccountEntry(key: self.secondMobile, label: "Demo · Second Mobile Vikings"),
            AccountEntry(key: self.home, label: "Demo · Home provider"),
            AccountEntry(key: self.failing, label: "Demo · Unavailable home"),
        ], selected: self.mobile)
    }

    public static func registry(at date: Date) -> ProviderRegistry {
        ProviderRegistry(providers: [
            ProviderRegistration(id: .mobileVikings, displayName: "Mobile Vikings",
                                 makeSession: { FixtureProviderAccount(key: $0.key, date: date) }),
            ProviderRegistration(id: .fixtureHome, displayName: "Home fixture",
                                 makeSession: { FixtureProviderAccount(key: $0.key, date: date) }),
        ])
    }
}

public actor FixtureProviderAccount: ProviderAccountSession {
    public nonisolated let key: AccountKey
    private let date: Date
    private var current = LiveSessionState()
    private var selected = "shared-service"
    public init(key: AccountKey, date: Date) {
        self.key = key
        self.date = date
    }

    public func connect(credentials: ProviderCredentials) async throws -> ConnectionID {
        guard case .fixture = credentials else { throw ProofFailure.invalidInput }
        self.current.connectionID = ConnectionID()
        try await self.perform(.refresh)
        return self.current.connectionID!
    }

    public func state() -> LiveSessionState {
        self.current
    }

    public func cancel() {}
    public func perform(_ operation: AccountOperation) async throws {
        switch operation {
        case .cancel: return
        case .configure: return
        case .restore, .refresh: break
        case let .refreshService(id):
            guard ["shared-service", "second-service"].contains(id) else { throw LiveFailure.invalidSelection }
            self.selected = id
        case let .selectService(service):
            guard service.account == self.key, service.kind == self.kind,
                  ["shared-service", "second-service"].contains(service.providerID)
            else {
                throw LiveFailure.invalidSelection
            }
            self.selected = service.providerID
        case .refreshPoints, .refreshInvoices, .refreshHistory, .selectBundle,
             .downloadInvoice, .reviewInvoicePayment, .clearPaymentReview:
            throw LiveFailure.requestDenied
        }
        let services = ["shared-service", "second-service"].enumerated().map { index, id in
            AccountService(key: ServiceKey(account: self.key, kind: self.kind, providerID: id),
                           name: self.kind == .home ? "Example home \(index + 1)" : "Example SIM \(index + 1)")
        }
        self.current.account = AccountContext(
            key: self.key, providerName: self.kind == .home ? "Home fixture" : "Mobile Vikings",
            services: services, selectedService: ServiceKey(
                account: self.key,
                kind: self.kind,
                providerID: self.selected,
            ),
            capabilities: .usageOnly,
        )
        self.current.connectionID = self.current.connectionID ?? FixtureAccounts.sharedConnection
        if self.key == FixtureAccounts.failing {
            self.current.failure = .transport
            self.current.snapshot = UsageSnapshot(source: .fixture(.error), subscriptionName: "Example home",
                                                  allowance: .unavailable, expiresAt: nil, freshness: .unavailable,
                                                  errorMessage: "The synthetic home provider is unavailable.")
            throw LiveFailure.transport
        }
        let total: UInt64 = self.kind == .home ? 1_000_000_000_000 : 80_000_000_000
        let used: UInt64 = self.selected == "shared-service" ? 20_000_000_000 : 40_000_000_000
        self.current.snapshot = UsageSnapshot(
            source: .fixture(.finite), subscriptionName: services.first { $0.key.providerID == self.selected }!.name,
            allowance: .finite(totalBytes: total, usedBytes: used, remainingBytes: total - used),
            expiresAt: self.date.addingTimeInterval(14 * 86400), freshness: .current(lastUpdated: self.date),
        )
        self.current.failure = nil
    }

    private var kind: ServiceKind {
        self.key.provider == .fixtureHome ? .home : .mobile
    }
}
