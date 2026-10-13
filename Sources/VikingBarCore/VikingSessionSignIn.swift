import Foundation

public extension VikingSession {
    internal func applySignIn(_ record: AccountSignInRecord) {
        if let connection = self.current.connectionID, connection != record.fence.connectionID {
            self.token = nil
            self.tokenGeneration = nil
            self.current = LiveSessionState()
        }
        self.current.signIn = record.presentation
        self.current.connectionSummary = record.summary ?? self.current.connectionSummary
    }

    func savedSignIn(expected: AccountMutationFence) async throws -> LiveSessionState {
        guard self.flight == nil else { throw LiveFailure.busy }
        let credentials: ProofCredentials
        let selectedSubscription: String?
        let reservation: PasswordAttemptReservation
        do {
            let handle = try self.lease.acquire()
            defer { handle.release() }
            let record = try self.signIn.checked(expected)
            let prior = expected.connectionID.flatMap { try? self.cache.load(connectionID: $0) }
            selectedSubscription = self.current.connectionID == expected.connectionID
                ? self.current.selectedSubscriptionID : prior?.selectedSubscriptionID
            guard self.api.now() >= record.nextPasswordAttemptAt ?? .distantPast else { throw LiveFailure.rateLimited }
            let reserved = try self.signIn.reservePasswordAttempt(expected: expected, now: self.api.now())
            guard let id = reserved.passwordAttemptID else { throw LiveFailure.storage }
            reservation = PasswordAttemptReservation(fence: reserved.fence, id: id)
            self.applySignIn(reserved)
            let envelope = try self.signIn.credentials(record: reserved)
            credentials = ProofCredentials(clientID: envelope.summary.clientID,
                                           username: envelope.summary.username ?? "", password: envelope.password)
        }
        return try await self.bootstrapSaved(credentials: credentials, reservation: reservation,
                                             selectedSubscription: selectedSubscription)
    }

    private func bootstrapSaved(
        credentials: ProofCredentials, reservation: PasswordAttemptReservation, selectedSubscription: String?,
    ) async throws -> LiveSessionState {
        self.generation &+= 1
        return try await self.run(kind: .bootstrap) { generation in
            try await self.connectSaved(credentials: credentials, reservation: reservation,
                                        selectedSubscription: selectedSubscription, generation: generation)
        }
    }

    private func connectSaved(
        credentials: ProofCredentials, reservation: PasswordAttemptReservation, selectedSubscription: String?,
        generation: UInt64,
    ) async throws -> LiveSessionState {
        _ = try await self.connect(credentials: credentials, rememberPassword: true, expected: reservation.fence,
                                   generation: generation, reservation: reservation)
        self.current.selectedSubscriptionID = selectedSubscription
        return try await self.fetch(subscriptionID: nil, generation: generation, forceTokenRefresh: false)
    }

    func disableRememberedSignIn(expected: AccountMutationFence) throws -> LiveSessionState {
        guard self.flight == nil else { throw LiveFailure.busy }
        let handle = try self.lease.acquire()
        defer {
            if let record = try? self.signIn.load() {
                if self.current.connectionID != record.fence.connectionID {
                    self.token = nil
                    self.tokenGeneration = nil
                    self.current = LiveSessionState()
                    self.current.connectionID = record.fence.connectionID
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
        return self.current
    }

    func logout(expected: AccountMutationFence) async throws -> LiveSessionState {
        _ = try self.signIn.checked(expected)
        self.cancel()
        _ = try? await self.flight?.task.value
        let handle = try self.lease.acquire()
        defer { handle.release() }
        _ = try self.signIn.checked(expected)
        defer {
            self.token = nil
            self.tokenGeneration = nil
            self.current = LiveSessionState()
            if let record = try? self.signIn.load() {
                self.applySignIn(record)
            }
        }
        _ = try self.signIn.logout(expected: expected)
        try self.cleanupLogout()
        var result = LiveSessionState()
        let record = try self.signIn.load()
        result.signIn = record.presentation
        result.connectionSummary = record.summary
        return result
    }

    internal func cleanupLogout() throws {
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
}

extension VikingSession {
    func readWithRecovery<Value: Sendable>(
        generation: UInt64, connection: ConnectionID?,
        read: @Sendable (LiveToken) async throws -> Value,
    ) async throws -> Value {
        guard let token = self.token else { throw LiveFailure.tokenExpired }
        do { return try await read(token) } catch LiveFailure.accessRejected, LiveFailure.tokenExpired {
            guard !self.renewalAttempted else { throw LiveFailure.unauthorized }
            self.renewalAttempted = true
            let renewed = try await self.authorize(force: true, generation: generation,
                                                   expectedConnectionID: connection, preserveUsage: true)
            do { return try await read(renewed) } catch LiveFailure.accessRejected { throw LiveFailure.unauthorized }
        }
    }
}
