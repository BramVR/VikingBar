import Foundation

public enum DataUnit: String, Codable, CaseIterable, Sendable {
    case gigabytes = "GB"
    case gibibytes = "GiB"

    public var explanation: String {
        switch self {
        case .gigabytes: "GB uses decimal units (1 GB = 1,000,000,000 bytes)."
        case .gibibytes: "GiB uses binary units (1 GiB = 1,073,741,824 bytes)."
        }
    }

    public func format(bytes: UInt64) -> String {
        let divisor = self == .gigabytes ? 1_000_000_000.0 : 1_073_741_824.0
        return String(
            format: "%.2f %@",
            locale: Locale(identifier: "en_US_POSIX"),
            Double(bytes) / divisor,
            self.rawValue,
        )
    }
}

public struct MenuPresentation: Codable, Equatable, Sendable {
    public let title: String
    public let sourceLabel: String
    public let statusTitle: String
    public let accessibilityLabel: String
    public let balanceTitle: String
    public let remainingText: String
    public let usedText: String
    public let totalText: String
    public let percentageUsed: Double?
    public let usedPercentageText: String?
    public let percentageRemaining: Double?
    public let percentageText: String?
    public let expiryText: String
    public let freshnessText: String
    public let warningText: String?
    public let unitExplanation: String

    public init(snapshot: UsageSnapshot, unit: DataUnit = .gigabytes, timeZone: TimeZone = .current) {
        self.title = snapshot.subscriptionName
        let isFixture: Bool
        switch snapshot.source {
        case let .fixture(state):
            self.sourceLabel = "FIXTURE · \(state.rawValue.capitalized) · Synthetic data"
            isFixture = true
        case .notConnected:
            self.sourceLabel = "Not connected"
            isFixture = false
        }
        let balance = BalancePresentation(allowance: snapshot.allowance, unit: unit)
        self.balanceTitle = balance.balanceTitle
        self.remainingText = balance.remainingText
        self.usedText = balance.usedText
        self.totalText = balance.totalText
        self.percentageUsed = balance.percentageUsed
        self.usedPercentageText = balance.usedPercentageText
        self.percentageRemaining = balance.percentageRemaining
        self.percentageText = balance.percentageText
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy, HH:mm z"
        self.expiryText = snapshot.expiresAt.map { "Expires \(formatter.string(from: $0))" } ?? "Expiry unavailable"
        let stale: Bool
        switch snapshot.freshness {
        case let .current(date):
            self.freshnessText = "Last updated \(formatter.string(from: date))"
            stale = false
        case let .stale(date):
            self.freshnessText = "Stale · Last updated \(formatter.string(from: date))"
            stale = true
        case .unavailable:
            self.freshnessText = "No successful update"
            stale = false
        }
        self.warningText = snapshot.errorMessage ?? (stale ? "Showing an older balance. It may have changed." : nil)
        self.unitExplanation = unit.explanation
        self.statusTitle = "\(isFixture ? "Fixture" : "VikingBar") \(stale ? "Stale " : "")\(balance.statusBalance)"
        let statusLabel = isFixture ? "VikingBar \(self.statusTitle)" : self.statusTitle
        self.accessibilityLabel = "\(statusLabel), \(self.remainingText), \(self.sourceLabel)"
    }
}

private struct BalancePresentation {
    let balanceTitle: String
    let remainingText: String
    let usedText: String
    let totalText: String
    let percentageUsed: Double?
    let usedPercentageText: String?
    let percentageRemaining: Double?
    let percentageText: String?
    let statusBalance: String

    init(allowance: Allowance, unit: DataUnit) {
        switch allowance {
        case let .finite(total, used, remaining):
            self.balanceTitle = remaining == 0 ? "Data exhausted" : "Data remaining"
            self.remainingText = unit.format(bytes: remaining)
            self.usedText = "\(unit.format(bytes: used)) used"
            self.totalText = "\(unit.format(bytes: total)) total"
            let percentage = total == 0 ? nil : min(100, Double(remaining) * 100 / Double(total))
            self.percentageUsed = total == 0 ? nil : Double(used) * 100 / Double(total)
            self.usedPercentageText = self.percentageUsed.map { String(format: "%.0f%% used", $0) }
            self.percentageRemaining = percentage
            self.percentageText = percentage.map { String(format: "%.0f%% remaining", $0) }
            self.statusBalance = percentage.map { String(format: "%.0f%%", $0) } ?? unit.format(bytes: remaining)
        case let .unlimited(used):
            self.balanceTitle = "Data remaining"
            self.remainingText = "Unlimited"
            self.usedText = "\(unit.format(bytes: used)) used"
            self.totalText = "Unlimited allowance"
            self.percentageUsed = nil
            self.usedPercentageText = nil
            self.percentageRemaining = nil
            self.percentageText = nil
            self.statusBalance = "∞"
        case .unavailable:
            self.balanceTitle = "Data balance"
            self.remainingText = "Unavailable"
            self.usedText = "Usage unavailable"
            self.totalText = "Allowance unavailable"
            self.percentageUsed = nil
            self.usedPercentageText = nil
            self.percentageRemaining = nil
            self.percentageText = nil
            self.statusBalance = "?"
        }
    }
}
