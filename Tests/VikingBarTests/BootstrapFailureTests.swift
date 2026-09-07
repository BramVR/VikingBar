import Foundation
import Testing
@testable import VikingBarCore

struct BootstrapFailureTests {
    @Test(arguments: [200, 400, 401, 403, 429, 500, 503, 404])
    func `token diagnostics retain only an allowlisted code and preserve session failure`(status: Int) async throws {
        let expected: BootstrapFailure = switch status {
        case 400, 401, 403: .tokenRejected
        case 429: .tokenRateLimited
        case 500, 503: .tokenServer
        default: .tokenResponse
        }
        let transport = BootstrapTransport(outcome: .response(status, Data(Self.privateMarker.utf8)))
        let session = Self.session(transport: transport)
        await #expect(throws: expected) {
            try await session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials)
        }
        #expect(await session.state().failure == expected.liveFailure)
        #expect(await transport.calls == 1)
        #expect(!String(describing: expected).contains(Self.privateMarker))
    }

    @Test func `transport and keychain error details never enter diagnostics`() async throws {
        let transport = BootstrapTransport(outcome: .rawError)
        let session = Self.session(transport: transport)
        await #expect(throws: BootstrapFailure.tokenNetwork) {
            try await session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials)
        }
        #expect(await session.state().failure == .transport)
        let store = BootstrapFailingStore()
        let accepted = Self.session(transport: BootstrapTransport(outcome: .response(200, Self.token)), store: store)
        await #expect(throws: BootstrapFailure.keychainWrite) {
            try await accepted.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials)
        }
        #expect(await accepted.state().failure == .storage)
    }

    @Test func `lease storage and exclusivity failures remain distinct before token exchange`() async throws {
        let transport = BootstrapTransport(outcome: .rawError)
        let inaccessible = Self.session(transport: transport, lease: BootstrapFailingLease())
        await #expect(throws: BootstrapFailure.localFilesystem) {
            try await inaccessible.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials)
        }
        let lease = MemoryLease()
        let handle = try lease.acquire()
        defer { handle.release() }
        let busy = Self.session(transport: transport, lease: lease)
        await #expect(throws: BootstrapFailure.sessionBusy) {
            try await busy.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials)
        }
        #expect(await inaccessible.state().failure == .storage)
        #expect(await busy.state().failure == .busy)
        #expect(await transport.calls == 0)
    }

    @Test func `invalid credentials are diagnosed without a token request`() async throws {
        let transport = BootstrapTransport(outcome: .rawError)
        let session = Self.session(transport: transport)
        let invalid = ProofCredentials(clientID: "", username: Self.privateMarker, password: Self.privateMarker)
        await #expect(throws: BootstrapFailure.credentialInput) {
            try await session.bootstrapWithDiagnostics(credentials: invalid)
        }
        #expect(await session.state().failure == .malformedResponse)
        #expect(await transport.calls == 0)
    }

    @Test func `legacy bootstrap callers still receive LiveFailure and cancellation types`() async throws {
        let rejected = Self.session(transport: BootstrapTransport(outcome: .response(401, Self.token)))
        await #expect(throws: LiveFailure.unauthorized) {
            try await rejected.bootstrap(credentials: LiveSessionTests.credentials)
        }
        let unavailable = Self.session(transport: BootstrapTransport(outcome: .rawError))
        await #expect(throws: LiveFailure.transport) {
            try await unavailable.bootstrap(credentials: LiveSessionTests.credentials)
        }
        let cancelled = Self.session(transport: BootstrapTransport(outcome: .cancel))
        await #expect(throws: CancellationError.self) {
            try await cancelled.bootstrap(credentials: LiveSessionTests.credentials)
        }
        await #expect(throws: BootstrapFailure.connectCancelled) {
            try await cancelled.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials)
        }
        #expect(await cancelled.state().failure == nil)
    }

    @Test func `bootstrap flight reports busy and cancellation saves received replacement`() async throws {
        let rig = Rig()
        await rig.transport.pauseNext()
        let connecting = Task {
            try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials)
        }
        await rig.transport.waitUntilPaused()
        await #expect(throws: BootstrapFailure.sessionBusy) {
            try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials)
        }
        await rig.session.cancel()
        await rig.transport.resume()
        await #expect(throws: BootstrapFailure.connectCancelled) { try await connecting.value }
        #expect(rig.store.saveCount == 1)
        #expect(await rig.session.state().connectionID == nil)
    }

    @Test func `failure recovery cannot replace the original bootstrap diagnostic`() async throws {
        let transport = BootstrapTransport(outcome: .response(429, Self.token))
        let session = Self.session(transport: transport, store: BootstrapFailingStore())
        await #expect(throws: BootstrapFailure.tokenRateLimited) {
            try await session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials)
        }
        #expect(await session.state().failure == .rateLimited)
    }

    @Test func `unknown diagnostic inputs cannot export descriptions or extra fields`() throws {
        let unknown = Self.privateError()
        #expect(BootstrapFailure.tokenFailure(unknown) == .connectFailed)
        #expect(BootstrapFailure.allCases.count == 11)
        for failure in BootstrapFailure.allCases {
            let encoded = try JSONEncoder().encode(failure)
            #expect(try JSONDecoder().decode(String.self, from: encoded) == failure.rawValue)
            #expect(failure.description == failure.rawValue)
            #expect(!failure.description.contains(Self.privateMarker))
        }
    }

    static let privateMarker = "DO_NOT_EXPORT_PROVIDER_BODY_OR_SECRET"
    static let token = Data("""
    {"access_token":"synthetic-access","refresh_token":"synthetic-refresh",
    "token_type":"Bearer","expires_in":599,"scope":"read"}
    """.utf8)

    static func privateError() -> NSError {
        NSError(domain: self.privateMarker, code: 9191, userInfo: [NSLocalizedDescriptionKey: self.privateMarker])
    }

    private static func session(
        transport: any ProofHTTPTransport,
        store: any SessionStore = MemorySessionStore(), lease: any SessionLease = MemoryLease(),
    ) -> VikingSession {
        VikingSession(transport: transport, store: store, lease: lease, cache: MemoryBalanceCache())
    }
}

private actor BootstrapTransport: ProofHTTPTransport {
    enum Outcome: Sendable { case response(Int, Data), rawError, cancel }
    let outcome: Outcome
    private(set) var calls = 0

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func send(_: URLRequest) async throws -> ProofHTTPResponse {
        self.calls += 1
        switch self.outcome {
        case let .response(status, data): return ProofHTTPResponse(statusCode: status, data: data)
        case .rawError: throw BootstrapFailureTests.privateError()
        case .cancel: throw CancellationError()
        }
    }
}

private struct BootstrapFailingStore: SessionStore {
    func load() throws -> Data? {
        throw BootstrapFailureTests.privateError()
    }

    func save(_: Data) throws {
        throw BootstrapFailureTests.privateError()
    }
}

private struct BootstrapFailingLease: SessionLease {
    func acquire() throws -> any SessionLeaseHandle {
        throw BootstrapFailureTests.privateError()
    }
}
