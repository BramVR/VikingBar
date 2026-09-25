import VikingBarCore

extension AppSession {
    var subscriptions: [AccountChoice] {
        if self.usesMobileFixture {
            return self.fixture == nil ? [] : self.fixtureAccount.subscriptions.map { AccountChoice(
                id: $0.id,
                title: $0.title,
            ) }
        }
        if let services = self.liveState.account?.services {
            return services.map { AccountChoice(id: $0.key.providerID, title: $0.name) }
        }
        return self.liveState.subscriptions.map { AccountChoice(id: $0.id, title: $0.displayName) }
    }

    var hasSelectableBundle: Bool {
        !self.bundles.isEmpty
    }

    var bundleSelectionLabel: String {
        self.hasSelectableBundle ? "Selected bundle" : "No active data bundle"
    }

    var bundles: [BundleChoice] {
        if self.usesMobileFixture {
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
        self.usesMobileFixture ? self.fixtureAccount.subscription.id : self.liveState.account?.selectedService?
            .providerID ?? self.liveState.selectedSubscriptionID ?? ""
    }

    var selectedBundleIndex: Int {
        self.usesMobileFixture ? self.fixtureAccount.bundleIndex : self.liveState.selectedBundleIndex ?? -1
    }

    var bundleDescription: String {
        self.usesMobileFixture ? self.fixtureAccount.bundle.description : self.balanceDetails.bundleDescription
    }

    var applicabilityText: String {
        self.usesMobileFixture ? "Mobile data · Domestic and EU roaming" : self.balanceDetails.applicabilityText
    }

    var extraChargesText: String {
        self.usesMobileFixture ? "Extra charges: €0.00" : self.balanceDetails.extraChargesText
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
            ?? "Connect your \(self.providerName) account to load usage."
    }

    var needsConnection: Bool {
        self.usesMobileFixture ? self.fixture == nil : [.notConnected, .reconnectRequired, .unauthorized]
            .contains(self.liveState.failure)
            || self.liveState.connectionID == nil
    }
}

extension AppSession {
    func selectSubscription(_ id: String) {
        if self.usesMobileFixture {
            guard self.canSelectAccountData else { return }
            self.fixtureAccount.selectSubscription(id)
            self.onPresentationChange?()
            return
        }
        guard self.selectedSubscriptionID != id else { return }
        if let service = self.liveState.account?.services.first(where: { $0.key.providerID == id }) {
            self.select(.selectService(service.key))
        } else {
            self.select(.selectSubscription(id))
        }
    }

    func selectBundle(_ index: Int) {
        if self.usesMobileFixture {
            guard self.canSelectAccountData else { return }
            self.fixtureAccount.selectBundle(index)
            self.onPresentationChange?()
            return
        }
        guard self.liveState.selectedBundleIndex != index else { return }
        self.select(.selectBundle(index))
    }
}

struct AccountPresentation {
    let summary: AccountConnectionSummary?
    let isConnected: Bool
    let isDemo: Bool
    var providerName = "Mobile Vikings"

    var status: String {
        if self.isDemo {
            return "Demo · \(self.providerName)"
        }
        return self.isConnected ? "Connected to \(self.providerName)" : "Sign in to \(self.providerName)"
    }

    var username: String? {
        self.summary?.username
    }
}

extension AppSession {
    var accountPresentation: AccountPresentation {
        if self.usesMobileFixture {
            return AccountPresentation(
                summary: AccountConnectionSummary(
                    clientID: "demo-public-client", username: "alex@example.invalid",
                ),
                isConnected: self.fixture != nil, isDemo: true,
            )
        }
        return AccountPresentation(
            summary: self.liveState.connectionSummary,
            isConnected: self.isConnected,
            isDemo: self.isFixtureLaunch, providerName: self.providerName,
        )
    }

    var hasAccount: Bool {
        self.usesMobileFixture ? self.fixture != nil : self.liveState.connectionID != nil
    }
}
