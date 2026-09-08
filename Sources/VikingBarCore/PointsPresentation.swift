import Foundation

public struct PointsTransactionPresentation: Codable, Equatable, Sendable {
    public let amountText: String
    public let stateText: String
    public let updatedText: String
    public let descriptionText: String
}

public struct PointsPresentation: Codable, Equatable, Sendable {
    public let customerLabel: String
    public let availableText: String
    public let pendingText: String
    public let blockedText: String
    public let balanceStatus: String
    public let historyStatus: String
    public let historySummary: String
    public let transactions: [PointsTransactionPresentation]

    public init(points: CustomerPoints?, timeZone: TimeZone = .current) {
        self.customerLabel = "Viking Points · Customer"
        self.availableText = points?.balance.map { "Available: \(Self.amount($0.available))" }
            ?? "Available: unavailable"
        self.pendingText = points?.balance.map { "Pending: \(Self.amount($0.pending))" } ?? "Pending: unavailable"
        self.blockedText = points?.balance.map { "Blocked: \(Self.amount($0.blocked))" } ?? "Blocked: unavailable"
        self.balanceStatus = Self.status(points?.balanceFreshness ?? .unavailable, failure: points?.balanceFailure)
        self.historyStatus = Self.status(points?.historyFreshness ?? .unavailable, failure: points?.historyFailure)
        if let history = points?.history {
            self.historySummary = history.truncated
                ? "Showing \(history.transactions.count) of \(history.totalItems) transactions. History truncated."
                : history.transactions.isEmpty ? "No transactions" : "\(history.transactions.count) recent transactions"
        } else {
            self.historySummary = "Transaction history unavailable"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        self.transactions = (points?.history?.transactions ?? []).map { transaction in
            PointsTransactionPresentation(
                amountText: (transaction.amount > 0 ? "+" : "") + Self.amount(transaction.amount),
                stateText: transaction.state.displayText,
                updatedText: formatter.string(from: transaction.lastUpdated),
                descriptionText: transaction.description.flatMap { $0.isEmpty ? nil : $0 } ?? "Points transaction",
            )
        }
    }

    private static func amount(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private static func status(_ freshness: Freshness, failure: LiveFailure?) -> String {
        let label = switch freshness {
        case .current: "Up to date"
        case .stale: "Stale"
        case .unavailable: "Unavailable"
        }
        return failure.map { "\(label). \($0.message)" } ?? label
    }
}

public extension FixtureState {
    func points(referenceDate: Date) -> CustomerPoints {
        var points = CustomerPoints()
        if self == .error {
            points.markUnavailable(.transport)
            return points
        }
        points.balance = PointsBalance(available: self == .exhausted ? 0 : 12.75, pending: 3.5, blocked: 2.25)
        points.balanceFreshness = .current(lastUpdated: referenceDate)
        points.historyFreshness = .current(lastUpdated: referenceDate)
        let states = ["completed", "reserved", "cancelled", "pending", "blocked", "expired", "rejected", "future-state"]
        points.history = PointsHistory(
            transactions: states.enumerated().map { index, state in
                PointsTransaction(
                    transactionID: "fixture-\(index)", amount: index.isMultiple(of: 2) ? 1.25 : -2.5,
                    state: PointsTransactionState(rawValue: state),
                    lastUpdated: referenceDate.addingTimeInterval(Double(-index) * 3600),
                    description: "Synthetic \(state)",
                )
            }, totalItems: states.count, truncated: false,
        )
        if self == .stale {
            points.markUnavailable(.transport)
        }
        return points
    }
}
