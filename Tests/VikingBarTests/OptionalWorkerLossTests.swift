import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct OptionalWorkerLossTests {
    @Test func `a Bills read that loses the worker fails queued points instead of leaving them pending`() async throws {
        let client = try OptionalModelClient()
        let model = try OptionalAppTests.model(client)
        model.start()
        try await AppSessionTests.until { client.requests == ["restore", "refresh", "points"] && model.canLoadInvoices }
        client.hold = ["invoices"]
        model.loadInvoices()
        try await AppSessionTests.until { client.pending["invoices"] != nil }
        model.enqueueOptional(.points)
        client.release("invoices", .failure(LiveBridgeFailure.invalidReply))
        try await AppSessionTests.until { client.shutdowns == 1 }
        #expect(model.pendingOptional.isEmpty)
        #expect(model.activeOptional == nil)
        #expect(!model.isLoadingInvoices)
        #expect(model.invoiceError == "Could not load bills. Refresh to try again.")
        #expect(model.liveState.points?.balanceFailure == .transport)
        #expect(model.bridgeError == nil)
        #expect(model.canRefresh)
        client.hold.removeAll()
        model.refresh()
        try await AppSessionTests.until { client.requests.count == 7 && model.activity == .idle }
        #expect(client.requests.suffix(3) == ["restore", "refresh", "points"])
        #expect(model.canLoadInvoices)
        await model.stop()
    }
}
