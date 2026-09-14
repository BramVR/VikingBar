import Foundation
import VikingBarCore

struct AccountChoice: Identifiable {
    let id: String
    let title: String
}

struct BundleChoice: Identifiable {
    let id: Int
    let title: String
}

struct FixtureAccount {
    struct Bundle {
        let title: String
        let total: UInt64
        let remaining: UInt64
        let description: String
    }

    struct Subscription {
        let id: String
        let title: String
        let bundles: [Bundle]
    }

    let subscriptions = [
        Subscription(id: "example", title: "Example SIM", bundles: [
            Bundle(title: "Monthly data", total: 50, remaining: 36, description: "Monthly mobile data allowance"),
            Bundle(title: "Extra data", total: 5, remaining: 4, description: "Additional mobile data allowance"),
        ]),
        Subscription(id: "travel", title: "Travel SIM", bundles: [
            Bundle(title: "Monthly data", total: 10, remaining: 8, description: "Travel SIM monthly allowance"),
            Bundle(title: "Extra data", total: 2, remaining: 1, description: "Travel SIM additional allowance"),
        ]),
    ]
    private(set) var subscriptionIndex = 0
    private(set) var bundleIndex = 0
    var refreshCount = 0

    var subscription: Subscription {
        self.subscriptions[self.subscriptionIndex]
    }

    var bundle: Bundle {
        self.subscription.bundles[self.bundleIndex]
    }

    mutating func selectSubscription(_ id: String) {
        guard let index = self.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        self.subscriptionIndex = index
        self.bundleIndex = 0
    }

    mutating func selectBundle(_ index: Int) {
        guard self.subscription.bundles.indices.contains(index) else { return }
        self.bundleIndex = index
    }

    func snapshot(state: FixtureState, referenceDate: Date) -> UsageSnapshot {
        let base = state.snapshot(referenceDate: referenceDate)
        let total = self.bundle.total * 1_000_000_000
        let remaining = self.bundle.remaining * 1_000_000_000
        let allowance: Allowance = switch state {
        case .finite, .stale: .finite(totalBytes: total, usedBytes: total - remaining, remainingBytes: remaining)
        case .exhausted: .finite(totalBytes: total, usedBytes: total, remainingBytes: 0)
        case .unlimited: .unlimited(usedBytes: total - remaining)
        case .error: .unavailable
        }
        let freshness: Freshness = switch base.freshness {
        case let .current(date): .current(lastUpdated: date.addingTimeInterval(Double(self.refreshCount) * 60))
        case let .stale(date): .stale(lastUpdated: date.addingTimeInterval(Double(self.refreshCount) * 60))
        case .unavailable: .unavailable
        }
        return UsageSnapshot(
            source: base.source, subscriptionName: self.subscription.title, allowance: allowance,
            expiresAt: base.expiresAt, freshness: freshness, errorMessage: base.errorMessage,
        )
    }
}
