import VikingBarCore

extension AppSession {
    var subscriptions: [AccountChoice] {
        if self.isFixtureLaunch {
            return self.fixture == nil ? [] : self.fixtureAccount.subscriptions.map { AccountChoice(
                id: $0.id,
                title: $0.title,
            ) }
        }
        return self.liveState.subscriptions.map { AccountChoice(id: $0.id, title: $0.displayName) }
    }

    var bundles: [BundleChoice] {
        if self.isFixtureLaunch {
            return self.fixture == nil ? [] : self.fixtureAccount.subscription.bundles.enumerated().map {
                BundleChoice(id: $0.offset, title: $0.element.title)
            }
        }
        return self.activeBundleIndices.compactMap { index in
            self.liveState.balance.map { BundleChoice(
                id: index,
                title: LiveBalancePresentation.title(for: $0.bundles[index], index: index),
            ) }
        }
    }

    var selectedSubscriptionID: String {
        self.isFixtureLaunch ? self.fixtureAccount.subscription.id : self.liveState.selectedSubscriptionID ?? ""
    }

    var selectedBundleIndex: Int {
        self.isFixtureLaunch ? self.fixtureAccount.bundleIndex : self.liveState.selectedBundleIndex ?? -1
    }

    var bundleDescription: String {
        self.isFixtureLaunch ? self.fixtureAccount.bundle.description : self.balanceDetails.bundleDescription
    }

    var applicabilityText: String {
        self.isFixtureLaunch ? "Mobile data · Domestic and EU roaming" : self.balanceDetails.applicabilityText
    }

    var extraChargesText: String {
        self.isFixtureLaunch ? "Extra charges: €0.00" : self.balanceDetails.extraChargesText
    }

    var connectionTitle: String {
        switch self.activity {
        case .restoring: "Restoring account…"
        case .connecting: "Connecting…"
        default:
            [.reconnectRequired, .unauthorized].contains(self.liveState.failure)
                ? "Reconnect your account" : "No account connected"
        }
    }

    var connectionMessage: String {
        self.bridgeError ?? self.liveState.failure?.message ?? self.menu.warningText
            ?? "Connect your Mobile Vikings account to load your data balance."
    }

    var needsConnection: Bool {
        self.isFixtureLaunch ? self.fixture == nil : [.notConnected, .reconnectRequired, .unauthorized]
            .contains(self.liveState.failure)
            || self.liveState.connectionID == nil
    }
}
