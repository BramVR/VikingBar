import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct DirectConnectionSessionTests {
    @Test func `direct sign in restores and refreshes after bootstrap consumes its credentials`() async throws {
        let client = ModelTestClient(state: AppSessionTests.connected())
        let connector = ModelTestConnector(fails: false)
        let model = try AppSessionTests.model(client: client, connector: connector)
        let credentials = try Self.credentials()
        model.connect(input: .credentials(credentials), resultURL: nil)
        try await AppSessionTests.until { model.activity == .idle && client.requests.last == "refreshPoints" }
        #expect(client.requests == ["restore", "refresh", "refreshPoints"])
        #expect(connector.connects == 1)
        #expect(connector.reference == nil)
        #expect(model.liveState.connectionID == client.state.connectionID)
        #expect(throws: LiveBridgeFailure.self) { try credentials.takePayload() }
        await model.stop()
    }

    @Test func `cancelled direct reconnect drains the connector and cannot restore either account`() async throws {
        let client = ModelTestClient(state: AppSessionTests.connected())
        let connector = ModelTestConnector(fails: false)
        connector.holdConnect = true
        let model = try AppSessionTests.model(client: client, connector: connector)
        model.start()
        try await AppSessionTests.until {
            model.activity == .idle && client.requests.last == "refreshPoints" && model.optionalOperation == nil
        }
        let requests = client.requests
        let credentials = try Self.credentials()
        model.connect(input: .credentials(credentials), resultURL: nil)
        try await AppSessionTests.until { connector.pendingConnect != nil }
        #expect(model.liveState.connectionID == nil)
        await model.cancelConnection()
        #expect(model.activity == .idle)
        #expect(model.liveState.connectionID == nil)
        #expect(model.snapshot.allowance == .unavailable)
        #expect(client.requests == requests)
        #expect(connector.cancels == 1)
        #expect(throws: LiveBridgeFailure.self) { try credentials.takePayload() }
        await model.stop()
    }

    @Test func `failed direct sign in releases input and does not start a session worker`() async throws {
        let client = ModelTestClient()
        let connector = ModelTestConnector(fails: true)
        let model = try AppSessionTests.model(client: client, connector: connector)
        let credentials = try Self.credentials()
        model.connect(input: .credentials(credentials), resultURL: nil)
        try await AppSessionTests.until { model.activity == .idle }
        #expect(client.requests.isEmpty)
        #expect(model.bridgeError == LiveBridgeFailure.connectFailed.message)
        #expect(throws: LiveBridgeFailure.self) { try credentials.takePayload() }
        await model.stop()
    }

    @Test func `fixture session discards direct credentials without creating any service`() async throws {
        var creations = 0
        let model = try AppSession(
            options: LaunchOptions(arguments: ["--fixture", "finite"]), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { creations += 1; throw LiveBridgeFailure.unavailable },
            connectorFactory: { creations += 1; throw LiveBridgeFailure.connectFailed },
        )
        let credentials = try Self.credentials()
        model.connect(input: .credentials(credentials), resultURL: nil)
        #expect(creations == 0)
        #expect(throws: LiveBridgeFailure.self) { try credentials.takePayload() }
        await model.stop()
    }

    @Test func `cancel during post login restoration shuts down the worker before draining the operation`(
    ) async throws {
        let client = ModelTestClient(state: AppSessionTests.connected())
        client.holdRestore = true
        let connector = ModelTestConnector(fails: false)
        let model = try AppSessionTests.model(client: client, connector: connector)
        try model.connect(input: .credentials(Self.credentials()), resultURL: nil)
        try await AppSessionTests.until { client.pendingRestore != nil }
        await model.cancelConnection()
        #expect(client.shutdowns == 1)
        #expect(client.pendingRestore == nil)
        #expect(model.client == nil)
        #expect(model.liveState.connectionID == nil)
        #expect(model.activity == .idle)
        #expect(client.requests == ["restore"])
        await model.stop()
    }

    private static func credentials() throws -> ConnectionCredentials {
        try ConnectionCredentials(clientID: "synthetic-client", username: "synthetic-user", password: "private-marker")
    }
}
