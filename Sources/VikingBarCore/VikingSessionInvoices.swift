import Foundation

public extension VikingSession {
    func refreshInvoices() async throws -> LiveSessionState {
        try await self.runOptional(kind: .invoices) { generation in
            try await self.fetchInvoices(generation: generation)
        }
    }

    func reviewInvoicePayment(id: String?) async throws -> LiveSessionState {
        try await self.runOptional(kind: .paymentReview(id)) { generation in
            try await self.fetchPaymentReview(id: id, generation: generation)
        }
    }

    func clearPaymentReview() {
        if case .paymentReview? = self.flight?.kind {
            self.cancel()
        }
        self.current.paymentReview = nil
    }
}

extension VikingSession {
    private func fetchPaymentReview(id: String?, generation: UInt64) async throws -> LiveSessionState {
        self.current.paymentReview = .checking(invoiceID: id)
        let connectionID = self.current.connectionID
        let snapshot: InvoiceSnapshot
        do {
            guard let token = self.token, self.api.now() < token.expiresAt else { throw LiveFailure.tokenExpired }
            snapshot = try await self.api.invoices(token: token)
            try self.checkGeneration(generation)
            try self.withConnectionLease(expected: connectionID) { _ in
                self.current.invoices = snapshot
                self.current.invoiceFailure = nil
                try? self.cache.save(self.current)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try self.checkGeneration(generation)
            try self.withConnectionLease(expected: connectionID) { _ in
                self.current.invoiceFailure = error as? LiveFailure ?? .malformedResponse
                self.current.paymentReview = .unavailable(.refreshFailed, candidates: [])
            }
            return self.current
        }
        let selection = InvoicePaymentSelection.select(
            snapshot: snapshot,
            requestedInvoiceID: id,
            selectedSubscriptionID: self.current.selectedSubscriptionID,
            now: self.api.now(),
        )
        let details: InvoicePaymentDetails
        let candidates: [InvoicePaymentCandidate]
        switch selection {
        case let .selected(value, values):
            details = value
            candidates = values
        case let .unavailable(reason, values):
            self.current.paymentReview = .unavailable(reason, candidates: values)
            return self.current
        }
        return try await self.renderPayment(
            details, candidates: candidates, requestedID: id,
            generation: generation, connectionID: connectionID,
        )
    }

    private func renderPayment(
        _ details: InvoicePaymentDetails, candidates: [InvoicePaymentCandidate], requestedID: String?,
        generation: UInt64, connectionID: ConnectionID?,
    ) async throws -> LiveSessionState {
        let qrCode: InvoicePaymentQRCode
        do {
            qrCode = try await self.paymentQRRenderer.render(details, now: self.api.now())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try self.checkGeneration(generation)
            self.current.paymentReview = .unavailable(.qrGenerationFailed, candidates: candidates)
            return self.current
        }
        return try self.withConnectionLease(expected: connectionID) { _ in
            try self.checkGeneration(generation)
            guard qrCode.details.invoiceID == requestedID || requestedID == nil else {
                throw LiveFailure.invalidSelection
            }
            self.current.paymentReview = .ready(qrCode, candidates: candidates)
            return self.current
        }
    }

    private func fetchInvoices(generation: UInt64) async throws -> LiveSessionState {
        self.current.paymentReview = nil
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
