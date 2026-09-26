import Foundation

public struct ConnectionID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct AccountConnectionSummary: Codable, Equatable, Sendable {
    public let clientID: String
    public let username: String?

    public init(clientID: String, username: String?) {
        self.clientID = clientID
        self.username = username
    }
}

public enum LiveFailure: String, Codable, Error, Sendable {
    case notConnected = "not_connected"
    case reconnectRequired = "reconnect_required"
    case busy
    case storage
    case transport
    case malformedResponse = "malformed_response"
    case unauthorized
    case tokenExpired = "token_expired"
    case connectionChanged = "connection_changed"
    case rateLimited = "rate_limited"
    case serverUnavailable = "server_unavailable"
    case requestDenied = "request_denied"
    case noMobileSubscriptions = "no_mobile_subscriptions"
    case invalidSelection = "invalid_selection"

    public var message: String {
        switch self {
        case .notConnected: "Connect your Mobile Vikings account."
        case .reconnectRequired, .unauthorized: "Reconnect your Mobile Vikings account."
        case .busy: "Another VikingBar session is updating. Try again shortly."
        case .storage: "VikingBar could not save the account session."
        case .transport: "Could not reach Mobile Vikings."
        case .tokenExpired: "The access token expired. Try refreshing again."
        case .connectionChanged: "The account connection changed. Refresh again."
        case .malformedResponse: "Mobile Vikings returned an unsupported response."
        case .rateLimited: "Mobile Vikings requested a pause. Try again later."
        case .serverUnavailable: "Mobile Vikings is temporarily unavailable."
        case .requestDenied: "VikingBar blocked an unsupported request."
        case .noMobileSubscriptions: "No mobile subscriptions are available."
        case .invalidSelection: "The selected subscription or bundle is unavailable."
        }
    }
}

public struct MobileSubscription: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let type: String
}

/// The provider's bundle `type`. Raw values are the wire strings, so cached balances decode unchanged.
public enum BundleKind: String, Codable, CaseIterable, Sendable {
    case data, sms, voice, value

    public var label: String {
        switch self {
        case .data: "Data"
        case .sms: "SMS"
        case .voice: "Calls"
        case .value: "Credit"
        }
    }

    public var bundleName: String {
        switch self {
        case .data: "Data bundle"
        case .sms: "SMS bundle"
        case .voice: "Call bundle"
        case .value: "Credit bundle"
        }
    }
}

public struct MessageCount: Equatable, Sendable {
    public let count: UInt64

    init?(exact amount: Decimal) {
        guard let count = BalanceBundle.exactInteger(amount) else { return nil }
        self.count = count
    }
}

public struct CallDuration: Equatable, Sendable {
    public let seconds: UInt64

    init?(exact amount: Decimal) {
        guard let seconds = BalanceBundle.exactInteger(amount) else { return nil }
        self.seconds = seconds
    }
}

/// The API documents no unit for `value` bundles. Every other money field it returns is EUR, so euros are inferred.
public struct EuroAmount: Equatable, Sendable {
    public let euros: Decimal

    init?(exact amount: Decimal) {
        guard !amount.isNaN, amount >= 0 else { return nil }
        self.euros = amount
    }
}

public enum Metered<Amount: Equatable & Sendable>: Equatable, Sendable {
    case finite(total: Amount, used: Amount, remaining: Amount)
    case unlimited(used: Amount)
    case unavailable
}

public enum BundleBalance: Equatable, Sendable {
    case data(Allowance)
    case sms(Metered<MessageCount>)
    case voice(Metered<CallDuration>)
    case value(Metered<EuroAmount>)
}

public struct BalanceBundle: Codable, Equatable, Sendable {
    public let title: String
    public let description: String
    public let category: String
    public let type: BundleKind
    public let total: Decimal
    public let used: Decimal
    public let remaining: Decimal
    public let validFrom: Date
    public let validUntil: Date

    public func isCurrent(at date: Date) -> Bool {
        self.validFrom <= date && date < self.validUntil
    }

