import CoreFoundation
import Foundation
import VikingBarCore

private struct TelenetHomeReceipt: Encodable {
    let schemaVersion = 1
    let check = "telenet-home-api"
    let passed = true
    let apiMatches = true
    let serviceCount: Int
    let dailyUsageMatches = true
    let dailyRowCount: Int
    let dailyHistoryMatches = true
    let forecastMatches = true
    let sessionReused = true
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case check, passed
        case apiMatches = "api_matches"
        case serviceCount = "service_count"
        case dailyUsageMatches = "daily_usage_matches"
        case dailyRowCount = "daily_row_count"
        case dailyHistoryMatches = "daily_history_matches"
        case forecastMatches = "forecast_matches"
        case sessionReused = "session_reused"
    }
}

private actor TelenetOracleTransport: TelenetTransport {
    private let base: any TelenetTransport
    private var responses: [String: Data] = [:]
    private var passwordRequests = 0

    init(base: any TelenetTransport) {
        self.base = base
    }

    func send(_ request: URLRequest) async throws -> TelenetResponse {
        let response = try await self.base.send(request)
        if request.httpMethod != "GET" {
            self.passwordRequests += 1
        }
        if response.status == 200, let url = request.url {
            self.responses[url.absoluteString] = response.body
        }
        return response
    }

    func verify(state: LiveSessionState, originalConnection: ConnectionID) throws -> (Int, Int) {
        guard self.passwordRequests == 0, state.connectionID == originalConnection, state.failure == nil,
              state.homeFailure == nil, let home = state.selectedHomeUsage, let downloaded = home.downloaded,
              let account = state.account, account.key.provider == .telenet else { throw LiveFailure.malformedResponse }
        let id = home.key.providerID
        let cycle = try self
            .object(path: "/ocapi/public/api/billing-service/v1/account/products/\(id)/billcycle-details")
        guard let cycles = cycle["billCycles"] as? [[String: Any]], let current = cycles.first,
              let start = current["startDate"] as? String, let end = current["endDate"] as? String,
              home.period.start.rawValue == start, home.period.end.rawValue == end
        else {
            throw LiveFailure.malformedResponse
        }
        let prefix = "/ocapi/public/api/product-service/v1/products/internet/\(id)"
        let usage = try self.object(path: prefix + "/usage", start: start, end: end)
        let daily = try self.object(path: prefix + "/dailyusage", start: start, end: end)
        guard let internet = usage["internet"] as? [String: Any],
              let counter = internet["totalUsage"] as? [String: Any],
              let allocation = internet["allocatedUsage"] as? [String: Any],
              let category = internet["category"] as? String,
              category == home.category.rawValue,
              try Self.number(counter["units"]) == home.policyCounterGB,
              try Self.number(allocation["units"]) == home.reportedAllocationGB,
              let rows = daily["internetUsage"] as? [[String: Any]], rows.count == 1,
              let split = rows[0]["totalUsage"] as? [String: Any],
              try Self.number(split["peak"]) == downloaded.peakGB,
              try Self.number(split["offPeak"]) == downloaded.offPeakGB,
              try Self.number(split["peak"]) + Self.number(split["offPeak"]) == downloaded.totalGB,
              try Self.date(counter["lastUsageDate"]) == home.providerUpdatedAt,
              home.speed == .unknown, state.snapshot.expiresAt == nil, state.snapshot.providerName == "Telenet",
              state.snapshot.freshness == .current(lastUpdated: home.fetchedAt)
        else {
            throw LiveFailure.malformedResponse
        }
        let used = try NSDecimalNumber(decimal: Self.number(counter["units"]) * 1_000_000_000).uint64Value
        let total = try NSDecimalNumber(decimal: Self.number(allocation["units"]) * 1_000_000_000).uint64Value
        let expected: Allowance = switch category {
        case "CAP": .finite(totalBytes: total, usedBytes: used, remainingBytes: total > used ? total - used : 0)
        case "FUP",
             "TURBO": total > 0 ? .speedThreshold(thresholdBytes: total, usedBytes: used, category: category) :
            .unavailable
        case "UNLIMITED": .unlimited(usedBytes: used)
        default: .unavailable
        }
        guard state.snapshot.allowance == expected, !account.services.isEmpty, account.services.count <= 8 else {
            throw LiveFailure.malformedResponse
        }
        let dailyCount = try Self.verifyHistory(raw: rows[0], home: home)
        return (account.services.count, dailyCount)
    }

    private struct RawDailyRow {
        let day: String
        let total: Decimal
        let peak: Decimal
        let offPeak: Decimal
    }

    private static func verifyHistory(raw: [String: Any], home: HomeUsage) throws -> Int {
        guard let retained = home.dailyHistory, retained.period == home.period else {
            throw LiveFailure.malformedResponse
        }
        let formatter = DateFormatter()
        formatter.calendar = HistoryPlan.calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = HistoryPlan.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let fetchDay = formatter.string(from: home.fetchedAt)
        guard retained.fetchedDay.rawValue == fetchDay else { throw LiveFailure.malformedResponse }
        let expected = try Self.rawDays(raw: raw, home: home, fetchedDay: fetchDay, formatter: formatter)
        guard !expected.isEmpty, retained.rows.count == expected.count else {
            throw LiveFailure.malformedResponse
        }
        for (actual, source) in zip(retained.rows, expected) {
            guard actual.day.rawValue == source.day, actual.totalGB == source.total,
                  actual.peakGB == source.peak, actual.offPeakGB == source.offPeak
            else {
                throw LiveFailure.malformedResponse
            }
        }
        let now = Date()
        let presentation = HistoryPresentation(home: home, now: now)
        try Self.verifyPresentation(presentation, rows: expected, home: home, now: now, formatter: formatter)
        try Self.verifyForecast(presentation, rows: expected, home: home, now: now, formatter: formatter)
        return expected.count
    }

    private static func rawDays(
        raw: [String: Any], home: HomeUsage, fetchedDay: String, formatter: DateFormatter,
    ) throws -> [RawDailyRow] {
        guard let rows = raw["dailyUsages"] as? [[String: Any]], rows.count <= 62 else {
            throw LiveFailure.malformedResponse
        }
        var retained: [RawDailyRow] = []
        var previous: String?
        for row in rows {
            guard let timestamp = row["date"] as? String,
                  timestamp.range(
                      of: #"^\d{4}-\d{2}-\d{2}T00:00:00(?:\.0+)?[+-]\d{2}:\d{2}$"#,
                      options: .regularExpression,
                  ) != nil,
                  let instant = try Self.date(timestamp),
                  HistoryPlan.calendar.component(.hour, from: instant) == 0,
                  HistoryPlan.calendar.component(.minute, from: instant) == 0
            else {
                throw LiveFailure.malformedResponse
            }
            let day = formatter.string(from: instant)
            guard day >= home.period.start.rawValue, day <= home.period.end.rawValue,
                  previous.map({ $0 < day }) ?? true else { throw LiveFailure.malformedResponse }
            previous = day
            let values = try RawDailyRow(
                day: day, total: Self.number(row["total"]), peak: Self.number(row["peak"]),
                offPeak: Self.number(row["offPeak"]),
            )
            if day <= fetchedDay {
                retained.append(values)
            }
        }
        return retained
    }

    private static func verifyPresentation(
        _ presentation: HistoryPresentation, rows: [RawDailyRow], home: HomeUsage,
        now: Date, formatter: DateFormatter,
    ) throws {
        var total: UInt64 = 0
        for row in rows {
            total = try Self.add(total, Self.roundedBytes(row.total))
        }
        let today = HistoryPlan.calendar.startOfDay(for: now)
        guard presentation.days.count == 30, presentation.totalObservedBytes == total else {
            throw LiveFailure.malformedResponse
        }
        for (offset, shown) in presentation.days.enumerated() {
            guard let dayStart = HistoryPlan.calendar.date(byAdding: .day, value: offset - 29, to: today) else {
                throw LiveFailure.malformedResponse
            }
            let day = formatter.string(from: dayStart)
            let raw = rows.first { $0.day == day }
            let amount = raw.map { Self.roundedBytes($0.total) }
            guard shown.dayStart == dayStart,
                  shown.bytes == (day < home.period.start.rawValue ? nil : amount),
                  shown.isToday == (dayStart == today),
                  shown.isPartial == (dayStart == today || day == home.dailyHistory?.fetchedDay.rawValue)
            else {
                throw LiveFailure.malformedResponse
            }
        }
    }

    private static func verifyForecast(
        _ presentation: HistoryPresentation, rows: [RawDailyRow], home: HomeUsage,
        now: Date, formatter: DateFormatter,
    ) throws {
        let today = HistoryPlan.calendar.startOfDay(for: now)
        let complete = rows.filter { $0.day < formatter.string(from: today) }
        guard let start = formatter.date(from: home.period.start.rawValue),
              let last = formatter.date(from: home.period.end.rawValue),
              let end = HistoryPlan.calendar.date(byAdding: .day, value: 1, to: last),
              start < today, today < end, complete.count >= 3,
              complete.first?.day == home.period.start.rawValue,
              let forecast = presentation.forecast else { throw LiveFailure.malformedResponse }
        var cursor = start
        var observed: UInt64 = 0
        for row in complete {
            guard formatter.string(from: cursor) == row.day,
                  let next = HistoryPlan.calendar.date(byAdding: .day, value: 1, to: cursor)
            else {
                throw LiveFailure.malformedResponse
            }
            observed = try Self.add(observed, Self.roundedBytes(row.total))
            cursor = next
        }
        let seconds = today.timeIntervalSince(start)
        let estimate = Double(observed) / seconds * end.timeIntervalSince(start)
        guard cursor == today, forecast.observedBytes == observed, forecast.observedSeconds == seconds,
              forecast.completeDays == complete.count, abs(forecast.estimatedCycleBytes - estimate) < 0.5
        else {
            throw LiveFailure.malformedResponse
        }
    }

    private func object(path: String, start: String? = nil, end: String? = nil) throws -> [String: Any] {
        let matching = self.responses.filter { address, _ in
            guard let url = URLComponents(string: address), url.path == path else { return false }
            if let start, let end {
                let query = url.queryItems ?? []
                return query.contains(URLQueryItem(name: "fromDate", value: start))
                    && query.contains(URLQueryItem(name: "toDate", value: end))
            }
            return true
        }
        guard matching.count == 1, let bytes = matching.first?.value,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else {
            throw LiveFailure.malformedResponse
        }
        return object
    }

    private static func number(_ value: Any?) throws -> Decimal {
        let text: String
        if let string = value as? String {
            text = string
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            text = number.stringValue
        } else {
            throw LiveFailure.malformedResponse
        }
        guard let result = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !result.isNaN,
              result >= 0 else { throw LiveFailure.malformedResponse }
        return result
    }

    private static func date(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw LiveFailure.malformedResponse }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) {
            return date
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone(identifier: "Europe/Brussels")
        local.isLenient = false
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            local.dateFormat = pattern
            if let date = local.date(from: text), local.string(from: date) == text {
                return date
            }
        }
        throw LiveFailure.malformedResponse
    }
}

