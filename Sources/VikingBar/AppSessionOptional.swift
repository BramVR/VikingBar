import Foundation
import VikingBarCore

extension AppSession {
    enum OptionalIntent: Equatable {
        case points, invoices
        case pdf(String)

        var request: SessionRequest {
            switch self {
            case .points: .refreshPoints
            case .invoices: .refreshInvoices
            case let .pdf(id): .downloadInvoice(id)
            }
        }

        var isInvoice: Bool {
            self != .points
        }

        var isPDF: Bool {
            if case .pdf = self {
                true
            } else {
                false
            }
        }
    }

    var isLoadingInvoices: Bool {
        self.activeOptional?.isInvoice == true || self.pendingOptional.contains(where: \.isInvoice)
    }
}

extension AppSession {
    var invoiceDetails: InvoicePresentation {
        InvoicePresentation(
            snapshot: self.liveState.invoices,
            selectedSubscriptionID: self.liveState.selectedSubscriptionID,
            timeZone: self.timeZone,
        )
    }

    func loadInvoices() {
        guard !self.isFixtureLaunch, self.isConnected, self.client != nil,
              self.activity != .stopped, self.activity != .connecting, !self.isLoadingInvoices else { return }
        self.invoiceError = nil
        self.enqueueOptional(.invoices)
        self.pumpOptional()
    }

    func openInvoice(_ id: String) {
        guard self.canSelectAccountData, !self.isLoadingInvoices,
              self.liveState.invoices?.invoices.contains(where: { $0.id == id }) == true else { return }
        self.invoiceError = nil
        self.enqueueOptional(.pdf(id))
        self.pumpOptional()
    }

    func enqueueOptional(_ intent: OptionalIntent) {
        guard self.activeOptional != intent, !self.pendingOptional.contains(intent) else { return }
        self.pendingOptional.append(intent)
    }

    func interruptOptional(clear: Bool) {
        if let active = self.activeOptional {
            switch active {
            case .points, .invoices:
                if !self.pendingOptional.contains(active) {
                    self.pendingOptional.insert(active, at: 0)
                }
            case .pdf:
                self.invoiceError = "Invoice PDF interrupted. Try again."
            }
        }
        if self.pendingOptional.contains(where: \.isPDF) {
            self.invoiceError = "Invoice PDF interrupted. Try again."
            self.pendingOptional.removeAll(where: \.isPDF)
        }
        if clear {
            self.pendingOptional.removeAll()
            self.invoiceError = nil
        }
        self.optionalRevision += 1
        if self.optionalOperation != nil, let client = self.client {
            let previous = self.optionalCancellation
            self.optionalCancellation = Task {
                await previous?.value
                _ = try? await client.request(.cancel)
            }
        }
        self.optionalOperation?.cancel()
        self.optionalOperation = nil
        self.activeOptional = nil
    }

    func pumpOptional() {
        guard self.activity == .idle, self.isConnected, self.optionalOperation == nil,
              !self.pendingOptional.isEmpty, let client = self.client else { return }
        let optional = self.pendingOptional.removeFirst()
        self.activeOptional = optional
        let revision = self.optionalRevision
        let connection = self.liveState.connectionID
        self.optionalOperation = Task {
            defer {
                if revision == self.optionalRevision {
                    self.optionalOperation = nil
                    self.activeOptional = nil
                    self.pumpOptional()
                }
            }
            do {
                let state = try await client.request(optional.request)
                guard !Task.isCancelled, revision == self.optionalRevision,
                      connection == state.connectionID, connection == self.liveState.connectionID,
                      self.activity == .idle else { return }
                self.publishOptional(state, intent: optional)
                self.onPresentationChange?()
            } catch {
                guard revision == self.optionalRevision, !Task.isCancelled else { return }
                if optional == .points {
                    self.liveState.markPointsUnavailable(.transport)
                } else {
                    self.invoiceError = "Could not load bills. Try again."
                }
                self.onPresentationChange?()
                self.client = nil
                await client.shutdown()
            }
        }
    }

    private func publishOptional(_ state: LiveSessionState, intent: OptionalIntent) {
        switch intent {
        case .points:
            self.liveState.mergePoints(from: state)
        case .invoices:
            self.liveState.mergeInvoices(from: state)
            if state.invoiceFailure == .tokenExpired {
                self.invoiceError = "Refresh data before loading bills again."
            }
        case let .pdf(id):
            guard let document = state.invoiceDocument, document.invoiceID == id,
                  document.fileURL.isFileURL, self.openDocument(document.fileURL)
            else { self.invoiceError = "Could not open invoice PDF. Try again."; return }
        }
    }
}
