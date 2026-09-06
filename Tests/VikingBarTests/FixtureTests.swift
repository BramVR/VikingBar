import Foundation
import Testing
@testable import VikingBarCore

private let referenceDate = Date(timeIntervalSince1970: 1_783_252_800)
private let utc = TimeZone(secondsFromGMT: 0)!

@Test func `finite fixture shares decimal usage and percentage`() {
    let snapshot = FixtureState.finite.snapshot(referenceDate: referenceDate)
    let menu = MenuPresentation(snapshot: snapshot, timeZone: utc)
    #expect(menu.remainingText == "36.00 GB")
    #expect(menu.usedText == "14.00 GB used")
    #expect(menu.totalText == "50.00 GB total")
    #expect(menu.percentageUsed == 28)
    #expect(menu.usedPercentageText == "28% used")
    #expect(menu.percentageRemaining == 72)
    #expect(menu.percentageText == "72% remaining")
    #expect(menu.statusTitle == "Fixture 72%")
    #expect(menu.accessibilityLabel == "VikingBar Fixture 72%, 36.00 GB, FIXTURE · Finite · Synthetic data")
}

@Test func `unlimited keeps usage without fabricated percentage`() {
    let menu = MenuPresentation(snapshot: FixtureState.unlimited.snapshot(referenceDate: referenceDate), timeZone: utc)
    #expect(menu.remainingText == "Unlimited")
    #expect(menu.usedText == "14.00 GB used")
    #expect(menu.percentageRemaining == nil)
    #expect(menu.percentageText == nil)
}

@Test func `exhausted allowance is zero rather than unavailable`() {
    let menu = MenuPresentation(snapshot: FixtureState.exhausted.snapshot(referenceDate: referenceDate), timeZone: utc)
    #expect(menu.remainingText == "0.00 GB")
    #expect(menu.balanceTitle == "Data exhausted")
    #expect(menu.percentageRemaining == 0)
}

@Test func `stale balance remains visible with old successful update`() {
    let snapshot = FixtureState.stale.snapshot(referenceDate: referenceDate)
    #expect(snapshot.freshness == .stale(lastUpdated: referenceDate.addingTimeInterval(-86400)))
    let menu = MenuPresentation(snapshot: snapshot, timeZone: utc)
    #expect(menu.remainingText == "36.00 GB")
    #expect(menu.freshnessText.hasPrefix("Stale"))
    #expect(menu.statusTitle.contains("Stale"))
    #expect(menu.warningText != nil)
}

@Test func `error has unknown amounts and no successful update`() {
    let snapshot = FixtureState.error.snapshot(referenceDate: referenceDate)
    let menu = MenuPresentation(snapshot: snapshot, timeZone: utc)
    #expect(snapshot.allowance == .unavailable)
    #expect(menu.remainingText == "Unavailable")
    #expect(menu.percentageRemaining == nil)
    #expect(menu.freshnessText == "No successful update")
    #expect(menu.warningText == "Could not load the example balance.")
}

@Test(arguments: FixtureState.allCases)
func `every fixture carries explicit provenance`(state: FixtureState) {
    let snapshot = state.snapshot(referenceDate: referenceDate)
    let menu = MenuPresentation(snapshot: snapshot, timeZone: utc)
    #expect(snapshot.source == .fixture(state))
    #expect(menu.sourceLabel.contains("FIXTURE"))
    #expect(menu.sourceLabel.contains("Synthetic data"))
    #expect(menu.statusTitle.hasPrefix("Fixture"))
}

@Test func `binary conversion is explicitly labeled GiB`() {
    let snapshot = FixtureState.finite.snapshot(referenceDate: referenceDate)
    let menu = MenuPresentation(snapshot: snapshot, unit: .gibibytes, timeZone: utc)
    #expect(menu.remainingText == "33.53 GiB")
    #expect(menu.usedText == "13.04 GiB used")
    #expect(menu.percentageRemaining == 72)
    #expect(menu.unitExplanation.contains("binary"))
    #expect(DataUnit.gigabytes.format(bytes: 1_000_000_000) == "1.00 GB")
    #expect(DataUnit.gibibytes.format(bytes: 1_073_741_824) == "1.00 GiB")
}

@Test func `dates follow supplied user timezone including daylight saving`() throws {
    let date = Date(timeIntervalSince1970: 1_783_252_800)
    let snapshot = FixtureState.finite.snapshot(referenceDate: date)
    let brussels = try #require(TimeZone(identifier: "Europe/Brussels"))
    let localMenu = MenuPresentation(snapshot: snapshot, timeZone: brussels)
    let utcMenu = MenuPresentation(snapshot: snapshot, timeZone: utc)
    #expect(localMenu.expiryText != utcMenu.expiryText)
    #expect(localMenu.freshnessText != utcMenu.freshnessText)
    #expect(localMenu.freshnessText.contains("14:00"))
    #expect(utcMenu.freshnessText.contains("12:00"))
}

@Test func `not connected never shows synthetic allowance`() {
    let menu = MenuPresentation(snapshot: .notConnected, timeZone: utc)
    #expect(menu.sourceLabel == "Not connected")
    #expect(menu.remainingText == "Unavailable")
    #expect(menu.percentageRemaining == nil)
    #expect(!menu.statusTitle.contains("Fixture"))
}

@Test func `default accessibility label names VikingBar once`() {
    let menu = MenuPresentation(snapshot: .notConnected)
    #expect(menu.accessibilityLabel == "VikingBar ?, Unavailable, Not connected")
}

@Test func `zero total never produces nonfinite JSON percentage`() throws {
    let snapshot = UsageSnapshot(
        source: .notConnected,
        subscriptionName: "Empty",
        allowance: .finite(totalBytes: 0, usedBytes: 0, remainingBytes: 0),
        expiresAt: nil,
        freshness: .unavailable,
    )
    let menu = MenuPresentation(snapshot: snapshot, timeZone: utc)
    #expect(menu.percentageRemaining == nil)
    _ = try JSONEncoder().encode(menu)
}
