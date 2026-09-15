import Foundation

public actor VikingSession {
    let api: LiveAPI
    private let store: any SessionStore
    private let lease: any SessionLease
    let cache: any BalanceCache
    var current = LiveSessionState()
    var token: LiveToken?
    private var tokenGeneration: UInt64?
    var generation: UInt64 = 0
    var flight: InFlight?
    private var failures = 0
    private var refreshInterval: RefreshInterval = .fiveMinutes

    public init(
        transport: any ProofHTTPTransport, store: any SessionStore,
        lease: any SessionLease, cache: any BalanceCache,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.api = LiveAPI(transport: transport, now: now)
        self.store = store
        self.lease = lease
        self.cache = cache
    }

    public func state() -> LiveSessionState {
        self.current
    }

    public func bootstrapWithDiagnostics(credentials: ProofCredentials) async throws -> LiveSessionState {
        do {
            guard self.flight == nil else { throw BootstrapFailure.sessionBusy }
            self.generation &+= 1
            self.token = nil
            self.current = LiveSessionState()
            return try await self.run(kind: .bootstrap) { generation in
                try await self.connect(credentials: credentials, generation: generation)
            }
        } catch is CancellationError {
            throw BootstrapFailure.connectCancelled
        } catch let failure as BootstrapFailure {
            throw failure
        } catch {
            throw BootstrapFailure.connectFailed
        }
    }

    public func restore() throws -> LiveSessionState {
        guard self.flight == nil else { throw LiveFailure.busy }
        let handle = try self.lease.acquire()
        defer { handle.release() }
        do {
            guard let record = try self.loadRecord() else {
                self.token = nil
                self.current = LiveSessionState()
                return self.current
            }
            self.adopt(record)
            let cached = try? self.cache.load(connectionID: record.connectionID)
            if let cached, cached.canRestore(connectionID: self.current.connectionID) {
                self.current = cached
                self.current.isRefreshing = false
                if let deadline = cached.freshDeadline(at: self.api.now(), interval: self.refreshInterval) {
                    self.current.nextRefreshAt = deadline
                } else {
                    if cached.failure == nil {
                        self.current.nextRefreshAt = nil
                    }
                    self.current.markStaleSnapshot(failure: cached.failure, at: self.api.now())
                }
                self.current.revalidateBundle(at: self.api.now())
                self.current.points?.revalidate(at: self.api.now())
            }
            guard !record.rotationPending else { throw LiveFailure.reconnectRequired }
            return self.current
        } catch {
            let failure = (error as? LiveFailure ?? .transport)
            self.markStale(failure: failure)
            throw failure
        }
    }

    public func refresh(
        subscriptionID: String? = nil, forceTokenRefresh: Bool = false,
    ) async throws -> LiveSessionState {
        let kind = OperationKind.refresh(subscriptionID: subscriptionID)
        if let flight, !flight.kind.isOptional {
            guard flight.kind == kind else { throw LiveFailure.busy }
            var completed = try await flight.task.value
            try Task.checkCancellation()
            completed.isRefreshing = false
            return completed
        }
        return try await self.run(kind: kind) { generation in
            try await self.fetch(
                subscriptionID: subscriptionID, generation: generation, forceTokenRefresh: forceTokenRefresh,
            )
        }
    }

    public func refreshPoints(forceTokenRefresh: Bool = false) async throws -> LiveSessionState {
        try await self.runOptional(kind: .points) { generation in
            try await self.fetchPoints(generation: generation, forceTokenRefresh: forceTokenRefresh)
        }
    }

    public func selectSubscription(id: String) async throws -> LiveSessionState {
        guard self.current.subscriptions.contains(where: { $0.id == id }) else {
            throw LiveFailure.invalidSelection
        }
        return try await self.run(kind: .refresh(subscriptionID: id)) { generation in
            try await self.fetch(subscriptionID: id, generation: generation, forceTokenRefresh: false)
        }
    }

    public func selectBundle(index: Int) throws -> LiveSessionState {
        guard self.flight == nil else { throw LiveFailure.busy }
        return try self.withConnectionLease(expected: self.current.connectionID) { _ in
            try self.current.selectBundle(index: index, at: self.api.now(), interval: self.refreshInterval)
            try? self.cache.save(self.current)
            return self.current
        }
    }

    public func configure(refreshInterval: RefreshInterval) -> LiveSessionState {
        self.refreshInterval = refreshInterval
        self.current.updateRefreshDeadline(interval: refreshInterval)
        return self.current
    }

    public func cancel() {
        self.generation &+= 1
        self.flight?.task.cancel()
    }
}

