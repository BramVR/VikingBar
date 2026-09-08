import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct ConnectionFormTests {
    @Test func `unsubmitted form does not own another session connection`() {
        var attempt = ConnectionFormAttempt()
        #expect(!attempt.isConnecting(activity: .connecting))
        let finished = attempt.finishIfNeeded(activity: .idle)
        #expect(!finished)
    }

    @Test func `submitted form shows progress only while its connection is active`() {
        var attempt = ConnectionFormAttempt()
        attempt.recordSubmission(accepted: true)
        #expect(attempt.isConnecting(activity: .connecting))
        let finished = attempt.finishIfNeeded(activity: .connecting)
        #expect(!finished)
        #expect(attempt.isConnecting(activity: .connecting))
    }

    @Test(arguments: [
        AppSession.Activity.idle, .restoring, .refreshing, .selecting, .stopped,
    ])
    func `refused or finished submissions recover once and allow retry`(activity: AppSession.Activity) {
        var attempt = ConnectionFormAttempt()
        attempt.recordSubmission(accepted: true)
        #expect(!attempt.isConnecting(activity: activity))
        let finished = attempt.finishIfNeeded(activity: activity)
        #expect(finished)
        let finishedAgain = attempt.finishIfNeeded(activity: activity)
        #expect(!finishedAgain)
        #expect(!attempt.isConnecting(activity: .connecting))
        attempt.recordSubmission(accepted: true)
        #expect(attempt.isConnecting(activity: .connecting))
    }

    @Test func `terminal activity missed while hidden reconciles on return`() {
        var attempt = ConnectionFormAttempt()
        attempt.recordSubmission(accepted: true)
        #expect(attempt.isConnecting(activity: .connecting))
        #expect(!attempt.isConnecting(activity: .idle))
        let finished = attempt.finishIfNeeded(activity: .idle)
        #expect(finished)
        #expect(!attempt.isConnecting(activity: .connecting))
    }

    @Test func `submission normalizes identifiers preserves password and consumes credentials once`() throws {
        let model = ConnectionFormModel()
        model.clientID = " synthetic-client \n"
        model.username = " synthetic-user "
        model.password = " synthetic-password \n"
        let credentials = try #require(model.takeCredentials(isFixture: false))
        #expect(model.password.isEmpty)
        let decoded = try JSONDecoder().decode(ProofCredentials.self, from: credentials.takePayload())
        #expect(decoded.clientID == "synthetic-client")
        #expect(decoded.username == "synthetic-user")
        #expect(decoded.password == " synthetic-password \n")
        #expect(throws: LiveBridgeFailure.self) { try credentials.takePayload() }
    }

    @Test func `invalid and oversized submissions clear the password with fixed messages`() {
        let model = ConnectionFormModel()
        model.clientID = " \n"
        model.username = "synthetic-user"
        model.password = "private-marker"
        #expect(model.takeCredentials(isFixture: false) == nil)
        #expect(model.password.isEmpty)
        #expect(model.error == "Enter all three fields.")
        model.clientID = "synthetic-client"
        model.password = String(repeating: "\\", count: 32768)
        #expect(model.takeCredentials(isFixture: false) == nil)
        #expect(model.password.isEmpty)
        #expect(model.error == "Sign-in details are too long.")
    }

    @Test func `fixture direct and reference methods clear secrets without producing live input`() {
        let model = ConnectionFormModel()
        model.clientID = "synthetic-client"
        model.username = "synthetic-user"
        model.password = "private-marker"
        #expect(model.takeCredentials(isFixture: true) == nil)
        #expect(model.password.isEmpty)
        #expect(model.error == "Fixture mode does not connect to an account.")
        model.password = "private-marker"
        #expect(!model.useReference(isFixture: true))
        #expect(model.password.isEmpty)
        #expect(model.error == "Fixture mode does not read 1Password.")
        model.password = "private-marker"
        #expect(model.useReference(isFixture: false))
        #expect(model.password.isEmpty)
        #expect(model.error == nil)
    }

    @Test func `dismissal and discarded inputs release credentials`() throws {
        let model = ConnectionFormModel()
        model.password = "private-marker"
        model.clear()
        #expect(model.password.isEmpty)
        let input = try ConnectionCredentials(clientID: "client", username: "user", password: "private-marker")
        input.discard()
        #expect(throws: LiveBridgeFailure.self) { try input.takePayload() }
    }
}
