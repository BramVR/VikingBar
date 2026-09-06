import SwiftUI

struct PopoverView: View {
    @Bindable var session: FixtureSession

    var body: some View {
        TabView {
            DataCard(session: self.session)
                .tabItem { Text("Data") }
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
                Spacer()
            }
            .padding(20)
            .frame(width: 360, height: 520, alignment: .topLeading)
            .tabItem { Text("Settings") }
        }
        .frame(width: 360, height: 570)
    }
}
