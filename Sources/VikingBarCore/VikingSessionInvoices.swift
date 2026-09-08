import Foundation

public extension VikingSession {
    func refreshInvoices() async throws -> LiveSessionState {
        try await self.runOptional(kind: .invoices) { generation in
            try await self.fetchInvoices(generation: generation)
        }
    }
}

extension VikingSession {
    private func fetchInvoices(generation: UInt64) async throws -> LiveSessionState {
        let connectionID = self.current.connectionID
        do {
            guard let token = self.token, self.api.now() < token.expiresAt else { throw LiveFailure.tokenExpired }
            let snapshot = try await self.api.invoices(token: token)
            try self.withConnectionLease(expected: connectionID) { _ in
                try self.checkGeneration(generation)
                self.current.invoices = snapshot
                self.current.invoiceFailure = nil
                try? self.cache.save(self.current)
            }
        } catch {
            try self.checkGeneration(generation)
            try self.withConnectionLease(expected: connectionID) { _ in
                self.current.invoices = .unavailable
                self.current.invoiceFailure = error as? LiveFailure ?? .malformedResponse
            }
        }
        return self.current
    }

    public func downloadInvoice(id: String) async throws -> LiveSessionState {
        try await self.runOptional(kind: .invoicePDF(id)) { generation in
            try await self.fetchInvoicePDF(id: id, generation: generation)
        }
    }

    private func fetchInvoicePDF(id: String, generation: UInt64) async throws -> LiveSessionState {
        self.current.invoiceDocument = nil
        guard self.current.invoices?.invoices.contains(where: { $0.id == id }) == true
        else { throw LiveFailure.invalidSelection }
        let connectionID = self.current.connectionID
        guard let token = self.token, self.api.now() < token.expiresAt else { throw LiveFailure.tokenExpired }
        let data = try await self.api.invoicePDF(id: id, token: token)
        return try self.withConnectionLease(expected: connectionID) { _ in
            try self.checkGeneration(generation)
            self.current.invoiceDocument = try InvoiceDocument.write(data, invoiceID: id)
            return self.current
        }
    }

    public func clearInvoiceDocument() {
        self.current.invoiceDocument = nil
    }
}