private extension TelenetOracleTransport {
    static func roundedBytes(_ amount: Decimal) -> UInt64 {
        var raw = amount * 1_000_000_000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 0, .plain)
        return NSDecimalNumber(decimal: rounded).uint64Value
    }

    static func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let sum = lhs.addingReportingOverflow(rhs)
        guard !sum.overflow else { throw LiveFailure.malformedResponse }
        return sum.partialValue
    }
}

extension VikingBarCLI {
    static func telenetHomeProof(arguments: [String]) async {
        do {
            let options = try AccountOptions(arguments: arguments)
            guard options.remaining.isEmpty else { throw ProofFailure.invalidInput }
            let catalog = try AccountCatalog.production()
            let key = try options.resolve(in: catalog)
            guard key.provider == .telenet else { throw ProofFailure.invalidInput }
            let transport = TelenetOracleTransport(base: EphemeralTelenetTransport())
            let account = try TelenetHomeAccount.production(
                storage: AccountStorage(root: catalog.root, key: key),
                transport: transport,
            )
            try await account.perform(.restore)
            guard let connection = await account.state().connectionID else { throw LiveFailure.notConnected }
            try await account.perform(.refresh)
            let counts = try await transport.verify(state: account.state(), originalConnection: connection)
            self.writeJSON(TelenetHomeReceipt(serviceCount: counts.0, dailyRowCount: counts.1))
        } catch {
            self.writeJSON(CommandFailure(error: "telenet-home-proof-failed"))
            exit(1)
        }
    }
}
