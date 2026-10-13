import Foundation

public actor TelenetHomeAccount: ProviderAccountSession {
    public nonisolated let key: AccountKey
    private let transport: any TelenetTransport
    let signIn: AccountSignInPersistence
    let store: any SessionStore
    let lease: any SessionLease
    let cache: any BalanceCache
    let now: @Sendable () -> Date
    var current = LiveSessionState()
    var busy = false
    var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var generation: UInt64 = 0

    public init(
        key: AccountKey, transport: any TelenetTransport, store: any SessionStore,
        lease: any SessionLease, cache: any BalanceCache,
        signInStore: any SessionStore = EphemeralSessionStore(),
        rememberedStore: any SessionStore = EphemeralSessionStore(),
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.key = key
        self.transport = transport
        self.store = store
        self.signIn = AccountSignInPersistence(key: key, store: signInStore, secrets: rememberedStore)
        self.lease = lease
        self.cache = cache
        self.now = now
        self.current.account = AccountContext(key: key, providerName: "Telenet", services: [], selectedService: nil,
                                              capabilities: .usageOnly)
    }

    public static func production(
        storage: AccountStorage, transport: any TelenetTransport = EphemeralTelenetTransport(),
        allowInteraction: Bool = true,
    ) throws -> TelenetHomeAccount {
        guard storage.key.provider == .telenet else { throw LiveFailure.invalidSelection }
        try storage.prepare()
        return Self(
            key: storage.key, transport: transport,
            store: KeychainSessionStore(account: storage.keychainAccount, service: "be.bram.vikingbar.telenet.session",
                                        allowInteraction: allowInteraction),
            lease: FileSessionLease(url: storage.leaseURL), cache: FileBalanceCache(url: storage.cacheURL),
            signInStore: FileAccountSignInStore(url: storage.signInURL),
            rememberedStore: KeychainSessionStore(account: storage.keychainAccount,
                                                  service: "be.bram.vikingbar.remembered-sign-in",
                                                  allowInteraction: allowInteraction),
        )
    }

    public func state() -> LiveSessionState {
        self.current
    }

    public func cancel() {
        self.generation &+= 1
    }

    public func connect(credentials: ProviderCredentials) async throws -> ConnectionID {
        try await self.connect(credentials: credentials, rememberPassword: false, expected: nil)
    }

    public func connect(
        credentials: ProviderCredentials, rememberPassword: Bool,
        expected: AccountMutationFence?,
    ) async throws -> ConnectionID {
        try await self.connect(credentials: credentials, rememberPassword: rememberPassword,
                               expected: expected, reservation: nil)
    }

    func connect(
        credentials: ProviderCredentials, rememberPassword: Bool,
        expected: AccountMutationFence?, reservation: PasswordAttemptReservation?,
    ) async throws -> ConnectionID {
        guard case let .telenet(input) = credentials else { throw ProofFailure.invalidInput }
        try input.validate()
        guard !self.busy else { throw LiveFailure.busy }
        let handle = try self.lease.acquire()
        defer { handle.release() }
        self.busy = true
        defer { self.finishOperation() }
        let generation = self.generation
        var record = try self.loadRecord(replacingInvalid: true) ?? TelenetSessionRecord(account: self.key)
        if record.established {
            try self.adopt(record)
        }
        let metadata = try reservation.map { try self.signIn.checked($0, now: self.now()) }
            ?? self.signIn.reservePasswordAttempt(expected: expected, now: self.now())
        self.applySignIn(metadata)
        let priorService = try self.retainedService(connection: metadata.fence.connectionID)
        let priorConnection = record.connectionID
        let priorNeedsReconnect = record.rotationPending
        let priorFailure = self.current.failure
        try self.reserveAttempt(&record, reconnecting: reservation == nil)
        let api = TelenetAPI(transport: self.transport, now: self.now)
        do {
            try await api.login(credentials: input)
            try self.check(generation)
            record = try await self.acceptLogin(api: api, credentials: input, previous: record,
                                                metadata: metadata, rememberPassword: rememberPassword)
            let services = try await api.discover()
            let rememberedService = priorService.flatMap { services.contains($0) ? $0 : nil }
            guard let selected = rememberedService ?? services.first else { throw LiveFailure.invalidSelection }
            try await self.read(
                api: api,
                services: services,
                selected: selected,
                record: &record,
                generation: generation,
            )
            return record.connectionID
        } catch {
            let cookies = record.connectionID == priorConnection ? record.cookies : await api.cookies
            let context: FailureContext = record.established && record.connectionID == priorConnection
                ? .replacementLogin(needsReconnect: priorNeedsReconnect, priorFailure: priorFailure) : .currentSession
            try self.finishFailure(error, record: &record, cookies: cookies, context: context)
            if let requestFailure = error as? TelenetRequestFailure {
                throw requestFailure.failure
            }
            throw error
        }
    }

    func restore() throws {
        guard !self.busy else { throw LiveFailure.busy }
        let handle = try self.lease.acquire()
        defer { handle.release() }
        guard let record = try self.loadRecord(), record.established else {
            self.current = self.emptyState(connectionID: nil)
            let metadata = try self.signIn.load()
            self.applySignIn(metadata)
            if metadata.disposition == .loggedOut {
                try? self.cleanupLogout()
            }
            return
        }
        try self.adopt(record)
        if record.rotationPending || !record.cookies.usable(at: self.now()) {
            self.markStale(.reconnectRequired)
            self.current.nextRefreshAt = nil
            return
        }
        if let next = self.current.nextRefreshAt, next <= self.now() {
            self.markStale(self.current.failure)
        }
        if let cooldown = record.nextAllowedAt {
            self.current.nextRefreshAt = max(self.current.nextRefreshAt ?? cooldown, cooldown)
        }
    }

    func refresh(serviceID: String?) async throws {
        guard !self.busy else { throw LiveFailure.busy }
        let handle = try self.lease.acquire()
        defer { handle.release() }
        self.busy = true
        defer { self.finishOperation() }
        let generation = self.generation
        let previousConnection = self.current.connectionID
        guard var record = try self.loadRecord(), record.established else { throw LiveFailure.notConnected }
        try self.adopt(record)
        if let previousConnection, previousConnection != record.connectionID {
            throw LiveFailure.connectionChanged
        }
        guard !record.rotationPending, record.cookies.usable(at: self.now()) else {
            self.markStale(.reconnectRequired)
            throw LiveFailure.reconnectRequired
        }
        if let serviceID, let services = self.current.account?.services, !services.isEmpty {
            guard services.contains(where: { $0.key.providerID == serviceID }) else {
                throw LiveFailure.invalidSelection
            }
        }
        try self.reserveAttempt(&record)
        self.current.isRefreshing = true
        let api = TelenetAPI(transport: self.transport, cookies: record.cookies, now: self.now)
        do {
            let services = try await api.discover()
            try self.check(generation)
            let previousID = self.current.account?.selectedService?.providerID
            let remembered = previousID.flatMap {
                services.contains($0) ? $0 : nil
            }
            let selected = serviceID ?? remembered ?? services.first
            guard let selected, services.contains(selected) else { throw LiveFailure.invalidSelection }
            try await self.read(
                api: api,
                services: services,
                selected: selected,
                record: &record,
                generation: generation,
            )
        } catch {
            try await self.finishFailure(error, record: &record, cookies: api.cookies)
            if let requestFailure = error as? TelenetRequestFailure {
                throw requestFailure.failure
            }
            throw error
        }
    }

    private func read(
        api: TelenetAPI, services: [String], selected: String, record: inout TelenetSessionRecord, generation: UInt64,
    ) async throws {
        let selectedKey = ServiceKey(account: self.key, kind: .home, providerID: selected)
        if self.current.account?.selectedService != selectedKey {
            self.current.homeUsage = nil
        }
        self.current.account = self.context(services: services, selected: selectedKey)
        if self.current.homeUsage == nil {
            self.current.snapshot = self.emptySnapshot(connected: true)
        }
        let payload = try await api.read(serviceID: selected)
        let usage = try HomeUsageDecoder.decode(
            payload,
            key: selectedKey, connectionID: record.connectionID, fetchedAt: self.now(),
        )
        try self.check(generation)
        record.cookies = await api.cookies
        record.rotationPending = false
        record.failures = payload.dailyFailure == nil ? 0 : min(5, record.failures + 1)
        if let retryAfter = payload.dailyRetryAfter {
            record.serverRetryAfter = max(record.serverRetryAfter ?? retryAfter, retryAfter)
        }
        record.nextAllowedAt = payload.dailyFailure.map { self.failureDeadline(
            $0,
            record: record,
            retryAfter: payload.dailyRetryAfter,
        ) }
        try self.saveRecord(record)
        self.current.homeUsage = usage
        self.current.homeFailure = payload.dailyFailure
        self.current.snapshot = usage.snapshot()
        self.current.failure = nil
        self.current.nextRefreshAt = max(self.now().addingTimeInterval(3600), record.nextAllowedAt ?? .distantPast)
        try self.cache.save(self.current)
    }
}

