import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct SignInFixtureTests {
    @Test func `fixture connection completes and provider logout survives isolated relaunch`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sign-in.json")
        let store = try SignInFixtureStore(url: url)
        let app = try Self.app(store)
        app.start()
        let credentials = try ConnectionCredentials(provider: .mobileVikings, clientID: "fixture-public",
                                                    username: "mobile@example.invalid", password: "synthetic",
                                                    rememberPassword: true)
        let attempt = try #require(app.connect(input: .credentials(credentials), resultURL: nil))
        var form = ConnectionFormAttempt()
        form.recordSubmission(attempt)
        #expect(form.isConnecting(in: app))
        try await Self.waitIdle(app)
        let finished = form.finishIfNeeded(in: app)
        #expect(finished)
        #expect(app.liveState.signIn?.remembered == .available)
        #expect(app.accountPresentation.username == "mobile@example.invalid")
        app.performSignInAction(.logout)
        #expect(app.snapshot.source == .fixture(.error))
        #expect(app.accountPresentation.isDemo)
        #expect(app.status.accessibilityLabel.contains("Fixture"))
        app.selectAccount(FixtureAccounts.telenet)
        try await Self.waitIdle(app)
        #expect(app.providerName == "Telenet")
        #expect(app.selectedServiceKind == .home)
        let homeCredentials = try ConnectionCredentials(provider: .telenet, clientID: "",
                                                        username: "home@example.invalid", password: "synthetic",
                                                        rememberPassword: true)
        _ = try #require(app.connect(input: .credentials(homeCredentials), resultURL: nil))
        try await Self.waitIdle(app)
        #expect(app.liveState.signIn?.remembered == .available)
        #expect(app.liveState.selectedHomeUsage?.policyCounterGB == 20)
        #expect(app.accountPresentation.username == "home@example.invalid")
        app.performSignInAction(.logout)
        #expect(app.snapshot.source == .fixture(.error))
        await app.stop()

        try await Self.verifyRelaunch(url: url)
    }

    private static func verifyRelaunch(url: URL) async throws {
        let relaunched = try self.app(SignInFixtureStore(url: url))
        relaunched.start()
        try await self.waitIdle(relaunched)
        #expect(relaunched.selectedAccount == FixtureAccounts.telenet)
        #expect(relaunched.liveState.connectionID == nil)
        #expect(relaunched.liveState.signIn?.remembered == .disabled)
        #expect(relaunched.accountPresentation.username == "home@example.invalid")
        #expect(relaunched.snapshot.source == .fixture(.error))
        #expect(relaunched.status.accessibilityLabel.contains("Fixture"))
        relaunched.selectAccount(FixtureAccounts.mobile)
        try await self.waitIdle(relaunched)
        #expect(relaunched.liveState.connectionID == nil)
        #expect(relaunched.accountPresentation.username == "mobile@example.invalid")
        #expect(relaunched.snapshot.source == .fixture(.error))
        let fields = ConnectionFormModel(account: relaunched.accountPresentation.summary)
        #expect(fields.clientID == "fixture-public")
        #expect(fields.username == "mobile@example.invalid")
        #expect(fields.password == "")
        #expect(fields.rememberPassword == false)
        await relaunched.stop()
    }

    @Test func `reference intent retains opt in and fence through clearing and dismissal`() {
        let fields = ConnectionFormModel()
        fields.password = "discard-me"
        fields.rememberPassword = true
        #expect(fields.useReference(isFixture: false))
        #expect(fields.password == "")
        #expect(fields.rememberPassword == true)
    }

    private static func waitIdle(_ app: AppSession) async throws {
        for _ in 0 ..< 200 {
            if app.activity == .idle {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(app.activity == .idle, "Fixture did not finish. Activity \(app.activity).")
    }

    private static func app(_ store: SignInFixtureStore) throws -> AppSession {
        try AppSession(options: LaunchOptions(arguments: ["--fixture", "finite"]),
                       preferences: MenuBarPreferences(fileURL: nil), referenceDate: LiveModelsTests.now,
                       signInFixtureStore: store)
    }
}
