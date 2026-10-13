import Foundation

extension VikingSession {
    func runOptional(
        kind: OperationKind,
        operation: @escaping @Sendable (UInt64) async throws -> LiveSessionState,
    ) async throws -> LiveSessionState {
        let generation = self.generation
        let connection = self.current.connectionID
        while let flight = self.flight {
            _ = try? await flight.task.value
            try self.checkGeneration(generation)
            guard self.current.connectionID == connection else { throw LiveFailure.connectionChanged }
        }
        try self.checkGeneration(generation)
        return try await self.run(kind: kind, operation: operation)
    }

    func run(
        kind: OperationKind,
        operation: @escaping @Sendable (UInt64) async throws -> LiveSessionState,
    ) async throws -> LiveSessionState {
        let previousState = self.current
        let previous = self.flight
        if previous != nil {
            self.cancel()
        }
        let id = UUID()
        let generation = self.generation
        if !kind.isOptional {
            self.current.isRefreshing = true
            self.current.paymentReview = nil
        }
        let task = Task {
            defer {
                if self.flight?.id == id {
                    self.flight = nil
                    if !kind.isOptional {
                        self.current.isRefreshing = false
                    }
                }
            }
            do {
                _ = try? await previous?.task.value
                try self.checkGeneration(generation)
                self.renewalAttempted = false
                _ = try await operation(generation)
                try self.checkGeneration(generation)
                if !kind.isOptional {
                    self.current.isRefreshing = false
                }
                return self.current
            } catch {
                if self.generation == generation, !kind.isOptional {
                    let requestFailure = error as? LiveRequestFailure
                    let failure = error is CancellationError ? self.current.failure
                        : ((error as? BootstrapFailure)?.liveFailure ?? requestFailure?.failure
                            ?? error as? LiveFailure ?? .transport)
                    self.recordOperationFailure(failure, kind: kind, previous: previousState,
                                                retryAfter: requestFailure?.retryAfter)
                }
                throw (error as? LiveRequestFailure)?.failure ?? error
            }
        }
        self.flight = InFlight(id: id, kind: kind, task: task)
        let state = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        return state
    }

    private func recordOperationFailure(
        _ failure: LiveFailure?, kind: OperationKind, previous: LiveSessionState, retryAfter: Date?,
    ) {
        let unchanged = previous.connectionID != nil && self.current.connectionID == previous.connectionID
        if kind == .bootstrap, unchanged {
            self.current.markStaleSnapshot(failure: previous.failure, at: self.api.now())
        } else {
            self.recordFailure(failure, retryAfter: retryAfter)
        }
    }
}

struct InFlight {
    let id: UUID
    let kind: OperationKind
    let task: Task<LiveSessionState, Error>
}

enum OperationKind: Equatable {
    case bootstrap
    case points
    case history
    case invoices
    case invoicePDF(String)
    case paymentReview(String?)
    case refresh(subscriptionID: String?)

    var isOptional: Bool {
        switch self {
        case .points, .history, .invoices, .invoicePDF, .paymentReview: true
        case .bootstrap, .refresh: false
        }
    }
}