extension TelenetHomeAccount {
    private func reserveAttempt(_ record: inout TelenetSessionRecord, reconnecting: Bool = false) throws {
        let backoff = reconnecting ? Date.distantPast : record.nextAllowedAt ?? .distantPast
        let deadline = max(record.nextAttemptAt ?? .distantPast, max(record.serverRetryAfter ?? .distantPast, backoff))
        guard self.now() >= deadline else {
            self.current.nextRefreshAt = max(self.current.nextRefreshAt ?? deadline, deadline)
            throw LiveFailure.rateLimited
        }
        record.nextAttemptAt = self.now().addingTimeInterval(60)
        record.rotationPending = true
        try self.saveRecord(record)
    }

    private func finishFailure(
        _ error: any Error, record: inout TelenetSessionRecord, cookies: TelenetCookieJar,
        context: FailureContext = .currentSession,
    ) throws {
        let requestFailure = error as? TelenetRequestFailure
        let failure = requestFailure?.failure ?? (error as? LiveFailure) ?? .transport
        record.cookies = cookies
        let authenticationFailed = [.unauthorized, .reconnectRequired].contains(failure)
        let visibleFailure: LiveFailure?
        switch context {
        case .currentSession:
            record.rotationPending = authenticationFailed
            visibleFailure = failure
        case let .replacementLogin(needsReconnect, priorFailure):
            record.rotationPending = needsReconnect
            visibleFailure = authenticationFailed ? priorFailure : failure
        }
        if let retryAfter = requestFailure?.retryAfter {
            record.serverRetryAfter = max(record.serverRetryAfter ?? retryAfter, retryAfter)
        }
        record.failures = min(5, record.failures + 1)
        record.nextAllowedAt = self.failureDeadline(failure, record: record, retryAfter: requestFailure?.retryAfter)
        try self.saveRecord(record)
        self.markStale(visibleFailure)
        self.current.nextRefreshAt = record.rotationPending ? nil : record.nextAllowedAt
        if record.established {
            try self.cache.save(self.current)
        }
    }

