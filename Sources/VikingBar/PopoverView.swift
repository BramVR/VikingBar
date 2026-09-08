import SwiftUI

struct PopoverView: View {
    @Bindable var session: AppSession

    var connect: () -> Void = {}
    var connectResultURL: URL?
    @State private var showsSettingsConnection = false

    var body: some View {
        TabView {
            DataCard(session: self.session, connect: self.connect, connectResultURL: self.connectResultURL)
                .tabItem { Text("Data") }
            if !self.session.isFixtureLaunch {
                InvoicesView(session: self.session).tabItem { Text("Bills") }
            }
            PointsCard(session: self.session)
                .tabItem { Text("Points") }
            Group {
                if self.showsSettingsConnection {
                    ConnectionForm(
                        session: self.session, resultURL: self.connectResultURL,
                        reference: self.connect, dismiss: { self.showsSettingsConnection = false },
                    )
                } else {
                    self.settings
                }
            }
            .tabItem { Text("Settings") }
        }
        .frame(width: 360, height: self.session.isFixtureLaunch ? 570 : 760)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            if self.session.fixture != nil {
                Text(self.session.menu.sourceLabel)
                    .font(.caption.bold())
                    .accessibilityIdentifier("vikingbar.fixtureMarker")
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
            Button("Connect account") { self.showsSettingsConnection = true }
                .disabled(self.session.activity == .connecting || self.session.activity == .stopped)
                .accessibilityIdentifier("vikingbar.connect.direct")
            Spacer()
        }
        .padding(20)
        .frame(width: 360, height: 520, alignment: .topLeading)
    }
}
