import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct ConnectionFormTests {
    @Test func `data and settings forms present only the attempt each submitted`() async throws {
        let connector = ModelTestConnector(fails: false)
        connector.holdConnect = true
        let session = try AppSessionTests.model(client: ModelTestClient(), connector: connector)
        var dataForm = ConnectionFormAttempt()
        var settingsForm = ConnectionFormAttempt()
        let attempt = try #require(session.connect(
            input: .reference(URL(fileURLWithPath: "/synthetic/reference")), resultURL: nil,
        ))
        dataForm.recordSubmission(attempt)
        try await AppSessionTests.until { connector.pendingConnect != nil }

        #expect(dataForm.isConnecting(in: session))
        #expect(!settingsForm.isConnecting(in: session))

        let settingsAttempt = settingsForm.takeAttempt()
        #expect(settingsAttempt == nil)
        #expect(session.isConnecting(attempt))
        await session.stop()
    }

    @Test func `hidden form from a prior attempt does not attach to its successor`() async throws {
        let connector = ModelTestConnector(fails: false)
        connector.holdConnect = true
        let session = try AppSessionTests.model(client: ModelTestClient(), connector: connector)
        var hiddenForm = ConnectionFormAttempt()
        let first = try #require(session.connect(
            input: .reference(URL(fileURLWithPath: "/synthetic/first")), resultURL: nil,
        ))
        hiddenForm.recordSubmission(first)
        try await AppSessionTests.until { connector.pendingConnect != nil }
        await session.cancelConnection(first)

        var currentForm = ConnectionFormAttempt()
        let second = try #require(session.connect(
            input: .reference(URL(fileURLWithPath: "/synthetic/second")), resultURL: nil,
        ))
        currentForm.recordSubmission(second)
        try await AppSessionTests.until { connector.pendingConnect != nil }

        #expect(!hiddenForm.isConnecting(in: session))
        let hiddenFinished = hiddenForm.finishIfNeeded(in: session)
        #expect(hiddenFinished)
        #expect(currentForm.isConnecting(in: session))
        await session.stop()
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
