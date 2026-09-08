import Foundation
import Testing
@testable import VikingBarCore

struct InvoiceProofTests {
    @Test func `invoice proof checks production presentation and authenticated saved PDF`() async throws {
        let (oracle, state) = try await Self.loaded()
        defer { Self.cleanup(state) }
        let receipt = try await oracle.receipt(state: state, presentation: Self.presentation(state))
        #expect(receipt.passed)
        #expect(receipt.invoiceCount == 1)
        #expect(receipt.pdfDownloaded)
        let json = try #require(String(bytes: JSONEncoder().encode(receipt), encoding: .utf8))
        #expect(!json.contains("inv-1"))
        #expect(!json.contains("access-"))
        #expect(!json.contains("invoice.pdf"))
    }

    @Test func `proof rejects corrupt monetary date status scope and points presentation`() async throws {
        let (oracle, state) = try await Self.loaded()
        defer { Self.cleanup(state) }
        let presentation = Self.presentation(state)
        let fields = ["total", "amountDue", "date", "status", "scope", "points", "reduction", "title", "linkedInvoice"]
        for field in fields {
            var object = try #require(JSONSerialization
                .jsonObject(with: JSONEncoder().encode(presentation)) as? [String: Any])
            var rows = try #require(object["rows"] as? [[String: Any]])
            rows[0][field] = "corrupted"
            object["rows"] = rows
            let changed = try JSONDecoder().decode(
                InvoicePresentation.self,
                from: JSONSerialization.data(withJSONObject: object),
            )
            await #expect(throws: LiveFailure.malformedResponse) { try await oracle.receipt(
                state: state,
                presentation: changed,
            ) }
        }
        let invoice = try #require(state.invoices?.invoices.first)
        for field in ["amount", "amountDue", "reduction", "loyaltyPointsAmount"] {
            var object = try #require(JSONSerialization
                .jsonObject(with: JSONEncoder().encode(invoice)) as? [String: Any])
            object[field] = 999
            let changed = try JSONDecoder().decode(Invoice.self, from: JSONSerialization.data(withJSONObject: object))
            var badState = state
            badState.invoices = .loaded([changed], updatedAt: LiveModelsTests.now)
            await #expect(throws: LiveFailure.malformedResponse) {
                try await oracle.receipt(state: badState, presentation: Self.presentation(badState))
            }
        }
    }

    @Test func `empty proof needs completed raw endpoint and matching empty presentation`() async throws {
        let oracle = InvoiceOracleTransport(base: InvoiceTestTransport(pages: [InvoiceTests.page([])]))
        var state = LiveSessionState()
        state.invoices = try await LiveAPI(transport: oracle, now: { LiveModelsTests.now })
            .invoices(token: InvoiceTests.token)
        let receipt = try await oracle.receipt(state: state, presentation: Self.presentation(state))
        #expect(receipt.empty)
        #expect(!receipt.pdfDownloaded)
        await #expect(throws: LiveFailure.malformedResponse) {
            try await oracle.receipt(
                state: state,
                presentation: InvoicePresentation(snapshot: .unavailable, selectedSubscriptionID: nil),
            )
        }
        state.invoices = .loaded([], updatedAt: LiveModelsTests.now)
        await #expect(throws: LiveFailure.malformedResponse) {
            try await oracle.receipt(state: state, presentation: Self.presentation(state))
        }
    }

    @Test func `proof rejects duplicated mapping and unrelated saved PDF bytes`() async throws {
        let (oracle, original) = try await Self.loaded(items: [
            InvoiceTests.item(),
            InvoiceTests.item(id: "inv-2", number: "2026-9"),
        ])
        defer { Self.cleanup(original) }
        var changed = original
        let invoice = try #require(original.invoices?.invoices.first)
        changed.invoices = .loaded([invoice, invoice], updatedAt: LiveModelsTests.now)
        await #expect(throws: LiveFailure.malformedResponse) {
            try await oracle.receipt(state: changed, presentation: Self.presentation(changed))
        }
        let document = try #require(original.invoiceDocument)
        try Data("%PDF-another document\n%%EOF".utf8).write(to: document.fileURL)
        await #expect(throws: LiveFailure.malformedResponse) {
            try await oracle.receipt(state: original, presentation: Self.presentation(original))
        }
    }

    @Test func `invoice date uses selected timezone across UTC midnight`() throws {
        let invoice = try InvoiceTests.invoice(InvoiceTests.item(date: "2026-09-01T00:00:00+02:00"))
        let snapshot = InvoiceSnapshot.loaded([invoice], updatedAt: LiveModelsTests.now)
        #expect(try InvoicePresentation(
            snapshot: snapshot,
            selectedSubscriptionID: nil,
            timeZone: #require(TimeZone(identifier: "Europe/Brussels")),
        ).rows.first?.date == "1 Sep 2026")
        #expect(try InvoicePresentation(
            snapshot: snapshot,
            selectedSubscriptionID: nil,
            timeZone: #require(TimeZone(secondsFromGMT: 0)),
        ).rows.first?.date == "31 Aug 2026")
    }

    private static func loaded(
        items: [String] = [InvoiceTests.item()],
    ) async throws -> (InvoiceOracleTransport, LiveSessionState) {
        let oracle = InvoiceOracleTransport(base: InvoiceTestTransport(pages: [InvoiceTests.page(items)]))
        let session = InvoiceSessionTests.session(oracle)
        _ = try await session.bootstrap(credentials: LiveSessionTests.credentials)
        _ = try await session.refresh()
        let state = try await session.refreshInvoices()
        let id = try #require(state.invoices?.invoices.first?.id)
        return try await (oracle, session.downloadInvoice(id: id))
    }

    private static func presentation(_ state: LiveSessionState) -> InvoicePresentation {
        InvoicePresentation(snapshot: state.invoices, selectedSubscriptionID: state.selectedSubscriptionID)
    }

    private static func cleanup(_ state: LiveSessionState) {
        if let document = state.invoiceDocument {
            try? FileManager.default.removeItem(at: document.fileURL.deletingLastPathComponent())
        }
    }
}
