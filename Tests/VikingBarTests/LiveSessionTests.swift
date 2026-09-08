import Foundation
import Testing
@testable import VikingBarCore

struct LiveSessionTests {
    @Test func `bootstrap persists only token and refresh shares one operation`() async throws {
        let rig = Rig()
        let connected = try await rig.session.bootstrap(credentials: Self.credentials)
        #expect(connected.connectionID != nil)
        #expect(await rig.transport.paths() == ["/mv/oauth2/token"])
        await rig.transport.pauseNext()
        let first = Task { try await rig.session.refresh() }
        await rig.transport.waitUntilPaused()
        let second = Task { try await rig.session.refresh() }
        await rig.transport.resume()
        let values = try await [first.value, second.value]
        #expect(values.allSatisfy { !$0.isRefreshing })
        #expect(values.allSatisfy { $0.snapshot.allowance == .finite(
            totalBytes: 100, usedBytes: 25, remainingBytes: 75,
        ) })
        #expect(await rig.transport.paths().count == 3)
        #expect(rig.store.saveCount == 1)
    }

    @Test func `rotated token saves before balance and relaunch uses replacement`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: Self.credentials)
        _ = try await rig.session.refresh(forceTokenRefresh: true)
        #expect(rig.store.saveCount == 3)
        let record = try #require(rig.store.load())
        let recordText = try #require(String(bytes: record, encoding: .utf8))
        #expect(recordText.contains("refresh-2"))
        let relaunched = rig.newSession()
        let restored = try await relaunched.restore()
        #expect(restored.balance != nil)
        #expect(restored.snapshot.freshness == .current(lastUpdated: LiveModelsTests.now))
        _ = try await relaunched.refresh()
        #expect(await rig.transport.refreshInputs() == ["refresh-1", "refresh-2"])
    }

    @Test func `failed replacement save leaves marker and prevents further token requests`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: Self.credentials)
        rig.store.failOnSave = 3
        await #expect(throws: LiveFailure.reconnectRequired) { try await rig.session.refresh(forceTokenRefresh: true) }
        let calls = await rig.transport.paths().count
        let relaunched = rig.newSession()
        await #expect(throws: LiveFailure.reconnectRequired) { try await relaunched.restore() }
        await #expect(throws: LiveFailure.reconnectRequired) { try await rig.session.refresh() }
        #expect(await rig.transport.paths().count == calls)
    }

    @Test func `failed pending save does not spend refresh token`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: Self.credentials)
        rig.store.failOnSave = 2
        await #expect(throws: LiveFailure.storage) { try await rig.session.refresh(forceTokenRefresh: true) }
        #expect(await rig.transport.paths().count == 1)
    }

    @Test func `ambiguous refresh outcome persists reconnect requirement across restart`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: Self.credentials)
        await rig.transport.failNext(code: 503)
        await #expect(throws: LiveFailure.reconnectRequired) { try await rig.session.refresh(forceTokenRefresh: true) }
        let relaunched = rig.newSession()
        await #expect(throws: LiveFailure.reconnectRequired) { try await relaunched.restore() }
        #expect(await rig.transport.paths().count == 2)
    }

    @Test func `balance failure retains successful values with backoff`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: Self.credentials)
        let good = try await rig.session.refresh()
        await rig.transport.failNext(code: 429)
        await #expect(throws: LiveFailure.rateLimited) { try await rig.session.refresh() }
        let failed = await rig.session.state()
        #expect(failed.snapshot.allowance == good.snapshot.allowance)
        #expect(failed.nextRefreshAt == LiveModelsTests.now.addingTimeInterval(30))
        if case .stale = failed.snapshot.freshness {} else {
            Issue.record("Successful balance must be stale")
        }
    }

    @Test func `explicit login discards earlier connection cache even for same SIM identifiers`() async throws {
        let rig = Rig()
        let first = try await rig.session.bootstrap(credentials: Self.credentials)
        _ = try await rig.session.refresh()
        let second = try await rig.session.bootstrap(credentials: Self.credentials)
        #expect(first.connectionID != second.connectionID)
        #expect(second.balance == nil)
        let restored = try await rig.newSession().restore()
        #expect(restored.connectionID == second.connectionID)
        #expect(restored.balance == nil)
    }

    @Test func `sim selection drains old fetch before publishing selected SIM`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: Self.credentials)
        _ = try await rig.session.refresh()
        await rig.transport.pauseNext()
        let old = Task { try await rig.session.refresh() }
        await rig.transport.waitUntilPaused()
        let selected = Task { try await rig.session.selectSubscription(id: "sim-b") }
        await Task.yield()
        await rig.transport.resume()
        _ = try? await old.value
        let result = try await selected.value
        #expect(result.selectedSubscriptionID == "sim-b")
        #expect(result.snapshot.subscriptionName == "Second")
        #expect(await rig.transport.paths().last == "/mv/subscriptions/sim-b/balance")
    }

    @Test func `cancellation after receiving rotated token still saves replacement`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: Self.credentials)
        await rig.transport.pauseNext()
        let task = Task { try await rig.session.refresh(forceTokenRefresh: true) }
        await rig.transport.waitUntilPaused()
        await rig.session.cancel()
        await rig.transport.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        let record = try #require(rig.store.load())
        let recordText = try #require(String(bytes: record, encoding: .utf8))
        #expect(recordText.contains("refresh-2"))
        #expect(!recordText.contains("\"rotationPending\":true"))
        #expect(await rig.session.state().balance == nil)
    }

    @Test func `file lease is exclusive and releases without touching other paths`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = FileSessionLease(url: directory.appendingPathComponent("session.lock"))
        let second = FileSessionLease(url: directory.appendingPathComponent("session.lock"))
        let handle = try first.acquire()
        #expect(throws: LiveFailure.busy) { try second.acquire() }
        handle.release()
        let next = try second.acquire()
        next.release()
    }

    static let credentials = ProofCredentials(clientID: "test-client", username: "test-user", password: "test-password")
}

