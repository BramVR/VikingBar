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
        let selected = try await rig.session.selectSubscription(id: "sim-b")
        await rig.transport.resume()
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
        let cache = FileBalanceCache(url: folder.appendingPathComponent("cache.json"))
        try cache.save(state)
        #expect(try cache.load(connectionID: connection)?.invoiceDocument == nil)
        let data = try Data(contentsOf: folder.appendingPathComponent("cache.json"))
        #expect(try !#require(String(bytes: data, encoding: .utf8)).contains("synthetic.pdf"))
        let encoded = try JSONEncoder().encode(LiveSessionState())
        let decoded = try JSONDecoder().decode(LiveSessionState.self, from: encoded)
        #expect(decoded.invoices == nil)
    }

    static func session(_ transport: any ProofHTTPTransport) -> VikingSession {
        VikingSession(
            transport: transport,
            store: MemorySessionStore(),
            lease: MemoryLease(),
            cache: MemoryBalanceCache(),
            now: { LiveModelsTests.now },
        )
    }
}
