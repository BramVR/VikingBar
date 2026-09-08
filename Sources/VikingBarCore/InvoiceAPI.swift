import CoreGraphics
import Darwin
import Foundation

extension LiveAPI {
    func invoices(token: LiveToken) async throws -> InvoiceSnapshot {
        try await withThrowingTaskGroup(of: InvoiceSnapshot.self) { group in
            group.addTask { try await self.invoicePages(token: token) }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw LiveFailure.transport
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw LiveFailure.transport }
            return result
        }
    }

    private func invoicePages(token: LiveToken) async throws -> InvoiceSnapshot {
        var invoices: [Invoice] = []
        var total: Int?
        for pageNumber in 1 ... 5 {
            let data = try await self.get(.invoices(page: pageNumber), token: token)
            let page = try Self.invoicePage(data, requestedPage: pageNumber)
            guard total == nil || total == page.totalItems else { throw LiveFailure.malformedResponse }
            total = page.totalItems
            invoices += try page.results.map { try $0.invoice() }
            guard Set(invoices.map(\.id)).count == invoices.count else { throw LiveFailure.malformedResponse }
            invoices.sort {
                let left = InvoiceDTO.parsedDate($0.date)!
                let right = InvoiceDTO.parsedDate($1.date)!
                if left != right {
                    return left > right
                }
                return $0.number.compare($1.number, options: .numeric) == .orderedDescending
            }
            if pageNumber >= page.totalPages {
                guard invoices.count == page.totalItems else { throw LiveFailure.malformedResponse }
                return invoices.isEmpty ? .empty(updatedAt: self.now()) : .loaded(invoices, updatedAt: self.now())
            }
        }
        return .truncated(invoices, updatedAt: self.now())
    }

    static func invoicePage(_ data: Data, requestedPage: Int) throws -> InvoicePage {
        do {
            let page = try JSONDecoder().decode(InvoicePage.self, from: data)
            guard page.page == requestedPage, page.perPage == 20, page.totalItems >= 0, page.totalItems <= 1_000_000,
                  page.totalPages >= 0, page.results.count <= 20,
                  page.totalPages == max(1, (page.totalItems + 19) / 20)
                  || (page.totalItems == 0 && page.totalPages == 0),
                  page.totalItems == 0 || !page.results.isEmpty,
                  page.page >= page.totalPages || page.results.count == 20
            else { throw LiveFailure.malformedResponse }
            return page
        } catch { throw LiveFailure.malformedResponse }
    }

    func invoicePDF(id: String, token: LiveToken) async throws -> Data {
        guard self.now() < token.expiresAt else { throw LiveFailure.tokenExpired }
        var request = try ProofEndpoint.invoicePDF(id: id).request()
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        let response = try await self.transport.send(request)
        guard response.statusCode == 200 else { throw LiveFailure.transport }
        let contentType = response.contentType?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard contentType == "application/pdf", response.data.count <= 10_485_760,
              response.data.starts(with: Data("%PDF-".utf8)),
              response.data.suffix(1024).range(of: Data("%%EOF".utf8)) != nil,
              let provider = CGDataProvider(data: response.data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0
        else { throw LiveFailure.malformedResponse }
        try Task.checkCancellation()
        return response.data
    }
}

public struct InvoiceDocument: Codable, Equatable, Sendable {
    public let invoiceID: String
    public let fileURL: URL

    static func write(_ data: Data, invoiceID: String) throws -> Self {
        var template = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("vikingbar-invoice-XXXXXX").path.utf8CString)
        guard let directory = mkdtemp(&template) else { throw LiveFailure.storage }
        let folder = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        let url = folder.appendingPathComponent("invoice.pdf")
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            rmdir(folder.path)
            throw LiveFailure.storage
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            return Self(invoiceID: invoiceID, fileURL: url)
        } catch {
            try? handle.close()
            unlink(url.path)
            rmdir(folder.path)
            throw LiveFailure.storage
        }
    }
}
