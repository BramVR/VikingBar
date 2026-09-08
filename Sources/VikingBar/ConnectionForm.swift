import SwiftUI

struct ConnectionFormAttempt {
    private enum Phase { case ready, submitted }
    private var phase = Phase.ready

    mutating func recordSubmission(accepted: Bool) {
        self.phase = accepted ? .submitted : .ready
    }

    func isConnecting(activity: AppSession.Activity) -> Bool {
        self.phase == .submitted && activity == .connecting
    }

    mutating func finishIfNeeded(activity: AppSession.Activity) -> Bool {
        guard self.phase == .submitted, activity != .connecting else { return false }
        self.phase = .ready
        return true
    }
}

struct ConnectionForm: View {
    @Bindable var session: AppSession
    @State private var fields = ConnectionFormModel()
    @State private var attempt = ConnectionFormAttempt()
    @FocusState private var clientIDFocused: Bool
    let resultURL: URL?
    let reference: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView { self.content }
            HStack {
                if !self.isConnecting {
                    Button("Connect", action: self.submit)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("vikingbar.connect.submit")
                }
                Button("Cancel") {
                    self.fields.clear()
                    Task {
                        await self.session.cancelConnection()
                        self.dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("vikingbar.connect.cancel")
            }
            if !self.isConnecting {
                Button("Connect with 1Password", action: self.connectReference)
                    .accessibilityIdentifier("vikingbar.connect")
                Text("Optional. Requires the configured 1Password helper and an approved credential reference.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 360, alignment: .topLeading)
        .onAppear {
            self.clientIDFocused = true
            self.finishIfNeeded()
        }
        .onDisappear { self.fields.clear() }
        .onChange(of: self.session.activity) { _, _ in
            self.finishIfNeeded()
        }
    }

    private var isConnecting: Bool {
        self.attempt.isConnecting(activity: self.session.activity)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect your account").font(.headline)
            if self.isConnecting {
                ProgressView("Connecting…")
            } else {
                Text(
                    "Use your Mobile Vikings username and password, plus the public client ID approved for API access.",
                )
                .font(.callout)
                Text("First request API access from api@mobilevikings.be. Include your name, Mobile Vikings, " +
                    "VikingBar, and the purpose: viewing your own balance. Wait for approval.")
                    .font(.caption)
                Text("Use a compatible public client with no client secret.")
                    .font(.caption)
                Link("API access instructions", destination: URL(string: "https://docs.uwa.mobilevikings.be/")!)
                TextField("Public client ID", text: self.$fields.clientID)
                    .accessibilityIdentifier("vikingbar.connect.client-id")
                    .focused(self.$clientIDFocused)
                TextField("Username", text: self.$fields.username)
                    .accessibilityIdentifier("vikingbar.connect.username")
                SecureField("Password", text: self.$fields.password)
                    .accessibilityIdentifier("vikingbar.connect.password")
                Text("VikingBar uses your password once to sign in. The saved connection is kept in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = self.fields.error ?? self.session.bridgeError {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("vikingbar.connect.error")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func submit() {
        guard let credentials = self.fields.takeCredentials(isFixture: self.session.isFixtureLaunch) else { return }
        let accepted = self.session.connect(input: .credentials(credentials), resultURL: self.resultURL)
        self.attempt.recordSubmission(accepted: accepted)
        self.finishIfNeeded()
    }

    private func finishIfNeeded() {
        guard self.attempt.finishIfNeeded(activity: self.session.activity) else { return }
        self.fields.clear()
        if self.session.bridgeError == nil, self.session.isConnected {
            self.dismiss()
        }
    }

    private func connectReference() {
        guard self.fields.useReference(isFixture: self.session.isFixtureLaunch) else { return }
        self.dismiss()
        self.reference()
    }
}
