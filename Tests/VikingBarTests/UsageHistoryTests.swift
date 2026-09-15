import Foundation
import Testing
@testable import VikingBarCore

struct UsageHistoryTests {
    @Test func `brussels days include spring and autumn DST and clipped cycle boundaries`() {
        let spring = Self.plan(start: "2026-03-28T00:00:00+01:00", now: "2026-03-31T12:00:00+02:00")
        #expect(spring.intervals.map { $0.end.timeIntervalSince($0.start) } == [86400, 82800, 86400, 43200])
        #expect(spring.intervals.filter(\.isCompleteDay).count == 3)
        #expect(spring.intervals.last?.isToday == true)
        let autumn = Self.plan(start: "2026-10-24T00:00:00+02:00", now: "2026-10-27T12:00:00+01:00")
        #expect(autumn.intervals.map { $0.end.timeIntervalSince($0.start) } == [86400, 90000, 86400, 43200])
        let clipped = Self.plan(start: "2026-03-28T12:00:00+01:00", now: "2026-03-31T12:00:00+02:00")
        #expect(clipped.intervals[0].start == Self.date("2026-03-28T12:00:00+01:00"))
        #expect(!clipped.intervals[0].isCompleteDay)
        #expect(clipped.intervals.filter(\.isCompleteDay).count == 2)
    }

    @Test func `history clips to exact cycle end and bounds long cycles at sixty two requests`() {
        let start = Self.date("2026-01-01T00:00:00+01:00")
        let end = Self.date("2026-01-03T12:34:00+01:00")
        let ended = HistoryPlan(cycleStart: start, cycleEnd: end, now: end.addingTimeInterval(86400))
        #expect(ended.intervals.count == 3)
        #expect(ended.intervals.last?.end == end)
        #expect(ended.intervals.last?.isCompleteDay == false)
        let long = Self.plan(start: "2026-01-01T00:00:00+01:00", now: "2026-06-01T12:00:00+02:00")
        #expect(long.intervals.count == 62)
        #expect(long.truncated)
        #expect(HistoryPlan(cycleStart: end, cycleEnd: end, now: end).intervals.isEmpty)
    }
}

extension UsageHistoryTests {
    @Test func `rolling month keeps exact cycle evidence and marks a midday boundary`() throws {
        let history = Self.history(start: "2026-08-28T12:00:00+02:00", now: "2026-09-15T12:00:00+02:00")
        let plan = HistoryRequestPlan(context: history.context, now: history.attemptedAt)

        #expect(plan.chartIntervals.count == 30)
        #expect(plan.cycleIntervals.count == 19)
        #expect(plan.requestIntervals.count == 31)
        #expect(!plan.cycleTruncated)

        let presentation = HistoryPresentation(history: history, now: history.attemptedAt)
        let boundary = try #require(presentation.boundary)
        #expect(presentation.days.count == 30)
        #expect(boundary.instant == history.context.bundle.cycleStart)
        #expect(boundary.label == "Cycle started")
        #expect(boundary.position == 11)
        #expect(boundary.dateText == "28 August 2026, 12:00")
    }

    @Test func `rolling month boundary fraction uses the actual Brussels DST day`() throws {
        let history = Self.history(start: "2026-03-29T12:00:00+02:00", now: "2026-04-02T12:00:00+02:00")
        let boundary = try #require(HistoryPresentation(history: history, now: history.attemptedAt).boundary)
        let expected = 25.0 - 0.5 + 11.0 / 23.0

        #expect(abs(boundary.position - expected) < 0.000_000_1)
    }

    @Test func `chart failure leaves complete current cycle total and forecast intact`() {
        let source = Self.history()
        let plan = HistoryRequestPlan(context: source.context, now: source.attemptedAt)
        let chart = HistoryChartSeries(
            observations: plan.chartIntervals.map {
                HistoryObservation(interval: $0, bytes: nil, fetchedAt: source.attemptedAt)
            },
            failure: .serverUnavailable,
        )
        let history = UsageHistory(
            context: source.context, observations: source.observations, chartSeries: chart,
            attemptedAt: source.attemptedAt,
        )
        let presentation = HistoryPresentation(history: history, now: history.attemptedAt)
        let allMissing = presentation.days.allSatisfy(\.isMissing)

        #expect(presentation.days.count == 30)
        #expect(allMissing)
        #expect(presentation.totalObservedBytes == 8_000_000_000)
        #expect(presentation.forecast != nil)
    }

