import Foundation
import Testing
@testable import VikingBarCore

struct InvoiceTests {
    static func item(
        id: String = "inv-1", number: String = "2026-10", date: String = "2026-09-01T10:00:00+02:00",
        amount: String = "24.50", due: String = "12.25", type: String = "invoice",
        status: String = "partially_paid", grouped: Bool = false, extra: String = "",
    ) -> String {
        """
        {"id":"\(id)","number":"\(number)","date":"\(date)","amount":\(amount),"amount_due":\(due),
        "type":"\(type)","status":"\(status)","grouped":\(grouped),"subscription_id":"sim-a",
        "bundles":[],"out_of_bundle_costs":[]\(extra)}
        """
    }

    static func page(_ items: [String], page: Int = 1, total: Int? = nil) -> String {
        let total = total ?? items.count
        return """
        {"page":\(page),"per_page":20,"total_pages":\(max(1, (total + 19) / 20)),
        "total_items":\(total),"results":[\(items.joined(separator: ","))],
        "links":{"next":"https://evil.invalid/?token=never-follow"}}
        """
    }

    static func invoice(_ json: String = item()) throws -> Invoice {
        try JSONDecoder().decode(InvoiceDTO.self, from: Data(json.utf8)).invoice()
    }

    static var pdf: Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>",
        ]
        var text = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(text.utf8.count)
            text += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = text.utf8.count
        text += "xref\n0 4\n0000000000 65535 f \n"
        for offset in offsets {
            text += String(format: "%010d 00000 n \n", offset)
        }
        text += "trailer\n<< /Root 1 0 R /Size 4 >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(text.utf8)
    }

    static let token = LiveToken(
        accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
        expiresAt: .distantFuture, scopeMismatch: false,
    )

    @Test func `invoice preserves partial payment credit zero and missing adjustments`() throws {
        let partial = try Self.invoice()
        #expect(partial.amount == Decimal(string: "24.50"))
        #expect(partial.amountDue == Decimal(string: "12.25"))
        #expect(partial.status == .partiallyPaid)
        let credit = try Self.invoice(Self.item(amount: "-3.50", due: "0", type: "credit_note", status: "paid"))
        #expect(credit.kind == .creditNote)
        #expect(credit.amount == Decimal(string: "-3.50"))
        #expect(credit.amountDue == 0)
        let row = try #require(InvoicePresentation(
            snapshot: .loaded([credit], updatedAt: LiveModelsTests.now), selectedSubscriptionID: "sim-a",
        ).rows.first)
        #expect(row.title == "Credit note 2026-10")
        #expect(row.reduction == "Unavailable")
        #expect(row.points == "Unavailable")
        #expect(row.amountDue == "€0.00")
        let zero = try Self.invoice(Self.item(
            amount: "0",
            due: "0",
            extra: ",\"reduction\":0,\"loyalty_points_amount\":0",
        ))
        #expect(zero.reduction == 0)
        #expect(zero.loyaltyPointsAmount == 0)
    }

    @Test func `grouped scope never presents whole bill as selected SIM balance`() throws {
        var raw = Self.item(grouped: true)
        raw = raw.replacingOccurrences(of: "\"bundles\":[]", with: "\"bundles\":[{\"subscription_id\":\"sim-b\"},{}]")
        let grouped = try Self.invoice(raw)
        #expect(grouped.membership(of: "sim-b") == .included)
        #expect(grouped.membership(of: "sim-a") == .unknown)
        let view = InvoicePresentation(
            snapshot: .loaded([grouped], updatedAt: LiveModelsTests.now),
            selectedSubscriptionID: "sim-a",
        )
        #expect(view.rows.first?.scope == "Grouped invoice. Selected SIM membership unknown.")
        let single = try Self.invoice()
        #expect(single.membership(of: "sim-b") == .excluded)
    }

    @Test func `malformed invoice rejects unknown status date unsafe ID and missing amount`() throws {
        let samples = [Self.item(status: "invented"), Self.item(date: "2026-99-99"), Self.item(id: "../escape"),
                       Self.item().replacingOccurrences(of: "\"amount\":24.50,", with: "")]
        for sample in samples {
            #expect(throws: (any Error).self) { try Self.invoice(sample) }
        }
    }

    @Test func `invoice endpoint denies foreign urls filters traversal and unbounded pagination`() throws {
        let urls = ["https://evil.invalid/mv/invoices?page=1&per_page=20",
                    "https://uwa.mobilevikings.be/mv/invoices?page=6&per_page=20",
                    "https://uwa.mobilevikings.be/mv/invoices?page=1&per_page=1000",
                    "https://uwa.mobilevikings.be/mv/invoices?page=1&per_page=20&subscription_id=x",
                    "https://uwa.mobilevikings.be/mv/invoices/x/pdf?token=secret",
                    "https://uwa.mobilevikings.be/mv/invoices/%2e%2e/pdf"]
        for text in urls {
            #expect(throws: ProofFailure.requestDenied) {
                try ProofEndpoint.validate(URLRequest(url: #require(URL(string: text))))
            }
        }
        try ProofEndpoint.validate(ProofEndpoint.invoices(page: 1).request())
        try ProofEndpoint.validate(ProofEndpoint.invoicePDF(id: "safe-1").request())
        #expect(throws: ProofFailure.requestDenied) { try ProofEndpoint.invoicePDF(id: "a/b").request() }
    }

    @Test func `bounded pages sort real dates and invoice numbers and never follow links`() async throws {
        let items = (1 ... 20).map { Self.item(id: "inv-\($0)", number: "2026-\($0)") }
        let last = Self.item(id: "last", date: "2026-09-01T09:30:00Z")
        let transport = InvoiceTestTransport(pages: [
            Self.page(items, total: 21),
            Self.page([last], page: 2, total: 21),
        ])
        let result = try await LiveAPI(transport: transport, now: { LiveModelsTests.now }).invoices(token: Self.token)
        #expect(result.invoices.first?.id == "last")
        #expect(result.invoices[1].number == "2026-20")
        #expect(await transport.requests.count == 2)
        #expect(await transport.requests.allSatisfy { $0.url?.host == "uwa.mobilevikings.be" })
    }

    @Test func `page bound produces truncated while actual empty stays distinct`() async throws {
        let pages = (1 ... 5).map { page in
            Self.page((1 ... 20).map { Self.item(id: "p\(page)-\($0)") }, page: page, total: 120)
        }
        let result = try await LiveAPI(transport: InvoiceTestTransport(pages: pages), now: { LiveModelsTests.now })
            .invoices(token: Self.token)
        if case let .truncated(values, _) = result {
            #expect(values.count == 100)
        } else {
            Issue.record("Expected truncation")
        }
        let empty = try await LiveAPI(
            transport: InvoiceTestTransport(pages: [Self.page([])]),
            now: { LiveModelsTests.now },
        )
        .invoices(token: Self.token)
        #expect(empty == .empty(updatedAt: LiveModelsTests.now))
        #expect(InvoicePresentation(snapshot: empty, selectedSubscriptionID: nil)
            .message == "No invoices on this account.")
        #expect(InvoicePresentation(snapshot: .unavailable, selectedSubscriptionID: nil).message
            .contains("unavailable"))
    }

    @Test func `pagination detects duplicate ids changed total wrong page and huge total`() async throws {
        let invalid = [Self.page([Self.item(), Self.item()]), Self.page([Self.item()], page: 2),
                       Self.page([]).replacingOccurrences(
                           of: "\"total_items\":0",
                           with: "\"total_items\":9223372036854775807",
                       )]
        for page in invalid {
            await #expect(throws: LiveFailure.malformedResponse) {
                try await LiveAPI(transport: InvoiceTestTransport(pages: [page]), now: { LiveModelsTests.now })
                    .invoices(token: Self.token)
            }
        }
        let first = Self.page((1 ... 20).map { Self.item(id: "inv-\($0)") }, total: 21)
        let second = Self.page([Self.item(id: "other")], page: 2, total: 22)
        await #expect(throws: LiveFailure.malformedResponse) {
            try await LiveAPI(transport: InvoiceTestTransport(pages: [first, second]), now: { LiveModelsTests.now })
                .invoices(token: Self.token)
        }
    }

    @Test func `PDF download negotiates vendor response while metadata stays JSON authenticated`() async throws {
        let transport = InvoiceTestTransport(pages: [Self.page([Self.item()])])
        let api = LiveAPI(transport: InvoiceNegotiationTransport(base: transport), now: { LiveModelsTests.now })
        let invoices = try await api.invoices(token: Self.token)
        let invoice = try #require(invoices.invoices.first)
        let pdf = try await api.invoicePDF(id: invoice.id, token: Self.token)
        #expect(pdf == Self.pdf)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.first?.url?.absoluteString
            == "https://uwa.mobilevikings.be/mv/invoices?page=1&per_page=20")
        #expect(requests.first?.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(requests.last?.url?.absoluteString == "https://uwa.mobilevikings.be/mv/invoices/inv-1/pdf")
        #expect(requests.last?.value(forHTTPHeaderField: "Accept") == "*/*")
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access" })
    }

    @Test func `PDF rejects redirect html missing type truncated oversized and failed responses`() async throws {
        let pdf = Data("%PDF-1.7\nsynthetic\n%%EOF\n".utf8)
        let responses = [ProofHTTPResponse(statusCode: 302, data: pdf, contentType: "application/pdf"),
                         ProofHTTPResponse(
                             statusCode: 200,
                             data: Data("<html>login</html>".utf8),
                             contentType: "text/html",
                         ),
                         ProofHTTPResponse(statusCode: 200, data: pdf),
                         ProofHTTPResponse(
                             statusCode: 200,
                             data: Data("%PDF-1.7".utf8),
                             contentType: "application/pdf",
                         ),
                         ProofHTTPResponse(statusCode: 503, data: pdf, contentType: "application/pdf"),
                         ProofHTTPResponse(
                             statusCode: 200,
                             data: Data(repeating: 0, count: 10_485_761),
                             contentType: "application/pdf",
                         )]
        for response in responses {
            await #expect(throws: (any Error).self) {
                try await LiveAPI(transport: InvoiceTestTransport(pdf: response), now: { LiveModelsTests.now })
                    .invoicePDF(id: "inv-1", token: Self.token)
            }
        }
    }
}