extension VikingSession {
    private func connect(credentials: ProofCredentials, generation: UInt64) async throws -> LiveSessionState {
        do { try credentials.validate() } catch { throw BootstrapFailure.credentialInput }
        let handle: any SessionLeaseHandle
        do { handle = try self.lease.acquire() } catch {
            throw (error as? LiveFailure) == .busy ? BootstrapFailure.sessionBusy : .localFilesystem
        }
        defer { handle.release() }
        try Task.checkCancellation()
        let received: LiveToken
        do {
            received = try await self.api.token(fields: [
                "client_id": credentials.clientID, "username": credentials.username, "password": credentials.password,
                "grant_type": "password", "scope": "read",
            ])
        } catch is CancellationError { throw CancellationError() } catch {
            throw BootstrapFailure.tokenFailure(error)
        }
        let record = StoredSession(
            clientID: credentials.clientID, connectionID: ConnectionID(), refreshToken: received.refreshToken,
            generation: 0, rotationPending: false,
        )
        do { try self.saveRecord(record) } catch { throw BootstrapFailure.keychainWrite }
        try self.checkGeneration(generation)
        self.current.connectionID = record.connectionID
        self.current.scopeMismatch = received.scopeMismatch
        self.current.snapshot = self.current.emptySnapshot
        self.token = received
        self.tokenGeneration = record.generation
        return self.current
    }

    private func fetch(
        subscriptionID: String?, generation: UInt64, forceTokenRefresh: Bool,
    ) async throws -> LiveSessionState {
        let token = try await self.authorize(force: forceTokenRefresh, generation: generation)
        let connectionID = self.current.connectionID
        do {
            return try await self.fetchBalance(
                subscriptionID: subscriptionID, token: token, connectionID: connectionID, generation: generation,
            )
        } catch LiveFailure.tokenExpired {
            let renewed = try await self.authorize(
                force: true, generation: generation, expectedConnectionID: connectionID,
            )
            return try await self.fetchBalance(
                subscriptionID: subscriptionID, token: renewed, connectionID: connectionID, generation: generation,
            )
        }
    }

    private func fetchBalance(
        subscriptionID: String?, token: LiveToken, connectionID: ConnectionID?, generation: UInt64,
    ) async throws -> LiveSessionState {
        let subscriptions = try await self.api.subscriptions(token: token)
        try self.checkGeneration(generation)
        guard !subscriptions.isEmpty else { throw LiveFailure.noMobileSubscriptions }
        let selected: MobileSubscription
        if let subscriptionID {
            guard let requested = subscriptions.first(where: { $0.id == subscriptionID }) else {
                throw LiveFailure.invalidSelection
            }
            selected = requested
        } else {
            selected = subscriptions.first(where: { $0.id == self.current.selectedSubscriptionID }) ?? subscriptions[0]
        }
        try self.withConnectionLease(expected: connectionID) { _ in
            try self.checkGeneration(generation)
            let changedSubscription = self.current.selectedSubscriptionID != selected.id
            self.current.subscriptions = subscriptions
            self.current.selectedSubscriptionID = selected.id
            if changedSubscription {
                self.current.balance = nil
                self.current.selectedBundleIndex = nil
                self.current.snapshot = self.current.emptySnapshot
            }
        }
        let balance = try await self.api.balance(subscriptionID: selected.id, token: token)
        return try self.withConnectionLease(expected: connectionID) { record in
            try self.checkGeneration(generation)
            guard !record.rotationPending else { throw LiveFailure.reconnectRequired }
            self.current.publish(balance, at: self.api.now(), interval: self.refreshInterval)
            self.failures = 0
            try? self.cache.save(self.current)
            return self.current
        }
    }

