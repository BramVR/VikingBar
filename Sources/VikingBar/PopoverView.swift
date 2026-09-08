import SwiftUI
import VikingBarCore

struct PopoverView: View {
    @Bindable var session: AppSession

    var connect: () -> Void = {}

    var body: some View {
        TabView {
            Group {
                if self.session.isFixtureLaunch {
                    DataCard(session: self.session, connect: self.connect)
                } else {
                    ScrollView { DataCard(session: self.session, connect: self.connect) }
                }
            }
            .tabItem { Text("Data") }
            if !self.session.isFixtureLaunch {
                InvoicesView(session: self.session).tabItem { Text("Bills") }
            }
            PointsCard(session: self.session)
                .tabItem { Text("Points") }
            VStack(alignment: .leading, spacing: 12) {
                if self.session.fixture != nil {
                    Text(self.session.menu.sourceLabel)
                        .font(.caption.bold())
                        .accessibilityIdentifier("vikingbar.fixtureMarker")
                }
                Picker("Data display", selection: self.$session.dataDisplayMode) {
                    ForEach(DataDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityIdentifier("vikingbar.dataDisplayMode")
                Picker("Refresh", selection: self.$session.refreshInterval) {
                    ForEach(RefreshInterval.allCases, id: \.self) { interval in
                        Text(interval.title).tag(interval)
                    }
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = self.session.settingsError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("vikingbar.settingsError")
                }
                Spacer()
            }
            .padding(20)
            .frame(width: 360, height: 520, alignment: .topLeading)
            .onAppear { self.session.checkLoginItem() }
            .tabItem { Text("Settings") }
        }
        .frame(width: 360, height: self.session.isFixtureLaunch ? 570 : 760)
    }
}
