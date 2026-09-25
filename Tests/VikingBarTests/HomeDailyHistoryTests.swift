import Foundation
import Testing
@testable import VikingBarCore

struct HomeDailyHistoryTests {
    private static func instant(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    private static func daily(_ rows: String) -> Data {
        Data("""
        {"internetUsage":[{"totalUsage":{"peak":15,"offPeak":45},"dailyUsages":[\(rows)]}]}
        """.utf8)
    }

    private static func row(
        _ day: String, total: String = "1", peak: String = "0.25", offPeak: String = "0.75",
    ) -> String {
        """
        {"date":"\(day)T00:00:00+02:00","total":\(total),"peak":\(peak),"offPeak":\(offPeak)}
        """
    }

    private static func decode(_ rows: String, fetchedAt: Date) throws -> HomeUsage {
        try HomeUsageDecoder.decode(
            TelenetHomePayload(
                cycle: HomeUsageTests.cycle,
                usage: HomeUsageTests.usage(),
                dailyUsage: self.daily(rows),
            ),
            key: HomeUsageTests.key, connectionID: HomeUsageTests.connection, fetchedAt: fetchedAt,
        )
    }

    @Test func `reported rows exclude future placeholders and forecast complete Brussels days`() throws {
        let rows = (1 ... 4).map { Self.row(String(format: "2026-09-%02d", $0)) }
            + [Self.row("2026-09-05", total: "0.5", peak: "0.2", offPeak: "0.3"),
               Self.row("2026-09-06", total: "0", peak: "0", offPeak: "0")]
        let now = Self.instant("2026-09-05T12:00:00+02:00")
        let usage = try Self.decode(rows.joined(separator: ","), fetchedAt: now)
        #expect(usage.dailyHistory?.rows.count == 5)
        #expect(usage.dailyHistory?.rows.last?.totalGB == Decimal(string: "0.5"))
        let chart = HistoryPresentation(home: usage, now: now)
        #expect(chart.days.count == 30)
        #expect(chart.days.last?.bytes == 500_000_000)
        #expect(chart.days.last?.isPartial == true)
        #expect(chart.days.first?.statusText == "Outside billing period")
        #expect(chart.days.first?.isMissing == false)
        #expect(chart.totalObservedBytes == 4_500_000_000)
        #expect(chart.forecast?.observedBytes == 4_000_000_000)
        #expect(chart.forecast?.completeDays == 4)
        #expect(chart.forecast?.observedSeconds == 345_600)
        #expect(abs((chart.forecast?.estimatedCycleBytes ?? 0) - 30_000_000_000) < 1)
        #expect(chart.scopeText.contains("policy counter"))
    }

    @Test func `missing day blocks forecast and reported zero remains an observation`() throws {
        let now = Self.instant("2026-09-05T12:00:00+02:00")
        let usage = try Self.decode([
            Self.row("2026-09-01"), Self.row("2026-09-02", total: "0", peak: "0", offPeak: "0"),
            Self.row("2026-09-04"), Self.row("2026-09-05"),
        ].joined(separator: ","), fetchedAt: now)
        let chart = HistoryPresentation(home: usage, now: now)
        #expect(chart.days.first(where: { $0.fullDateText == "2 September 2026" })?.statusText
            == "Reported zero downloads")
        #expect(chart.days.first(where: { $0.fullDateText == "3 September 2026" })?.statusText
            == "No data (missing)")
        #expect(chart.forecast == nil)
        #expect(chart.totalObservedBytes == 3_000_000_000)
    }

    @Test func `cached fetch day remains partial after midnight and cannot forecast`() throws {
        let fetched = Self.instant("2026-09-04T23:50:00+02:00")
        let now = Self.instant("2026-09-05T00:10:00+02:00")
        let rows = (1 ... 4).map { Self.row(String(format: "2026-09-%02d", $0)) }.joined(separator: ",")
        let chart = try HistoryPresentation(home: Self.decode(rows, fetchedAt: fetched), now: now)
        #expect(chart.days.first(where: { $0.fullDateText == "4 September 2026" })?.isPartial == true)
        #expect(chart.days.last?.bytes == nil)
        #expect(chart.forecast == nil)
    }

    @Test func `invalid optional rows retain the provider period total and primary usage`() throws {
        let fetched = Self.instant("2026-09-05T12:00:00+02:00")
        for rows in [
            [Self.row("2026-09-01"), Self.row("2026-09-01")].joined(separator: ","),
            Self.row("2026-09-01", total: "-1"),
            Self.row("2026-09-01", total: "999999999999999999999999"),
            Self.row("2026-08-31"),
            Self.row("2026-09-01").replacingOccurrences(of: "T00:00:00+02:00", with: "T14:00:00+02:00"),
        ] {
            let usage = try Self.decode(rows, fetchedAt: fetched)
            #expect(usage.dailyHistory == nil)
            #expect(usage.downloaded?.totalGB == 60)
            #expect(usage.policyCounterGB == Decimal(string: "20.25"))
        }
    }

    @Test func `old cached home usage decodes without daily history`() throws {
        let old = try HomeUsageTests.decode()
        let encoded = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(HomeUsage.self, from: encoded)
        #expect(decoded.dailyHistory == nil)
        #expect(decoded.downloaded?.totalGB == 60)
    }

    @Test func `duplicate cached daily rows are rejected before presentation`() throws {
        let fetched = Self.instant("2026-09-05T12:00:00+02:00")
        let usage = try Self.decode(Self.row("2026-09-01"), fetchedAt: fetched)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(usage)) as? [String: Any])
        var history = try #require(object["dailyHistory"] as? [String: Any])
        let rows = try #require(history["rows"] as? [[String: Any]])
        history["rows"] = rows + rows
        object["dailyHistory"] = history
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: LiveFailure.malformedResponse) {
            try JSONDecoder().decode(HomeUsage.self, from: malformed)
        }
    }

    @Test func `daily failure and stale report suppress the estimate`() throws {
        let now = Self.instant("2026-09-05T12:00:00+02:00")
        let rows = (1 ... 5).map { Self.row(String(format: "2026-09-%02d", $0)) }.joined(separator: ",")
        let usage = try Self.decode(rows, fetchedAt: now)
        #expect(HistoryPresentation(home: usage, now: now).forecast != nil)
        let failed = HistoryPresentation(home: usage, dailyFailure: .transport, now: now)
        #expect(failed.forecast == nil)
        #expect(failed.statusText.contains("unavailable"))
        let stale = HistoryPresentation(home: usage, now: now.addingTimeInterval(3600))
        #expect(stale.forecast == nil)
        #expect(stale.days.last?.isStale == true)
        #expect(HistoryPresentation(home: usage, now: now.addingTimeInterval(3599)).forecast != nil)
    }

    @Test func `decimal daily total rounds once at presentation boundary and honors GiB`() throws {
        let now = Self.instant("2026-09-05T12:00:00+02:00")
        let usage = try Self.decode(Self.row("2026-09-05", total: "0.0000000005", peak: "0", offPeak: "0"),
                                    fetchedAt: now)
        #expect(usage.dailyHistory?.rows.first?.totalGB == Decimal(string: "0.0000000005"))
        let chart = HistoryPresentation(home: usage, unit: .gibibytes, now: now)
        #expect(chart.days.last?.bytes == 1)
        #expect(chart.unit == "GiB")
    }

    @Test func `forecast uses actual seconds across Brussels daylight saving change`() throws {
        let period = try BillingPeriod(start: CalendarDay("2026-10-24"), end: CalendarDay("2026-11-02"))
        let fetched = Self.instant("2026-10-27T12:00:00+01:00")
        let history = try HomeDailyHistory(
            fetchedDay: CalendarDay("2026-10-27"), rows: [
                HomeDailyUsage(day: CalendarDay("2026-10-24"), totalGB: 1, peakGB: 0, offPeakGB: 1),
                HomeDailyUsage(day: CalendarDay("2026-10-25"), totalGB: 1, peakGB: 0, offPeakGB: 1),
                HomeDailyUsage(day: CalendarDay("2026-10-26"), totalGB: 1, peakGB: 0, offPeakGB: 1),
                HomeDailyUsage(day: CalendarDay("2026-10-27"), totalGB: 1, peakGB: 0, offPeakGB: 1),
            ], period: period,
        )
        let home = try HomeUsage(
            key: HomeUsageTests.key, connectionID: HomeUsageTests.connection, period: period, category: .cap,
            policyCounterGB: 4, reportedAllocationGB: 100, downloaded: nil, dailyHistory: history,
            providerUpdatedAt: nil, fetchedAt: fetched,
        )
        let forecast = try #require(HistoryPresentation(home: home, now: fetched).forecast)
        #expect(forecast.observedSeconds == 73 * 3600)
        #expect(forecast.completeDays == 3)
        #expect(abs(forecast.estimatedCycleBytes - 3_000_000_000 / 73.0 * 241) < 1)
    }
}