    func authorize(
        force: Bool, generation: UInt64, expectedConnectionID: ConnectionID? = nil, preserveUsage: Bool = false,
    ) async throws -> LiveToken {
        let handle = try self.lease.acquire()
        defer { handle.release() }
        guard var record = try self.loadRecord() else { throw LiveFailure.notConnected }
        if let expectedConnectionID, record.connectionID != expectedConnectionID {
            self.adopt(record)
            throw LiveFailure.connectionChanged
        }
        let sameConnection = self.current.connectionID == record.connectionID
        self.adopt(record)
        guard !record.rotationPending,
              self.current.failure != .reconnectRequired, self.current.failure != .unauthorized
        else { throw LiveFailure.reconnectRequired }
        let canReuse = sameConnection && self.tokenGeneration == record.generation && !force
        if canReuse, let token, self.api.now() < token.expiresAt {
            return token
        }
        try self.checkGeneration(generation)
        record.rotationPending = true
        try self.saveRecord(record)
        let received: LiveToken
        do {
            let fields = [
                "client_id": record.clientID, "refresh_token": record.refreshToken, "grant_type": "refresh_token",
            ]
            let exchange = Task { try await self.api.token(fields: fields) }
            received = try await exchange.value
        } catch {
            self.token = nil
            if !preserveUsage {
                self.markStale(failure: .reconnectRequired)
            }
            if error is CancellationError {
                throw CancellationError()
            }
            throw LiveFailure.reconnectRequired
        }
        record.refreshToken = received.refreshToken
        record.rotationPending = false
        record.generation &+= 1
        // A received replacement must survive cancellation before anything observes the new access token.
        do { try self.saveRecord(record) } catch {
            self.token = nil
            throw LiveFailure.reconnectRequired
        }
        self.token = received
        self.tokenGeneration = record.generation
        self.current.scopeMismatch = received.scopeMismatch
        try self.checkGeneration(generation)
        return received
    }
}

extension VikingSession {
    func withConnectionLease<Value>(
        expected: ConnectionID?, operation: (StoredSession) throws -> Value,
    ) throws -> Value {
        let handle = try self.lease.acquire()
        defer { handle.release() }
        guard let record = try self.loadRecord() else {
            self.token = nil
            self.current = LiveSessionState()
            throw LiveFailure.notConnected
        }
        guard record.connectionID == expected else {
            self.adopt(record)
            throw LiveFailure.connectionChanged
        }
        return try operation(record)
    }

    func recordFailure(_ failure: LiveFailure?) {
        guard failure != .connectionChanged else {
            self.markStale(failure: failure)
            return
        }
        do {
            try self.withConnectionLease(expected: self.current.connectionID) { _ in
                self.markStale(failure: failure)
                try? self.cache.save(self.current)
            }
        } catch LiveFailure.connectionChanged {
            self.markStale(failure: .connectionChanged)
        } catch {
            self.markStale(failure: failure)
        }
    }

    private func adopt(_ record: StoredSession) {
        if self.current.connectionID != record.connectionID {
            self.token = nil
            self.current = LiveSessionState()
            self.current.connectionID = record.connectionID
            self.current.snapshot = self.current.emptySnapshot
        }
    }

    private func markStale(failure: LiveFailure?) {
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

    private func loadRecord() throws -> StoredSession? {
        do {
            guard let data = try self.store.load() else { return nil }
            let record = try JSONDecoder().decode(StoredSession.self, from: data)
            guard record.version == 1, !record.clientID.isEmpty, !record.refreshToken.isEmpty else {
                throw LiveFailure.reconnectRequired
            }
            return record
        } catch let failure as LiveFailure { throw failure } catch { throw LiveFailure.reconnectRequired }
    }

    private func saveRecord(_ record: StoredSession) throws {
        do { try self.store.save(JSONEncoder().encode(record)) } catch { throw LiveFailure.storage }
    }
}
