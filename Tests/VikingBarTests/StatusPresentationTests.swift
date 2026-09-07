import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

struct StatusPresentationTests {
    private let date = Date(timeIntervalSince1970: 1_783_252_800)
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test(arguments: [
        (100 as UInt64, 100 as UInt64, HelmetTreatment.finite(fraction: 1)),
        (100, 50, .finite(fraction: 0.5)),
        (100, 1, .finite(fraction: 0.01)),
        (100, 0, .finite(fraction: 0)),
        (0, 0, .unavailable),
        (0, 10, .unavailable),
        (100, 150, .finite(fraction: 1)),
    ])
    func `finite fill follows remaining allowance with undefined totals guarded`(
        total: UInt64, remaining: UInt64, expected: HelmetTreatment,
    ) {
        let snapshot = self.snapshot(.finite(totalBytes: total, usedBytes: 0, remainingBytes: remaining))
        let status = StatusPresentation(snapshot: snapshot, showRemainingGB: false)
        #expect(status.treatment == expected)
        #expect(status.title.isEmpty)
    }

    @Test(arguments: [
        (0 as UInt64, "0 GB"), (1, "<0.1 GB"), (99_999_999, "<0.1 GB"),
        (100_000_000, "0.1 GB"), (1_000_000_000, "1 GB"), (1_250_000_000, "1.2 GB"),
        (24_000_000_000, "24 GB"), (36_000_000_000, "36 GB"),
    ])
    func `optional amount is compact decimal GB independent of card units`(bytes: UInt64, expected: String) {
        let snapshot = self.snapshot(.finite(totalBytes: 50_000_000_000, usedBytes: 0, remainingBytes: bytes))
        for unit in DataUnit.allCases {
            #expect(StatusPresentation(snapshot: snapshot, showRemainingGB: true, unit: unit).title == expected)
            #expect(StatusPresentation(snapshot: snapshot, showRemainingGB: false, unit: unit).title.isEmpty)
        }
    }

    @Test func `exceptional states remain honest with and without text`() {
        let unlimited = self.snapshot(.unlimited(usedBytes: 42))
        let unknown = self.snapshot(.unavailable)
        #expect(StatusPresentation(snapshot: unlimited, showRemainingGB: true).title == "Unlimited")
        #expect(StatusPresentation(snapshot: unlimited, showRemainingGB: false).treatment == .unlimited)
        #expect(StatusPresentation(snapshot: unknown, showRemainingGB: true).title == "Unavailable")
        #expect(StatusPresentation(snapshot: unknown, showRemainingGB: false).treatment == .unavailable)
    }

    @Test func `status preserves selected subscription amount provenance and exact stale date`() {
        let snapshot = FixtureState.stale.snapshot(referenceDate: self.date)
        let menu = MenuPresentation(snapshot: snapshot, unit: .gibibytes, timeZone: self.utc)
        let status = StatusPresentation(snapshot: snapshot, showRemainingGB: true, unit: .gibibytes, timeZone: self.utc)
        #expect(status.treatment == .finite(fraction: 0.72))
        #expect(status.title == "36 GB")
        #expect(status.accessibilityLabel.contains(menu.remainingText))
        #expect(status.accessibilityLabel.contains(menu.title))
        #expect(status.accessibilityLabel.contains(menu.sourceLabel))
        #expect(status.accessibilityLabel.contains(menu.freshnessText))
        #expect(status.accessibilityLabel.contains("Stale"))
    }

    @MainActor @Test func `session updates status without mounted views using the card snapshot`() throws {
        let options = try LaunchOptions(arguments: ["--fixture", "finite", "--time-zone", "UTC"])
        let session = FixtureSession(
            options: options,
            preferences: MenuBarPreferences(fileURL: nil),
            referenceDate: self.date,
        )
        var updates: [StatusPresentation] = []
        session.onPresentationChange = { updates.append(session.status) }
        #expect(session.status.title.isEmpty)
        session.showRemainingGB = true
        session.fixture = .exhausted
        session.unit = .gibibytes
        session.fixture = .stale
        session.showRemainingGB = false
        #expect(updates.count == 5)
        #expect(updates[0].title == "36 GB")
        #expect(updates[1].title == "0 GB")
        #expect(updates[2].accessibilityLabel.contains("0.00 GiB"))
        #expect(updates[3].title == "36 GB")
        #expect(updates[4].title.isEmpty)
        for fixture in FixtureState.allCases {
            session.fixture = fixture
            #expect(session.snapshot == fixture.snapshot(referenceDate: self.date))
            #expect(session.menu == MenuPresentation(
                snapshot: session.snapshot,
                unit: session.unit,
                timeZone: session.timeZone,
            ))
            #expect(session.status.accessibilityLabel.contains(session.menu.freshnessText))
        }
        session.fixture = nil
        #expect(session.snapshot == .notConnected)
        #expect(session.status.treatment == .unavailable)
        session.onPresentationChange = nil
    }

    private func snapshot(_ allowance: Allowance) -> UsageSnapshot {
        UsageSnapshot(source: .notConnected, subscriptionName: "Selected SIM", allowance: allowance,
                      expiresAt: nil, freshness: .current(lastUpdated: self.date))
    }
}
