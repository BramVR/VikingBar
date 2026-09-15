import SwiftUI

struct AccountView: View {
    let account: AccountPresentation
    let changeAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            Button(action: self.changeAccount) {
                Text(self.account.isConnected ? "Change account…" : "Sign in again…")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("vikingbar.account.change")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
