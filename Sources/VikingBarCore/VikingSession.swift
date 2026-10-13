import Foundation

public actor VikingSession {
    let api: LiveAPI
    let signIn: AccountSignInPersistence
    let store: any SessionStore
    let lease: any SessionLease
    let cache: any BalanceCache
    let paymentQRRenderer: any PaymentQRRendering
    var current = LiveSessionState()
    var token: LiveToken?
    var renewalAttempted = false
    var tokenGeneration: UInt64?
    var generation: UInt64 = 0
    var flight: InFlight?
    var failures = 0
    var refreshInterval: RefreshInterval = .fiveMinutes

    public init(
        transport: any ProofHTTPTransport, store: any SessionStore,
        lease: any SessionLease, cache: any BalanceCache,
        key: AccountKey = .legacy, signInStore: any SessionStore = EphemeralSessionStore(),
        rememberedStore: any SessionStore = EphemeralSessionStore(),
        paymentQRRenderer: any PaymentQRRendering = UnavailablePaymentQRRenderer(),
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.api = LiveAPI(transport: transport, now: now)
        self.store = store
        self.signIn = AccountSignInPersistence(key: key, store: signInStore, secrets: rememberedStore)
        self.lease = lease
        self.cache = cache
        self.paymentQRRenderer = paymentQRRenderer
    }

    public func state() -> LiveSessionState {
        self.current
    }

    public func bootstrapWithDiagnostics(
        credentials: ProofCredentials, rememberPassword: Bool = false,
        expected: AccountMutationFence? = nil,
    ) async throws -> LiveSessionState {
        do {
            guard self.flight == nil else { throw BootstrapFailure.sessionBusy }
            self.generation &+= 1
            return try await self.run(kind: .bootstrap) { generation in
                try await self.connect(
                    credentials: credentials,
                    rememberPassword: rememberPassword,
                    expected: expected,
                    generation: generation,
                )
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
                let metadata = try self.signIn.load()
                self.applySignIn(metadata)
                if metadata.disposition == .loggedOut {
                    try? self.cleanupLogout()
                }
                return self.current
            }
            self.adopt(record)
            let signIn = self.current.signIn
            let cached = try? self.cache.load(connectionID: record.connectionID)
            if let cached, cached.canRestore(connectionID: self.current.connectionID) {
                self.current = cached
                self.current.isRefreshing = false
                if self.current.history?.context != self.current.historyContext {
                    self.current.history = nil
                }
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
            self.current.connectionSummary = record.connectionSummary
            self.current.signIn = signIn
            guard !record.rotationPending else { throw LiveFailure.reconnectRequired }
            if let deadline = try self.signIn.load().nextRenewalAt, deadline > self.api.now() {
                self.current.nextRefreshAt = max(self.current.nextRefreshAt ?? deadline, deadline)
            }
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
            self.current.paymentReview = nil
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
        self.current.paymentReview = nil
    }
}

extension VikingSession {
    func connect(
        credentials: ProofCredentials, rememberPassword: Bool, expected: AccountMutationFence?,
        generation: UInt64, reservation: PasswordAttemptReservation? = nil,
    ) async throws -> LiveSessionState {
        do { try credentials.validate() } catch { throw BootstrapFailure.credentialInput }
        let handle: any SessionLeaseHandle
        do { handle = try self.lease.acquire() } catch {
            throw (error as? LiveFailure) == .busy ? BootstrapFailure.sessionBusy : .localFilesystem
        }
        defer { handle.release() }
        try Task.checkCancellation()
        let attempted = try reservation.map { try self.signIn.checked($0, now: self.api.now()) }
            ?? self.signIn.reservePasswordAttempt(expected: expected, now: self.api.now())
        self.applySignIn(attempted)
        let received: LiveToken
        do {
            received = try await self.api.token(fields: [
                "client_id": credentials.clientID, "username": credentials.username, "password": credentials.password,
                "grant_type": "password", "scope": "read",
            ])
        } catch is CancellationError { throw CancellationError() } catch {
            var failed = attempted
            let requestFailure = error as? LiveRequestFailure
            failed.nextPasswordAttemptAt = max(failed.nextPasswordAttemptAt ?? .distantPast,
                                               requestFailure?.retryAfter ?? .distantPast)
            failed.rememberedFailure = requestFailure?.failure ?? error as? LiveFailure ?? .transport
            try? self.signIn.save(failed)
            self.applySignIn(failed)
            throw BootstrapFailure.tokenFailure(requestFailure?.failure ?? error)
        }
        try self.checkGeneration(generation)
        let connection = ConnectionID()
        var metadata = try self.signIn.accept(
            setup: AccountConnectionSummary(clientID: credentials.clientID, username: credentials.username),
            connection: connection, expected: attempted.fence,
        )
        let record = StoredSession(
            clientID: credentials.clientID, username: credentials.username,
            signInRevision: metadata.revision, connectionID: connection, refreshToken: received.refreshToken,
            generation: 0, rotationPending: false,
        )
        do { try self.saveRecord(record) } catch { throw BootstrapFailure.keychainWrite }
        metadata = self.signIn.finishAccepted(metadata, password: credentials.password,
                                              rememberPassword: rememberPassword)
        try self.checkGeneration(generation)
        self.current = LiveSessionState()
        self.applySignIn(metadata)
        self.current.connectionID = record.connectionID
        self.current.connectionSummary = record.connectionSummary
        self.current.scopeMismatch = received.scopeMismatch
        self.current.snapshot = self.current.emptySnapshot
        self.token = received
        self.tokenGeneration = record.generation
        return self.current
    }

    func fetch(
        subscriptionID: String?, generation: UInt64, forceTokenRefresh: Bool,
    ) async throws -> LiveSessionState {
        let token = try await self.authorize(force: forceTokenRefresh, generation: generation)
        let connectionID = self.current.connectionID
        do {
            return try await self.fetchBalance(
                subscriptionID: subscriptionID, token: token, connectionID: connectionID, generation: generation,
            )
        } catch let failure as LiveFailure where [.tokenExpired, .accessRejected].contains(failure) {
            let renewed = try await self.authorize(
                force: true, generation: generation, expectedConnectionID: connectionID,
            )
            do {
                return try await self.fetchBalance(
                    subscriptionID: subscriptionID, token: renewed, connectionID: connectionID, generation: generation,
                )
            } catch LiveFailure.accessRejected { throw LiveFailure.unauthorized }
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
                self.current.history = nil
                self.current.historyRevision = nil
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
        let metadata = try self.signIn.load()
        if let deadline = metadata.nextRenewalAt, self.api.now() < deadline {
            throw LiveFailure.rateLimited
        }
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
            try self.finishRenewalFailure(error, record: &record, preserveUsage: preserveUsage)
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

    private func finishRenewalFailure(
        _ error: any Error, record: inout StoredSession, preserveUsage: Bool,
    ) throws -> Never {
        self.token = nil
        var metadata = try self.signIn.load()
        let requestFailure = error as? LiveRequestFailure
        metadata.nextRenewalAt = max(self.api.now().addingTimeInterval(60),
                                     requestFailure?.retryAfter ?? .distantPast)
        metadata.nextPasswordAttemptAt = max(metadata.nextPasswordAttemptAt ?? .distantPast,
                                             requestFailure?.retryAfter ?? .distantPast)
        metadata.rememberedFailure = requestFailure?.failure ?? error as? LiveFailure ?? .transport
        if requestFailure?.dispatched == false {
            record.rotationPending = false
            try self.saveRecord(record)
        }
        try self.signIn.save(metadata)
        self.applySignIn(metadata)
        if !preserveUsage {
            self.markStale(failure: .reconnectRequired)
        }
        if error is CancellationError {
            throw CancellationError()
        }
        if let requestFailure, !requestFailure.dispatched {
            throw requestFailure.failure
        }
        throw LiveFailure.reconnectRequired
    }
}
