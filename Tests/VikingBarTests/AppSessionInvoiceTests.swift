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
        try await AppSessionTests.until { model.activity == .idle && client.requests.count == 3 }
        try await AppSessionTests.until { sleeper.deadlines.count >= 3 }
        let before = model.snapshot
        let invoiceRows = model.invoiceDetails.rows
        #expect(!invoiceRows.isEmpty)
        let deadlines = sleeper.deadlines
        client.hold = true
        model.loadInvoices()
        try await AppSessionTests.until { client.pending != nil }
        #expect(model.canRefresh)
        #expect(model.isLoadingInvoices)
        #expect(model.invoiceDetails.rows == invoiceRows)
        #expect(model.snapshot == before)
        #expect(sleeper.deadlines == deadlines)
        client.release(.failure(LiveBridgeFailure.invalidReply))
        try await AppSessionTests.until { !model.isLoadingInvoices }
        #expect(model.snapshot == before)
        #expect(model.bridgeError == nil)
        #expect(model.invoiceError != nil)
        #expect(model.invoiceDetails.rows == invoiceRows)
        await model.stop()
    }

    @Test func `refresh cancels obsolete invoice reply without replacing fresh balance`() async throws {
        let client = try InvoiceModelClient()
        let model = try Self.model(client)
        model.start()
        try await AppSessionTests.until { model.activity == .idle && client.requests.count == 3 }
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
        try await AppSessionTests.until { model.activity == .idle && client.requests.count == 3 }
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

    @Test func `payment fixture uses isolated copy storage and expires an open review`() async throws {
        let sleeper = ModelTestSleeper()
        let model = try AppSession(
            options: LaunchOptions(arguments: ["--fixture", "finite"]),
            preferences: MenuBarPreferences(fileURL: nil),
            referenceDate: LiveModelsTests.now,
            now: { LiveModelsTests.now },
            paymentFixtureRenderer: AppPaymentRenderer(),
            clipboardWrite: { _ in Issue.record("Fixture touched the system clipboard seam") },
            sleepUntil: { try await sleeper.sleep(until: $0) },
        )
        let id = try #require(model.paymentCandidates.first?.id)
        model.reviewPayment(id)
        try await AppSessionTests.until {
            if case .ready = model.paymentReview {
                true
            } else {
                false
            }
        }
        guard case let .ready(qrCode, _) = model.paymentReview else { return }
        #expect(qrCode.details.amountText == "42.50")
        model.copyPaymentField(qrCode.details.recipient.iban)
        #expect(model.fixtureClipboardValue == "BE02737026917240")
        try await AppSessionTests.until { !sleeper.deadlines.isEmpty }
        sleeper.wake()
        try await AppSessionTests.until {
            model.paymentReview == PaymentReview.unavailable(.reviewExpired, candidates: model.paymentCandidates)
        }
    }

    @Test func `collapse prevents an obsolete fixture renderer from publishing`() async throws {
        let renderer = HeldPaymentRenderer()
        let model = try AppSession(
            options: LaunchOptions(arguments: ["--fixture", "finite"]),
            preferences: MenuBarPreferences(fileURL: nil),
            referenceDate: LiveModelsTests.now,
            now: { LiveModelsTests.now },
            paymentFixtureRenderer: renderer,
        )
        let id = try #require(model.paymentCandidates.first?.id)
        model.reviewPayment(id)
        while await !renderer.isWaiting {
            await Task.yield()
        }
        model.clearPaymentReview()
        await renderer.release()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(model.paymentReview == PaymentReview.idle)
    }

    @Test func `collapse removes payment queued behind another optional request`() async throws {
        let client = try OptionalModelClient()
        client.hold = ["points"]
        let model = try OptionalAppTests.model(client)
        model.start()
        try await AppSessionTests.until { client.pending["points"] != nil }
        let id = try #require(model.paymentCandidates.first?.id)
        model.reviewPayment(id)
        #expect(model.paymentReview == PaymentReview.checking(invoiceID: id))
        model.clearPaymentReview()
        client.release("points", .success(client.state))
        try await AppSessionTests.until { model.activeOptional == nil }
        #expect(!client.requests.contains("payment"))
        #expect(!client.requests.contains("clearPayment"))
        #expect(model.paymentReview == PaymentReview.idle)
        await model.stop()
    }

    @Test func `invoice load and account refresh hide ready QR before awaiting worker`() async throws {
        let client = try InvoiceModelClient()
        let model = try Self.model(client)
        model.start()
        try await AppSessionTests.until { model.activity == .idle && client.requests.count == 3 }
        let details = try #require(Self.paymentDetails(model))
        let qrCode = try await AppPaymentRenderer().render(details, now: LiveModelsTests.now)
        model.liveState.setPaymentReview(.ready(qrCode, candidates: model.paymentCandidates))
        client.hold = true
        model.loadInvoices()
        #expect(model.paymentReview == .idle)
        try await AppSessionTests.until { client.pending != nil }
        model.refresh()
        #expect(model.paymentReview == .idle)
        client.release(.failure(CancellationError()))
        try await AppSessionTests.until { model.activity == .idle }
        await model.stop()
    }

    @Test func `reopen waits for payment cancellation acknowledgement before new review`() async throws {
        let client = try OptionalModelClient()
        let model = try OptionalAppTests.model(client)
        model.start()
        try await AppSessionTests.until { model.activity == .idle && model.activeOptional == nil }
        client.hold = ["payment", "cancel"]
        let id = try #require(model.paymentCandidates.first?.id)
        model.reviewPayment(id)
        try await AppSessionTests.until { client.pending["payment"] != nil }
        model.clearPaymentReview()
        try await AppSessionTests.until { client.pending["cancel"] != nil }
        model.reviewPayment(id)
        #expect(client.requests.filter { $0 == "payment" }.count == 1)
        client.release("payment", .failure(CancellationError()))
        client.release("cancel", .success(client.state))
        try await AppSessionTests.until { client.requests.filter { $0 == "payment" }.count == 2 }
        client.release("payment", .failure(CancellationError()))
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

    private static func paymentDetails(_ model: AppSession) -> InvoicePaymentDetails? {
        guard let invoices = model.liveState.invoices,
              case let .selected(details, _) = InvoicePaymentSelection.select(
                  snapshot: invoices,
                  requestedInvoiceID: model.paymentCandidates.first?.id,
                  selectedSubscriptionID: model.liveState.selectedSubscriptionID,
                  now: LiveModelsTests.now,
              )
        else { return nil }
        return details
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
        self.state.invoices = try .loaded([InvoiceTests.invoice(InvoiceTests.item(
            extra: ",\"reference_number\":\"+++123/4567/89002+++\"",
        ))], updatedAt: LiveModelsTests.now)
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

private struct AppPaymentRenderer: PaymentQRRendering {
    func render(_ details: InvoicePaymentDetails, now: Date) async throws -> InvoicePaymentQRCode {
        InvoicePaymentQRCode(
            details: details,
            payload: "BCD\n002\n1\nSCT\nKREDBEBB\nMobile Vikings NV\nBE02737026917240\n"
                + "EUR\(details.amountText)\n\n\(details.epcReference)\n\n",
            png: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            generatedAt: now, expiresAt: now.addingTimeInterval(300),
        )
    }
}

private actor HeldPaymentRenderer: PaymentQRRendering {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool {
        self.continuation != nil
    }

    func render(_ details: InvoicePaymentDetails, now: Date) async throws -> InvoicePaymentQRCode {
        await withCheckedContinuation { self.continuation = $0 }
        return try await AppPaymentRenderer().render(details, now: now)
    }

    func release() {
        self.continuation?.resume()
        self.continuation = nil
    }
}
