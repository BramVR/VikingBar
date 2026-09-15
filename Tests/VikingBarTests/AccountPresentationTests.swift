import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct AccountPresentationTests {
    @Test func `connected summary identifies the account and change form never prefills a password`() {
        let summary = AccountConnectionSummary(clientID: "public-client", username: "demo@example.invalid")
        let account = AccountPresentation(summary: summary, isConnected: true, isDemo: false)
        #expect(account.status == "Connected to Mobile Vikings")
        #expect(account.username == "demo@example.invalid")
        let form = ConnectionFormModel(account: summary)
        #expect(form.clientID == "public-client")
        #expect(form.username == "demo@example.invalid")
        #expect(form.password.isEmpty)
        #expect(form.takeCredentials(isFixture: true) == nil)
        #expect(form.error == "Enter all three fields.")
    }

    @Test func `older saved connections never invent a username`() {
        let account = AccountPresentation(
            summary: AccountConnectionSummary(clientID: "legacy-client", username: nil),
            isConnected: true, isDemo: false,
        )
        #expect(account.username == nil)
    }

    @Test func `expired credentials request sign-in without claiming connected`() {
        let account = AccountPresentation(summary: nil, isConnected: false, isDemo: false)
        #expect(account.status == "Sign in to Mobile Vikings")
    }
}
