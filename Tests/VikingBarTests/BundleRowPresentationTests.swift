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
            Self.row(0, .sms, "Monthly SMS", "Synthetic monthly SMS", "60 SMS", "40 SMS used", "100 SMS total",
                     "SMS · default", expires, .finite),
            Self.row(1, .voice, "Call bundle 2", "", "19 min 30 s", "20 min 30 s used", "40 min total",
                     "Calls · default", expires, .finite),
            Self.row(2, .value, "Prepaid credit", "Synthetic prepaid credit", "€12.50", "€2.50 used", "€15.00 total",
                     "Credit · default", expires, .finite),
            Self.row(3, .sms, "Unlimited SMS", "Synthetic unlimited SMS", "Unlimited", "12 SMS used",
                     "Unlimited allowance", "SMS · super_on_net", expires, .unlimited),
            Self.row(4, .voice, "Roaming calls", "Synthetic roaming minutes", "Unavailable", "Usage unavailable",
                     "Allowance unavailable", "Calls · default", "Expired 4 Jul 2026, 12:00 GMT", .expired),
        ])
    }

    @Test func `each fixture SIM has its own rows and other states have none`() {
        let travel = FixtureState.mixed.nonDataBundles(subscriptionID: "travel", referenceDate: Self.referenceDate)
        let rows = BundleRowPresentation.rows(for: travel, at: Self.referenceDate, timeZone: Self.utc)
        #expect(rows.map(\.title) == ["Travel credit"])
        #expect(rows.map(\.remainingText) == ["€5.00"])
        for state in FixtureState.allCases where state != .mixed {
            #expect(state.nonDataBundles(subscriptionID: "example", referenceDate: Self.referenceDate).isEmpty)
        }
    }

    @Test func `data bundles are excluded and indices stay provider positions`() {
        let bundles = [
            Self.bundle(.data, total: 50, used: 20, remaining: 30),
            Self.bundle(.voice, total: 45, used: 0, remaining: 45),
            Self.bundle(.data, total: 10, used: 1, remaining: 9),
            Self.bundle(.value, total: 0, used: 0, remaining: 0),
        ]
        let rows = BundleRowPresentation.rows(for: bundles, at: Self.referenceDate, timeZone: Self.utc)
        #expect(rows.map(\.index) == [1, 3])
        #expect(rows.map(\.title) == ["Call bundle 2", "Credit bundle 4"])
        #expect(rows.map(\.remainingText) == ["45 s", "€0.00"])
        #expect(rows.map(\.usedText) == ["0 s used", "€0.00 used"])
        #expect(rows.map(\.state) == [.finite, .exhausted])
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

    // swiftlint:disable:next function_parameter_count
    private static func row(
        _ index: Int, _ kind: BundleKind, _ title: String, _ description: String, _ remaining: String,
        _ used: String, _ total: String, _ detail: String, _ validity: String, _ state: BundleRowPresentation.State,
    ) -> BundleRowPresentation {
        BundleRowPresentation(
            index: index, kind: kind, title: title, description: description, remainingText: remaining,
            usedText: used, totalText: total, detailText: detail, validityText: validity, state: state,
        )
    }
}
