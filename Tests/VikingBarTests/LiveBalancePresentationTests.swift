import Foundation
import Testing
@testable import VikingBarCore

struct LiveBalancePresentationTests {
    @Test func `unnamed bundles get distinct display titles without changing provider values`() {
        var state = LiveSessionState()
        let bundles = ["", " \n\t"].map { title in
            BalanceBundle(
                title: title, description: "", category: "default", type: "data",
                total: 100, used: 20, remaining: 80, validFrom: .distantPast, validUntil: .distantFuture,
            )
        }
        state.balance = LiveBalance(bundles: bundles, regionality: nil, outOfBundleCost: nil)
        for index in bundles.indices {
            state.selectedBundleIndex = index
            #expect(LiveBalancePresentation(state: state).bundleTitle == "Data bundle \(index + 1)")
        }
        #expect(state.balance?.bundles.map(\.title) == ["", " \n\t"])
    }

    @Test func `missing charges stay unavailable and decimal charges remain separate`() {
        var state = LiveSessionState()
        #expect(LiveBalancePresentation(state: state).extraChargesText == "Extra charges unavailable")
        state.balance = LiveBalance(bundles: [], regionality: nil, outOfBundleCost: Decimal(string: "12.34"))
        #expect(LiveBalancePresentation(state: state).extraChargesText == "Extra charges: €12.34")
        #expect(state.balance?.outOfBundleCost == Decimal(string: "12.34"))
    }

    @Test func `selected bundle keeps its applicability and description`() {
        var state = LiveSessionState()
        let bundle = BalanceBundle(
            title: " Roaming data ", description: "Only in selected countries", category: "travel", type: "data",
            total: 100, used: 20, remaining: 80, validFrom: .distantPast, validUntil: .distantFuture,
        )
        state.balance = LiveBalance(bundles: [bundle], regionality: "international", outOfBundleCost: nil)
        state.selectedBundleIndex = 0
        let details = LiveBalancePresentation(state: state)
        #expect(details.bundleTitle == "Roaming data")
        #expect(bundle.title == " Roaming data ")
        #expect(details.bundleDescription == "Only in selected countries")
        #expect(details.applicabilityText == "travel · international")
        state.selectedBundleIndex = nil
        #expect(LiveBalancePresentation(state: state).bundleTitle == "No active data bundle")
    }
}
