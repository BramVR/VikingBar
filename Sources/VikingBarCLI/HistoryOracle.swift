import Foundation
import VikingBarCore

struct HistoryAPIReceipt: Encodable {
    let schemaVersion = 1
    let check = "history-api"
    let passed = true
    let apiMatches = true
    let forecastMatches = true
    let tokenRefreshed = true
    let requestCount: Int
    let observedDays: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case apiMatches = "api_matches"
        case forecastMatches = "forecast_matches"
        case tokenRefreshed = "token_refreshed"
        case requestCount = "request_count"
        case observedDays = "observed_days"
        case check, passed
    }
}

enum HistoryOracleFailure: Error {
    case insufficientEvidence
}

actor HistoryOracleTransport: ProofHTTPTransport {
    private struct Summary {
        let subscriptionID: String
        let start: Date
        let end: Date
        let bytes: UInt64?
    }

    private let base: any ProofHTTPTransport
    private var summaries: [Summary] = []
    private var refreshed = false

    init(base: any ProofHTTPTransport) {
        self.base = base
    }

    func send(_ request: URLRequest) async throws -> ProofHTTPResponse {
        let response = try await self.base.send(request)
        guard response.statusCode == 200, let url = request.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return response }
        if parts.path == "/mv/oauth2/token/" {
            self.refreshed = request.httpBody.map {
                String(data: $0, encoding: .utf8)?.split(separator: "&").contains("grant_type=refresh_token") ?? false
            } ?? false
        } else if parts.path.hasSuffix("/usage-summary") {
            let items = parts.queryItems ?? []
            guard items.count == 4, Set(items.map(\.name)) == ["traffic_type", "direction", "from_date", "until_date"],
                  items.first(where: { $0.name == "traffic_type" })?.value == "data",
                  items.first(where: { $0.name == "direction" })?.value == "outgoing",
                  let from = items.first(where: { $0.name == "from_date" })?.value,
                  let until = items.first(where: { $0.name == "until_date" })?.value,
                  let id = parts.path.split(separator: "/").dropLast().last
            else { throw ProofFailure.malformedResponse }
            let start = try Self.date(from)
            let end = try Self.date(until)
            guard start < end, end.timeIntervalSince(start) <= 25 * 3600 else {
                throw ProofFailure.malformedResponse
            }
            let bytes = try Self.decodeSummary(response.data)
            self.summaries.append(Summary(
                subscriptionID: String(id), start: start, end: end, bytes: bytes,
            ))
        }
        return response
    }

    private static func decodeSummary(_ data: Data) throws -> UInt64? {
        switch try JSONDecoder().decode(HistoryOraclePayload.self, from: data) {
        case let .rows(rows):
            var total: UInt64 = 0
            for row in rows {
                guard row.trafficType == "data", !row.incoming,
                      ["national", "international", "roaming", "unknown"].contains(row.regionality),
                      row.totalDuration >= 0, !row.totalDuration.isNaN, !row.totalPrice.isNaN
                else { throw ProofFailure.malformedResponse }
                let addition = total.addingReportingOverflow(row.totalQuantity)
                guard !addition.overflow else { throw ProofFailure.malformedResponse }
                total = addition.partialValue
            }
            return rows.isEmpty ? nil : total
        case let .grouped(response):
            let data = response.outgoing.data
            guard data.totalDuration >= 0, !data.totalDuration.isNaN, !data.totalPrice.isNaN else {
                throw ProofFailure.malformedResponse
            }
            return data.totalQuantity
        }
    }

    func receipt(state: LiveSessionState, presentation: HistoryPresentation) throws -> HistoryAPIReceipt {
        guard self.refreshed, state.failure == nil, !state.isRefreshing,
              let history = state.history, history.failure == nil, !history.truncated,
              let index = state.selectedBundleIndex, let balance = state.balance,
              balance.bundles.indices.contains(index), history.context.bundleIndex == index,
              history.context.connectionID == state.connectionID,
              history.context.subscriptionID == state.selectedSubscriptionID,
              history.context.revision == state.historyRevision,
              history.context.bundle.cycleStart == balance.bundles[index].validFrom,
              history.context.bundle.cycleEnd == balance.bundles[index].validUntil,
              (1 ... 62).contains(self.summaries.count),
              let chart = history.chartSeries, chart.failure == nil,
              chart.observations.count == 30, presentation.days.count == 30
        else { throw ProofFailure.malformedResponse }
        try self.verifyChart(history: history, chart: chart, presentation: presentation)
        var uniqueIntervals: [HistoryInterval] = []
        let intervals = (history.observations + chart.observations).map(\.interval).filter { $0.start < $0.end }
        for interval in intervals where !uniqueIntervals.contains(interval) {
            uniqueIntervals.append(interval)
        }
        guard self.summaries.count == uniqueIntervals.count else { throw ProofFailure.malformedResponse }
        let coverage = try self.coverage(history: history, presentation: presentation)
        guard coverage.completed >= 3,
              history.observations.filter({ !$0.interval.isToday }).allSatisfy({ $0.bytes != nil }),
              let forecast = presentation.forecast else { throw HistoryOracleFailure.insufficientEvidence }
        let today = Self.calendar.startOfDay(for: history.attemptedAt)
        let elapsed = today.timeIntervalSince(history.context.bundle.cycleStart)
        let duration = history.context.bundle.cycleEnd.timeIntervalSince(history.context.bundle.cycleStart)
        guard elapsed > 0, history.attemptedAt < history.context.bundle.cycleEnd else {
            throw HistoryOracleFailure.insufficientEvidence
        }
        let estimate = Double(coverage.observed) / elapsed * duration
        guard forecast.observedBytes == coverage.observed, forecast.observedSeconds == elapsed,
              forecast.completeDays == coverage.completed, forecast.estimatedCycleBytes.isFinite,
              abs(forecast.estimatedCycleBytes - estimate) <= max(0.000001, abs(estimate) * 1e-12),
              presentation.unit == "GB", presentation.forecastText.lowercased().contains("estimated"),
              !presentation.forecastText.contains("%")
        else { throw ProofFailure.malformedResponse }
        return HistoryAPIReceipt(requestCount: self.summaries.count, observedDays: coverage.completed)
    }

    private func coverage(
        history: UsageHistory, presentation: HistoryPresentation,
    ) throws -> (observed: UInt64, completed: Int) {
        var cursor = history.context.bundle.cycleStart
        var observed: UInt64 = 0
        var total: UInt64?
        var completed = 0
        for observation in history.observations {
            let interval = observation.interval
            try self.verifyObservation(
                observation, history: history, cursor: cursor,
                until: min(history.attemptedAt, history.context.bundle.cycleEnd),
            )
            if let bytes = observation.bytes {
                let addition = (total ?? 0).addingReportingOverflow(bytes)
                guard !addition.overflow else { throw ProofFailure.malformedResponse }
                total = addition.partialValue
                if !interval.isToday {
                    let addition = observed.addingReportingOverflow(bytes)
                    guard !addition.overflow else { throw ProofFailure.malformedResponse }
                    observed = addition.partialValue
                    if interval.isCompleteDay {
                        completed += 1
                    }
                }
            }
            cursor = interval.end
        }
        guard cursor == min(history.attemptedAt, history.context.bundle.cycleEnd),
              presentation.totalObservedBytes == total else { throw ProofFailure.malformedResponse }
        return (observed, completed)
    }

    private func verifyObservation(
        _ observation: HistoryObservation, history: UsageHistory, cursor: Date, until: Date,
    ) throws {
        let interval = observation.interval
        let matches = self.summaries.filter {
            $0.subscriptionID == history.context.subscriptionID && $0.start == interval.start && $0.end == interval.end
        }
        let today = Self.calendar.startOfDay(for: history.attemptedAt)
        if cursor == until, cursor == today, interval.start == cursor, interval.end == cursor {
            guard interval.dayStart == today, interval.isToday, !interval.isCompleteDay,
                  matches.isEmpty, observation.bytes == nil, observation.fetchedAt == nil, !observation.isStale
            else { throw ProofFailure.malformedResponse }
            return
        }
        guard matches.count == 1, let match = matches.first,
              interval.start == cursor, interval.dayStart == Self.calendar.startOfDay(for: cursor),
              let nextDay = Self.calendar.date(byAdding: .day, value: 1, to: interval.dayStart),
              interval.end == min(nextDay, until),
              interval.isToday == (interval.dayStart == today),
              interval.isCompleteDay == (interval.start == interval.dayStart && interval.end == nextDay),
              observation.bytes == match.bytes, !observation.isStale, observation.fetchedAt != nil
        else { throw ProofFailure.malformedResponse }
    }

    private func verifyChart(
        history: UsageHistory, chart: HistoryChartSeries, presentation: HistoryPresentation,
    ) throws {
        let today = Self.calendar.startOfDay(for: history.attemptedAt)
        guard let start = Self.calendar.date(byAdding: .day, value: -29, to: today) else {
            throw ProofFailure.malformedResponse
        }
        var cursor = start
        for (observation, day) in zip(chart.observations, presentation.days) {
            try self.verifyObservation(observation, history: history, cursor: cursor, until: history.attemptedAt)
            let interval = observation.interval
            guard day.dayStart == interval.dayStart, day.bytes == observation.bytes,
                  day.isMissing == (observation.bytes == nil), day.isToday == interval.isToday, !day.isStale,
                  day.isPartial == !interval.isCompleteDay,
                  day.value == observation.bytes.map({ Double($0) / 1_000_000_000 })
            else { throw ProofFailure.malformedResponse }
            cursor = interval.end
        }
        guard cursor == history.attemptedAt else { throw ProofFailure.malformedResponse }
        let cycleStart = history.context.bundle.cycleStart
        if cycleStart >= start, cycleStart <= history.attemptedAt {
            let dayStart = Self.calendar.startOfDay(for: cycleStart)
            guard let boundary = presentation.boundary,
                  let index = presentation.days.firstIndex(where: { $0.dayStart == dayStart }),
                  let next = Self.calendar.date(byAdding: .day, value: 1, to: dayStart),
                  boundary.instant == cycleStart, boundary.dayStart == dayStart,
                  boundary.label == "Cycle started"
            else { throw ProofFailure.malformedResponse }
            let position = Double(index) - 0.5 + cycleStart.timeIntervalSince(dayStart) / next
                .timeIntervalSince(dayStart)
            guard abs(boundary.position - position) < 1e-12 else { throw ProofFailure.malformedResponse }
        } else if presentation.boundary != nil {
            throw ProofFailure.malformedResponse
        }
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Brussels")!
        return calendar
    }

    private static func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw ProofFailure.malformedResponse }
        return date
    }
}

