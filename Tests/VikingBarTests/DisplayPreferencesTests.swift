import Foundation
import Testing
@testable import VikingBarCore

struct DisplayPreferencesTests {
    @Test func `default card preserves every fixture presentation`() {
        for fixture in FixtureState.allCases {
            let snapshot = fixture.snapshot(referenceDate: LiveModelsTests.now)
            let menu = MenuPresentation(snapshot: snapshot)
            let card = DataCardPresentation(allowance: snapshot.allowance, mode: .remaining, unit: .gigabytes)
            #expect(card.title == menu.balanceTitle)
            #expect(card.value == menu.remainingText)
            #expect(card.percentage == menu.percentageRemaining)
            #expect(card.percentageText == menu.percentageText)
            #expect(card.supportingPercentageText == menu.usedPercentageText)
        }
    }

    @Test func `used card projects finite bytes and leaves raw menu remaining`() {
        let snapshot = FixtureState.finite.snapshot(referenceDate: LiveModelsTests.now)
        let card = DataCardPresentation(allowance: snapshot.allowance, mode: .used, unit: .gigabytes)
        #expect(card.title == "Data used")
        #expect(card.value == "14.00 GB")
        #expect(card.percentage == 28)
        #expect(MenuPresentation(snapshot: snapshot).remainingText == "36.00 GB")
    }

    @Test func `unlimited zero and unavailable never invent percentages`() {
        let allowances: [Allowance] = [
            .unlimited(usedBytes: 1_000_000_000), .unavailable,
            .finite(totalBytes: 0, usedBytes: 0, remainingBytes: 0),
        ]
        for mode in DataDisplayMode.allCases {
            for allowance in allowances {
                let card = DataCardPresentation(allowance: allowance, mode: mode, unit: .gigabytes)
                #expect(card.percentage == nil)
                #expect(card.percentageText == nil)
            }
        }
        #expect(DataCardPresentation(allowance: .unlimited(usedBytes: 1_000_000_000), mode: .used,
                                     unit: .gigabytes).value == "1.00 GB")
    }

    @Test func `interval enum rejects unknown persisted values`() throws {
        for interval in RefreshInterval.allCases {
            #expect(try JSONDecoder().decode(RefreshInterval.self, from: JSONEncoder().encode(interval)) == interval)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RefreshInterval.self, from: Data("600".utf8))
        }
    }
}
