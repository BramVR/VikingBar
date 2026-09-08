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
        let previous = self.flight
        if previous != nil {
            self.cancel()
        }
        let id = UUID()
        let generation = self.generation
        if !kind.isOptional {
            self.current.isRefreshing = true
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
                _ = try await operation(generation)
                try self.checkGeneration(generation)
                if !kind.isOptional {
                    self.current.isRefreshing = false
                }
                return self.current
            } catch {
                if self.generation == generation, !kind.isOptional {
                    let failure = error is CancellationError ? self.current.failure
                        : ((error as? BootstrapFailure)?.liveFailure ?? error as? LiveFailure ?? .transport)
                    self.recordFailure(failure)
                }
                throw error
            }
        }
        self.flight = InFlight(id: id, kind: kind, task: task)
        let state = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        return state
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
    case invoices
    case invoicePDF(String)
    case refresh(subscriptionID: String?)

    var isOptional: Bool {
        switch self {
        case .points, .invoices, .invoicePDF: true
        case .bootstrap, .refresh: false
        }
    }
}
