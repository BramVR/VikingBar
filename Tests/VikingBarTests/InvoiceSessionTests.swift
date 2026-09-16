import Foundation
import Testing
@testable import VikingBarCore

struct InvoiceSessionTests {
    @Test func `invoice failure preserves balance freshness and retry deadline`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        let before = try await rig.session.refresh()
        await rig.transport.failNext(code: 503)
        let after = try await rig.session.refreshInvoices()
        #expect(after.snapshot == before.snapshot)
        #expect(after.failure == before.failure)
        #expect(after.nextRefreshAt == before.nextRefreshAt)
        #expect(after.invoices == .unavailable)
    }

    @Test func `SIM change cancels obsolete invoice response without contaminating selected balance`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        _ = try await rig.session.refresh()
        await rig.transport.setResponse(path: "/mv/invoices", json: InvoiceTests.page([InvoiceTests.item()]))
        await rig.transport.pauseNext(path: "/mv/invoices")
        let old = Task { try await rig.session.refreshInvoices() }
        await rig.transport.waitUntilPaused()
        let selection = Task { try await rig.session.selectSubscription(id: "sim-b") }
        while await !rig.session.state().isRefreshing {
            await Task.yield()
        }
        await rig.transport.resume()
        let selected = try await selection.value
        await #expect(throws: CancellationError.self) { try await old.value }
        let final = await rig.session.state()
        #expect(final.selectedSubscriptionID == "sim-b")
        #expect(final.snapshot == selected.snapshot)
        #expect(final.invoices == nil)
    }

    @Test func `account replacement while invoices in flight rejects old account`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        _ = try await rig.session.refresh()
        await rig.transport.setResponse(path: "/mv/invoices", json: InvoiceTests.page([InvoiceTests.item()]))
        await rig.transport.pauseNext(path: "/mv/invoices")
        let old = Task { try await rig.session.refreshInvoices() }
        await rig.transport.waitUntilPaused()
        let replacement = try await rig.newSession().bootstrap(credentials: LiveSessionTests.credentials)
        await rig.transport.resume()
        await #expect(throws: LiveFailure.connectionChanged) { try await old.value }
        let final = await rig.session.state()
        #expect(final.connectionID == replacement.connectionID)
        #expect(final.invoices == nil)
    }

    @Test func `explicit PDF download alone writes private generated file with bearer auth`() async throws {
        let transport = InvoiceTestTransport(pages: [InvoiceTests.page([InvoiceTests.item()])])
        let session = Self.session(transport)
        _ = try await session.bootstrap(credentials: LiveSessionTests.credentials)
        _ = try await session.refresh()
        let loaded = try await session.refreshInvoices()
        #expect(loaded.invoiceDocument == nil)
        #expect(await transport.requests.contains { $0.url?.path.hasSuffix("/pdf") == true } == false)
        let downloaded = try await session.downloadInvoice(id: "inv-1")
        let document = try #require(downloaded.invoiceDocument)
        defer { try? FileManager.default.removeItem(at: document.fileURL.deletingLastPathComponent()) }
        #expect(document.fileURL.lastPathComponent == "invoice.pdf")
        #expect(try FileManager.default
            .attributesOfItem(atPath: document.fileURL.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default
            .attributesOfItem(atPath: document.fileURL.deletingLastPathComponent().path)[.posixPermissions] as? Int ==
            0o700)
        let request = try #require(await transport.requests.last)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        #expect(request.url?.query == nil)
        #expect(downloaded.snapshot == loaded.snapshot)
        await #expect(throws: LiveFailure.invalidSelection) { try await session.downloadInvoice(id: "not-listed") }
        #expect(await session.state().invoiceDocument == nil)
    }

    @Test func `cached snapshots exclude transient PDF paths and old cache decodes`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        var state = LiveSessionState()
        let connection = ConnectionID()
        state.connectionID = connection
        state.invoiceDocument = InvoiceDocument(
            invoiceID: "inv-1",
            fileURL: URL(fileURLWithPath: "/private/synthetic.pdf"),
        )
        let invoice = try InvoiceTests.invoice(InvoiceTests.item(extra:
            ",\"reference_number\":\"+++123/4567/89002+++\""))
        guard case let .selected(details, _) = InvoicePaymentSelection.select(
            snapshot: .loaded([invoice], updatedAt: LiveModelsTests.now), requestedInvoiceID: nil,
            selectedSubscriptionID: nil, now: LiveModelsTests.now,
        ) else {
            Issue.record("Expected payment details")
            return
        }
        state.paymentReview = .ready(Self.qr(details), candidates: [])
        let cache = FileBalanceCache(url: folder.appendingPathComponent("cache.json"))
        try cache.save(state)
        #expect(try cache.load(connectionID: connection)?.invoiceDocument == nil)
        #expect(try cache.load(connectionID: connection)?.paymentReview == nil)
        let data = try Data(contentsOf: folder.appendingPathComponent("cache.json"))
        #expect(try !#require(String(bytes: data, encoding: .utf8)).contains("synthetic.pdf"))
        #expect(try !#require(String(bytes: data, encoding: .utf8)).contains("123/4567"))
        let encoded = try JSONEncoder().encode(LiveSessionState())
        let decoded = try JSONDecoder().decode(LiveSessionState.self, from: encoded)
        #expect(decoded.invoices == nil)
    }

    @Test func `payment review refreshes exact selection and publishes generated QR atomically`() async throws {
        let transport = InvoiceTestTransport(pages: [InvoiceTests.page([
            InvoiceTests.item(extra: ",\"reference_number\":\"+++123/4567/89002+++\""),
        ])])
        let session = Self.session(transport, renderer: TestPaymentRenderer())
        _ = try await session.bootstrap(credentials: LiveSessionTests.credentials)
        let balance = try await session.refresh()
        let reviewed = try await session.reviewInvoicePayment(id: "inv-1")
        guard case let .ready(qrCode, candidates) = reviewed.paymentReview else {
            Issue.record("Expected ready payment review")
            return
        }
        #expect(qrCode.details.invoiceID == "inv-1")
        #expect(qrCode.details.amountText == "12.25")
        #expect(qrCode.validatePayload())
        #expect(candidates.map(\.id) == ["inv-1"])
        #expect(reviewed.snapshot == balance.snapshot)
        #expect(await transport.requests.contains { $0.url?.path.hasSuffix("/pdf") == true } == false)
        let selectedBundle = try await session.selectBundle(index: 0)
        #expect(selectedBundle.paymentReview == nil)
    }

    @Test func `payment refresh failure preserves bills and balance while clearing QR`() async throws {
        let transport = InvoiceTestTransport(pages: [InvoiceTests.page([
            InvoiceTests.item(extra: ",\"reference_number\":\"+++123/4567/89002+++\""),
        ])])
        let session = Self.session(transport, renderer: TestPaymentRenderer())
        _ = try await session.bootstrap(credentials: LiveSessionTests.credentials)
        let balance = try await session.refresh()
        let loaded = try await session.refreshInvoices()
        let failed = try await session.reviewInvoicePayment(id: "inv-1")
        #expect(failed.snapshot == balance.snapshot)
        #expect(failed.invoices == loaded.invoices)
        #expect(failed.paymentReview == .unavailable(.refreshFailed, candidates: []))
    }

    static func session(
        _ transport: any ProofHTTPTransport,
        renderer: any PaymentQRRendering = UnavailablePaymentQRRenderer(),
    ) -> VikingSession {
        VikingSession(
            transport: transport,
            store: MemorySessionStore(),
            lease: MemoryLease(),
            cache: MemoryBalanceCache(),
            paymentQRRenderer: renderer,
            now: { LiveModelsTests.now },
        )
    }

    fileprivate static func qr(_ details: InvoicePaymentDetails) -> InvoicePaymentQRCode {
        InvoicePaymentQRCode(
            details: details,
            payload: "BCD\n002\n1\nSCT\nKREDBEBB\nMobile Vikings NV\nBE02737026917240\n"
                + "EUR\(details.amountText)\n\n\(details.epcReference)\n\n",
            png: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            generatedAt: LiveModelsTests.now,
            expiresAt: LiveModelsTests.now.addingTimeInterval(300),
        )
    }
}

private struct TestPaymentRenderer: PaymentQRRendering {
    func render(_ details: InvoicePaymentDetails, now _: Date) async throws -> InvoicePaymentQRCode {
        InvoiceSessionTests.qr(details)
    }
}
