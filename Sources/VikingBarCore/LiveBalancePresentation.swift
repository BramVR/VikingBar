import Foundation

public struct LiveBalancePresentation: Codable, Equatable, Sendable {
    public let extraChargesText: String
    public let bundleTitle: String
    public let bundleDescription: String
    public let applicabilityText: String

    public init(state: LiveSessionState) {
        let bundle = state.selectedBundleIndex.flatMap { index in
            state.balance.flatMap { $0.bundles.indices.contains(index) ? $0.bundles[index] : nil }
        }
        self.bundleTitle = bundle?.title ?? "No active data bundle"
        self.bundleDescription = bundle?.description ?? ""
        self.applicabilityText = [bundle?.category, state.balance?.regionality]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.locale = Locale(identifier: "en_IE")
        guard let amount = state.balance?.outOfBundleCost, !amount.isNaN,
              let formatted = formatter.string(from: NSDecimalNumber(decimal: amount))
        else {
            self.extraChargesText = "Extra charges unavailable"
            return
        }
        self.extraChargesText = "Extra charges: \(formatted)"
    }
}