    @Test func `long cycle prioritizes the rolling month within the global request cap`() {
        let history = Self.history(
            start: "2026-01-01T00:00:00+01:00", now: "2026-04-15T12:00:00+02:00",
            cycleDuration: 20_000_000,
        )
        let plan = HistoryRequestPlan(context: history.context, now: history.attemptedAt)

        #expect(plan.cycleTruncated)
        #expect(plan.cycleIntervals.isEmpty)
        #expect(plan.chartIntervals.count == 30)
        #expect(plan.requestIntervals == plan.chartIntervals.filter { $0.start < $0.end })
        #expect(plan.requestIntervals.count <= 62)

        let presentation = HistoryPresentation(history: history, now: history.attemptedAt)
        #expect(presentation.totalObservedBytes == nil)
        #expect(presentation.forecast == nil)
        #expect(presentation.totalText == "Observed this cycle unavailable.")
        #expect(presentation.statusText == "Cycle exceeds 62 days. Cycle total and estimate unavailable.")
    }

    @Test func `rolling month includes a zero length today slot at Brussels midnight without requesting it`() {
        let history = Self.history(now: "2026-09-08T00:00:00+02:00")
        let plan = HistoryRequestPlan(context: history.context, now: history.attemptedAt)

        #expect(plan.chartIntervals.count == 30)
        #expect(plan.chartIntervals.last?.start == plan.chartIntervals.last?.end)
        #expect(plan.requestIntervals.allSatisfy { $0.start < $0.end })
        #expect(plan.requestIntervals.count == 29)
        let presentation = HistoryPresentation(history: history, now: history.attemptedAt)
        #expect(presentation.days.count == 30)
        #expect(presentation.days.last?.isToday == true)
        #expect(presentation.days.last?.isMissing == true)
    }

    @Test func `future cycle start later today does not create a chart boundary`() {
        let history = Self.history(start: "2026-09-08T18:00:00+02:00", now: "2026-09-08T12:00:00+02:00")
        #expect(HistoryPresentation(history: history, now: history.attemptedAt).boundary == nil)
    }

    @Test func `history decoded without chart series presents thirty explicit gaps`() throws {
        let history = Self.history()
        let encoded = try JSONEncoder().encode(history)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "chartSeries")
        let oldCache = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(UsageHistory.self, from: oldCache)
        let presentation = HistoryPresentation(history: decoded, now: decoded.attemptedAt)

        #expect(decoded.chartSeries == nil)
        #expect(presentation.days.count == 30)
        #expect(!presentation.days.contains { !$0.isMissing })
    }
}

