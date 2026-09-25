import Foundation
import Testing
@testable import VikingBarCore

struct HomeUsageTests {
    static let key = ServiceKey(account: AccountKey(provider: .telenet), kind: .home, providerID: "home-a")
    static let connection = ConnectionID()
    static let cycle = Data(#"{"billCycles":[{"startDate":"2026-09-01","endDate":"2026-09-30"}]}"#.utf8)
    static let daily = Data(#"{"internetUsage":[{"totalUsage":{"peak":15,"offPeak":45}}]}"#.utf8)
    static func usage(category: String = "FUP", counter: String = "20.25", allocation: String = "3000") -> Data {
        Data("""
        {"internet":{"category":"\(category)",
        "totalUsage":{"units":\(counter),"lastUsageDate":"2026-09-20T10:30:00+02:00"},
        "allocatedUsage":{"units":\(allocation)}}}
        """.utf8)
    }

    static func decode(usage: Data? = nil, daily: Data? = daily) throws -> HomeUsage {
        try HomeUsageDecoder.decode(
            TelenetHomePayload(cycle: self.cycle, usage: usage ?? self.usage(), dailyUsage: daily),
            key: self.key,
            connectionID: self.connection,
            fetchedAt: LiveModelsTests.now,
        )
    }

    @Test func `policy counter is separate from downloaded peak and off peak traffic`() throws {
        let usage = try Self.decode()
        #expect(usage.policyCounterGB == Decimal(string: "20.25"))
        #expect(usage.downloaded?.totalGB == 60)
        #expect(usage.downloaded?.peakGB == 15)
        #expect(usage.downloaded?.offPeakGB == 45)
        #expect(usage.providerUpdatedAt == Date(timeIntervalSince1970: 1_789_893_000))
        #expect(usage.snapshot().expiresAt == nil)
        #expect(usage.snapshot().allowance == .speedThreshold(thresholdBytes: 3_000_000_000_000,
                                                              usedBytes: 20_250_000_000, category: "FUP"))
        let presentation = HomeUsagePresentation(usage: usage)
        #expect(presentation.policyCounterText == "Policy counter 20.25 GB")
        #expect(presentation.downloadedText == "Downloaded 60 GB")
        #expect(presentation.speedText == "Speed state unknown")
        #expect(presentation.periodText == "Billing period 2026-09-01 to 2026-09-30")
    }

