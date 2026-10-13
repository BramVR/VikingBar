import Foundation

struct TelenetSessionRecord: Codable {
    var version = 1
    let account: AccountKey
    var connectionID = ConnectionID()
    var cookies = TelenetCookieJar()
    var established = false
    var nextAttemptAt: Date?
    var nextAllowedAt: Date?
    var serverRetryAfter: Date?
    var failures = 0
    var rotationPending = false
    var summary: AccountConnectionSummary?
    var signInRevision: UInt64?
}

extension TelenetHomeAccount {
    func applySignIn(_ record: AccountSignInRecord) {
        if let connection = self.current.connectionID, connection != record.fence.connectionID {
            self.current = self.emptyState(connectionID: nil)
        }
        self.current.signIn = record.presentation
        self.current.connectionSummary = record.summary
    }

    public func savedSignIn(expected: AccountMutationFence) async throws {
        guard !self.busy else { throw LiveFailure.busy }
        let envelope: RememberedSignInEnvelope
        let reservation: PasswordAttemptReservation
        do {
            let handle = try self.lease.acquire()
            defer { handle.release() }
            let metadata = try self.signIn.checked(expected)
            if let record = try self.loadRecord() {
                let deadline = max(record.nextAllowedAt ?? .distantPast,
                                   max(record.nextAttemptAt ?? .distantPast, record.serverRetryAfter ?? .distantPast))
                guard self.now() >= deadline else { throw LiveFailure.rateLimited }
            }
            guard metadata.remembered == .available else { throw LiveFailure.savedSignInUnavailable }
            let reserved = try self.signIn.reservePasswordAttempt(expected: expected, now: self.now())
            guard let id = reserved.passwordAttemptID else { throw LiveFailure.storage }
            reservation = PasswordAttemptReservation(fence: reserved.fence, id: id)
            self.applySignIn(reserved)
            envelope = try self.signIn.credentials(record: reserved)
        }
        _ = try await self.connect(credentials: .telenet(TelenetCredentials(
            username: envelope.summary.username ?? "", password: envelope.password,
        )), rememberPassword: true, expected: expected, reservation: reservation)
    }

    public func disableRememberedSignIn(expected: AccountMutationFence) throws {
        guard !self.busy else { throw LiveFailure.busy }
        let handle = try self.lease.acquire()
        defer {
            if let record = try? self.signIn.load() {
                if self.current.connectionID != record.fence.connectionID {
                    self.current = self.emptyState(connectionID: record.fence.connectionID)
                }
                self.applySignIn(record)
            }
            handle.release()
        }
        if try self.signIn.checked(expected).disposition == .loggedOut {
            try self.cleanupLogout()
        } else {
            try self.applySignIn(self.signIn.disable(expected: expected))
        }
    }

    public func logout(expected: AccountMutationFence) async throws {
        _ = try self.signIn.checked(expected)
        self.cancel()
        if self.busy {
            await withCheckedContinuation { self.idleWaiters.append($0) }
        }
        let handle = try self.lease.acquire()
        defer { handle.release() }
        _ = try self.signIn.checked(expected)
        self.generation &+= 1
        defer {
            self.current = self.emptyState(connectionID: nil)
            if let record = try? self.signIn.load() {
                self.applySignIn(record)
            }
        }
        _ = try self.signIn.logout(expected: expected)
        try self.cleanupLogout()
    }

    func cleanupLogout() throws {
        var failure: (any Error)?
        do { try self.signIn.secrets.delete() } catch { failure = error }
        do { try self.store.delete() } catch { failure = error }
        do { try self.cache.delete() } catch { failure = error }
        var record = try self.signIn.load()
        if let failure {
            record.remembered = .cleanupRequired
            record.rememberedFailure = .storage
            try self.signIn.save(record)
            self.applySignIn(record)
            throw failure
        }
        record.remembered = .disabled
        record.rememberedFailure = nil
        try self.signIn.save(record)
        self.applySignIn(record)
    }

    func finishOperation() {
        self.busy = false
        self.current.isRefreshing = false
        let waiters = self.idleWaiters
        self.idleWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

extension TelenetHomeAccount {
    public func perform(_ operation: AccountOperation) async throws {
        switch operation {
        case let .savedSignIn(fence): try await self.savedSignIn(expected: fence)
        case let .disableRememberedSignIn(fence): try self.disableRememberedSignIn(expected: fence)
        case let .logout(fence): try await self.logout(expected: fence)
        case .restore: try self.restore()
        case .refresh: try await self.refresh(serviceID: nil)
        case let .refreshService(id): try await self.refresh(serviceID: id)
        case let .selectService(service):
            try await self.selectService(service)
        case .configure: break
        case .cancel: self.cancel()
        case .refreshHistory, .refreshPoints, .refreshInvoices, .clearPaymentReview,
             .downloadInvoice, .reviewInvoicePayment, .selectBundle:
            throw LiveFailure.requestDenied
        }
    }

    private func selectService(_ service: ServiceKey) async throws {
        guard service.account == self.key, service.kind == .home,
              self.current.account?.services.contains(where: { $0.key == service }) == true
        else {
            throw LiveFailure.invalidSelection
        }
        try await self.refresh(serviceID: service.providerID)
    }

    func acceptLogin(
        api: TelenetAPI, credentials: TelenetCredentials, previous: TelenetSessionRecord,
        metadata: AccountSignInRecord, rememberPassword: Bool,
    ) async throws -> TelenetSessionRecord {
        let generation = self.generation
        let cookies = await api.cookies
        try self.check(generation)
        let connection = ConnectionID()
        let summary = AccountConnectionSummary(clientID: "", username: credentials.username)
        var accepted = try self.signIn.accept(setup: summary, connection: connection, expected: metadata.fence)
        let record = TelenetSessionRecord(account: self.key, connectionID: connection, cookies: cookies,
                                          established: true, nextAttemptAt: previous.nextAttemptAt,
                                          nextAllowedAt: previous.nextAllowedAt,
                                          serverRetryAfter: previous.serverRetryAfter,
                                          rotationPending: true, summary: summary,
                                          signInRevision: accepted.revision)
        try self.saveRecord(record)
        accepted = self.signIn.finishAccepted(accepted, password: credentials.password,
                                              rememberPassword: rememberPassword)
        self.current = self.emptyState(connectionID: record.connectionID)
        self.applySignIn(accepted)
        return record
    }
}
