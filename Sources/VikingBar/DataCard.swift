import AppKit
import SwiftUI
import VikingBarCore

struct DataCard: View {
    @Bindable var session: FixtureSession
    let onChange: () -> Void

    var body: some View {
        let menu = self.session.menu
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
            VStack(alignment: .leading, spacing: 5) {
                Text(menu.title).font(.subheadline).foregroundStyle(.secondary)
                Text(menu.balanceTitle).font(.caption).foregroundStyle(.secondary)
                Text(menu.remainingText)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .accessibilityIdentifier("vikingbar.remaining")
                if let percentage = menu.percentageRemaining {
                    ProgressView(value: percentage, total: 100)
                        .tint(percentage == 0 ? .orange : .accentColor)
                        .accessibilityLabel("Data remaining")
                        .accessibilityValue(menu.percentageText ?? "")
                }
                if let percentageText = menu.usedPercentageText {
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
                Picker("Fixture state", selection: self.$session.fixture) {
                    Text("Not connected").tag(FixtureState?.none)
                    ForEach(FixtureState.allCases, id: \.self) { fixture in
                        Text(fixture.rawValue.capitalized).tag(Optional(fixture))
                    }
                }
                .accessibilityIdentifier("vikingbar.fixturePicker")
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
        .frame(width: 360, height: 520, alignment: .top)
        .onChange(of: self.session.fixture) { self.onChange() }
        .onChange(of: self.session.unit) { self.onChange() }
    }
}
