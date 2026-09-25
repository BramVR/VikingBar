import Foundation

public struct CalendarDay: Codable, Equatable, Comparable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        guard rawValue.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw LiveFailure.malformedResponse
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: rawValue), formatter.string(from: date) == rawValue else {
            throw LiveFailure.malformedResponse
        }
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) throws {
        try self.init(rawValue: rawValue)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct BillingPeriod: Codable, Equatable, Sendable {
    public let start: CalendarDay
    public let end: CalendarDay

    public init(start: CalendarDay, end: CalendarDay) throws {
        guard start <= end else { throw LiveFailure.malformedResponse }
        self.start = start
        self.end = end
    }
}

public enum HomeCategory: String, Codable,
    Sendable { case cap = "CAP", fup = "FUP", turbo = "TURBO", unlimited = "UNLIMITED" }
public enum HomeSpeedState: String, Codable, Sendable { case unknown, reportedNormal, reportedReduced }

public struct HomeDownloadedTraffic: Codable, Equatable, Sendable {
    public let peakGB: Decimal
    public let offPeakGB: Decimal
    public var totalGB: Decimal {
        self.peakGB + self.offPeakGB
    }

    public init(peakGB: Decimal, offPeakGB: Decimal) throws {
        try HomeUsage.validateQuantity(peakGB)
        try HomeUsage.validateQuantity(offPeakGB)
        try HomeUsage.validateQuantity(peakGB + offPeakGB)
        self.peakGB = peakGB
        self.offPeakGB = offPeakGB
    }
}

public struct HomeDailyUsage: Codable, Equatable, Sendable {
    public let day: CalendarDay
    public let totalGB: Decimal
    public let peakGB: Decimal
    public let offPeakGB: Decimal

    public init(day: CalendarDay, totalGB: Decimal, peakGB: Decimal, offPeakGB: Decimal) throws {
        try HomeUsage.validateQuantity(totalGB)
        try HomeUsage.validateQuantity(peakGB)
        try HomeUsage.validateQuantity(offPeakGB)
        self.day = day
        self.totalGB = totalGB
        self.peakGB = peakGB
        self.offPeakGB = offPeakGB
    }
}

public struct HomeDailyHistory: Codable, Equatable, Sendable {
    public let fetchedDay: CalendarDay
    public let rows: [HomeDailyUsage]
    public let period: BillingPeriod

    public init(fetchedDay: CalendarDay, rows: [HomeDailyUsage], period: BillingPeriod) throws {
        guard rows.count <= 62 else { throw LiveFailure.malformedResponse }
        var previous: CalendarDay?
        for row in rows {
            try HomeUsage.validateQuantity(row.totalGB)
            try HomeUsage.validateQuantity(row.peakGB)
            try HomeUsage.validateQuantity(row.offPeakGB)
            guard row.day >= period.start, row.day <= period.end, previous.map({ $0 < row.day }) ?? true else {
                throw LiveFailure.malformedResponse
            }
            previous = row.day
        }
        self.fetchedDay = fetchedDay
        self.rows = rows.filter { $0.day <= fetchedDay }
        self.period = period
    }

    private enum CodingKeys: CodingKey { case fetchedDay, rows, period }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            fetchedDay: container.decode(CalendarDay.self, forKey: .fetchedDay),
            rows: container.decode([HomeDailyUsage].self, forKey: .rows),
            period: container.decode(BillingPeriod.self, forKey: .period),
        )
    }
}

public struct HomeUsage: Codable, Equatable, Sendable {
    public let key: ServiceKey
    public let connectionID: ConnectionID
    public let period: BillingPeriod
    public let category: HomeCategory
    public let policyCounterGB: Decimal
    public let reportedAllocationGB: Decimal
    public let downloaded: HomeDownloadedTraffic?
    public let dailyHistory: HomeDailyHistory?
    public let speed: HomeSpeedState
    public let providerUpdatedAt: Date?
    public let fetchedAt: Date

    public init(
        key: ServiceKey, connectionID: ConnectionID, period: BillingPeriod, category: HomeCategory,
        policyCounterGB: Decimal, reportedAllocationGB: Decimal, downloaded: HomeDownloadedTraffic?,
        dailyHistory: HomeDailyHistory? = nil,
        providerUpdatedAt: Date?, fetchedAt: Date, speed: HomeSpeedState = .unknown,
    ) throws {
        guard key.kind == .home,
              [.telenet, .fixtureHome].contains(key.account.provider) else { throw LiveFailure.invalidSelection }
        try Self.validateQuantity(policyCounterGB)
        try Self.validateQuantity(reportedAllocationGB)
        self.key = key
        self.connectionID = connectionID
        self.period = period
        self.category = category
        self.policyCounterGB = policyCounterGB
        self.reportedAllocationGB = reportedAllocationGB
        self.downloaded = downloaded
        self.dailyHistory = dailyHistory
        self.speed = speed
        self.providerUpdatedAt = providerUpdatedAt
        self.fetchedAt = fetchedAt
    }

    public var allowance: Allowance {
        guard let used = Self.bytes(self.policyCounterGB), let allocation = Self.bytes(self.reportedAllocationGB) else {
            return .unavailable
        }
        switch self.category {
        case .cap:
            return .finite(
                totalBytes: allocation,
                usedBytes: used,
                remainingBytes: allocation > used ? allocation - used : 0,
            )
        case .fup, .turbo:
            return allocation > 0 ? .speedThreshold(
                thresholdBytes: allocation,
                usedBytes: used,
                category: self.category.rawValue,
            ) : .unavailable
        case .unlimited:
            return .unlimited(usedBytes: used)
        }
    }

    public func snapshot(stale: Bool = false, failure: LiveFailure? = nil) -> UsageSnapshot {
        UsageSnapshot(
            source: .live, subscriptionName: "Telenet home internet", allowance: self.allowance, expiresAt: nil,
            freshness: stale ? .stale(lastUpdated: self.fetchedAt) : .current(lastUpdated: self.fetchedAt),
            errorMessage: failure.map { TelenetHomeAccount.message(for: $0) }, providerName: "Telenet",
        )
    }

    static func validateQuantity(_ value: Decimal) throws {
        guard !value.isNaN, value >= 0, value <= Decimal(UInt64.max) / 1_000_000_000 else {
            throw LiveFailure.malformedResponse
        }
    }

    private static func bytes(_ value: Decimal) -> UInt64? {
        let decimal = value * 1_000_000_000
        guard !decimal.isNaN, decimal >= 0, decimal <= Decimal(UInt64.max) else { return nil }
        let bytes = NSDecimalNumber(decimal: decimal).uint64Value
        return Decimal(bytes) == decimal ? bytes : nil
    }
}

public extension LiveSessionState {
    var selectedHomeUsage: HomeUsage? {
        guard let homeUsage, let account, homeUsage.key.account == account.key,
              homeUsage.key == account.selectedService, homeUsage.connectionID == self.connectionID else { return nil }
        return homeUsage
    }
}
