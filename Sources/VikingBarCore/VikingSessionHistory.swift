import Foundation

extension VikingSession {
    public func refreshHistory(force: Bool = false) async throws -> LiveSessionState {
        guard let context = self.current.historyContext,
              self.current.selectedBundle?.isActive(at: self.api.now()) == true,
              self.current.failure == nil else { return self.current }
        if !force, let history = self.current.history, history.context == context {
            let now = self.api.now()
            let sameDay = HistoryPlan.calendar.isDate(history.attemptedAt, inSameDayAs: now)
            if sameDay, now.timeIntervalSince(history.attemptedAt) < 300 {
                return self.current
            }
        }
        return try await self.runOptional(kind: .history) { generation in
            try await self.fetchHistory(context: context, generation: generation, force: force)
        }
    }

    private func fetchHistory(
        context: HistoryContext, generation: UInt64, force: Bool,
    ) async throws -> LiveSessionState {
        let history: UsageHistory
        do {
            try self.checkHistory(context: context, generation: generation)
            guard let token = self.token, self.api.now() < token.expiresAt else { throw LiveFailure.tokenExpired }
            history = try await HistoryReader(
                api: self.api, token: token, context: context, previous: self.current.history, force: force,
            ).read { try await self.checkHistory(context: context, generation: generation) }
        } catch is CancellationError { throw CancellationError() } catch {
            history = UsageHistory(
                context: context, observations: (self.current.history?.observations ?? []).map {
                    HistoryObservation(interval: $0.interval, bytes: $0.bytes, fetchedAt: $0.fetchedAt, isStale: true)
                }, attemptedAt: self.api.now(), failure: error as? LiveFailure ?? .transport,
            )
        }
        do {
            try self.checkHistory(context: context, generation: generation, publish: history)
        } catch is CancellationError { throw CancellationError() } catch {
            try self.checkGeneration(generation)
            guard self.current.historyContext == context else { throw CancellationError() }
            self.current.history = UsageHistory(
                context: context, observations: history.observations.map {
                    HistoryObservation(interval: $0.interval, bytes: $0.bytes, fetchedAt: $0.fetchedAt, isStale: true)
                }, attemptedAt: history.attemptedAt, failure: error as? LiveFailure ?? .transport,
                truncated: history.truncated,
            )
        }
        return self.current
    }

    private func checkHistory(context: HistoryContext, generation: UInt64, publish: UsageHistory? = nil) throws {
        try self.checkGeneration(generation)
        guard self.current.historyContext == context else { throw CancellationError() }
        let handle = try self.lease.acquire()
        defer { handle.release() }
        guard let record = try self.loadRecord(), record.connectionID == context.connectionID,
              !record.rotationPending, record.generation == self.tokenGeneration
        else {
            throw LiveFailure.connectionChanged
        }
        if let publish {
            self.current.history = publish
            try? self.cache.save(self.current)
        }
    }
}
