import SwiftUI
import VikingBarCore

struct AccountView: View {
    let account: AccountPresentation
    var signIn: AccountSignInPresentation?
    var savedSignIn: () -> Void = {}
    var disableRememberedSignIn: () -> Void = {}
    var logout: () -> Void = {}
    let changeAccount: () -> Void
    let addAccount: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            self.content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            self.accountHeader
            Button(action: self.changeAccount) {
                Text(self.account.isConnected ? "Reconnect account…" : "Sign in again…")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("vikingbar.account.change")
            if let deadline = self.signIn?.nextPasswordAttemptAt, deadline > now {
                Text("Sign-in paused until \(deadline.formatted(date: .omitted, time: .shortened)).")
                    .font(.caption).foregroundStyle(.secondary)
            } else if self.signIn?.attemptPending == true {
                Text("The previous sign-in did not finish. Choose Sign in again to retry.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if self.signIn?.failure == .storage {
                Text(self.account.isConnected
                    ? "Connected, but password storage needs attention. Reconnect to remember it again."
                    : "Local cleanup needs attention. Retry removing the saved password.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if self.signIn?.remembered == .available {
                Button("Sign in again with saved password", action: self.savedSignIn)
                    .disabled((self.signIn?.nextPasswordAttemptAt ?? .distantPast) > now)
                    .accessibilityIdentifier("vikingbar.account.saved-sign-in")
                Button("Stop remembering password", action: self.disableRememberedSignIn)
                    .accessibilityIdentifier("vikingbar.account.disable-remembered-sign-in")
            } else if self.signIn?.remembered == .cleanupRequired {
                Button("Retry removing saved password", action: self.disableRememberedSignIn)
                    .accessibilityIdentifier("vikingbar.account.disable-remembered-sign-in")
            }
            if self.account.isConnected || self.signIn?.fence.connectionID != nil {
                Button("Log out", action: self.logout)
                    .accessibilityIdentifier("vikingbar.account.logout")
            }
            Button("Add account…", action: self.addAccount)
                .accessibilityIdentifier("vikingbar.account.add")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accountHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: self.account.isConnected ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.title2)
                .foregroundStyle(self.account.isConnected ? .green : .orange)
                .accessibilityHidden(true)
            Text(self.account.status)
                .font(.headline)
                .accessibilityIdentifier("vikingbar.account.status")
            if let username = self.account.username {
                Text(username)
                    .font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("vikingbar.account.username")
            } else if !self.account.isDemo {
                Text("Username unavailable for this saved connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
    }
}
