import AppKit
import SwiftUI
import VikingBarCore

struct DataCard: View {
    @Bindable var session: AppSession

    var connect: () -> Void = {}

    var body: some View {
        let menu = self.session.menu
        let card = self.session.card
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("VikingBar", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                if self.session.fixture != nil {
                    Text("FIXTURE")
                        .font(.caption.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .accessibilityIdentifier("vikingbar.fixtureMarker")
                }
            }
            if !self.session.isFixtureLaunch {
                self.liveSelection
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(menu.title).font(.subheadline).foregroundStyle(.secondary)
                Text(card.title).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vikingbar.balanceTitle")
                Text(card.value)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .accessibilityIdentifier("vikingbar.remaining")
                if let percentage = card.percentage {
                    ProgressView(value: percentage, total: 100)
                        .tint(menu.percentageRemaining == 0 ? .orange : .accentColor)
                        .accessibilityLabel(card.title)
                        .accessibilityValue(card.percentageText ?? "")
                }
                if let percentageText = card.supportingPercentageText {
                    Text(percentageText).font(.subheadline.weight(.medium))
                }
                HStack {
                    Text(menu.usedText)
                    Spacer()
                    Text(menu.totalText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(menu.expiryText)
                Text(menu.freshnessText)
                    .accessibilityIdentifier("vikingbar.freshness")
            }
            .font(.caption)
            if let warning = menu.warningText {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(menu.sourceLabel)
                    .font(.caption.weight(.medium))
                    .accessibilityIdentifier("vikingbar.source")
                if self.session.isFixtureLaunch {
                    Picker("Fixture state", selection: self.$session.fixture) {
                        Text("Not connected").tag(FixtureState?.none)
                        ForEach(FixtureState.allCases, id: \.self) { fixture in
                            Text(fixture.rawValue.capitalized).tag(Optional(fixture))
                        }
                    }
                    .accessibilityIdentifier("vikingbar.fixturePicker")
                } else {
                    self.liveActions
                }
                Picker("Data units", selection: self.$session.unit) {
                    ForEach(DataUnit.allCases, id: \.self) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                Text(menu.unitExplanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Quit VikingBar") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .accessibilityIdentifier("vikingbar.quit")
        }
        .padding(20)
        .frame(width: 360, height: self.session.isFixtureLaunch ? 520 : nil, alignment: .top)
        .frame(minHeight: self.session.isFixtureLaunch ? nil : 710, alignment: .top)
    }

    private var liveSelection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !self.session.liveState.subscriptions.isEmpty {
                Picker("SIM", selection: Binding(
                    get: { self.session.liveState.selectedSubscriptionID ?? "" },
                    set: { self.session.selectSubscription($0) },
                )) {
                    ForEach(self.session.liveState.subscriptions, id: \.id) { subscription in
                        Text(subscription.displayName).tag(subscription.id)
                    }
                }
                .accessibilityIdentifier("vikingbar.subscriptionPicker")
                .disabled(!self.session.canSelectAccountData)
            }
            if !self.session.activeBundleIndices.isEmpty {
                Picker("Data bundle", selection: Binding(
                    get: { self.session.liveState.selectedBundleIndex ?? -1 },
                    set: { self.session.selectBundle($0) },
                )) {
                    ForEach(self.session.activeBundleIndices, id: \.self) { index in
                        if let bundle = self.session.liveState.balance?.bundles[index] {
                            Text(LiveBalancePresentation.title(for: bundle, index: index)).tag(index)
                        }
                    }
                }
                .accessibilityIdentifier("vikingbar.bundlePicker")
                .disabled(!self.session.canSelectAccountData)
            }
            let details = self.session.balanceDetails
            Text(details.bundleTitle).font(.subheadline.weight(.medium))
            if !details.bundleDescription.isEmpty {
                Text(details.bundleDescription).font(.caption)
            }
            if !details.applicabilityText.isEmpty {
                Text(details.applicabilityText).font(.caption).foregroundStyle(.secondary)
            }
            Text(details.extraChargesText).font(.caption)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var liveActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(self.session.activity == .refreshing ? "Refreshing…" : "Refresh now") {
                self.session.refresh()
            }
            .disabled(!self.session.canRefresh)
            .accessibilityIdentifier("vikingbar.refresh")
            Button(self.session.activity == .connecting ? "Connecting…" : "Connect with 1Password") {
                self.connect()
            }
            .disabled(self.session.activity == .connecting || self.session.activity == .stopped)
            .accessibilityIdentifier("vikingbar.connect")
            Link("Open My Viking", destination: URL(string: "https://mobilevikings.be/en/my-viking/")!)
                .accessibilityIdentifier("vikingbar.openMyViking")
        }
    }
}