    private func failureDeadline(_ failure: LiveFailure, record: TelenetSessionRecord, retryAfter: Date?) -> Date {
        let backoff = min(21600, 1800 * pow(2, Double(max(1, record.failures) - 1)))
        let jitter = TimeInterval(self.key.slot.uuidString.utf8.reduce(0) { ($0 + Int($1)) % 301 })
        let delay = failure == .malformedResponse ? 3600 : backoff + jitter
        return max(record.nextAllowedAt ?? .distantPast,
                   max(self.now().addingTimeInterval(delay), retryAfter ?? .distantPast))
    }

    private func adopt(_ record: TelenetSessionRecord) throws {
        let signIn = self.current.signIn
        let summary = record.summary ?? self.current.connectionSummary
        let cached = try self.cache.load(connectionID: record.connectionID)
        let belongs = cached?.account?.key == self.key && (cached?.homeUsage == nil || cached?.selectedHomeUsage != nil)
        if let cached, belongs {
            self.current = cached
            self.current.isRefreshing = false
        } else if self.current.connectionID != record.connectionID {
            self.current = self.emptyState(connectionID: record.connectionID)
        }
        self.current.connectionSummary = summary
        self.current.signIn = signIn
    }

    func check(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
    }

    private func markStale(_ failure: LiveFailure?) {
        self.current.failure = failure
        if let usage = self.current.selectedHomeUsage {
            self.current.snapshot = usage.snapshot(stale: true, failure: failure)
        } else {
            self.current.snapshot = self.emptySnapshot(connected: self.current.connectionID != nil, failure: failure)
        }
    }

