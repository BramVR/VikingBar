import Foundation

public enum Allowance: Codable, Equatable, Sendable {
    case finite(totalBytes: UInt64, usedBytes: UInt64, remainingBytes: UInt64)
    case unlimited(usedBytes: UInt64)
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
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
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
    ) {
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
        errorMessage: "Live account access is not available in this build. Select a fixture to preview the app.",
    )
}

public enum FixtureState: String, Codable, CaseIterable, Sendable {
    case finite, unlimited, exhausted, stale, error

    public func snapshot(referenceDate: Date) -> UsageSnapshot {
        let allowance: Allowance = switch self {
        case .finite, .stale:
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
        case .finite, .unlimited, .exhausted: .current(lastUpdated: referenceDate)
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
}