extension UsageHistoryTests {
    @Test func `forecast uses elapsed seconds through yesterday including clipped first day`() throws {
        let history = Self.history(start: "2026-03-27T12:00:00+01:00", now: "2026-03-31T12:00:00+02:00")
        let presentation = HistoryPresentation(history: history, now: history.attemptedAt)
        let forecast = try #require(presentation.forecast)
        #expect(forecast.completeDays == 3)
        #expect(forecast.observedBytes == 4_000_000_000)
        #expect(forecast.observedSeconds == 298_800)
        #expect(forecast.estimatedCycleBytes == 4e9 / 298_800 * history.context.bundle.cycleEnd.timeIntervalSince(
            history.context.bundle.cycleStart,
        ))
        #expect(presentation.totalObservedBytes == 5_000_000_000)
        #expect(presentation.days.last?.isToday == true)
        #expect(presentation.forecastText.hasPrefix("Estimated SIM data this cycle:"))
    }

    @Test func `zero remains a valid forecast while missing stale gaps short cycles and renewals suppress it`() {
        let zero = Self.history(bytes: 0)
        #expect(HistoryPresentation(history: zero, now: zero.attemptedAt).forecast?.estimatedCycleBytes == 0)
        let complete = Self.history()
        let first = complete.observations[0]
        let variants = [
            Array(complete.observations.dropFirst()),
            [HistoryObservation(interval: first.interval, bytes: nil, fetchedAt: complete.attemptedAt)]
                + complete.observations.dropFirst(),
            [HistoryObservation(interval: first.interval, bytes: 1, fetchedAt: complete.attemptedAt, isStale: true)]
                + complete.observations.dropFirst(),
            complete.observations + [first],
        ]
        for observations in variants {
            let history = UsageHistory(
                context: complete.context, observations: observations, attemptedAt: complete.attemptedAt,
            )
            #expect(HistoryPresentation(history: history, now: history.attemptedAt).forecast == nil)
        }
        let short = Self.history(start: "2026-09-05T12:00:00+02:00", now: "2026-09-08T12:00:00+02:00")
        #expect(HistoryPresentation(history: short, now: short.attemptedAt).forecast == nil)
        #expect(HistoryPresentation(history: complete, now: complete.attemptedAt.addingTimeInterval(300))
            .forecast == nil)
        #expect(HistoryPresentation(history: complete, now: complete.context.bundle.cycleEnd).forecast == nil)
        let truncated = UsageHistory(
            context: complete.context, observations: complete.observations,
            attemptedAt: complete.attemptedAt, truncated: true,
        )
        #expect(HistoryPresentation(history: truncated, now: complete.attemptedAt).forecast == nil)
    }

    @Test func `units convert observations while retaining exact bytes and explicit gaps`() {
        let history = Self.history(bytes: 1_073_741_824)
        let decimal = HistoryPresentation(history: history, unit: .gigabytes, now: history.attemptedAt)
        let binary = HistoryPresentation(history: history, unit: .gibibytes, now: history.attemptedAt)
        #expect(decimal.days[0].value == 1.073741824)
        #expect(binary.days[0].value == 1)
        #expect(binary.days[0].bytes == 1_073_741_824)
        #expect(binary.days[0].valueText == "1.00 GiB")
        #expect(binary.days.last?.valueText.contains("today, partial") == true)
        #expect(binary.scopeText.contains("different scope"))
        #expect(HistoryPresentation(history: nil).totalObservedBytes == nil)
    }

    @Test func `summary validates exact bytes disjoint dimensions and missing versus zero`() throws {
        #expect(try LiveAPI.decodeUsageSummary(Data("[]".utf8)) == nil)
        #expect(try LiveAPI.decodeUsageSummary(Data("[\(Self.row(bytes: "0"))]".utf8)) == 0)
        #expect(try LiveAPI.decodeUsageSummary(Data("[\(Self.row(bytes: "9007199254740993"))]".utf8))
            == 9_007_199_254_740_993)
        #expect(try LiveAPI
            .decodeUsageSummary(Data("[\(Self.row(bytes: "2")),\(Self.row(region: "roaming"))]".utf8)) == 3)
        #expect(try LiveAPI.decodeUsageSummary(Data("[\(Self.row(region: "unknown"))]".utf8)) == 1)
        for row in [
            Self.row(bytes: "-1"), Self.row(bytes: "0.5"), Self.row(bytes: "18446744073709551616"),
            Self.row(bytes: "true"), Self.row(region: "future"),
            Self.row().replacingOccurrences(of: "\"data\"", with: "\"voice\""),
            Self.row().replacingOccurrences(of: "false", with: "true"),
            Self.row() + "," + Self.row(),
            Self.row(bytes: "18446744073709551615") + "," + Self.row(region: "roaming"),
        ] {
            #expect(throws: LiveFailure.malformedResponse) {
                try LiveAPI.decodeUsageSummary(Data("[\(row)]".utf8))
            }
        }
    }

    @Test func `summary accepts grouped outgoing data and ignores unrelated traffic totals`() throws {
        #expect(try LiveAPI.decodeUsageSummary(Data(Self.groupedSummary(quantity: "42").utf8)) == 42)
        #expect(try LiveAPI.decodeUsageSummary(Data(Self.groupedSummary(quantity: "0", records: "0", price: "-1").utf8))
            == 0)
        #expect(try LiveAPI.decodeUsageSummary(Data(Self.groupedSummary(quantity: "18446744073709551615").utf8))
            == UInt64.max)
    }

    @Test func `grouped summary requires exact nonnegative integral data totals`() {
        let missing = """
        {"outgoing":{"data":{"number_of_records":1,"total_duration":0,"total_quantity":1}}}
        """
        let invalid = [
            "{}",
            "{\"incoming\":{\"data\":{}}}",
            "{\"outgoing\":{}}",
            missing,
            Self.groupedSummary(quantity: "-1"),
            Self.groupedSummary(quantity: "0.5"),
            Self.groupedSummary(quantity: "\"1\""),
            Self.groupedSummary(quantity: "null"),
            Self.groupedSummary(quantity: "18446744073709551616"),
            Self.groupedSummary(records: "-1"),
            Self.groupedSummary(records: "0.5"),
            Self.groupedSummary(records: "\"1\""),
            Self.groupedSummary(records: "null"),
            Self.groupedSummary(records: "18446744073709551616"),
            Self.groupedSummary(duration: "-1"),
            Self.groupedSummary(duration: "\"0\""),
            Self.groupedSummary(price: "null"),
        ]
        for value in invalid {
            #expect(throws: LiveFailure.malformedResponse) {
                try LiveAPI.decodeUsageSummary(Data(value.utf8))
            }
        }
    }

    @Test func `retained partial observations stop claiming today after brussels midnight`() throws {
        let history = Self.history(now: "2026-09-08T23:59:00+02:00")
        let nextDay = HistoryPresentation(history: history, now: history.attemptedAt.addingTimeInterval(120))
        let retained = try #require(nextDay.days.first(where: {
            $0.dayStart == HistoryPlan.calendar.startOfDay(for: history.attemptedAt)
        }))
        #expect(!retained.isToday)
        #expect(retained.valueText.contains("partial"))
        #expect(!retained.valueText.contains("today"))
        #expect(nextDay.days.last?.isToday == true)
        #expect(nextDay.days.last?.isMissing == true)
        #expect(nextDay.forecast == nil)
    }

    @Test func `allowlist admits only fixed outgoing data datetime summary queries`() throws {
        let interval = Self.plan(start: "2026-10-25T00:00:00+02:00", now: "2026-10-26T12:00:00+01:00").intervals[0]
        let request = try ProofEndpoint.usageSummary(subscriptionID: "sim-a", from: interval.start, until: interval.end)
            .request()
        try ProofEndpoint.validate(request)
        let url = try #require(request.url)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.queryItems?.first(where: { $0.name == "from_date" })?.value == "2026-10-24T22:00:00+0000")
        #expect(parts.queryItems?.first(where: { $0.name == "until_date" })?.value == "2026-10-25T23:00:00+0000")
        #expect(parts.percentEncodedQuery?.contains("%2B0000") == true)
        #expect(parts.percentEncodedQuery?.contains("+") == false)
        for suffix in ["&bundle=in", "&traffic_type=data", "&extra=value"] {
            var changed = request
            changed.url = try URL(string: #require(request.url?.absoluteString) + suffix)
            #expect(throws: ProofFailure.requestDenied) { try ProofEndpoint.validate(changed) }
        }
        for replacement in ["voice", "data%2Csms"] {
            var changed = request
            changed.url = try URL(string: #require(request.url?.absoluteString.replacingOccurrences(
                of: "traffic_type=data",
                with:
                "traffic_type=\(replacement)",
            )))
            #expect(throws: ProofFailure.requestDenied) { try ProofEndpoint.validate(changed) }
        }
        var detail = request
        detail.url = try URL(string: #require(request.url?.absoluteString.replacingOccurrences(
            of: "usage-summary",
            with: "usage",
        )))
        #expect(throws: ProofFailure.requestDenied) { try ProofEndpoint.validate(detail) }
        #expect(throws: ProofFailure.requestDenied) {
            try ProofEndpoint.usageSummary(subscriptionID: "../x", from: interval.start, until: interval.end).request()
        }
    }

    @Test func `summary rejects unsupported timestamps rather than shifting exact interval boundaries`() throws {
        let start = Self.date("2026-09-01T00:00:00Z")
        let end = start.addingTimeInterval(86400)
        for (from, until) in [(start.addingTimeInterval(0.123), end), (start, end.addingTimeInterval(0.123))] {
            #expect(throws: ProofFailure.requestDenied) {
                try ProofEndpoint.usageSummary(subscriptionID: "sim-a", from: from, until: until).request()
            }
        }
        let request = try ProofEndpoint.usageSummary(subscriptionID: "sim-a", from: start, until: end).request()
        let url = try #require(request.url?.absoluteString)
        for replacement in [".000Z", "Z", "+0000", "%2B0100", "%2B00:00", ""] {
            var changed = request
            changed.url = URL(string: url.replacingOccurrences(of: "%2B0000", with: replacement))
            #expect(throws: ProofFailure.requestDenied) { try ProofEndpoint.validate(changed) }
        }
    }

    static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    static func row(bytes: String = "1", region: String = "national") -> String {
        """
        {"traffic_type":"data","regionality":"\(region)","incoming":false,"number_of_records":1,
        "total_duration":0,"total_quantity":\(bytes),"total_price":0}
        """
    }

    static func groupedSummary(
        quantity: String = "1", records: String = "1", duration: String = "0", price: String = "0",
    ) -> String {
        let unrelated = """
        {"number_of_records":7,"total_duration":8,"total_quantity":900,"total_price":10}
        """
        let selected = """
        {"number_of_records":\(records),"total_duration":\(duration),"total_quantity":\(quantity),
         "total_price":\(price)}
        """
        return """
        {"incoming":{"data":\(unrelated),"sms":\(unrelated),"unknown":\(unrelated),"voice":\(unrelated)},
         "outgoing":{"data":\(selected),"sms":\(unrelated),"unknown":\(unrelated),"voice":\(unrelated)}}
        """
    }

    static func plan(start: String, now: String) -> HistoryPlan {
        HistoryPlan(
            cycleStart: self.date(start),
            cycleEnd: self.date(now).addingTimeInterval(864_000),
            now: self.date(now),
        )
    }

    static func history(
        start: String = "2026-09-01T00:00:00+02:00", now: String = "2026-09-08T12:00:00+02:00",
        bytes: UInt64 = 1_000_000_000, cycleDuration: TimeInterval = 2_592_000,
    ) -> UsageHistory {
        let start = Self.date(start)
        let now = Self.date(now)
        let bundle = BalanceBundle(
            title: "Data", description: "Synthetic", category: "default", type: "data", total: 10_000_000_000,
            used: 2_000_000_000, remaining: 8_000_000_000, validFrom: start,
            validUntil: start.addingTimeInterval(cycleDuration),
        )
        let context = HistoryContext(
            connectionID: ConnectionID(), subscriptionID: "sim-a", bundleIndex: 0,
            bundle: HistoryBundleIdentity(bundle: bundle), revision: UUID(),
        )
        let chartPlan = HistoryRequestPlan(context: context, now: now)
        return UsageHistory(
            context: context,
            observations: chartPlan.cycleIntervals.map {
                HistoryObservation(interval: $0, bytes: bytes, fetchedAt: now)
            },
            chartSeries: HistoryChartSeries(observations: chartPlan.chartIntervals.map {
                HistoryObservation(
                    interval: $0, bytes: $0.start < $0.end ? bytes : nil,
                    fetchedAt: $0.start < $0.end ? now : nil,
                )
            }),
            attemptedAt: now,
            truncated: chartPlan.cycleTruncated,
        )
    }
}
