import SwiftUI
import VikingBarCore

struct DataCard: View {
    @Bindable var session: AppSession
    @Binding var detailsExpanded: Bool
    @Binding var otherBundlesExpanded: Bool
    let historyCompanion: HistoryCompanionController
    var presentConnection: () -> Void = {}

    var body: some View {
        self.card
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            if self.showConnectionPrompt {
                Text(self.session.connectionTitle).font(.headline)
                    .accessibilityIdentifier("vikingbar.connectionStatus")
                Text(self.session.connectionMessage)
                    .accessibilityIdentifier("vikingbar.warning")
                    .foregroundStyle(.secondary)
                if self.session.isFixtureLaunch {
                    Text("Choose a synthetic state in Settings.").font(.caption)
                }
                self.directConnect
                if self.session.canRefresh || self.session.activity == .refreshing {
                    self.refreshAction
                }
            } else {
                self.selection
                if let home = self.session.homeUsagePresentation, let card = self.session.homeUsageCardPresentation {
                    HomeUsageCard(
                        usage: home, card: card, detailsExpanded: self.$detailsExpanded,
                        warning: self.session.menu.warningText,
                    )
                    if self.session.needsConnection {
                        Text(self.session.connectionMessage)
                            .font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("vikingbar.warning")
                        self.directConnect
                    }
                } else if self.session.selectedAccount.provider == .telenet {
                    Text("Home usage unavailable")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("vikingbar.home.unavailable")
                    if let warning = self.session.menu.warningText {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("vikingbar.warning")
                    }
                } else {
                    self.balance
                    let rows = self.session.nonDataBundles
                    if !rows.isEmpty {
                        OtherBundles(rows: rows, isExpanded: self.$otherBundlesExpanded)
                    }
                }
                if self.showHistory, let content = HistoryCompanionContent(session: self.session) {
                    HistoryCard(content: content, companion: self.historyCompanion)
                }
                if self.session.selectedServiceKind == .mobile {
                    self.details
                }
                Divider().padding(.vertical, 2)
                HStack {
                    self.refreshAction
                    Spacer()
                    if self.session.selectedAccount.provider == .mobileVikings {
                        self.myViking
                    }
                }
                Text(self.session.menu.freshnessText)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vikingbar.freshness")
            }
            if self.showConnectionPrompt {
                Divider().padding(.vertical, 2)
                if self.session.selectedAccount.provider == .mobileVikings {
                    self.myViking
                }
            }
            Text(self.session.menu.sourceLabel)
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("vikingbar.source")
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var showHistory: Bool {
        !self.session.isFixtureLaunch || self.session.liveState.selectedHomeUsage?.dailyHistory != nil
    }

    private var showConnectionPrompt: Bool {
        self.session.needsConnection && self.session.homeUsagePresentation == nil
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(self.session.selectedServiceKind == .mobile ? "SIM" : "Home service", selection: Binding(
                get: { self.session.selectedSubscriptionID },
                set: { self.session.selectSubscription($0) },
            )) {
                ForEach(self.session.subscriptions) { Text($0.title).tag($0.id) }
            }
            .accessibilityIdentifier("vikingbar.subscriptionPicker")
            .disabled(!self.session.canSelectAccountData)
            if self.session.hasSelectableBundle {
                Picker("Data bundle", selection: Binding(
                    get: { self.session.selectedBundleIndex },
                    set: { self.session.selectBundle($0) },
                )) {
                    ForEach(self.session.bundles) { Text($0.title).tag($0.id) }
                }
                .accessibilityIdentifier("vikingbar.bundlePicker")
                .disabled(!self.session.canSelectAccountData)
            }
            if self.session.selectedServiceKind == .mobile {
                Text(self.session.bundleSelectionLabel).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vikingbar.bundleSelectionLabel")
            }
        }
        .pickerStyle(.menu)
    }

