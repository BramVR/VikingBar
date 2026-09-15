import SwiftUI
import VikingBarCore

@MainActor
struct ConnectionFormAttempt {
    private var attempt: AppSession.ConnectionAttempt?

    mutating func recordSubmission(_ attempt: AppSession.ConnectionAttempt?) {
        self.attempt = attempt
    }

    func isConnecting(in session: AppSession) -> Bool {
        guard let attempt = self.attempt else { return false }
        return session.isConnecting(attempt)
    }

    mutating func finishIfNeeded(in session: AppSession) -> Bool {
        guard self.attempt != nil, !self.isConnecting(in: session) else { return false }
        self.attempt = nil
        return true
    }

    mutating func takeAttempt() -> AppSession.ConnectionAttempt? {
        defer { self.attempt = nil }
        return self.attempt
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

    init(
        session: AppSession, resultURL: URL?, initialAccount: AccountConnectionSummary? = nil,
        reference: @escaping () -> Void, dismiss: @escaping () -> Void,
    ) {
        self.session = session
        self.resultURL = resultURL
        self.reference = reference
        self.dismiss = dismiss
        self._fields = State(initialValue: ConnectionFormModel(account: initialAccount))
    }

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
                    let attempt = self.attempt.takeAttempt()
                    Task {
                        if let attempt {
                            await self.session.cancelConnection(attempt)
                        }
                        self.dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("vikingbar.connect.cancel")
                .buttonStyle(.menuAction)
            }
            if !self.isConnecting {
                Button("Connect with 1Password", action: self.connectReference)
                    .accessibilityIdentifier("vikingbar.connect")
                    .buttonStyle(.menuAction)
                Text("Optional. Requires the configured 1Password helper and an approved credential reference.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity, maxHeight: 560, alignment: .topLeading)
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
        self.attempt.isConnecting(in: self.session)
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
                    .buttonStyle(.menuAction)
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
        let attempt = self.session.connect(input: .credentials(credentials), resultURL: self.resultURL)
        self.attempt.recordSubmission(attempt)
        self.finishIfNeeded()
    }

    private func finishIfNeeded() {
        guard self.attempt.finishIfNeeded(in: self.session) else { return }
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
