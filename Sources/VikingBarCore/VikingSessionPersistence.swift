import Foundation

extension VikingSession {
    func withConnectionLease<Value>(
        expected: ConnectionID?, operation: (StoredSession) throws -> Value,
    ) throws -> Value {
        let handle = try self.lease.acquire()
        defer { handle.release() }
        guard let record = try self.loadRecord() else {
            self.token = nil
            self.current = LiveSessionState()
            if let metadata = try? self.signIn.load() {
                self.applySignIn(metadata)
            }
            throw LiveFailure.notConnected
        }
        guard record.connectionID == expected else {
            self.adopt(record)
            throw LiveFailure.connectionChanged
        }
        return try operation(record)
    }

    func recordFailure(_ failure: LiveFailure?, retryAfter: Date? = nil) {
        guard failure != .connectionChanged else {
            self.markStale(failure: failure)
            return
        }
        do {
            try self.withConnectionLease(expected: self.current.connectionID) { _ in
                self.markStale(failure: failure)
                if let retryAfter {
                    var metadata = try self.signIn.load()
                    metadata.nextRenewalAt = max(metadata.nextRenewalAt ?? .distantPast, retryAfter)
                    metadata.nextPasswordAttemptAt = max(metadata.nextPasswordAttemptAt ?? .distantPast, retryAfter)
                    try self.signIn.save(metadata)
                    self.applySignIn(metadata)
                    self.current.nextRefreshAt = max(self.current.nextRefreshAt ?? retryAfter, retryAfter)
                }
                try? self.cache.save(self.current)
            }
        } catch LiveFailure.connectionChanged {
            self.markStale(failure: .connectionChanged)
        } catch {
            self.markStale(failure: failure)
        }
    }

    func adopt(_ record: StoredSession) {
        let signIn = self.current.signIn
        if self.current.connectionID != record.connectionID {
            self.token = nil
            self.current = LiveSessionState()
            self.current.connectionID = record.connectionID
            self.current.snapshot = self.current.emptySnapshot
        }
        self.current.connectionSummary = record.connectionSummary
        self.current.signIn = signIn
    }

    func markStale(failure: LiveFailure?) {
        self.current.failure = failure
        if let failure {
            self.failures = min(self.failures + 1, 7)
            self.current.nextRefreshAt = [.reconnectRequired, .unauthorized, .notConnected].contains(failure)
                ? nil : self.api.now().addingTimeInterval(min(1800, 30 * pow(2, Double(self.failures - 1))))
        }
        self.current.markStaleSnapshot(failure: failure, at: self.api.now())
    }

    func checkGeneration(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
    }

    func loadRecord() throws -> StoredSession? {
        let metadata = try self.signIn.load()
        self.applySignIn(metadata)
        do {
            guard let data = try self.store.load() else { return nil }
            let record = try JSONDecoder().decode(StoredSession.self, from: data)
            if metadata.disposition == .loggedOut, (record.signInRevision ?? 0) <= metadata.revision {
                return nil
            }
            guard record.version == 1, !record.clientID.isEmpty, !record.refreshToken.isEmpty else {
                throw LiveFailure.reconnectRequired
            }
            let reconciled = try self.signIn.reconcile(
                summary: record.connectionSummary,
                connection: record.connectionID,
                revision: record.signInRevision,
            )
            self.applySignIn(reconciled)
            guard reconciled.fence.connectionID == record.connectionID else { throw LiveFailure.connectionChanged }
            return record
        } catch let failure as LiveFailure { throw failure } catch {
            if metadata.disposition == .loggedOut {
                return nil
            }
            throw LiveFailure.reconnectRequired
        }
    }

    func saveRecord(_ record: StoredSession) throws {
        do { try self.store.save(JSONEncoder().encode(record)) } catch { throw LiveFailure.storage }
    }
}
