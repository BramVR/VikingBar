import Foundation

public struct HomeUsagePresentation: Codable, Equatable, Sendable {
    public let periodText: String
    public let categoryText: String
    public let policyCounterText: String
    public let allocationText: String
    public let downloadedText: String
    public let peakText: String
    public let offPeakText: String
    public let speedText: String
    public let providerUpdatedText: String
    public let fetchedText: String

    public init(usage: HomeUsage, unit: DataUnit = .gigabytes, timeZone: TimeZone = .current) {
        self.periodText = "Billing period \(usage.period.start.rawValue) to \(usage.period.end.rawValue)"
        self.categoryText = "Policy \(usage.category.rawValue)"
        self.policyCounterText = "Policy counter \(Self.amount(usage.policyCounterGB, unit: unit))"
        let label = switch usage.category {
        case .cap: "Allowance"
        case .fup, .turbo: "Reported policy threshold"
        case .unlimited: "Reported allocation"
        }
        self.allocationText = "\(label) \(Self.amount(usage.reportedAllocationGB, unit: unit))"
        self.downloadedText = usage.downloaded.map { "Downloaded \(Self.amount($0.totalGB, unit: unit))" }
            ?? "Downloaded traffic unavailable"
        self.peakText = usage.downloaded.map { "Peak \(Self.amount($0.peakGB, unit: unit))" } ?? "Peak unavailable"
        self.offPeakText = usage.downloaded.map { "Off-peak \(Self.amount($0.offPeakGB, unit: unit))" }
            ?? "Off-peak unavailable"
        self.speedText = switch usage.speed {
        case .unknown: "Speed state unknown"
        case .reportedNormal: "Provider reports normal speed"
        case .reportedReduced: "Provider reports reduced speed"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy, HH:mm:ss z"
        self.providerUpdatedText = usage.providerUpdatedAt.map { "Provider updated \(formatter.string(from: $0))" }
            ?? "Provider update time unavailable"
        self.fetchedText = "Fetched \(formatter.string(from: usage.fetchedAt))"
    }

    static func amount(_ value: Decimal, unit: DataUnit) -> String {
        if unit == .gigabytes {
            return "\(NSDecimalNumber(decimal: value).stringValue) GB"
        }
        let gibibytes = NSDecimalNumber(decimal: value * 1_000_000_000 / 1_073_741_824).doubleValue
        return String(format: "%.2f GiB", locale: Locale(identifier: "en_US_POSIX"), gibibytes)
    }
}

public struct HomeUsageCardPresentation: Equatable, Sendable {
    public let headline: String
    public let headlineLabel: String
    public let allocation: String
    public let category: String
    public let policyCounter: String
    public let quotaFraction: Double?
    public let quotaText: String?
    public let overage: String?
    public let period: String
    public let downloaded: String
    public let peak: String
    public let offPeak: String
    public let peakFraction: Double?
    public let trafficPercentage: String?
    public let speed: String

    public init(
        usage: HomeUsage, mode: DataDisplayMode = .remaining, unit: DataUnit = .gigabytes,
    ) {
        func amount(_ value: Decimal) -> String {
            Self.compactAmount(value, unit: unit)
        }
        let quota = HomeQuotaCard(usage: usage, mode: mode, unit: unit)
        self.headline = quota.headline
        self.headlineLabel = quota.headlineLabel
        self.allocation = quota.allocation
        self.quotaFraction = quota.fraction
        self.quotaText = quota.percentage
        self.overage = quota.overage
        self.category = usage.category.rawValue
        self.policyCounter = amount(usage.policyCounterGB)
        self.period = Self.period(usage.period)
        self.speed = switch usage.speed {
        case .unknown: "Speed state unknown"
        case .reportedNormal: "Provider reports normal speed"
        case .reportedReduced: "Provider reports reduced speed"
        }
        if let traffic = usage.downloaded {
            self.downloaded = amount(traffic.totalGB)
            self.peak = "Peak \(amount(traffic.peakGB))"
            self.offPeak = "Off-peak \(amount(traffic.offPeakGB))"
            self.peakFraction = traffic.totalGB == 0 ? nil
                : max(0, min(1, NSDecimalNumber(decimal: traffic.peakGB / traffic.totalGB).doubleValue))
            self.trafficPercentage = self.peakFraction.map {
                "Peak \(Int(($0 * 100).rounded()))%, off-peak \(Int(((1 - $0) * 100).rounded()))%"
            }
        } else {
            self.downloaded = "Unavailable"
            self.peak = "Peak unavailable"
            self.offPeak = "Off-peak unavailable"
            self.peakFraction = nil
            self.trafficPercentage = nil
        }
    }