    public func isActive(at date: Date) -> Bool {
        self.type == .data && self.isCurrent(at: date)
    }

    public func allowance(at date: Date) -> Allowance {
        guard self.isActive(at: date), let used = Self.exactInteger(self.used) else { return .unavailable }
        if self.total == -1 {
            return .unlimited(usedBytes: used)
        }
        guard let total = Self.exactInteger(self.total), let remaining = Self.exactInteger(self.remaining) else {
            return .unavailable
        }
        return .finite(totalBytes: total, usedBytes: used, remainingBytes: remaining)
    }

    public func balance(at date: Date) -> BundleBalance {
        switch self.type {
        case .data: .data(self.allowance(at: date))
        case .sms: .sms(self.metered(MessageCount.init(exact:), at: date))
        case .voice: .voice(self.metered(CallDuration.init(exact:), at: date))
        case .value: .value(self.metered(EuroAmount.init(exact:), at: date))
        }
    }

    private func metered<Amount>(_ parse: (Decimal) -> Amount?, at date: Date) -> Metered<Amount> {
        guard self.isCurrent(at: date), let used = parse(self.used) else { return .unavailable }
        if self.total == -1 {
            return .unlimited(used: used)
        }
        guard let total = parse(self.total), let remaining = parse(self.remaining) else { return .unavailable }
        return .finite(total: total, used: used, remaining: remaining)
    }

    static func exactInteger(_ decimal: Decimal) -> UInt64? {
        guard !decimal.isNaN, decimal >= 0, decimal <= Decimal(UInt64.max) else { return nil }
        let value = NSDecimalNumber(decimal: decimal).uint64Value
        return Decimal(value) == decimal ? value : nil
    }
}

public struct LiveBalance: Codable, Equatable, Sendable {
    public let bundles: [BalanceBundle]
    public let regionality: String?
    public let outOfBundleCost: Decimal?
}

public struct LiveSessionState: Codable, Equatable, Sendable {
    public internal(set) var account: AccountContext?
    public internal(set) var homeUsage: HomeUsage?
    public internal(set) var homeFailure: LiveFailure?
    public internal(set) var connectionID: ConnectionID?
    public internal(set) var connectionSummary: AccountConnectionSummary?
    public internal(set) var subscriptions: [MobileSubscription] = []
    public internal(set) var selectedSubscriptionID: String?
    public internal(set) var balance: LiveBalance?
    public internal(set) var invoices: InvoiceSnapshot?
    public internal(set) var invoiceFailure: LiveFailure?
    public internal(set) var invoiceDocument: InvoiceDocument?
    public internal(set) var paymentReview: PaymentReview?
    public internal(set) var points: CustomerPoints?
    public internal(set) var selectedBundleIndex: Int?
    public internal(set) var historyRevision: UUID?
    public internal(set) var history: UsageHistory?
    public internal(set) var snapshot: UsageSnapshot = .notConnected
    public internal(set) var failure: LiveFailure?
    public internal(set) var nextRefreshAt: Date?
    public internal(set) var isRefreshing = false
    public internal(set) var scopeMismatch = false

    public init() {}
}

public extension LiveSessionState {
    mutating func mergePoints(from state: LiveSessionState) {
        guard self.account?.key == state.account?.key, self.connectionID == state.connectionID else { return }
        self.points = state.points
    }

    mutating func mergeInvoices(from state: LiveSessionState, includePaymentReview: Bool = true) {
        guard self.account?.key == state.account?.key, self.connectionID == state.connectionID else { return }
        self.invoices = state.invoices
        self.invoiceFailure = state.invoiceFailure
        if includePaymentReview {
            self.paymentReview = state.paymentReview
        }
    }

    mutating func setPaymentReview(_ review: PaymentReview?) {
        self.paymentReview = review
    }

    mutating func installPaymentFixture(at now: Date) {
        self.invoices = InvoicePaymentFixture.snapshot(at: now)
        self.invoiceFailure = nil
        self.paymentReview = nil
    }
}