    func emptyState(connectionID: ConnectionID?) -> LiveSessionState {
        var result = LiveSessionState()
        result.connectionID = connectionID
        result.account = self.context(services: [], selected: nil)
        result.snapshot = self.emptySnapshot(connected: connectionID != nil)
        return result
    }

    private func emptySnapshot(connected: Bool, failure: LiveFailure? = nil) -> UsageSnapshot {
        UsageSnapshot(source: connected ? .live : .notConnected, subscriptionName: "Telenet home internet",
                      allowance: .unavailable, expiresAt: nil, freshness: .unavailable,
                      errorMessage: failure.map(Self.message), providerName: "Telenet")
    }

    private func context(services: [String], selected: ServiceKey?) -> AccountContext {
        AccountContext(key: self.key, providerName: "Telenet", services: services.enumerated().map { index, id in
            AccountService(
                key: ServiceKey(account: self.key, kind: .home, providerID: id),
                name: "Home internet \(index + 1)",
            )
        }, selectedService: selected, capabilities: .usageOnly)
    }

    func loadRecord(replacingInvalid: Bool = false) throws -> TelenetSessionRecord? {
        let metadata = try self.signIn.load()
        self.applySignIn(metadata)
        guard let data = try self.store.load() else { return nil }
        let record: TelenetSessionRecord
        do {
            record = try JSONDecoder().decode(TelenetSessionRecord.self, from: data)
        } catch {
            if replacingInvalid || metadata.disposition == .loggedOut {
                return nil
            }
            throw LiveFailure.reconnectRequired
        }
        if metadata.disposition == .loggedOut {
            guard record.established, record.summary != nil,
                  (record.signInRevision ?? 0) > metadata.revision else { return nil }
        }
        guard record.version == 1, record.account == self.key else {
            if replacingInvalid || metadata.disposition == .loggedOut {
                return nil
            }
            throw LiveFailure.reconnectRequired
        }
        if record.established {
            let summary = record.summary ?? metadata.summary ?? AccountConnectionSummary(
                clientID: "",
                username: nil,
            )
            let metadata = try self.signIn.reconcile(summary: summary, connection: record.connectionID,
                                                     revision: record.signInRevision)
            self.applySignIn(metadata)
            guard metadata.fence.connectionID == record.connectionID else { throw LiveFailure.connectionChanged }
        }
        return record
    }

    func saveRecord(_ record: TelenetSessionRecord) throws {
        try self.store.save(JSONEncoder().encode(record))
    }

    public nonisolated static func message(for failure: LiveFailure) -> String {
        switch failure {
        case .notConnected: "Connect your Telenet account."
        case .reconnectRequired, .unauthorized: "Reconnect your Telenet account."
        case .transport: "Could not reach Telenet."
        case .malformedResponse: "Telenet returned an unsupported home usage response."
        case .rateLimited: "Telenet updates are paused. Try again after the scheduled refresh."
        case .serverUnavailable: "Telenet is temporarily unavailable."
        default: failure.message
        }
    }
}

private enum FailureContext {
    case currentSession
    case replacementLogin(needsReconnect: Bool, priorFailure: LiveFailure?)
}
