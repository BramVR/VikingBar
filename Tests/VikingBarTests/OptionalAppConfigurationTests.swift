import Foundation
import Testing
@testable import VikingBarApp

extension OptionalAppTests {
    @Test func `late configuration success after stop cannot enqueue metadata`() async throws {
        let client = try OptionalModelClient()
        client.hold = ["refresh", "configure"]
        client.completeOnShutdown = true
        let model = try Self.model(client)
        model.start()
        try await AppSessionTests.until { client.pending["refresh"] != nil }
        model.refreshInterval = .oneHour
        client.release("refresh", .success(client.state))
        try await AppSessionTests.until { client.pending["configure"] != nil }
        await model.stop()
        #expect(model.activity == .stopped)
        #expect(model.pendingOptional.isEmpty)
        #expect(client.requests == ["restore", "refresh", "configure"])
    }

    @Test func `configuration errors remain visible and delayed replies cannot undo reconnect`() async throws {
        for reconnect in [false, true] {
            let client = try OptionalModelClient()
            let model = try Self.model(client)
            model.start()
            try await AppSessionTests.until { client.requests.last == "points" }
            client.hold = ["configure"]
            model.refreshInterval = .oneHour
            try await AppSessionTests.until { client.pending["configure"] != nil }
            if reconnect {
                model.connect(
                    input: .reference(URL(fileURLWithPath: "/synthetic/reference")),
                    resultURL: nil,
                )
                client.release("configure", .success(client.state))
            } else {
                client.release("configure", .failure(LiveBridgeFailure.invalidReply))
            }
            try await AppSessionTests.until { model.activity == .idle }
            #expect(model.bridgeError == (reconnect ? LiveBridgeFailure.connectFailed : .unavailable).message)
            if reconnect {
                #expect(model.liveState.connectionID == nil)
            }
            await model.stop()
        }
    }

    @Test func `worker recovery with saved interval retains queued Bills until account restore`() async throws {
        let client = try OptionalModelClient()
        client.hold = ["points"]
        let model = try Self.model(client)
        model.refreshInterval = .oneHour
        model.start()
        try await AppSessionTests.until { client.pending["points"] != nil }
        model.loadInvoices()
        client.release("points", .failure(LiveBridgeFailure.invalidReply))
        try await AppSessionTests.until { client.shutdowns == 1 }
        client.hold.remove("points")
        model.refresh()
        try await AppSessionTests.until { client.requests.filter { $0 == "points" }.count == 2 }
        #expect(client.requests == [
            "configure", "restore", "refresh", "points", "configure", "restore", "refresh", "invoices", "points",
        ])
        #expect(model.liveState.invoices == client.state.invoices)
        await model.stop()
    }

    @Test func `interval changes drain optional cancellation and resume queued Bills`() async throws {
        let client = try OptionalModelClient()
        client.hold = ["points", "cancel"]
        let model = try Self.model(client)
        model.start()
        try await AppSessionTests.until { client.pending["points"] != nil }
        model.loadInvoices()
        model.refreshInterval = .oneHour
        try await AppSessionTests.until { client.pending["cancel"] != nil }
        #expect(client.requests == ["restore", "refresh", "points", "cancel"])
        #expect(model.activity == .configuring)
        client.release("points", .failure(CancellationError()))
        client.hold.remove("points")
        client.release("cancel", .success(client.state))
        try await AppSessionTests.until { client.requests.last == "invoices" && !model.isLoadingInvoices }
        #expect(client.requests == ["restore", "refresh", "points", "cancel", "configure", "points", "invoices"])
        #expect(model.liveState.points == client.state.points)
        #expect(model.liveState.invoices == client.state.invoices)
        #expect(model.activity == .idle)
        await model.stop()
    }
}
