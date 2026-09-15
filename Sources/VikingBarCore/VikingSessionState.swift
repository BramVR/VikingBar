import Foundation

extension LiveSessionState {
    var selectedBundle: BalanceBundle? {
        guard let index = self.selectedBundleIndex, let balance = self.balance,
              balance.bundles.indices.contains(index) else { return nil }
        return balance.bundles[index]
    }

    private var selectedName: String {
        self.subscriptions.first(where: { $0.id == self.selectedSubscriptionID })?.displayName ?? "Mobile Vikings"
    }

    var emptySnapshot: UsageSnapshot {
        UsageSnapshot(
            source: self.connectionID == nil ? .notConnected : .live,
            subscriptionName: self.selectedName, allowance: .unavailable, expiresAt: nil, freshness: .unavailable,
        )
    }

    func canRestore(connectionID: ConnectionID?) -> Bool {
        guard let connectionID, self.connectionID == connectionID, self.snapshot.source == .live else { return false }
        guard let selectedSubscriptionID else {
            return self.failure != nil && self.subscriptions.isEmpty && self.balance == nil
                && self.selectedBundleIndex == nil && self.snapshot.allowance == .unavailable
                && self.snapshot.expiresAt == nil && self.snapshot.freshness == .unavailable
                && self.snapshot.subscriptionName == self.selectedName
                && self.snapshot.errorMessage == self.failure?.message
        }
        return self.subscriptions.contains(where: { $0.id == selectedSubscriptionID })
            && (self.selectedBundleIndex.map { self.balance?.bundles.indices.contains($0) == true } ?? true)
    }

    mutating func updateRefreshDeadline(interval: RefreshInterval) {
        guard self.failure == nil else { return }
        switch self.snapshot.freshness {
        case let .current(updated), let .stale(updated):
            self.nextRefreshAt = interval.deadline(updated: updated, expiry: self.snapshot.expiresAt)
        case .unavailable: break
        }
    }

    func freshDeadline(at date: Date, interval: RefreshInterval) -> Date? {
        guard case let .current(updated) = self.snapshot.freshness, self.failure == nil else { return nil }
        let deadline = interval.deadline(updated: updated, expiry: self.selectedBundle?.validUntil)
        return date < deadline ? deadline : nil
    }

    mutating func selectBundle(index: Int, at now: Date, interval: RefreshInterval) throws {
        guard let balance = self.balance, balance.bundles.indices.contains(index),
              balance.bundles[index].isActive(at: now) else { throw LiveFailure.invalidSelection }
        self.selectedBundleIndex = index
        self.reviseHistory()
        let updated: Date = switch self.snapshot.freshness {
        case let .current(date), let .stale(date): date
        case .unavailable: now
        }
        let freshness = self.snapshot.freshness
        self.project(updated: updated, now: now)
        if case .stale = freshness {
            self.markStaleSnapshot(failure: self.failure, at: now)
        }
        if self.failure == nil {
            self.nextRefreshAt = interval.deadline(updated: updated, expiry: balance.bundles[index].validUntil)
        }
    }

    mutating func publish(_ balance: LiveBalance, at now: Date, interval: RefreshInterval) {
        let previous = self.selectedBundle
        self.balance = balance
        let matching = previous.flatMap { selected in
            let matches = balance.bundles.indices.filter { index in
                let bundle = balance.bundles[index]
                return bundle.isActive(at: now) && bundle.title == selected.title && bundle.category == selected
                    .category
                    && bundle.type == selected.type && bundle.description == selected.description
                    && bundle.validFrom == selected.validFrom && bundle.validUntil == selected.validUntil
            }
            return matches.count == 1 ? matches.first : nil
        }
        self.selectedBundleIndex = matching ?? balance.bundles.firstIndex(where: { $0.isActive(at: now) })
        self.reviseHistory()
        self.failure = nil
        self.nextRefreshAt = interval.deadline(updated: now, expiry: self.selectedBundle?.validUntil)
        self.project(updated: now, now: now)
    }

    mutating func revalidateBundle(at now: Date) {
        guard let bundle = self.selectedBundle, !bundle.isActive(at: now) else { return }
        self.markStaleSnapshot(failure: self.failure, at: now)
        if self.failure == nil {
            self.nextRefreshAt = now
        }
    }

    mutating func project(updated: Date, now: Date) {
        let bundle = self.selectedBundle
        self.snapshot = UsageSnapshot(
            source: .live, subscriptionName: self.selectedName,
            allowance: bundle?.allowance(at: now) ?? .unavailable,
            expiresAt: bundle?.validUntil, freshness: .current(lastUpdated: updated),
        )
    }

    mutating func markStaleSnapshot(failure: LiveFailure?, at now: Date) {
        self.failure = failure
        let previous = self.snapshot
        let freshness: Freshness = switch previous.freshness {
        case let .current(date), let .stale(date): .stale(lastUpdated: date)
        case .unavailable: .unavailable
        }
        let expired = self.selectedBundle.map { !$0.isActive(at: now) } ?? false
        self.snapshot = UsageSnapshot(
            source: previous.source, subscriptionName: previous.subscriptionName,
            allowance: expired ? .unavailable : previous.allowance,
            expiresAt: previous.expiresAt, freshness: freshness, errorMessage: failure?.message,
        )
    }
}