    private var balance: some View {
        let menu = self.session.menu
        let card = self.session.card
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.value)
                    .font(.system(size: 30, weight: .semibold))
                    .accessibilityIdentifier("vikingbar.remaining")
                Spacer(minLength: 8)
                Text(menu.totalText).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vikingbar.total")
            }
            Text(card.title).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("vikingbar.balanceTitle")
            if let percentage = card.percentage {
                ProgressView(value: percentage, total: 100)
                    .tint(menu.percentageRemaining == 0 ? .orange : .cyan)
                    .accessibilityLabel(card.title)
                    .accessibilityValue(card.percentageText ?? "")
                    .accessibilityIdentifier("vikingbar.progress")
            }
            HStack {
                Text(self.session.dataDisplayMode == .remaining ? menu.usedText : "\(menu.remainingText) remaining")
                Spacer()
                if let percentageText = card.percentageText {
                    Text(percentageText)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            Label(menu.expiryText, systemImage: "calendar")
                .font(.caption).padding(.vertical, 2)
                .accessibilityIdentifier("vikingbar.expiry")
            if let warning = menu.warningText {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("vikingbar.warning")
            }
        }
        .padding(.top, 8)
    }

    private var details: some View {
        VStack(spacing: 3) {
            Divider()
            DisclosureGroup(isExpanded: self.$detailsExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(self.session.bundleDescription)
                        .accessibilityIdentifier("vikingbar.bundleDescription")
                    Text(self.session.applicabilityText).foregroundStyle(.secondary)
                        .accessibilityIdentifier("vikingbar.bundleApplicability")
                }
                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 3)
            } label: {
                HStack {
                    Text("Bundle details")
                    Spacer()
                    Text(self.session.extraChargesText).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("vikingbar.bundleDetails")
        }
    }

    private var refreshAction: some View {
        Button(action: self.session.refresh) {
            Label(
                self.session.activity == .refreshing ? "Refreshing…" : "Refresh",
                systemImage: "arrow.clockwise",
            )
        }
        .disabled(!self.session.canRefresh)
        .keyboardShortcut("r")
        .accessibilityIdentifier("vikingbar.refresh")
        .buttonStyle(.menuAction)
    }

    private var myViking: some View {
        Link(destination: URL(string: "https://mobilevikings.be/en/my-viking/")!) {
            Label("Open My Viking", systemImage: "link")
        }
        .accessibilityIdentifier("vikingbar.openMyViking")
        .buttonStyle(.menuAction)
    }

    private var directConnect: some View {
        Button("Connect account", action: self.presentConnection)
            .disabled(self.session.activity == .connecting || self.session.activity == .stopped)
            .accessibilityIdentifier("vikingbar.connect.direct")
            .buttonStyle(.menuAction)
    }
}

private struct OtherBundles: View {
    let rows: [BundleRowPresentation]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 3) {
            Divider()
            DisclosureGroup(isExpanded: self.$isExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(self.rows, id: \.index) { BundleRow(row: $0) }
                }
                .padding(.top, 3)
            } label: {
                HStack {
                    Text("Other bundles")
                    Spacer()
                    Text(self.summary).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("vikingbar.otherBundles.summary")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("vikingbar.otherBundles")
        }
    }

    private var summary: String {
        var kinds: [BundleKind] = []
        for row in self.rows where !kinds.contains(row.kind) {
            kinds.append(row.kind)
        }
        return kinds.map(\.label).joined(separator: ", ")
    }
}

private struct BundleRow: View {
    let row: BundleRowPresentation

    var body: some View {
        let id = "vikingbar.bundle.\(self.row.index)"
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.row.title).font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("\(id).title")
                Spacer(minLength: 8)
                Text(self.row.remainingText).font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("\(id).remaining")
            }
            HStack {
                Text(self.row.usedText).accessibilityIdentifier("\(id).used")
                Spacer()
                Text(self.row.totalText).accessibilityIdentifier("\(id).total")
            }
            .font(.caption).foregroundStyle(.secondary)
            if let percentage = self.row.percentageRemaining {
                ProgressView(value: percentage, total: 100)
                    .controlSize(.mini)
                    .tint(percentage == 0 ? .orange : .cyan)
                    .accessibilityLabel(self.row.title)
                    .accessibilityIdentifier("\(id).progress")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(self.row.detailText).accessibilityIdentifier("\(id).detail")
                Spacer(minLength: 6)
                Label(self.row.validityText, systemImage: "calendar")
                    .accessibilityIdentifier("\(id).validity")
            }
            .font(.caption).foregroundStyle(.secondary)
            if !self.row.description.isEmpty {
                Text(self.row.description).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(id).description")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }
}