struct Rig {
    let transport = LiveTransport()
    let store = MemorySessionStore()
    let cache = MemoryBalanceCache()
    let lease = MemoryLease()
    let session: VikingSession
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { LiveModelsTests.now }) {
        self.now = now
        self.session = VikingSession(
            transport: self.transport, store: self.store, lease: self.lease, cache: self.cache,
            now: now,
        )
    }

    func newSession() -> VikingSession {
        VikingSession(
            transport: self.transport, store: self.store, lease: self.lease, cache: self.cache,
            now: self.now,
        )
    }
}

final class MemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var saves = 0
    private var failedSave: Int?

    var saveCount: Int {
        self.lock.withLock { self.saves }
    }

    var failOnSave: Int? {
        get { self.lock.withLock { self.failedSave } }
        set { self.lock.withLock { self.failedSave = newValue } }
    }

    func load() -> Data? {
        self.lock.withLock { self.data }
    }

    func save(_ data: Data) throws {
        try self.lock.withLock {
            self.saves += 1
            if self.saves == self.failedSave {
                throw LiveFailure.storage
            }
            self.data = data
        }
    }
}

final class MemoryBalanceCache: BalanceCache, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LiveSessionState?

    func load(connectionID: ConnectionID) -> LiveSessionState? {
        self.lock.withLock { self.stored?.connectionID == connectionID ? self.stored : nil }
    }

    func save(_ state: LiveSessionState) {
        self.lock.withLock { self.stored = state }
    }
}

final class MemoryLease: SessionLease, SessionLeaseHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var held = false

    func acquire() throws -> any SessionLeaseHandle {
        try self.lock.withLock {
            guard !self.held else { throw LiveFailure.busy }
            self.held = true
            return self
        }
    }

    func release() {
        self.lock.withLock { self.held = false }
    }
}

