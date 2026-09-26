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
        self.bundleTitle = if let bundle, let index = state.selectedBundleIndex {
            Self.title(for: bundle, index: index)
        } else {
            "No active data bundle"
        }
        self.bundleDescription = bundle?.description ?? ""
        self.applicabilityText = [bundle?.category, state.balance?.regionality]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        guard let amount = state.balance?.outOfBundleCost, let formatted = Self.euros(amount) else {
            self.extraChargesText = "Extra charges unavailable"
            return
        }
        self.extraChargesText = "Extra charges: \(formatted)"
    }

    public static func title(for bundle: BalanceBundle, index: Int) -> String {
        let title = bundle.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "\(bundle.type.bundleName) \(index + 1)" : title
    }

    static func euros(_ amount: Decimal) -> String? {
        guard !amount.isNaN else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.locale = Locale(identifier: "en_IE")
        return formatter.string(from: NSDecimalNumber(decimal: amount))
    }
}

/// Rows cover non-data bundles only. The main card and its picker own data bundles.
public struct BundleRowPresentation: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case finite, exhausted, unlimited, expired, upcoming, unavailable
    }

    /// Position in the provider bundle array, the same index space as `live --bundle`.
    public let index: Int
    public let kind: BundleKind
    public let title: String
    public let description: String
    public let remainingText: String
    public let usedText: String
    public let totalText: String
    public let detailText: String
    public let validityText: String
    public let state: State
    public let percentageRemaining: Double?

    public static func rows(
        for bundles: [BalanceBundle], at now: Date, timeZone: TimeZone = .current,
    ) -> [BundleRowPresentation] {
        let formatter = MenuPresentation.dateFormatter(timeZone: timeZone)
        return bundles.enumerated().compactMap { index, bundle in
            let amounts: AmountTexts
            switch bundle.balance(at: now) {
            case .data:
                return nil
            case let .sms(metered):
                amounts = AmountTexts(metered, magnitude: { Double($0.count) }, format: { "\($0.count) SMS" })
            case let .voice(metered):
                amounts = AmountTexts(
                    metered, magnitude: { Double($0.seconds) }, format: { Self.duration($0.seconds) },
                )
            case let .value(metered):
                amounts = AmountTexts(
                    metered, magnitude: { NSDecimalNumber(decimal: $0.euros).doubleValue },
                    format: { LiveBalancePresentation.euros($0.euros) ?? "Unavailable" },
                )
            }
            let validity: (text: String, state: State) = if now < bundle.validFrom {
                ("Starts \(formatter.string(from: bundle.validFrom))", .upcoming)
            } else if now >= bundle.validUntil {
                ("Expired \(formatter.string(from: bundle.validUntil))", .expired)
            } else {
                ("Expires \(formatter.string(from: bundle.validUntil))", amounts.state)
            }
            return BundleRowPresentation(
                index: index, kind: bundle.type, title: LiveBalancePresentation.title(for: bundle, index: index),
                description: bundle.description, remainingText: amounts.remaining, usedText: amounts.used,
                totalText: amounts.total, detailText: "\(bundle.type.label) · \(bundle.category)",
                validityText: validity.text, state: validity.state, percentageRemaining: amounts.percentageRemaining,
            )
        }
    }

    static func duration(_ seconds: UInt64) -> String {
        let (minutes, rest) = seconds.quotientAndRemainder(dividingBy: 60)
        return switch (minutes, rest) {
        case (0, 0): "0 min"
        case (0, _): "\(rest) s"
        case (_, 0): "\(minutes) min"
        default: "\(minutes) min \(rest) s"
        }
    }
}

private struct AmountTexts {
    let remaining: String
    let used: String
    let total: String
    let state: BundleRowPresentation.State
    let percentageRemaining: Double?

    init<Amount>(_ metered: Metered<Amount>, magnitude: (Amount) -> Double, format: (Amount) -> String) {
        switch metered {
        case let .finite(total, used, remaining):
            self.remaining = format(remaining)
            self.used = "\(format(used)) used"
            self.total = "\(format(total)) total"
            self.state = magnitude(remaining) == 0 ? .exhausted : .finite
            self.percentageRemaining = magnitude(total) == 0
                ? nil : min(100, magnitude(remaining) * 100 / magnitude(total))
        case let .unlimited(used):
            self.remaining = "Unlimited"
            self.used = "\(format(used)) used"
            self.total = "Unlimited allowance"
            self.state = .unlimited
            self.percentageRemaining = nil
        case .unavailable:
            self.remaining = "Unavailable"
            self.used = "Usage unavailable"
            self.total = "Allowance unavailable"
            self.state = .unavailable
            self.percentageRemaining = nil
        }
    }
}
