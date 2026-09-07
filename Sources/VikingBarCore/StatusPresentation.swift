import Foundation

public enum HelmetTreatment: Equatable, Sendable {
    case finite(fraction: Double)
    case unlimited
    case unavailable
}

public struct StatusPresentation: Equatable, Sendable {
    public let treatment: HelmetTreatment
    public let title: String
    public let accessibilityLabel: String

    public init(
        snapshot: UsageSnapshot,
        showRemainingGB: Bool,
        unit: DataUnit = .gigabytes,
        timeZone: TimeZone = .current,
    ) {
        let amount: String
        switch snapshot.allowance {
        case let .finite(total, _, remaining):
            self.treatment = total == 0 ? .unavailable : .finite(fraction: min(1, Double(remaining) / Double(total)))
            amount = Self.compactGigabytes(remaining)
        case .unlimited:
            self.treatment = .unlimited
            amount = "Unlimited"
        case .unavailable:
            self.treatment = .unavailable
            amount = "Unavailable"
        }
        self.title = showRemainingGB ? amount : ""
        let menu = MenuPresentation(snapshot: snapshot, unit: unit, timeZone: timeZone)
        self.accessibilityLabel = "\(menu.accessibilityLabel), \(menu.title), \(menu.freshnessText)"
    }

    private static func compactGigabytes(_ bytes: UInt64) -> String {
        if bytes == 0 {
            return "0 GB"
        }
        if bytes < 100_000_000 {
            return "<0.1 GB"
        }
        let formatted = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(bytes) / 1_000_000_000)
        return "\(formatted.hasSuffix(".0") ? String(formatted.dropLast(2)) : formatted) GB"
    }
}
