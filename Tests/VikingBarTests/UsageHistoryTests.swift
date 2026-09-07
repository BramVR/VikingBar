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

    @Test func `retained partial observations stop claiming today after brussels midnight`() throws {
        let history = Self.history(now: "2026-09-08T23:59:00+02:00")
        let nextDay = HistoryPresentation(history: history, now: history.attemptedAt.addingTimeInterval(120))
        let last = try #require(nextDay.days.last)
        #expect(!last.isToday)
        #expect(last.valueText.contains("partial"))
        #expect(!last.valueText.contains("today"))
        #expect(nextDay.forecast == nil)
    }

    @Test func `allowlist admits only fixed outgoing data datetime summary queries`() throws {
        let interval = Self.plan(start: "2026-10-25T00:00:00+02:00", now: "2026-10-26T12:00:00+01:00").intervals[0]
        let request = try ProofEndpoint.usageSummary(subscriptionID: "sim-a", from: interval.start, until: interval.end)
            .request()
        try ProofEndpoint.validate(request)
        let url = try #require(request.url)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.queryItems?.first(where: { $0.name == "from_date" })?.value == "2026-10-24T22:00:00.000Z")
        #expect(parts.queryItems?.first(where: { $0.name == "until_date" })?.value == "2026-10-25T23:00:00.000Z")
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

    static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    static func row(bytes: String = "1", region: String = "national") -> String {
        """
        {"traffic_type":"data","regionality":"\(region)","incoming":false,"number_of_records":1,
        "total_duration":0,"total_quantity":\(bytes),"total_price":0}
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
        bytes: UInt64 = 1_000_000_000,
    ) -> UsageHistory {
        let start = Self.date(start)
        let now = Self.date(now)
        let bundle = BalanceBundle(
            title: "Data", description: "Synthetic", category: "default", type: "data", total: 10_000_000_000,
            used: 2_000_000_000, remaining: 8_000_000_000, validFrom: start,
            validUntil: start.addingTimeInterval(2_592_000),
        )
        let context = HistoryContext(
            connectionID: ConnectionID(), subscriptionID: "sim-a", bundleIndex: 0,
            bundle: HistoryBundleIdentity(bundle: bundle), revision: UUID(),
        )
        let plan = HistoryPlan(cycleStart: start, cycleEnd: bundle.validUntil, now: now)
        return UsageHistory(
            context: context,
            observations: plan.intervals.map { HistoryObservation(interval: $0, bytes: bytes, fetchedAt: now) },
            attemptedAt: now,
        )
    }
}
