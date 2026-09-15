import Foundation

public enum DataDisplayMode: String, Codable, CaseIterable, Sendable {
    case remaining, used

    public var title: String {
        self == .remaining ? "Remaining" : "Used"
    }
}

public enum RefreshInterval: Int, Codable, CaseIterable, Sendable {
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600

    public var title: String {
        switch self {
        case .fiveMinutes: "Every 5 minutes"
        case .fifteenMinutes: "Every 15 minutes"
        case .thirtyMinutes: "Every 30 minutes"
        case .oneHour: "Every hour"
        }
    }

    func deadline(updated: Date, expiry: Date?) -> Date {
        min(updated.addingTimeInterval(TimeInterval(self.rawValue)), expiry ?? .distantFuture)
    }
}

public struct DataCardPresentation: Equatable, Sendable {
    public let title: String
    public let value: String
    public let percentage: Double?
    public let percentageText: String?

    public let supportingPercentageText: String?

    public init(allowance: Allowance, mode: DataDisplayMode, unit: DataUnit) {
        let balance = BalancePresentation(allowance: allowance, unit: unit)
        self.title = mode == .remaining ? balance.balanceTitle : "Data used"
        self.value = mode == .remaining ? balance.remainingText : balance.usedValueText
        self.percentage = mode == .remaining ? balance.percentageRemaining : balance.percentageUsed
        self.percentageText = mode == .remaining ? balance.percentageText : balance.usedPercentageText
        self.supportingPercentageText = balance.usedPercentageText
    }
}
