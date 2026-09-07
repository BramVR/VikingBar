import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct AppSessionInvoiceTests {
    @Test func `fixture invoice paths never construct client or open document`() throws {
        var clients = 0
        var opened = 0
        let model = try AppSession(
            options: LaunchOptions(arguments: ["--fixture", "finite"]), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { clients += 1; throw LiveBridgeFailure.unavailable },
            openDocument: { _ in opened += 1; return true },
        )
        model.start()
        model.loadInvoices()
        model.openInvoice("inv-1")
        #expect(clients == 0)
        #expect(opened == 0)
    }

    @Test func `invoice request preserves refresh availability balance and expiry schedule`() async throws {
        let client = try InvoiceModelClient()
        let sleeper = ModelTestSleeper()
        let model = try Self.model(client, sleeper: sleeper)
        model.start()
        try await AppSessionTests.until { model.activity == .idle && client.requests.count == 2 }
        try await AppSessionTests.until { sleeper.deadlines.count >= 3 }
        let before = model.snapshot
        let deadlines = sleeper.deadlines
        client.hold = true
        model.loadInvoices()
        try await AppSessionTests.until { client.pending != nil }
        #expect(model.canRefresh)
        #expect(model.isLoadingInvoices)
        #expect(model.snapshot == before)
        #expect(sleeper.deadlines == deadlines)
        client.release(.failure(LiveBridgeFailure.invalidReply))
        try await AppSessionTests.until { !model.isLoadingInvoices }
        #expect(model.snapshot == before)
        #expect(model.bridgeError == nil)
        #expect(model.invoiceError != nil)
        await model.stop()
    }

    @Test func `refresh cancels obsolete invoice reply without replacing fresh balance`() async throws {
        let client = try InvoiceModelClient()
        let model = try Self.model(client)
        model.start()
        try await AppSessionTests.until { model.activity == .idle && client.requests.count == 2 }
        let old = client.state
        client.hold = true
        model.loadInvoices()
        try await AppSessionTests.until { client.pending != nil }
        client.state = AppSessionTests.connected()
        model.refresh()
        try await AppSessionTests.until { client.requests.contains("cancel") && model.activity == .idle }
        client.release(.success(old))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(model.liveState.connectionID == client.state.connectionID)
        #expect(model.liveState.invoices == nil)
        await model.stop()
    }

    @Test func `PDF opens once only after explicit request and stale reply never opens`() async throws {
        let client = try InvoiceModelClient()
        var opened: [URL] = []
        let model = try Self.model(client, open: { opened.append($0); return true })
        model.start()
        try await AppSessionTests.until { model.activity == .idle && client.requests.count == 2 }
        model.loadInvoices()
        try await AppSessionTests.until { !model.isLoadingInvoices }
        #expect(opened.isEmpty)
        model.openInvoice("inv-1")
        try await AppSessionTests.until { !model.isLoadingInvoices }
        #expect(opened == [client.document.fileURL])
        model.refresh()
        try await AppSessionTests.until { model.activity == .idle }
        #expect(opened.count == 1)
        client.hold = true
        model.openInvoice("inv-1")
        try await AppSessionTests.until { client.pending != nil }
        var old = client.state
        old.invoiceDocument = client.document
        model.refresh()
        try await AppSessionTests.until { model.activity == .idle }
        client.release(.success(old))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(opened.count == 1)
        await model.stop()
    }

    private static func model(
        _ client: InvoiceModelClient, sleeper: ModelTestSleeper = ModelTestSleeper(),
        open: @escaping (URL) -> Bool = { _ in false },
    ) throws -> AppSession {
        try AppSession(
            options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { client }, now: { LiveModelsTests.now }, openDocument: open,
            sleepUntil: { try await sleeper.sleep(until: $0) },
        )
    }
}

@MainActor
private final class InvoiceModelClient: SessionClient {
    var state = AppSessionTests.connected()
    var requests: [String] = []
    var hold = false
    var pending: CheckedContinuation<LiveSessionState, any Error>?
    let document = InvoiceDocument(invoiceID: "inv-1", fileURL: URL(fileURLWithPath: "/private/synthetic/invoice.pdf"))

    init() throws {
        self.state.invoices = try .loaded([InvoiceTests.invoice()], updatedAt: LiveModelsTests.now)
        self.state.nextRefreshAt = LiveModelsTests.now.addingTimeInterval(300)
    }

    func request(_ request: SessionRequest) async throws -> LiveSessionState {
        switch request {
        case .restore: self.requests.append("restore")
        case .refresh: self.requests.append("refresh")
        case .refreshInvoices, .downloadInvoice:
            self.requests.append("invoices")
            if self.hold {
                return try await withCheckedThrowingContinuation { self.pending = $0 }
            }
            var result = self.state
            if case .downloadInvoice = request {
                result.invoiceDocument = self.document
            }
            return result
        case .cancel: self.requests.append("cancel")
        default: self.requests.append("other")
        }
        return self.state
    }

    func release(_ result: Result<LiveSessionState, any Error>) {
        self.pending?.resume(with: result)
        self.pending = nil
    }

    func shutdown() async {
        self.release(.failure(CancellationError()))
    }
}
