import Testing
@testable import VikingBarCore

struct HistoryPresentationTests {
    @Test func `day presentation exposes exact brussels dates and observation boundaries`() throws {
        let history = UsageHistoryTests.history(
            start: "2026-09-01T12:00:00+02:00",
            now: "2026-09-08T12:00:00+02:00",
        )
        let presentation = HistoryPresentation(history: history, now: history.attemptedAt)
        let first = try #require(presentation.days.first)
        let today = try #require(presentation.days.last)
        #expect(first.fullDateText == "1 September 2026")
        #expect(first.isPartial)
        #expect(!first.isToday)
        #expect(first.statusText == "Data usage confirmed")
        #expect(today.fullDateText == "8 September 2026")
        #expect(today.isPartial)
        #expect(today.isToday)

        let zero = HistoryPresentation(history: UsageHistoryTests.history(bytes: 0), now: history.attemptedAt)
        #expect(zero.days.first?.statusText == "Confirmed zero usage")
        let missingObservation = HistoryObservation(
            interval: history.observations[0].interval,
            bytes: nil,
            fetchedAt: history.attemptedAt,
        )
        let missing = UsageHistory(
            context: history.context,
            observations: [missingObservation] + history.observations.dropFirst(),
            attemptedAt: history.attemptedAt,
        )
        #expect(HistoryPresentation(history: missing, now: history.attemptedAt).days.first?.statusText
            == "No data (missing)")
    }
}
