import VikingBarCore

extension AppSession {
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
