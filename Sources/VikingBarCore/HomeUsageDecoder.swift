import Foundation

public enum HomeUsageDecoder {
    public static func decode(
        _ payload: TelenetHomePayload, key: ServiceKey, connectionID: ConnectionID, fetchedAt: Date,
    ) throws -> HomeUsage {
        do {
            let decoder = JSONDecoder()
            let cycles = try decoder.decode(Cycles.self, from: payload.cycle)
            guard let current = cycles.billCycles.first, cycles.billCycles.count <= 3 else {
                throw LiveFailure.malformedResponse
            }
            let period = try BillingPeriod(start: current.startDate, end: current.endDate)
            let root = try decoder.decode(Usage.self, from: payload.usage)
            try root.identity.validate(key: key, period: period)
            try root.internet.identity.validate(key: key, period: period)
            let downloaded: HomeDownloadedTraffic?
            var dailyHistory: HomeDailyHistory?
            if let dailyUsage = payload.dailyUsage {
                let daily = try decoder.decode(Daily.self, from: dailyUsage)
                try daily.identity.validate(key: key, period: period)
                guard daily.internetUsage.count == 1, let first = daily.internetUsage.first else {
                    throw LiveFailure.malformedResponse
                }
                try first.identity.validate(key: key, period: period)
                downloaded = try HomeDownloadedTraffic(
                    peakGB: first.totalUsage.peak.value,
                    offPeakGB: first.totalUsage.offPeak.value,
                )
                if let rows = first.dailyUsages {
                    dailyHistory = try? Self.history(rows, period: period, fetchedAt: fetchedAt)
                }
            } else {
                downloaded = nil
            }
            let updated = try root.internet.totalUsage.lastUsageDate.map(Self.timestamp)
            return try HomeUsage(
                key: key, connectionID: connectionID, period: period, category: root.internet.category,
                policyCounterGB: root.internet.totalUsage.units.value,
                reportedAllocationGB: root.internet.allocatedUsage.units.value, downloaded: downloaded,
                dailyHistory: dailyHistory,
                providerUpdatedAt: updated, fetchedAt: fetchedAt,
            )
        } catch { throw LiveFailure.malformedResponse }
    }

    private static func timestamp(_ value: String) throws -> Date {
        guard value.count <= 40 else { throw LiveFailure.malformedResponse }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return date
        }
        // Offset-free timestamps are interpreted as Belgian civil time.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone(identifier: "Europe/Brussels")
        local.isLenient = false
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            local.dateFormat = format
            if let date = local.date(from: value), local.string(from: date) == value {
                return date
            }
        }
        throw LiveFailure.malformedResponse
    }

    private static func history(_ rows: [DailyRow], period: BillingPeriod, fetchedAt: Date) throws -> HomeDailyHistory {
        guard rows.count <= 62 else { throw LiveFailure.malformedResponse }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Brussels")
        formatter.dateFormat = "yyyy-MM-dd"
        let fetchedDay = try CalendarDay(formatter.string(from: fetchedAt))
        return try HomeDailyHistory(
            fetchedDay: fetchedDay,
            rows: rows.map { row in
                guard row.date.range(
                    of: #"^\d{4}-\d{2}-\d{2}T00:00:00(?:\.0+)?[+-]\d{2}:\d{2}$"#,
                    options: .regularExpression,
                ) != nil else { throw LiveFailure.malformedResponse }
                let instant = try Self.timestamp(row.date)
                guard HistoryPlan.calendar.component(.hour, from: instant) == 0,
                      HistoryPlan.calendar.component(.minute, from: instant) == 0
                else {
                    throw LiveFailure.malformedResponse
                }
                let day = try CalendarDay(formatter.string(from: instant))
                return try HomeDailyUsage(
                    day: day, totalGB: row.total.value, peakGB: row.peak.value, offPeakGB: row.offPeak.value,
                )
            },
            period: period,
        )
    }
}

private struct Quantity: Decodable {
    let value: Decimal
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            guard string.count <= 60, string.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  let value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
            else {
                throw LiveFailure.malformedResponse
            }
            self.value = value
        } else {
            self.value = try container.decode(Decimal.self)
        }
        try HomeUsage.validateQuantity(self.value)
    }
}

private struct WireIdentity: Decodable {
    let identifier: String?
    let productIdentifier: String?
    let startDate: CalendarDay?
    let endDate: CalendarDay?
    let fromDate: CalendarDay?
    let toDate: CalendarDay?
    func validate(key: ServiceKey, period: BillingPeriod) throws {
        guard [self.identifier, self.productIdentifier].compactMap(\.self).allSatisfy({ $0 == key.providerID }),
              [self.startDate, self.fromDate].compactMap(\.self).allSatisfy({ $0 == period.start }),
              [self.endDate, self.toDate].compactMap(\.self).allSatisfy({ $0 == period.end })
        else {
            throw LiveFailure.malformedResponse
        }
    }
}

private struct Cycles: Decodable {
    let billCycles: [Cycle]
    struct Cycle: Decodable { let startDate: CalendarDay; let endDate: CalendarDay }
}

private struct Usage: Decodable {
    let internet: Internet
    let identity: WireIdentity
    enum CodingKeys: CodingKey { case internet }
    init(from decoder: any Decoder) throws {
        self.internet = try decoder.container(keyedBy: CodingKeys.self).decode(Internet.self, forKey: .internet)
        self.identity = try WireIdentity(from: decoder)
    }
}

private struct Internet: Decodable {
    let category: HomeCategory
    let totalUsage: Counter
    let allocatedUsage: Allocation
    let identity: WireIdentity
    enum CodingKeys: CodingKey { case category, totalUsage, allocatedUsage }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.category = try container.decode(HomeCategory.self, forKey: .category)
        self.totalUsage = try container.decode(Counter.self, forKey: .totalUsage)
        self.allocatedUsage = try container.decode(Allocation.self, forKey: .allocatedUsage)
        self.identity = try WireIdentity(from: decoder)
    }
}

private struct Counter: Decodable { let units: Quantity; let lastUsageDate: String? }
private struct Allocation: Decodable { let units: Quantity }

private struct Daily: Decodable {
    let internetUsage: [Traffic]
    let identity: WireIdentity
    enum CodingKeys: CodingKey { case internetUsage }
    init(from decoder: any Decoder) throws {
        self.internetUsage = try decoder.container(keyedBy: CodingKeys.self).decode(
            [Traffic].self,
            forKey: .internetUsage,
        )
        self.identity = try WireIdentity(from: decoder)
    }
}

private struct Traffic: Decodable {
    let totalUsage: Split
    let dailyUsages: [DailyRow]?
    let identity: WireIdentity
    enum CodingKeys: CodingKey { case totalUsage, dailyUsages }
    init(from decoder: any Decoder) throws {
        self.totalUsage = try decoder.container(keyedBy: CodingKeys.self).decode(Split.self, forKey: .totalUsage)
        self.dailyUsages = try? decoder.container(keyedBy: CodingKeys.self).decode(
            [DailyRow].self,
            forKey: .dailyUsages,
        )
        self.identity = try WireIdentity(from: decoder)
    }
}

private struct Split: Decodable { let peak: Quantity; let offPeak: Quantity }
private struct DailyRow: Decodable {
    let date: String
    let total: Quantity
    let peak: Quantity
    let offPeak: Quantity
}
