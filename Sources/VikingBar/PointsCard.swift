import SwiftUI
import VikingBarCore

struct PointsCard: View {
    @Bindable var session: AppSession
    @State private var expanded = false

    var body: some View {
        let points = self.session.points
        VStack(alignment: .leading, spacing: 12) {
            if self.session.isFixtureLaunch {
                Text(self.session.menu.sourceLabel).font(.caption.bold())
                    .accessibilityIdentifier("vikingbar.points.fixtureMarker")
            }
            Text(points.customerLabel).font(.headline)
                .accessibilityIdentifier("vikingbar.points.customerLabel")
            Text("Shared across this customer's subscriptions.").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(points.availableText).font(.title2.bold())
                    .accessibilityIdentifier("vikingbar.points.available")
                Text(points.pendingText).accessibilityIdentifier("vikingbar.points.pending")
                Text(points.blockedText).accessibilityIdentifier("vikingbar.points.blocked")
            }
            Text(points.balanceStatus).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("vikingbar.points.balanceStatus")
            Divider()
            Text(points.historySummary).font(.caption)
                .accessibilityIdentifier("vikingbar.points.historySummary")
            Text(points.historyStatus).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("vikingbar.points.historyStatus")
            DisclosureGroup("Recent transactions", isExpanded: self.$expanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(points.transactions.enumerated()), id: \.offset) { index, row in
                            self.transaction(row, index: index)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
                .accessibilityIdentifier("vikingbar.points.transactionsScroll")
            }
            .accessibilityIdentifier("vikingbar.points.transactionsToggle")
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func transaction(_ row: PointsTransactionPresentation, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.amountText).fontWeight(.semibold)
                    .accessibilityIdentifier("vikingbar.points.transaction.\(index).amount")
                Spacer()
                Text(row.stateText).accessibilityIdentifier("vikingbar.points.transaction.\(index).state")
            }
            Text(row.descriptionText).accessibilityIdentifier("vikingbar.points.transaction.\(index).description")
            Text(row.updatedText).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("vikingbar.points.transaction.\(index).updated")
            Divider()
        }
    }
}
