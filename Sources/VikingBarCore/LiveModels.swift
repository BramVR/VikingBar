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

public struct BalanceBundle: Codable, Equatable, Sendable {
    public let title: String
    public let description: String
    public let category: String
    public let type: String
    public let total: Decimal
    public let used: Decimal
    public let remaining: Decimal
    public let validFrom: Date
    public let validUntil: Date

    public func isActive(at date: Date) -> Bool {
        self.type == "data" && self.validFrom <= date && date < self.validUntil
    }

    public func allowance(at date: Date) -> Allowance {
        guard self.isActive(at: date), let used = Self.exactBytes(self.used) else { return .unavailable }
        if self.total == -1 {
            return .unlimited(usedBytes: used)
        }
        guard let total = Self.exactBytes(self.total), let remaining = Self.exactBytes(self.remaining) else {
            return .unavailable
        }
        return .finite(totalBytes: total, usedBytes: used, remainingBytes: remaining)
    }

    private static func exactBytes(_ decimal: Decimal) -> UInt64? {
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
    public internal(set) var connectionID: ConnectionID?
    public internal(set) var connectionSummary: AccountConnectionSummary?
    public internal(set) var subscriptions: [MobileSubscription] = []
    public internal(set) var selectedSubscriptionID: String?
    public internal(set) var balance: LiveBalance?
    public internal(set) var invoices: InvoiceSnapshot?
    public internal(set) var invoiceFailure: LiveFailure?
    public internal(set) var invoiceDocument: InvoiceDocument?
    public internal(set) var points: CustomerPoints?
    public internal(set) var selectedBundleIndex: Int?
    public internal(set) var snapshot: UsageSnapshot = .notConnected
    public internal(set) var failure: LiveFailure?
    public internal(set) var nextRefreshAt: Date?
    public internal(set) var isRefreshing = false
    public internal(set) var scopeMismatch = false

    public init() {}
}

public extension LiveSessionState {
    mutating func mergePoints(from state: LiveSessionState) {
        guard self.connectionID == state.connectionID else { return }
        self.points = state.points
    }

    mutating func mergeInvoices(from state: LiveSessionState) {
        guard self.connectionID == state.connectionID else { return }
        self.invoices = state.invoices
        self.invoiceFailure = state.invoiceFailure
    }
}
