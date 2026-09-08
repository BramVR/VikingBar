import Foundation

public struct InvoiceProofReceipt: Codable, Sendable {
    public let schemaVersion = 1
    public let check = "invoices"
    public let passed = true
    public let invoiceCount: Int
    public let empty: Bool
    public let truncated: Bool
    public let metadataMatches = true
    public let presentationMatches = true
    public let pdfDownloaded: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case check, passed, empty, truncated
        case invoiceCount = "invoice_count"
        case metadataMatches = "metadata_matches"
        case presentationMatches = "presentation_matches"
        case pdfDownloaded = "pdf_downloaded"
    }
}

public actor InvoiceOracleTransport: ProofHTTPTransport {
    private let base: any ProofHTTPTransport
    private var pages: [Data] = []
    private struct PDFResponse {
        let id: String
        let authenticated: Bool
        let data: Data
    }

    private var pdfResponses: [PDFResponse] = []

    public init(base: any ProofHTTPTransport) {
        self.base = base
    }

    public func send(_ request: URLRequest) async throws -> ProofHTTPResponse {
        let response = try await self.base.send(request)
        if request.url?.path == "/mv/invoices", response.statusCode == 200 {
            self.pages.append(response.data)
        }
        if let url = request.url, url.path.hasSuffix("/pdf"), response.statusCode == 200 {
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            self.pdfResponses.append(PDFResponse(
                id: url.deletingLastPathComponent().lastPathComponent,
                authenticated: bearer.hasPrefix("Bearer ") && bearer.count > 7 && url.query == nil,
                data: response.data,
            ))
        }
        return response
    }

    public func receipt(
        state: LiveSessionState, presentation: InvoicePresentation, timeZone: TimeZone = .current,
    ) throws -> InvoiceProofReceipt {
        let (truncated, expectedMessage) = try Self.snapshotState(state.invoices)
        guard !self.pages.isEmpty, presentation.message == expectedMessage else { throw LiveFailure.malformedResponse }
        let raw = try self.rawInvoices(truncated: truncated)
        let invoices = state.invoices?.invoices ?? []
        guard invoices.count == raw.count, presentation.rows.count == invoices.count,
              self.pdfResponses.count == (invoices.isEmpty ? 0 : 1),
              Set(invoices.map(\.id)).count == invoices.count,
              Set(raw.compactMap { $0["id"] as? String }).count == raw.count,
              Set(invoices.map(\.id)) == Set(raw.compactMap { $0["id"] as? String })
        else { throw LiveFailure.malformedResponse }
        for (index, invoice) in invoices.enumerated() {
            guard let value = raw.first(where: { $0["id"] as? String == invoice.id }) else {
                throw LiveFailure.malformedResponse
            }
            try Self.compare(
                value,
                invoice: invoice,
                row: presentation.rows[index],
                selected: state.selectedSubscriptionID,
                timeZone: timeZone,
            )
            if index > 0 {
                let previous = invoices[index - 1]
                let previousDate = try Self.date(previous.date)
                let date = try Self.date(invoice.date)
                guard previousDate >= date,
                      previousDate != date || previous.number
                      .compare(invoice.number, options: .numeric) != .orderedAscending
                else { throw LiveFailure.malformedResponse }
            }
        }
        try self.verifyPDF(state: state)
        return InvoiceProofReceipt(
            invoiceCount: invoices.count, empty: invoices.isEmpty, truncated: truncated,
            pdfDownloaded: !invoices.isEmpty,
        )
    }

    private static func snapshotState(_ snapshot: InvoiceSnapshot?) throws -> (Bool, String) {
        let truncated: Bool
        let expectedMessage: String
        switch snapshot {
        case .empty?:
            truncated = false
            expectedMessage = "No invoices on this account."
        case let .loaded(values, _)?:
            guard !values.isEmpty else { throw LiveFailure.malformedResponse }
            truncated = false
            expectedMessage = "Account invoices"
        case let .truncated(values, _)?:
            guard !values.isEmpty else { throw LiveFailure.malformedResponse }
            truncated = true
            expectedMessage = "Recent account invoices. More invoices are available in My Viking."
        case .unavailable?, nil: throw LiveFailure.malformedResponse
        }
        return (truncated, expectedMessage)
    }

    private func rawInvoices(truncated: Bool) throws -> [[String: Any]] {
        var raw: [[String: Any]] = []
        for (index, data) in self.pages.enumerated() {
            guard let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  page["page"] as? Int == index + 1, page["per_page"] as? Int == 20,
                  let values = page["results"] as? [[String: Any]], let total = page["total_items"] as? Int,
                  let totalPages = page["total_pages"] as? Int,
                  total >= values.count, totalPages >= 0
            else { throw LiveFailure.malformedResponse }
            let fetchedCount = raw.count + values.count
            if index + 1 == self.pages.count {
                guard truncated ? totalPages > self.pages.count : total == fetchedCount else {
                    throw LiveFailure.malformedResponse
                }
            }
            raw += values
        }
        return raw
    }

    private func verifyPDF(state: LiveSessionState) throws {
        let invoices = state.invoices?.invoices ?? []
        if let latest = invoices.first {
            guard let document = state.invoiceDocument, document.invoiceID == latest.id,
                  document.fileURL.isFileURL else { throw LiveFailure.malformedResponse }
            let data = try Data(contentsOf: document.fileURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: document.fileURL.path)
            let folder = try FileManager.default
                .attributesOfItem(atPath: document.fileURL.deletingLastPathComponent().path)
            guard let response = self.pdfResponses.first, response.id == latest.id, response.authenticated,
                  data == response.data, data.starts(with: Data("%PDF-".utf8)),
                  attributes[.posixPermissions] as? Int == 0o600, folder[.posixPermissions] as? Int == 0o700
            else {
                throw LiveFailure.malformedResponse
            }
        }
    }

    private static func compare(
        _ raw: [String: Any], invoice: Invoice, row: InvoicePresentation.Row, selected: String?, timeZone: TimeZone,
    ) throws {
        guard invoice.number == raw["number"] as? String, invoice.date == raw["date"] as? String,
              invoice.status.rawValue == raw["status"] as? String, invoice.kind.rawValue == raw["type"] as? String,
              invoice.amount == self.decimal(raw["amount"]), invoice.amountDue == self.decimal(raw["amount_due"]),
              invoice.reduction == self.decimal(raw["reduction"]),
              invoice.loyaltyPointsAmount == self.decimal(raw["loyalty_points_amount"]),
              invoice.linkedInvoiceID == raw["linked_invoice_id"] as? String,
              let grouped = raw["grouped"] as? Bool
        else { throw LiveFailure.malformedResponse }
        let scope: String
        if grouped {
            let lines = (raw["bundles"] as? [[String: Any]] ?? []) +
                (raw["out_of_bundle_costs"] as? [[String: Any]] ?? [])
            let ids = Set(lines.compactMap { $0["subscription_id"] as? String }.filter { !$0.isEmpty })
            guard case let .grouped(actual, complete) = invoice.scope, actual == ids, !complete else {
                throw LiveFailure.malformedResponse
            }
            scope = selected.map { ids.contains($0) } == true
                ? "Grouped invoice. Includes selected SIM." : "Grouped invoice. Selected SIM membership unknown."
        } else if let id = raw["subscription_id"] as? String, !id.isEmpty {
            guard invoice.scope == .subscription(id) else { throw LiveFailure.malformedResponse }
            scope = id == selected ? "Selected SIM" : "Other SIM"
        } else {
            guard invoice.scope == .customer else { throw LiveFailure.malformedResponse }
            scope = "Customer invoice. SIM membership unknown."
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_IE")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy"
        let title = "\(raw["type"] as? String == "credit_note" ? "Credit note" : "Invoice") \(invoice.number)"
        guard row.id == invoice.id, row.title == title,
              try row.date == (formatter.string(from: self.date(invoice.date))),
              row.status == (invoice.status == .badDebt ? "bad debt" : invoice.status.rawValue.replacingOccurrences(
                  of: "_",
                  with: " ",
              )), row.scope == scope,
              row.total == self.money(raw["amount"]), row.amountDue == self.money(raw["amount_due"]),
              row.reduction == self.money(raw["reduction"]), row.linkedInvoice == invoice.linkedInvoiceID,
              row.points == self.decimal(raw["loyalty_points_amount"]).map({ NSDecimalNumber(decimal: $0).stringValue })
              ?? "Unavailable"
        else { throw LiveFailure.malformedResponse }
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        guard let number = value as? NSNumber else { return nil }
        return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func money(_ value: Any?) -> String {
        guard let number = value as? NSNumber else { return "Unavailable" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_IE")
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        return formatter.string(from: number) ?? "Unavailable"
    }

    private static func date(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { throw LiveFailure.malformedResponse }
        return date
    }
}
