import VikingBarCore

extension AppSession {
    var launchAtLogin: Bool {
        self.loginItemStatus == .enabled || self.loginItemStatus == .requiresApproval
    }

    var menu: MenuPresentation {
        MenuPresentation(snapshot: self.snapshot, unit: self.unit, timeZone: self.timeZone)
    }

    var card: DataCardPresentation {
        DataCardPresentation(allowance: self.snapshot.allowance, mode: self.dataDisplayMode, unit: self.unit)
    }

    var status: StatusPresentation {
        StatusPresentation(
            snapshot: self.snapshot, showRemainingGB: self.showRemainingGB,
            unit: self.unit, timeZone: self.timeZone,
        )
    }

    var balanceDetails: LiveBalancePresentation {
        LiveBalancePresentation(state: self.liveState)
    }
}

extension AppSession {
    var points: PointsPresentation {
        var values = self.isFixtureLaunch
            ? self.fixture?.points(referenceDate: self.referenceDate) : self.liveState.points(at: self.now())
        if !self.isFixtureLaunch, self.bridgeFailure != nil {
            values?.markUnavailable(.transport)
        }
        return PointsPresentation(points: values, timeZone: self.timeZone)
    }
}

extension AppSession {
    var activeBundleIndices: [Int] {
        guard let balance = self.liveState.balance else { return [] }
        return balance.bundles.indices.filter { balance.bundles[$0].isActive(at: self.now()) }
    }
}

extension AppSession {
    var canRefresh: Bool {
        self.activity == .idle
            && (self.isFixtureLaunch ? self.fixture != nil : self.isConnected || self.canRestartWorker)
    }

    var canSelectAccountData: Bool {
        self.activity == .idle
            && (self.isFixtureLaunch ? self.fixture != nil : self.isConnected && self.bridgeFailure == nil)
    }
}

extension AppSession {
    private var canRestartWorker: Bool {
        if case .unavailable? = self.bridgeFailure {
            return true
        }
        return false
    }

    var isConnected: Bool {
        self.liveState.connectionID != nil
            && ![.notConnected, .reconnectRequired, .unauthorized].contains(self.liveState.failure)
    }
}
