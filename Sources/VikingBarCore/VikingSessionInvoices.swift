import Foundation

public extension VikingSession {
    func refreshInvoices() async throws -> LiveSessionState {
        guard !self.hasBalanceOperation, self.optionalOperation == nil else { throw LiveFailure.busy }
        let generation = self.generation
        let connectionID = self.current.connectionID
        do {
            guard let token = self.token, self.api.now() < token.expiresAt else { throw LiveFailure.tokenExpired }
            let id = UUID()
            let task = Task { try await self.api.invoices(token: token) }
            self.optionalOperation = (id, { task.cancel() })
            defer {
                if self.optionalOperation?.id == id {
                    self.optionalOperation = nil
                }
            }
            let snapshot = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
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

    func downloadInvoice(id: String) async throws -> LiveSessionState {
        self.current.invoiceDocument = nil
        guard !self.hasBalanceOperation, self.optionalOperation == nil,
              self.current.invoices?.invoices.contains(where: { $0.id == id }) == true
        else { throw LiveFailure.invalidSelection }
        let generation = self.generation
        let connectionID = self.current.connectionID
        guard let token = self.token, self.api.now() < token.expiresAt else { throw LiveFailure.tokenExpired }
        let operationID = UUID()
        let task = Task { try await self.api.invoicePDF(id: id, token: token) }
        self.optionalOperation = (operationID, { task.cancel() })
        defer {
            if self.optionalOperation?.id == operationID {
                self.optionalOperation = nil
            }
        }
        let data = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        return try self.withConnectionLease(expected: connectionID) { _ in
            try self.checkGeneration(generation)
            self.current.invoiceDocument = try InvoiceDocument.write(data, invoiceID: id)
            return self.current
        }
    }

    func clearInvoiceDocument() {
        self.current.invoiceDocument = nil
    }
}
