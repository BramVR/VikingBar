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
        #expect(model.connect(input: .credentials(credentials), resultURL: nil) != nil)
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
        let attempt = try #require(model.connect(input: .credentials(credentials), resultURL: nil))
        try await AppSessionTests.until { connector.pendingConnect != nil }
        #expect(model.liveState.connectionID == nil)
        await model.cancelConnection(attempt)
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
        #expect(model.connect(input: .credentials(credentials), resultURL: nil) != nil)
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
        let connectionAttempt = model.connect(input: .credentials(credentials), resultURL: nil)
        var attempt = ConnectionFormAttempt()
        attempt.recordSubmission(connectionAttempt)
        #expect(connectionAttempt == nil)
        #expect(!attempt.isConnecting(in: model))
        #expect(creations == 0)
        #expect(throws: LiveBridgeFailure.self) { try credentials.takePayload() }
        await model.stop()
    }

    @Test func `duplicate and stopped direct submissions are refused and release credentials`() async throws {
        let connector = ModelTestConnector(fails: false)
        connector.holdConnect = true
        let model = try AppSessionTests.model(client: ModelTestClient(), connector: connector)
        let active = try Self.credentials()
        #expect(model.connect(input: .credentials(active), resultURL: nil) != nil)
        try await AppSessionTests.until { connector.pendingConnect != nil }

        let duplicate = try Self.credentials()
        let duplicateAttempt = model.connect(input: .credentials(duplicate), resultURL: nil)
        var attempt = ConnectionFormAttempt()
        attempt.recordSubmission(duplicateAttempt)
        #expect(duplicateAttempt == nil)
        #expect(model.activity == .connecting)
        #expect(!attempt.isConnecting(in: model))
        #expect(connector.connects == 1)
        #expect(throws: LiveBridgeFailure.self) { try duplicate.takePayload() }

        await model.stop()
        let stopped = try Self.credentials()
        let stoppedAttempt = model.connect(input: .credentials(stopped), resultURL: nil)
        attempt.recordSubmission(stoppedAttempt)
        #expect(stoppedAttempt == nil)
        #expect(!attempt.isConnecting(in: model))
        #expect(connector.connects == 1)
        #expect(throws: LiveBridgeFailure.self) { try stopped.takePayload() }
    }

    @Test func `accepted connection identity is active only for its session attempt`() async throws {
        let connector = ModelTestConnector(fails: false)
        connector.holdConnect = true
        let model = try AppSessionTests.model(client: ModelTestClient(), connector: connector)
        let attempt = try #require(model.connect(input: .credentials(Self.credentials()), resultURL: nil))
        try await AppSessionTests.until { connector.pendingConnect != nil }
        #expect(model.isConnecting(attempt))
        await model.stop()
        #expect(!model.isConnecting(attempt))
    }

    @Test func `attempt identity from another session cannot present or cancel its first connection`() async throws {
        let connectorA = ModelTestConnector(fails: false)
        let connectorB = ModelTestConnector(fails: false)
        connectorA.holdConnect = true
        connectorB.holdConnect = true
        let sessionA = try AppSessionTests.model(client: ModelTestClient(), connector: connectorA)
        let sessionB = try AppSessionTests.model(client: ModelTestClient(), connector: connectorB)
        let attemptA = try #require(sessionA.connect(input: .credentials(Self.credentials()), resultURL: nil))
        let attemptB = try #require(sessionB.connect(input: .credentials(Self.credentials()), resultURL: nil))
        try await AppSessionTests.until { connectorA.pendingConnect != nil && connectorB.pendingConnect != nil }

        #expect(!sessionB.isConnecting(attemptA))
        let cancelledB = await sessionB.cancelConnection(attemptA)
        #expect(!cancelledB)
        #expect(sessionB.isConnecting(attemptB))
        #expect(connectorB.cancels == 0)

        await sessionA.stop()
        await sessionB.stop()
    }

    @Test func `stale connection identity cannot cancel its successor`() async throws {
        let connector = ModelTestConnector(fails: false)
        connector.holdConnect = true
        let model = try AppSessionTests.model(client: ModelTestClient(), connector: connector)
        let first = try #require(model.connect(input: .credentials(Self.credentials()), resultURL: nil))
        try await AppSessionTests.until { connector.pendingConnect != nil }
        let cancelledFirst = await model.cancelConnection(first)
        #expect(cancelledFirst)

        let second = try #require(model.connect(input: .credentials(Self.credentials()), resultURL: nil))
        try await AppSessionTests.until { connector.pendingConnect != nil }
        let cancelledStale = await model.cancelConnection(first)
        #expect(!cancelledStale)
        #expect(model.isConnecting(second))
        #expect(connector.cancels == 1)

        let cancelledSecond = await model.cancelConnection(second)
        #expect(cancelledSecond)
        #expect(model.activity == .idle)
        #expect(connector.cancels == 2)
    }

    @Test func `cancel during post login restoration shuts down the worker before draining the operation`(
    ) async throws {
        let client = ModelTestClient(state: AppSessionTests.connected())
        client.holdRestore = true
        let connector = ModelTestConnector(fails: false)
        let model = try AppSessionTests.model(client: client, connector: connector)
        let attempt = try #require(model.connect(input: .credentials(Self.credentials()), resultURL: nil))
        try await AppSessionTests.until { client.pendingRestore != nil }
        await model.cancelConnection(attempt)
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