private struct HistoryOracleRow: Decodable {
    let trafficType: String
    let regionality: String
    let incoming: Bool
    let numberOfRecords: UInt64
    let totalDuration: Decimal
    let totalQuantity: UInt64
    let totalPrice: Decimal

    enum CodingKeys: String, CodingKey {
        case trafficType = "traffic_type"
        case numberOfRecords = "number_of_records"
        case totalDuration = "total_duration"
        case totalQuantity = "total_quantity"
        case totalPrice = "total_price"
        case regionality, incoming
    }
}

private enum HistoryOraclePayload: Decodable {
    case rows([HistoryOracleRow])
    case grouped(HistoryOracleGroupedResponse)

    init(from decoder: any Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            var rows: [HistoryOracleRow] = []
            while !container.isAtEnd {
                try rows.append(container.decode(HistoryOracleRow.self))
            }
            self = .rows(rows)
        } else {
            self = try .grouped(HistoryOracleGroupedResponse(from: decoder))
        }
    }
}

private struct HistoryOracleGroupedResponse: Decodable {
    let outgoing: HistoryOracleGroupedDirection
}

private struct HistoryOracleGroupedDirection: Decodable {
    let data: HistoryOracleGroupedTotals
}

private struct HistoryOracleGroupedTotals: Decodable {
    let numberOfRecords: UInt64
    let totalDuration: Decimal
    let totalQuantity: UInt64
    let totalPrice: Decimal

    enum CodingKeys: String, CodingKey {
        case numberOfRecords = "number_of_records"
        case totalDuration = "total_duration"
        case totalQuantity = "total_quantity"
        case totalPrice = "total_price"
    }
}

extension VikingBarCLI {
    static func historyProof() async {
        do {
            let transport = HistoryOracleTransport(base: EphemeralProofTransport())
            let session = try VikingSession.production(transport: transport)
            _ = try await session.restore()
            _ = try await session.refresh(forceTokenRefresh: true)
            let state = try await session.refreshHistory(force: true)
            let presentation = HistoryPresentation(history: state.history, unit: .gigabytes, now: Date())
            try await self.writeJSON(transport.receipt(state: state, presentation: presentation))
        } catch {
            let diagnostic = switch error {
            case HistoryOracleFailure.insufficientEvidence: "history-evidence-insufficient"
            case LiveFailure.busy: "session-busy"
            default: "history-api-failed"
            }
            self.writeJSON(CommandFailure(error: diagnostic))
            exit(1)
        }
    }
}
