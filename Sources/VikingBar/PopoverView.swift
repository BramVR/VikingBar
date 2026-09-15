import AppKit
import SwiftUI
import VikingBarCore

struct PopoverView: View {
    enum Destination: Equatable {
        case balance, settings, points, bills
        case connection(ConnectionReturn)
    }

    enum ConnectionReturn: Equatable {
        case balance, settings

        var destination: Destination {
            switch self {
            case .balance: .balance
            case .settings: .settings
            }
        }
    }

    @Bindable var session: AppSession
    @State private var destination = Destination.balance
    @State private var detailsExpanded = false
    @State private var pointsExpanded = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var connect: () -> Void = {}
    var connectResultURL: URL?
    var fixtureReduceTransparency = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            self.header
            self.activeDestination
        }
        .buttonStyle(.plain)
        .padding(20)
        .frame(width: 360)
        .frame(maxHeight: 680)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            if self.reduceTransparency || self.fixtureReduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            }
        }
    }

    private var header: some View {
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
    }

    @ViewBuilder private var activeDestination: some View {
        switch self.destination {
        case let .connection(returnTo):
            ConnectionForm(
                session: self.session,
                resultURL: self.connectResultURL,
                reference: self.connect,
                dismiss: { self.destination = returnTo.destination },
            )
        default:
            ViewThatFits(in: .vertical) {
                self.adaptiveDestination
                ScrollView { self.adaptiveDestination }
            }
        }
    }

    private var adaptiveDestination: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                DataCard(
                    session: self.session,
                    detailsExpanded: self.$detailsExpanded,
                    presentConnection: { self.destination = .connection(.balance) },
                )
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
                PointsCard(session: self.session, expanded: self.$pointsExpanded)
            case .bills:
                InvoicesView(session: self.session)
            case .connection:
                EmptyView()
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)
            Picker("Data display", selection: self.$session.dataDisplayMode) {
                ForEach(DataDisplayMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
            }
            .accessibilityIdentifier("vikingbar.dataDisplayMode")
            Picker("Refresh", selection: self.$session.refreshInterval) {
                ForEach(RefreshInterval.allCases, id: \.self) { interval in Text(interval.title).tag(interval) }
            }
            .accessibilityIdentifier("vikingbar.refreshInterval")
            Toggle("Launch at login", isOn: Binding(
                get: { self.session.launchAtLogin },
                set: { enabled in Task { await self.session.setLaunchAtLogin(enabled) } },
            ))
            .disabled(self.session.changingLoginItem || self.session.loginItemStatus == .unavailable)
            .accessibilityIdentifier("vikingbar.launchAtLogin")
            Text(self.session.loginItemStatus.title)
                .accessibilityIdentifier("vikingbar.loginItemStatus")
            if self.session.loginItemStatus == .requiresApproval {
                Button("Open Login Items") { self.session.openLoginItems() }
            }
            if let error = self.session.loginItemError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("vikingbar.loginItemError")
            }
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
                Button("Connect account") { self.destination = .connection(.settings) }
                    .disabled(self.session.activity == .connecting || self.session.activity == .stopped)
                    .accessibilityIdentifier("vikingbar.connect.direct")
            }
            Divider()
            Button("Quit VikingBar") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .accessibilityIdentifier("vikingbar.quit")
        }
        .onAppear { self.session.checkLoginItem() }
    }
}
