import Foundation

public struct AccountService: Codable, Equatable, Sendable {
    public let key: ServiceKey
    public let name: String
    public init(key: ServiceKey, name: String) {
        self.key = key; self.name = name
    }
}

public struct AccountCapabilities: Codable, Equatable, Sendable {
    public let points: Bool
    public let invoices: Bool
    public let history: Bool
    public static let mobileVikings = Self(points: true, invoices: true, history: true)
    public static let usageOnly = Self(points: false, invoices: false, history: false)
}

public struct AccountContext: Codable, Equatable, Sendable {
    public let key: AccountKey
    public let providerName: String
    public let services: [AccountService]
    public let selectedService: ServiceKey?
    public let capabilities: AccountCapabilities
    public init(
        key: AccountKey, providerName: String, services: [AccountService],
        selectedService: ServiceKey?, capabilities: AccountCapabilities,
    ) {
        self.key = key
        self.providerName = providerName
        self.services = services
        self.selectedService = selectedService
        self.capabilities = capabilities
    }
}

public enum AccountOperation: Sendable {
    case restore, refresh, refreshHistory, refreshPoints, refreshInvoices, clearPaymentReview, cancel
    case downloadInvoice(String), reviewInvoicePayment(String?)
    case refreshService(String), selectService(ServiceKey), selectBundle(Int), configure(RefreshInterval)
}

public enum ProviderCredentials: Sendable {
    case mobileVikings(ProofCredentials)
    case telenet(TelenetCredentials)
    case fixture
}

public enum CredentialField: String, Codable, Sendable { case clientID, username, password }

public extension ProviderCredentials {
    static func decode(_ data: Data, for provider: ProviderID) throws -> Self {
        if provider == .telenet {
            return try .telenet(TelenetCredentials.decode(data))
        }
        guard provider == .mobileVikings,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["client_id", "username", "password"] else { throw ProofFailure.invalidInput }
        let credentials = try JSONDecoder().decode(ProofCredentials.self, from: data)
        try credentials.validate()
        return .mobileVikings(credentials)
    }
}

public protocol ProviderAccountSession: Sendable {
    var key: AccountKey { get }
    func perform(_ operation: AccountOperation) async throws
    func state() async -> LiveSessionState
    func connect(credentials: ProviderCredentials) async throws -> ConnectionID
    func cancel() async
}

public struct ProviderRegistration: Sendable {
    public let id: ProviderID
    public let displayName: String
    public let credentialFields: [CredentialField]
    public let makeSession: @Sendable (AccountStorage) throws -> any ProviderAccountSession
    public init(
        id: ProviderID, displayName: String,
        makeSession: @escaping @Sendable (AccountStorage) throws -> any ProviderAccountSession,
    ) {
        self.id = id
        self.displayName = displayName
        self.credentialFields = id == .telenet ? [.username, .password] : [.clientID, .username, .password]
        self.makeSession = makeSession
    }
}

public struct ProviderRegistry: Sendable {
    public let providers: [ProviderRegistration]
    public init(providers: [ProviderRegistration]) {
        self.providers = providers
    }

    public static let production = Self(providers: [ProviderRegistration(
        id: .mobileVikings, displayName: "Mobile Vikings",
        makeSession: { try MobileVikingsAccount(key: $0.key, session: VikingSession.production(storage: $0)) },
    ), ProviderRegistration(
        id: .telenet,
        displayName: "Telenet",
        makeSession: { try TelenetHomeAccount.production(storage: $0) },
    )])
    public func registration(_ id: ProviderID) throws -> ProviderRegistration {
        guard let registration = self.providers.first(where: { $0.id == id }) else {
            throw LiveFailure.invalidSelection
        }
        return registration
    }

    public func open(_ key: AccountKey, catalog: AccountCatalog) throws -> any ProviderAccountSession {
        let registration = try self.registration(key.provider)
        _ = try catalog.resolve(key)
        return try registration.makeSession(AccountStorage(root: catalog.root, key: key))
    }
}

public struct MobileVikingsAccount: ProviderAccountSession {
    public let key: AccountKey
    private let session: VikingSession
    public init(key: AccountKey, session: VikingSession) {
        self.key = key; self.session = session
    }

    public func state() async -> LiveSessionState {
        var state = await self.session.state()
        state.account = AccountContext(
            key: self.key, providerName: "Mobile Vikings",
            services: state.subscriptions.map { AccountService(
                key: ServiceKey(account: self.key, kind: .mobile, providerID: $0.id), name: $0.displayName,
            ) },
            selectedService: state.selectedSubscriptionID.map {
                ServiceKey(account: self.key, kind: .mobile, providerID: $0)
            }, capabilities: .mobileVikings,
        )
        return state
    }

    public func connect(credentials: ProviderCredentials) async throws -> ConnectionID {
        guard case let .mobileVikings(input) = credentials else { throw ProofFailure.invalidInput }
        let state = try await self.session.bootstrapWithDiagnostics(credentials: input)
        guard let connection = state.connectionID, state.failure == nil else { throw BootstrapFailure.connectFailed }
        return connection
    }

    public func cancel() async {
        await self.session.cancel()
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func perform(_ operation: AccountOperation) async throws {
        await self.session.clearInvoiceDocument()
        switch operation {
        case .restore: _ = try await self.session.restore()
        case .refresh: _ = try await self.session.refresh()
        case let .refreshService(id):
            _ = try ProofEndpoint.balance(subscriptionID: id).request()
            _ = try await self.session.refresh(subscriptionID: id)
        case .refreshHistory: _ = try await self.session.refreshHistory()
        case .refreshPoints: _ = try await self.session.refreshPoints()
        case .refreshInvoices: _ = try await self.session.refreshInvoices()
        case let .downloadInvoice(id): _ = try await self.session.downloadInvoice(id: id)
        case let .reviewInvoicePayment(id): _ = try await self.session.reviewInvoicePayment(id: id)
        case .clearPaymentReview: await self.session.clearPaymentReview()
        case let .configure(interval): _ = await self.session.configure(refreshInterval: interval)
        case let .selectBundle(index): _ = try await self.session.selectBundle(index: index)
        case let .selectService(service):
            guard service.account == self.key, service.kind == .mobile else { throw LiveFailure.invalidSelection }
            _ = try ProofEndpoint.balance(subscriptionID: service.providerID).request()
            _ = try await self.session.selectSubscription(id: service.providerID)
        case .cancel: await self.cancel()
        }
    }
}