private struct InvoiceNegotiationTransport: ProofHTTPTransport {
    let base: InvoiceTestTransport

    func send(_ request: URLRequest) async throws -> ProofHTTPResponse {
        let acceptsPDF = request.value(forHTTPHeaderField: "Accept") == "*/*"
        if request.url?.path.hasSuffix("/pdf") == true, !acceptsPDF {
            return ProofHTTPResponse(statusCode: 406, data: Data())
        }
        return try await self.base.send(request)
    }
}

actor InvoiceTestTransport: ProofHTTPTransport {
    var requests: [URLRequest] = []
    var pages: [String]
    let pdf: ProofHTTPResponse
    let balance = LiveTransport()

    init(pages: [String] = [], pdf: ProofHTTPResponse = ProofHTTPResponse(
        statusCode: 200, data: InvoiceTests.pdf, contentType: "application/pdf",
    )) {
        self.pages = pages
        self.pdf = pdf
    }

    func send(_ request: URLRequest) async throws -> ProofHTTPResponse {
        try ProofEndpoint.validate(request)
        self.requests.append(request)
        if request.url?.path == "/mv/invoices" {
            guard !self.pages.isEmpty else { throw LiveFailure.transport }
            return ProofHTTPResponse(statusCode: 200, data: Data(self.pages.removeFirst().utf8))
        }
        if request.url?.path.hasSuffix("/pdf") == true {
            return self.pdf
        }
        return try await self.balance.send(request)
    }
}
