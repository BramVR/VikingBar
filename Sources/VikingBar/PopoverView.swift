import AppKit
import SwiftUI
import VikingBarCore

struct PopoverView: View {
    enum Destination { case balance, settings, points, bills }

    @Bindable var session: AppSession
    @State private var destination = Destination.balance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var connect: () -> Void = {}
    var fixtureReduceTransparency = false

    var body: some View {
        ViewThatFits(in: .vertical) {
            self.content
            ScrollView { self.content }
        }
        .frame(width: 360)
        .frame(maxHeight: 680)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            if self.reduceTransparency || self.fixtureReduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(nsImage: HelmetRenderer.image(for: self.session.status.treatment))
                    .accessibilityHidden(true)
                Text("VikingBar").font(.headline)
                Spacer()
                if self.session.isFixtureLaunch {
                    Text("FIXTURE").font(.caption.bold()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("vikingbar.fixtureMarker")
                }
            }
            .padding(.bottom, 10)
            if self.destination != .balance {
                Button { self.destination = .balance } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .accessibilityIdentifier("vikingbar.back")
                Divider().padding(.vertical, 6)
            }
            switch self.destination {
            case .balance:
                DataCard(session: self.session, connect: self.connect)
                Divider().padding(.vertical, 6)
                if !self.session.isFixtureLaunch {
                    Button { self.destination = .bills } label: { Label("Bills", systemImage: "doc.text") }
                        .accessibilityIdentifier("vikingbar.bills")
                }
                Button { self.destination = .points } label: { Label("Viking Points", systemImage: "star") }
                    .accessibilityIdentifier("vikingbar.points")
                Divider().padding(.vertical, 6)
                Button { self.destination = .settings } label: { Label("Settings…", systemImage: "gearshape") }
                    .keyboardShortcut(",")
                    .accessibilityIdentifier("vikingbar.settings")
            case .settings:
                self.settings
            case .points:
                PointsCard(session: self.session)
            case .bills:
                InvoicesView(session: self.session)
            }
        }
        .buttonStyle(.plain)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)
            Toggle("Show remaining GB in menu bar", isOn: self.$session.showRemainingGB)
                .accessibilityIdentifier("vikingbar.showRemainingGB")
            Text("Display the data left in GB beside the helmet.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = self.session.settingsError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("vikingbar.settingsError")
            }
            Picker("Data units", selection: self.$session.unit) {
                ForEach(DataUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .accessibilityIdentifier("vikingbar.units")
            Text(self.session.menu.unitExplanation).font(.caption).foregroundStyle(.secondary)
            Divider()
            if self.session.isFixtureLaunch {
                Text(self.session.menu.sourceLabel).font(.caption)
                    .accessibilityIdentifier("vikingbar.source")
                Picker("Fixture state", selection: self.$session.fixture) {
                    Text("Not connected").tag(FixtureState?.none)
                    ForEach(FixtureState.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional($0)) }
                }
                .accessibilityIdentifier("vikingbar.fixturePicker")
            } else {
                Button(
                    self.session.activity == .connecting ? "Connecting…" : "Connect with 1Password",
                    action: self.connect,
                )
                .disabled(self.session.activity == .connecting || self.session.activity == .stopped)
                .accessibilityIdentifier("vikingbar.connect")
            }
            Divider()
            Button("Quit VikingBar") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .accessibilityIdentifier("vikingbar.quit")
        }
    }
}
