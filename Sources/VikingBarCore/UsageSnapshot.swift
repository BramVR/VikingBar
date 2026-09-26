import Foundation

public enum Allowance: Codable, Equatable, Sendable {
    case finite(totalBytes: UInt64, usedBytes: UInt64, remainingBytes: UInt64)
    case unlimited(usedBytes: UInt64)
    case speedThreshold(thresholdBytes: UInt64, usedBytes: UInt64, category: String)
    case unavailable
}

public enum Freshness: Codable, Equatable, Sendable {
    case current(lastUpdated: Date)
    case stale(lastUpdated: Date)
    case unavailable
}

public enum SnapshotSource: Codable, Equatable, Sendable {
    case fixture(FixtureState)
    case notConnected
    case live
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let providerName: String?
    public let source: SnapshotSource
    public let subscriptionName: String
    public let allowance: Allowance
    public let expiresAt: Date?
    public let freshness: Freshness
    public let errorMessage: String?

    public init(
        source: SnapshotSource,
        subscriptionName: String,
        allowance: Allowance,
        expiresAt: Date?,
        freshness: Freshness,
        errorMessage: String? = nil,
        providerName: String? = nil,
    ) {
        self.providerName = providerName
        self.source = source
        self.subscriptionName = subscriptionName
        self.allowance = allowance
        self.expiresAt = expiresAt
        self.freshness = freshness
        self.errorMessage = errorMessage
    }

    public static let notConnected = UsageSnapshot(
        source: .notConnected,
        subscriptionName: "No account connected",
        allowance: .unavailable,
        expiresAt: nil,
        freshness: .unavailable,
        errorMessage: "Connect your Mobile Vikings account to load your data balance.",
    )
}

public enum FixtureState: String, Codable, CaseIterable, Sendable {
    case finite, unlimited, exhausted, stale, error, mixed

    public func snapshot(referenceDate: Date) -> UsageSnapshot {
        let allowance: Allowance = switch self {
        case .finite, .stale, .mixed:
            .finite(totalBytes: 50_000_000_000, usedBytes: 14_000_000_000, remainingBytes: 36_000_000_000)
        case .unlimited:
            .unlimited(usedBytes: 14_000_000_000)
        case .exhausted:
            .finite(totalBytes: 50_000_000_000, usedBytes: 50_000_000_000, remainingBytes: 0)
        case .error:
            .unavailable
        }
        let freshness: Freshness = switch self {
        case .stale: .stale(lastUpdated: referenceDate.addingTimeInterval(-86400))
        case .error: .unavailable
        case .finite, .unlimited, .exhausted, .mixed: .current(lastUpdated: referenceDate)
        }
        return UsageSnapshot(
            source: .fixture(self),
            subscriptionName: "Example SIM",
            allowance: allowance,
            expiresAt: self == .error ? nil : referenceDate.addingTimeInterval(14 * 86400),
            freshness: freshness,
            errorMessage: self == .error ? "Could not load the example balance." : nil,
        )
    }

    public func nonDataBundles(subscriptionID: String, referenceDate: Date) -> [BalanceBundle] {
        guard self == .mixed else { return [] }
        let day: TimeInterval = 86400
        let start = referenceDate.addingTimeInterval(-16 * day)
        let end = referenceDate.addingTimeInterval(14 * day)
        if subscriptionID == "travel" {
            return [BalanceBundle(
                title: "Travel credit", description: "Synthetic travel credit", category: "default", type: .value,
                total: 5, used: 0, remaining: 5, validFrom: start, validUntil: end,
            )]
        }
        return [
            BalanceBundle(
                title: "Monthly SMS", description: "Synthetic monthly SMS", category: "default", type: .sms,
                total: 100, used: 40, remaining: 60, validFrom: start, validUntil: end,
            ),
            BalanceBundle(
                title: "", description: "", category: "default", type: .voice,
                total: 2400, used: 1230, remaining: 1170, validFrom: start, validUntil: end,
            ),
            BalanceBundle(
                title: "Prepaid credit", description: "Synthetic prepaid credit", category: "default", type: .value,
                total: 15, used: Decimal(250) / 100, remaining: Decimal(1250) / 100, validFrom: start, validUntil: end,
            ),
            BalanceBundle(
                title: "Unlimited SMS", description: "Synthetic unlimited SMS", category: "super_on_net", type: .sms,
                total: -1, used: 12, remaining: -1, validFrom: start, validUntil: end,
            ),
            BalanceBundle(
                title: "Roaming calls", description: "Synthetic roaming minutes", category: "default", type: .voice,
                total: 600, used: 0, remaining: 600, validFrom: referenceDate.addingTimeInterval(-31 * day),
                validUntil: referenceDate.addingTimeInterval(-day),
            ),
        ]
    }
}