    @Test func `unlimited allocation is reported without a remaining percentage or inferred speed`() throws {
        let usage = try Self.decode(usage: Self.usage(category: "UNLIMITED", counter: "4000"))
        #expect(usage.snapshot().allowance == .unlimited(usedBytes: 4_000_000_000_000))
        #expect(HomeUsagePresentation(usage: usage).allocationText == "Reported allocation 3000 GB")
        #expect(MenuPresentation(snapshot: usage.snapshot()).percentageRemaining == nil)
        #expect(usage.speed == .unknown)
        let cap = try Self.decode(usage: Self.usage(category: "CAP", counter: "4000"))
        #expect(cap.allowance == .finite(
            totalBytes: 3_000_000_000_000,
            usedBytes: 4_000_000_000_000,
            remainingBytes: 0,
        ))
        let turbo = try Self.decode(usage: Self.usage(category: "TURBO", counter: "4000"))
        #expect(MenuPresentation(snapshot: turbo.snapshot()).balanceTitle == "Reported TURBO policy threshold")
        #expect(HomeUsagePresentation(usage: turbo).speedText == "Speed state unknown")
    }

    @Test func `absent daily reading does not substitute the policy counter`() throws {
        let usage = try Self.decode(daily: nil)
        #expect(usage.policyCounterGB == Decimal(string: "20.25"))
        #expect(HomeUsagePresentation(usage: usage).downloadedText == "Downloaded traffic unavailable")
        #expect(try HomeUsagePresentation(usage: Self.decode()).downloadedText == "Downloaded 60 GB")
    }

    @Test func `invalid quantities categories dates identities and splits fail closed`() throws {
        for invalid in ["-1", "true", "null", #""NaN""#, "999999999999999999999999"] {
            #expect(throws: LiveFailure.malformedResponse) { try Self.decode(usage: Self.usage(counter: invalid)) }
        }
        #expect(throws: LiveFailure.malformedResponse) { try Self.decode(usage: Self.usage(category: "UNKNOWN")) }
        #expect(throws: LiveFailure.malformedResponse) { try CalendarDay("2026-02-30") }
        #expect(throws: LiveFailure.malformedResponse) {
            try Self.decode(daily: Data(#"{"internetUsage":[{"totalUsage":{"peak":1}}]}"#.utf8))
        }
        #expect(throws: LiveFailure.malformedResponse) {
            try Self
                .decode(daily: Data(#"{"identifier":"other","internetUsage":[{"totalUsage":{"peak":1,"offPeak":2}}]}"#
                        .utf8))
        }
        #expect(throws: LiveFailure.malformedResponse) {
            try Self
                .decode(
                    daily: Data(#"{"startDate":"2026-08-01","internetUsage":[{"totalUsage":{"peak":1,"offPeak":2}}]}"#
                        .utf8),
                )
        }
    }

    @Test func `home state cannot present another account service or connection`() throws {
        let usage = try Self.decode()
        var state = LiveSessionState()
        state.connectionID = Self.connection
        state.homeUsage = usage
        state.account = AccountContext(key: Self.key.account, providerName: "Telenet", services: [],
                                       selectedService: Self.key, capabilities: .usageOnly)
        #expect(state.selectedHomeUsage?.policyCounterGB == Decimal(string: "20.25"))
        state.connectionID = ConnectionID()
        #expect(state.selectedHomeUsage == nil)
        state.connectionID = Self.connection
        let other = AccountKey(provider: .telenet)
        state.account = AccountContext(key: other, providerName: "Telenet", services: [],
                                       selectedService: ServiceKey(account: other, kind: .home, providerID: "home-a"),
                                       capabilities: .usageOnly)
        #expect(state.selectedHomeUsage == nil)
    }

    @Test func `home civil dates survive coding and units honor the preference`() throws {
        let usage = try Self.decode()
        let decoded = try JSONDecoder().decode(HomeUsage.self, from: JSONEncoder().encode(usage))
        #expect(decoded == usage)
        #expect(HomeUsagePresentation(usage: usage, unit: .gibibytes).downloadedText == "Downloaded 55.88 GiB")
        let fractional = try Self.decode(usage: Self.usage(counter: "0.0000000001"))
        #expect(fractional.allowance == .unavailable)
    }

    @Test func `cap card separates remaining allowance from policy and downloaded traffic`() throws {
        let usage = try Self.decode(usage: Self.usage(category: "CAP", counter: "20", allocation: "1000"))
        let remaining = HomeUsageCardPresentation(usage: usage)
        #expect(remaining.headline == "980 GB")
        #expect(remaining.headlineLabel == "Data remaining")
        #expect(remaining.allocation == "1000 GB total")
        #expect(remaining.policyCounter == "20 GB")
        #expect(remaining.quotaFraction == 0.98)
        #expect(remaining.quotaText == "98% remaining")
        #expect(remaining.period == "1–30 Sep 2026")
        #expect(remaining.downloaded == "60 GB")
        #expect(remaining.peak == "Peak 15 GB")
        #expect(remaining.offPeak == "Off-peak 45 GB")
        #expect(remaining.peakFraction == 0.25)
        #expect(remaining.trafficPercentage == "Peak 25%, off-peak 75%")
        #expect(remaining.speed == "Speed state unknown")
        let used = HomeUsageCardPresentation(usage: usage, mode: .used)
        #expect(used.headline == "20 GB")
        #expect(used.headlineLabel == "Policy counter")
        #expect(used.quotaFraction == 0.02)
        #expect(used.quotaText == "2% of cap")
        let binary = HomeUsageCardPresentation(usage: usage, unit: .gibibytes)
        #expect(binary.headline == "912.70 GiB")
        #expect(binary.allocation == "931.32 GiB total")
    }

    @Test func `card rounds long provider fractions while proof strings retain source precision`() throws {
        let daily = Data(#"{"internetUsage":[{"totalUsage":{"peak":614.0344667434692,"offPeak":0}}]}"#.utf8)
        let usage = try Self.decode(
            usage: Self.usage(category: "CAP", counter: "614.034466743", allocation: "1000"), daily: daily,
        )
        let card = HomeUsageCardPresentation(usage: usage)
        #expect(card.headline == "385.97 GB")
        #expect(card.policyCounter == "614.03 GB")
        #expect(card.downloaded == "614.03 GB")
        #expect(card.peak == "Peak 614.03 GB")
        #expect(card.offPeak == "Off-peak 0 GB")
        #expect(HomeUsagePresentation(usage: usage).downloadedText == "Downloaded 614.0344667434692 GB")
    }

    @Test func `non cap card never presents threshold or unlimited allocation as remaining`() throws {
        let fup = try HomeUsageCardPresentation(usage: Self.decode())
        #expect(fup.headline == "3000 GB")
        #expect(fup.headlineLabel == "Reported FUP policy threshold")
        #expect(fup.quotaFraction == nil)
        #expect(fup.quotaText == nil)
        let turbo = try HomeUsageCardPresentation(usage: Self.decode(usage: Self.usage(category: "TURBO")))
        #expect(turbo.headlineLabel == "Reported TURBO policy threshold")
        #expect(turbo.quotaFraction == nil)
        let unlimited = try HomeUsageCardPresentation(usage: Self.decode(usage: Self.usage(category: "UNLIMITED")))
        #expect(unlimited.headline == "Unlimited")
        #expect(unlimited.allocation == "Reported allocation 3000 GB")
        #expect(unlimited.quotaFraction == nil)
        #expect(unlimited.quotaText == nil)
    }

    @Test func `cap overage and zero allowance do not invent remaining data`() throws {
        let over = try HomeUsageCardPresentation(
            usage: Self.decode(usage: Self.usage(category: "CAP", counter: "1100", allocation: "1000")),
        )
        #expect(over.headline == "0 GB")
        #expect(over.quotaFraction == 0)
        #expect(over.quotaText == "0% remaining")
        #expect(over.overage == "100 GB over cap")
        let zero = try HomeUsageCardPresentation(
            usage: Self.decode(usage: Self.usage(category: "CAP", counter: "0", allocation: "0")),
        )
        #expect(zero.headline == "0 GB")
        #expect(zero.quotaFraction == nil)
        #expect(zero.quotaText == nil)
        #expect(zero.overage == nil)
    }

    @Test func `missing and zero daily splits have no invented composition bar`() throws {
        let missing = try HomeUsageCardPresentation(usage: Self.decode(daily: nil))
        #expect(missing.downloaded == "Unavailable")
        #expect(missing.peak == "Peak unavailable")
        #expect(missing.peakFraction == nil)
        #expect(missing.trafficPercentage == nil)
        let zero = try HomeUsageCardPresentation(usage: Self.decode(
            daily: Data(#"{"internetUsage":[{"totalUsage":{"peak":0,"offPeak":0}}]}"#.utf8),
        ))
        #expect(zero.downloaded == "0 GB")
        #expect(zero.peak == "Peak 0 GB")
        #expect(zero.offPeak == "Off-peak 0 GB")
        #expect(zero.peakFraction == nil)
        #expect(zero.trafficPercentage == nil)
    }
}
