import SwiftUI
import VikingBarCore

struct DataCard: View {
    @Bindable var session: AppSession
    @Binding var detailsExpanded: Bool
    var presentConnection: () -> Void = {}

    var body: some View {
        self.card
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            if self.session.needsConnection {
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
                self.balance
                self.details
                if !self.session.isFixtureLaunch, self.session.liveState.historyContext != nil {
                    HistoryCard(
                        presentation: self.session.historyPresentation,
                        isLoading: self.session.isHistoryLoading,
                        error: self.session.historyError,
                        reportedUsedText: self.session.menu.usedText,
                    )
                }
                Divider().padding(.vertical, 6)
                self.refreshAction
                Text(self.session.menu.freshnessText)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vikingbar.freshness")
            }
            Divider().padding(.vertical, 6)
            Link(destination: URL(string: "https://mobilevikings.be/en/my-viking/")!) {
                Label("Open My Viking", systemImage: "link")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("vikingbar.openMyViking")
            Text(self.session.menu.sourceLabel)
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("vikingbar.source")
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("SIM", selection: Binding(
                get: { self.session.selectedSubscriptionID },
                set: { self.session.selectSubscription($0) },
            )) {
                ForEach(self.session.subscriptions) { Text($0.title).tag($0.id) }
            }
            .accessibilityIdentifier("vikingbar.subscriptionPicker")
            .disabled(!self.session.canSelectAccountData)
            Divider().padding(.vertical, 6)
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
            Text(self.session.bundleSelectionLabel).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("vikingbar.bundleSelectionLabel")
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
                .font(.caption).padding(.vertical, 6)
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
        VStack(spacing: 6) {
            Divider()
            DisclosureGroup(isExpanded: self.$detailsExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(self.session.bundleDescription)
                        .accessibilityIdentifier("vikingbar.bundleDescription")
                    Text(self.session.applicabilityText).foregroundStyle(.secondary)
                        .accessibilityIdentifier("vikingbar.bundleApplicability")
                }
                .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(!self.session.canRefresh)
        .keyboardShortcut("r")
        .accessibilityIdentifier("vikingbar.refresh")
    }

    private var directConnect: some View {
        Button("Connect account", action: self.presentConnection)
            .disabled(self.session.activity == .connecting || self.session.activity == .stopped)
            .accessibilityIdentifier("vikingbar.connect.direct")
    }
}
