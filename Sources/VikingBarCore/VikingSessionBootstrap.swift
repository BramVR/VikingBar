import Foundation

public extension VikingSession {
    static func production(
        transport: any ProofHTTPTransport = EphemeralProofTransport(),
    ) throws -> VikingSession {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true,
        ).appendingPathComponent("VikingBar", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700],
        )
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw LiveFailure.storage
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return VikingSession(
            transport: transport, store: KeychainSessionStore(),
            lease: FileSessionLease(url: directory.appendingPathComponent("session.lock")),
            cache: FileBalanceCache(url: directory.appendingPathComponent("balance-v1.json")),
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