    static func compactAmount(_ value: Decimal, unit: DataUnit) -> String {
        guard unit == .gigabytes else { return HomeUsagePresentation.amount(value, unit: unit) }
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 2, .plain)
        return "\(NSDecimalNumber(decimal: rounded).stringValue) GB"
    }

    private static func period(_ period: BillingPeriod) -> String {
        let start = period.start.rawValue
        let end = period.end.rawValue
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let startDate = formatter.date(from: start), let endDate = formatter.date(from: end) else {
            return "\(start) – \(end)"
        }
        if start.prefix(7) == end.prefix(7) {
            formatter.dateFormat = "d"
            let first = formatter.string(from: startDate)
            formatter.dateFormat = "d MMM yyyy"
            return "\(first)–\(formatter.string(from: endDate))"
        }
        formatter.dateFormat = start.prefix(4) == end.prefix(4) ? "d MMM" : "d MMM yyyy"
        let first = formatter.string(from: startDate)
        formatter.dateFormat = "d MMM yyyy"
        return "\(first) – \(formatter.string(from: endDate))"
    }
}

private struct HomeQuotaCard {
    let headline: String
    let headlineLabel: String
    let allocation: String
    let fraction: Double?
    let percentage: String?
    let overage: String?

    init(usage: HomeUsage, mode: DataDisplayMode, unit: DataUnit) {
        func amount(_ value: Decimal) -> String {
            HomeUsageCardPresentation.compactAmount(value, unit: unit)
        }
        switch usage.allowance {
        case let .finite(total, used, remaining):
            self.allocation = "\(amount(Decimal(total) / 1_000_000_000)) total"
            if mode == .remaining {
                self.headline = amount(Decimal(remaining) / 1_000_000_000)
                self.headlineLabel = remaining == 0 ? "Data exhausted" : "Data remaining"
                self.fraction = total == 0 ? nil : Double(remaining) / Double(total)
                self.percentage = total == 0 ? nil
                    : String(format: "%.0f%% remaining", Double(remaining) * 100 / Double(total))
            } else {
                self.headline = amount(usage.policyCounterGB)
                self.headlineLabel = "Policy counter"
                self.fraction = total == 0 ? nil : min(1, Double(used) / Double(total))
                self.percentage = total == 0 ? nil
                    : String(format: "%.0f%% of cap", Double(used) * 100 / Double(total))
            }
            self.overage = used > total ? "\(amount(Decimal(used - total) / 1_000_000_000)) over cap" : nil
        case let .speedThreshold(threshold, _, category):
            self.headline = amount(Decimal(threshold) / 1_000_000_000)
            self.headlineLabel = "Reported \(category) policy threshold"
            self.allocation = "Reported policy threshold \(self.headline)"
            self.fraction = nil
            self.percentage = nil
            self.overage = nil
        case .unlimited:
            self.headline = "Unlimited"
            self.headlineLabel = "Home data"
            self.allocation = "Reported allocation \(amount(usage.reportedAllocationGB))"
            self.fraction = nil
            self.percentage = nil
            self.overage = nil
        case .unavailable:
            self.headline = "Unavailable"
            self.headlineLabel = "Home data balance"
            self.allocation = "Reported allocation \(amount(usage.reportedAllocationGB))"
            self.fraction = nil
            self.percentage = nil
            self.overage = nil
        }
    }
}
