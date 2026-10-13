import Foundation
import Testing
@testable import VikingBarCore

struct Rig {
    let transport = LiveTransport()
    let store = MemorySessionStore()
    let cache = MemoryBalanceCache()
    let metadata = MemorySessionStore()
    let secrets = MemorySessionStore()
    let lease = MemoryLease()
    let session: VikingSession
    let clock = LiveTestClock()
    private let now: @Sendable () -> Date

    init(now: (@Sendable () -> Date)? = nil) {
        let clock = self.clock
        let now = now ?? { clock.now() }
        self.now = now
        self.session = VikingSession(
            transport: self.transport, store: self.store, lease: self.lease, cache: self.cache,
            signInStore: self.metadata, rememberedStore: self.secrets,
            now: now,
        )
    }

    func newSession() -> VikingSession {
        VikingSession(
            transport: self.transport, store: self.store, lease: self.lease, cache: self.cache,
            signInStore: self.metadata, rememberedStore: self.secrets,
            now: self.now,
        )
    }
}

final class MemorySessionStore: SessionStore, @unchecked Sendable {
    var failDelete = false
    func delete() throws {
        self.lock.lock(); defer { self.lock.unlock() }
        guard !self.failDelete else { throw LiveFailure.storage }
        self.data = nil
    }

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
    func delete() throws {
        self.lock.withLock { self.stored = nil }
    }

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
    private var successesBeforeFailure = 0
    private var responses: [String: String] = [:]
    private var balanceFailure: Int?
    private var balanceFailuresRemaining = 0
    private var responseAction: ResponseAction?

    func actBeforeResponse(path: String, count: Int = 1, action: @escaping @Sendable () -> Void) {
        self.responseAction = ResponseAction(path: path, remaining: count, action: action)
    }

    func setResponse(path: String, json: String) {
        self.responses[path] = json
    }

    func failBalance(code: Int, count: Int = 1) {
        self.balanceFailure = code
        self.balanceFailuresRemaining = count
    }

    func pauseNext(path: String? = nil, cancellable: Bool = false) {
        self.pause = true
        self.pausePath = path
        self.cancelPause = cancellable
    }

    func failNext(code: Int, after successes: Int = 0) {
        self.failure = code
        self.successesBeforeFailure = successes
    }

    func recordedRequests() -> [URLRequest] {
        self.requests
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
        if let failure = self.failure, self.successesBeforeFailure == 0 {
            self.failure = nil
            return ProofHTTPResponse(statusCode: failure, data: Data())
        }
        if self.failure != nil {
            self.successesBeforeFailure -= 1
        }
        if request.url?.path.hasSuffix("/balance") == true, let code = self.balanceFailure {
            self.balanceFailuresRemaining -= 1
            if self.balanceFailuresRemaining == 0 {
                self.balanceFailure = nil
            }
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
