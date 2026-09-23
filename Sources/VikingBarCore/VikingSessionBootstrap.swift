import Foundation

public extension VikingSession {
    static func production(
        transport: any ProofHTTPTransport = EphemeralProofTransport(),
        account: AccountKey? = nil,
    ) throws -> VikingSession {
        let catalog = try AccountCatalog.production()
        let key = try catalog.resolve(account, provider: .mobileVikings)
        let storage = AccountStorage(root: catalog.root, key: key)
        return try Self.production(storage: storage, transport: transport)
    }

    static func production(
        storage: AccountStorage,
        transport: any ProofHTTPTransport = EphemeralProofTransport(),
    ) throws -> VikingSession {
        guard storage.key.provider == .mobileVikings else { throw LiveFailure.invalidSelection }
        try storage.prepare()
        return VikingSession(
            transport: transport, store: KeychainSessionStore(account: storage.keychainAccount),
            lease: FileSessionLease(url: storage.leaseURL),
            cache: FileBalanceCache(url: storage.cacheURL),
            paymentQRRenderer: PaymentQRHelper(executableURL: PaymentQRHelper.productionExecutableURL()),
        )
    }

    func bootstrap(credentials: ProofCredentials) async throws -> LiveSessionState {
        do {
            return try await self.bootstrapWithDiagnostics(credentials: credentials)
        } catch let failure as BootstrapFailure {
            if failure == .connectCancelled {
                throw CancellationError()
            }
            throw failure.liveFailure
        }
    }
}
