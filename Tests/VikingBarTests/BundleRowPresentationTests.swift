import Foundation
import Testing
@testable import VikingBarCore

struct BundleRowPresentationTests {
    private static let referenceDate = Date(timeIntervalSince1970: 1_783_252_800)
    private static let utc = TimeZone(identifier: "UTC")!

    @Test func `mixed fixture rows show each kind in its own unit`() {
        let bundles = FixtureState.mixed.nonDataBundles(subscriptionID: "example", referenceDate: Self.referenceDate)
        let rows = BundleRowPresentation.rows(for: bundles, at: Self.referenceDate, timeZone: Self.utc)
        let expires = "Expires 19 Jul 2026, 12:00 GMT"
        #expect(rows == [
            BundleRowPresentation(
                index: 0, kind: .sms, title: "Monthly SMS", description: "Synthetic monthly SMS",
                remainingText: "60 SMS", usedText: "40 SMS used", totalText: "100 SMS total",
                detailText: "SMS · default", validityText: expires, state: .finite, percentageRemaining: 60,
            ),
            BundleRowPresentation(
                index: 1, kind: .voice, title: "Call bundle 2", description: "", remainingText: "19 min 30 s",
                usedText: "20 min 30 s used", totalText: "40 min total", detailText: "Calls · default",
                validityText: expires, state: .finite, percentageRemaining: 48.75,
            ),
            BundleRowPresentation(
                index: 2, kind: .value, title: "Prepaid credit", description: "Synthetic prepaid credit",
                remainingText: "€12.50", usedText: "€2.50 used", totalText: "€15.00 total",
                detailText: "Credit · default", validityText: expires, state: .finite,
                percentageRemaining: 12.5 * 100 / 15,
            ),
            BundleRowPresentation(
                index: 3, kind: .sms, title: "Unlimited SMS", description: "Synthetic unlimited SMS",
                remainingText: "Unlimited", usedText: "12 SMS used", totalText: "Unlimited allowance",
                detailText: "SMS · super_on_net", validityText: expires, state: .unlimited, percentageRemaining: nil,
            ),
            BundleRowPresentation(
                index: 4, kind: .voice, title: "Roaming calls", description: "Synthetic roaming minutes",
                remainingText: "Unavailable", usedText: "Usage unavailable", totalText: "Allowance unavailable",
                detailText: "Calls · default", validityText: "Expired 4 Jul 2026, 12:00 GMT", state: .expired,
                percentageRemaining: nil,
            ),
        ])
    }

    @Test func `zero-sized call and SMS bundles get no rows`() {
        let bundles = [
            Self.bundle(.voice, total: 0, used: 0, remaining: 0),
            Self.bundle(.sms, total: 0, used: 0, remaining: 0),
        ]
        #expect(BundleRowPresentation.rows(for: bundles, at: Self.referenceDate, timeZone: Self.utc) == [])
    }

    @Test func `only zero-sized bundles are hidden and the rest keep provider indices`() {
        let bundles = [
            Self.bundle(.voice, total: 0, used: 0, remaining: 0),
            Self.bundle(.sms, total: -1, used: 3, remaining: -1),
            Self.bundle(.value, total: 0, used: 0, remaining: 0),
            Self.bundle(.voice, total: 120, used: 60, remaining: 60),
        ]
        let rows = BundleRowPresentation.rows(for: bundles, at: Self.referenceDate, timeZone: Self.utc)
        let expires = "Expires 19 Jul 2026, 12:00 GMT"
        #expect(rows == [
            BundleRowPresentation(
                index: 1, kind: .sms, title: "SMS bundle 2", description: "", remainingText: "Unlimited",
                usedText: "3 SMS used", totalText: "Unlimited allowance", detailText: "SMS · default",
                validityText: expires, state: .unlimited, percentageRemaining: nil,
            ),
            BundleRowPresentation(
                index: 3, kind: .voice, title: "Call bundle 4", description: "", remainingText: "1 min",
                usedText: "1 min used", totalText: "2 min total", detailText: "Calls · default",
                validityText: expires, state: .finite, percentageRemaining: 50,
            ),
        ])
    }

    @Test func `each fixture SIM has its own rows and other states have none`() {
        let travel = FixtureState.mixed.nonDataBundles(subscriptionID: "travel", referenceDate: Self.referenceDate)
        let rows = BundleRowPresentation.rows(for: travel, at: Self.referenceDate, timeZone: Self.utc)
        #expect(rows.map(\.title) == ["Travel credit"])
        #expect(rows.map(\.remainingText) == ["€5.00"])
        #expect(rows.map(\.percentageRemaining) == [100])
        for state in FixtureState.allCases where state != .mixed {
            #expect(state.nonDataBundles(subscriptionID: "example", referenceDate: Self.referenceDate).isEmpty)
        }
    }

    @Test func `data bundles are excluded and indices stay provider positions`() {
        let bundles = [
            Self.bundle(.data, total: 50, used: 20, remaining: 30),
            Self.bundle(.voice, total: 45, used: 0, remaining: 45),
            Self.bundle(.data, total: 10, used: 1, remaining: 9),
            Self.bundle(.value, total: 5, used: 5, remaining: 0),
        ]
        let rows = BundleRowPresentation.rows(for: bundles, at: Self.referenceDate, timeZone: Self.utc)
        #expect(rows.map(\.index) == [1, 3])
        #expect(rows.map(\.title) == ["Call bundle 2", "Credit bundle 4"])
        #expect(rows.map(\.remainingText) == ["45 s", "€0.00"])
        #expect(rows.map(\.usedText) == ["0 min used", "€5.00 used"])
        #expect(rows.map(\.state) == [.finite, .exhausted])
        #expect(rows.map(\.percentageRemaining) == [100, 0])
        #expect(LiveBalancePresentation.title(for: bundles[2], index: 2) == "Data bundle 3")
        #expect(LiveBalancePresentation.title(for: Self.bundle(.sms, total: 1, used: 0, remaining: 1), index: 0)
            == "SMS bundle 1")
    }

    @Test func `upcoming and unrepresentable bundles keep amounts unavailable`() throws {
        let upcoming = Self.bundle(
            .sms, total: 10, used: 0, remaining: 10,
            validFrom: Self.referenceDate.addingTimeInterval(3600),
            validUntil: Self.referenceDate.addingTimeInterval(86400),
        )
        let fractional = try Self.bundle(
            .voice,
            total: 60,
            used: #require(Decimal(string: "0.5")),
            remaining: #require(Decimal(string: "59.5")),
        )
        let rows = BundleRowPresentation.rows(for: [upcoming, fractional], at: Self.referenceDate, timeZone: Self.utc)
        #expect(rows.map(\.validityText) == ["Starts 5 Jul 2026, 13:00 GMT", "Expires 19 Jul 2026, 12:00 GMT"])
        #expect(rows.map(\.state) == [.upcoming, .unavailable])
        #expect(rows.map(\.remainingText) == ["Unavailable", "Unavailable"])
        #expect(rows.map(\.totalText) == ["Allowance unavailable", "Allowance unavailable"])
        #expect(BundleRowPresentation.duration(7200) == "120 min")
    }

    @Test func `fixture report carries mixed rows and empty rows for other states`() throws {
        for state in FixtureState.allCases {
            let options = try LaunchOptions(arguments: ["--fixture", state.rawValue, "--time-zone", "UTC"])
            let report = try FixtureReport(options: options, referenceDate: Self.referenceDate)
            #expect(report.nonDataBundles.map(\.kind) == (state == .mixed
                    ? [.sms, .voice, .value, .sms, .voice]
                    : []))
        }
    }

    private static func bundle(
        _ type: BundleKind, total: Decimal, used: Decimal, remaining: Decimal,
        validFrom: Date? = nil, validUntil: Date? = nil,
    ) -> BalanceBundle {
        BalanceBundle(
            title: "", description: "", category: "default", type: type, total: total, used: used,
            remaining: remaining, validFrom: validFrom ?? self.referenceDate.addingTimeInterval(-86400),
            validUntil: validUntil ?? self.referenceDate.addingTimeInterval(14 * 86400),
        )
    }
}