actor LiveTransport: ProofHTTPTransport {
    private var requests: [URLRequest] = []
    private var tokens = 0
    private var pause = false
    private var pausePath: String?
    private var paused: CheckedContinuation<Void, any Error>?
    private var pauseID: UUID?
    private var cancelPause = false
    private(set) var cancellations = 0
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    private var failure: Int?
    private var responses: [String: String] = [:]
    private var balanceFailure: Int?
    private var responseAction: ResponseAction?

    func actBeforeResponse(path: String, count: Int = 1, action: @escaping @Sendable () -> Void) {
        self.responseAction = ResponseAction(path: path, remaining: count, action: action)
    }

    func setResponse(path: String, json: String) {
        self.responses[path] = json
    }

    func failBalance(code: Int) {
        self.balanceFailure = code
    }

    func pauseNext(path: String? = nil, cancellable: Bool = false) {
        self.pause = true
        self.pausePath = path
        self.cancelPause = cancellable
    }

    func failNext(code: Int) {
        self.failure = code
    }

    func paths() -> [String] {
        self.requests.compactMap { $0.url?.path }
    }

    func refreshInputs() -> [String] {
        self.requests.compactMap { request in
            guard let body = String(bytes: request.httpBody ?? Data(), encoding: .utf8) else {
                Issue.record("Request body must contain valid UTF-8")
                return nil
            }
            return body.split(separator: "&").first(where: { $0.hasPrefix("refresh_token=") })
                .map { String($0.dropFirst("refresh_token=".count)) }
        }
    }

    func waitUntilPaused() async {
        if self.paused != nil {
            return
        }
        await withCheckedContinuation { self.pauseWaiter = $0 }
    }

    func resume() {
        self.paused?.resume()
        self.paused = nil
        self.pauseID = nil
    }

    private func cancelPaused(id: UUID) {
        guard self.pauseID == id else { return }
        self.cancellations += 1
        self.paused?.resume(throwing: CancellationError())
        self.paused = nil
        self.pauseID = nil
    }

    private func suspendIfNeeded(path: String?) async throws {
        let matchesPause = self.pausePath == nil || self.pausePath == path
        if self.pause, matchesPause {
            self.pause = false
            let id = UUID()
            let cancellable = self.cancelPause
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    self.pauseID = id
                    self.paused = $0
                    self.pauseWaiter?.resume()
                    self.pauseWaiter = nil
                }
                if cancellable {
                    try Task.checkCancellation()
                }
            } onCancel: {
                if cancellable {
                    Task { await self.cancelPaused(id: id) }
                }
            }
        }
    }

    func send(_ request: URLRequest) async throws -> ProofHTTPResponse {
        try ProofEndpoint.validate(request)
        self.requests.append(request)
        try await self.suspendIfNeeded(path: request.url?.path)
        if let failure = self.failure {
            self.failure = nil
            return ProofHTTPResponse(statusCode: failure, data: Data())
        }
        if request.url?.path.hasSuffix("/balance") == true, let code = self.balanceFailure {
            self.balanceFailure = nil
            return ProofHTTPResponse(statusCode: code, data: Data())
        }
        let json: String
        if let override = self.responses[request.url?.path ?? ""] {
            json = override
        } else if request.httpMethod == "POST" {
            self.tokens += 1
            json = """
            {"access_token":"access-\(self.tokens)","refresh_token":"refresh-\(self.tokens)",
            "token_type":"Bearer","expires_in":599,"scope":"read write"}
            """
        } else if request.url?.path == "/mv/subscriptions" {
            json = LiveModelsTests.subscriptions
        } else {
            json = "{\"bundles\":[\(LiveModelsTests.bundle())]}"
        }
        if var action = self.responseAction, action.path == request.url?.path {
            action.action()
            action.remaining -= 1
            self.responseAction = action.remaining > 0 ? action : nil
        }
        return ProofHTTPResponse(statusCode: 200, data: Data(json.utf8))
    }
}

private struct ResponseAction {
    let path: String
    var remaining: Int
    let action: @Sendable () -> Void
}
