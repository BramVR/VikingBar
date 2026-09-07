import Foundation

public struct PointsBalance: Codable, Equatable, Sendable {
    public let available: Decimal
    public let pending: Decimal
    public let blocked: Decimal
}

public struct PointsTransactionState: RawRepresentable, Codable, Equatable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    public var displayText: String {
        switch self.rawValue {
        case "completed": "Completed"
        case "reserved": "Reserved"
        case "cancelled": "Cancelled"
        case "pending": "Pending"
        case "blocked": "Blocked"
        case "expired": "Expired"
        case "rejected": "Rejected"
        default: "Unknown state: \(self.rawValue)"
        }
    }
}

public struct PointsTransaction: Codable, Equatable, Sendable {
    public let transactionID: String?
    public let amount: Decimal
    public let state: PointsTransactionState
    public let lastUpdated: Date
    public let description: String?
}

public struct PointsHistory: Codable, Equatable, Sendable {
    public let transactions: [PointsTransaction]
    public let totalItems: Int
    public let truncated: Bool
}

public struct CustomerPoints: Codable, Equatable, Sendable {
    public internal(set) var balance: PointsBalance?
    public internal(set) var balanceFreshness: Freshness = .unavailable
    public internal(set) var balanceFailure: LiveFailure?
    public internal(set) var history: PointsHistory?
    public internal(set) var historyFreshness: Freshness = .unavailable
    public internal(set) var historyFailure: LiveFailure?

    public init() {}

    public mutating func markUnavailable(_ failure: LiveFailure) {
        self.balanceFailure = failure
        self.historyFailure = failure
        self.balanceFreshness = Self.stale(self.balanceFreshness)
        self.historyFreshness = Self.stale(self.historyFreshness)
    }

    mutating func revalidate(at date: Date) {
        if case let .current(updated) = self.balanceFreshness, date >= updated.addingTimeInterval(300) {
            self.balanceFreshness = .stale(lastUpdated: updated)
        }
        if case let .current(updated) = self.historyFreshness, date >= updated.addingTimeInterval(300) {
            self.historyFreshness = .stale(lastUpdated: updated)
        }
    }

    static func stale(_ freshness: Freshness) -> Freshness {
        switch freshness {
        case let .current(date), let .stale(date): .stale(lastUpdated: date)
        case .unavailable: .unavailable
        }
    }
}

public extension LiveSessionState {
    func points(at date: Date) -> CustomerPoints? {
        var points = self.points
        points?.revalidate(at: date)
        let terminalFailures: [LiveFailure] = [.unauthorized, .reconnectRequired, .notConnected, .connectionChanged]
        if let failure = self.failure, terminalFailures.contains(failure) {
            points?.markUnavailable(failure)
        }
        return points
    }

    mutating func markPointsUnavailable(_ failure: LiveFailure) {
        var points = self.points ?? CustomerPoints()
        points.markUnavailable(failure)
        self.points = points
    }
}
