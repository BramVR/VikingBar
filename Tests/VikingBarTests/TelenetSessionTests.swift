import Foundation
import Testing
@testable import VikingBarCore

struct TelenetSessionTests {
    @Test func `stored cookies refresh home once and restore an hourly deadline without network`() async throws {
        let rig = try HomeRig()
        let account = rig.account()
        try await account.perform(.restore)
        try await account.perform(.refresh)
        let state = await account.state()
        #expect(state.selectedHomeUsage?.downloaded?.totalGB == 60)
        #expect(state.selectedHomeUsage?.policyCounterGB == Decimal(string: "20.25"))
        #expect(state.nextRefreshAt == rig.clock.now.addingTimeInterval(3600))
        #expect(await rig.transport.requests.count == 4)
        let restored = rig.account()
        try await restored.perform(.restore)
        #expect(await restored.state().selectedHomeUsage == state.selectedHomeUsage)
        #expect(await restored.state().nextRefreshAt == state.nextRefreshAt)
        await #expect(throws: LiveFailure.rateLimited) { try await restored.perform(.refresh) }
        #expect(await rig.transport.requests.count == 4)
        #expect(await restored.state().failure == nil)
        #expect(await restored.state().nextRefreshAt == state.nextRefreshAt)
        rig.clock.advance(61)
        try await restored.perform(.refresh)
        #expect(await restored.state().selectedHomeUsage?.fetchedAt == rig.clock.now)
        #expect(await rig.transport.requests.count == 8)
        #expect(await rig.transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func `automatic refresh replaces a removed selection with a discovered home service`() async throws {
        let rig = try HomeRig()
        let account = rig.account()
        try await account.perform(.refresh)
        let connection = await account.state().connectionID
        #expect(await account.state().selectedHomeUsage?.key.providerID == "home-a")
        rig.clock.advance(61)
        try await rig.transport.replaceServices(["home-c"])
        try await account.perform(.refresh)
        let changed = await account.state()
        #expect(changed.account?.services.map(\.key.providerID) == ["home-c"])
        #expect(changed.account?.selectedService?.providerID == "home-c")
        #expect(changed.selectedHomeUsage?.key.providerID == "home-c")
        #expect(changed.selectedHomeUsage?.fetchedAt == rig.clock.now)
        #expect(changed.connectionID == connection)
        let restored = rig.account()
        try await restored.perform(.restore)
        #expect(await restored.state().selectedHomeUsage?.key.providerID == "home-c")
        #expect(await rig.transport.requests.suffix(2).allSatisfy { $0.url?.path.contains("/home-c/") == true })
    }

    @Test func `server retry after survives another process and is never capped`() async throws {
        let rig = try HomeRig()
        let account = rig.account()
        try await account.perform(.refresh)
        let previous = await account.state().selectedHomeUsage
        rig.clock.advance(61)
        await rig.transport.fail(pathSuffix: "/usage", status: 429, retry: "172800")
        await #expect(throws: LiveFailure.rateLimited) { try await account.perform(.refresh) }
        let failed = await account.state()
        #expect(failed.failure == .rateLimited)
        #expect(failed.selectedHomeUsage == previous)
        #expect(failed.nextRefreshAt == rig.clock.now.addingTimeInterval(172_800))
        #expect(try failed.snapshot.freshness == .stale(lastUpdated: #require(previous?.fetchedAt)))
        let requests = await rig.transport.requests.count
        let otherProcess = rig.account()
        try await otherProcess.perform(.restore)
        rig.clock.advance(7200)
        await #expect(throws: LiveFailure.rateLimited) { try await otherProcess.perform(.refresh) }
        #expect(await otherProcess.state().nextRefreshAt == failed.nextRefreshAt)
        #expect(await rig.transport.requests.count == requests)
    }

    @Test func `optional daily rate limit without retry header preserves policy and backs off`() async throws {
        let rig = try HomeRig()
        await rig.transport.fail(pathSuffix: "/dailyusage", status: 429)
        let account = rig.account()
        try await account.perform(.refresh)
        let state = await account.state()
        #expect(state.failure == nil)
        #expect(state.homeFailure == .rateLimited)
        #expect(state.selectedHomeUsage?.policyCounterGB == Decimal(string: "20.25"))
        #expect(state.selectedHomeUsage?.downloaded == nil)
        rig.clock.advance(61)
        await #expect(throws: LiveFailure.rateLimited) { try await rig.account().perform(.refresh) }
        #expect(await rig.transport.requests.count == 4)
    }

    @Test func `unauthorized stored session requires reconnect and never submits credentials`() async throws {
        let rig = try HomeRig()
        let account = rig.account()
        try await account.perform(.refresh)
        rig.clock.advance(61)
        await rig.transport.fail(pathSuffix: "/usage", status: 401)
        await #expect(throws: LiveFailure.unauthorized) { try await account.perform(.refresh) }
        let otherProcess = rig.account()
        try await otherProcess.perform(.restore)
        #expect(await otherProcess.state().failure == .reconnectRequired)
        #expect(await otherProcess.state().nextRefreshAt == nil)
        let count = await rig.transport.requests.count
        rig.clock.advance(9000)
        await #expect(throws: LiveFailure.reconnectRequired) { try await otherProcess.perform(.refresh) }
        #expect(await rig.transport.requests.count == count)
        #expect(await rig.transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    @Test func `switching to a failing service never displays the previous service usage`() async throws {
        let rig = try HomeRig()
        let account = rig.account()
        try await account.perform(.refresh)
        #expect(await account.state().selectedHomeUsage?.key.providerID == "home-a")
        rig.clock.advance(61)
        await rig.transport.fail(pathSuffix: "/usage", status: 500)
        await #expect(throws: LiveFailure.serverUnavailable) {
            try await account.perform(.selectService(ServiceKey(account: rig.key, kind: .home, providerID: "home-b")))
        }
        let state = await account.state()
        #expect(state.account?.selectedService?.providerID == "home-b")
        #expect(state.selectedHomeUsage == nil)
        #expect(state.snapshot.allowance == .unavailable)
        await #expect(throws: LiveFailure.invalidSelection) {
            try await account.perform(.selectService(ServiceKey(
                account: AccountKey(provider: .telenet),
                kind: .home,
                providerID: "home-a",
            )))
        }
    }

    @Test func `changed connection discards cached identity before another request`() async throws {
        let rig = try HomeRig()
        let account = rig.account()
        try await account.perform(.refresh)
        let original = await account.state().connectionID
        rig.clock.advance(61)
        let replacement = ConnectionID()
        try rig.seed(connection: replacement)
        await #expect(throws: LiveFailure.connectionChanged) { try await account.perform(.refresh) }
        #expect(await account.state().connectionID == replacement)
        #expect(await account.state().connectionID != original)
        #expect(await account.state().selectedHomeUsage == nil)
        #expect(await rig.transport.requests.count == 4)
    }

    @Test func `cancellation keeps old usage and attempt floor while another process cannot race the lease`(
    ) async throws {
        let rig = try HomeRig()
        let account = rig.account()
        try await account.perform(.refresh)
        let previous = await account.state().selectedHomeUsage
        rig.clock.advance(61)
        await rig.transport.pauseDaily()
        let task = Task { try await account.perform(.refresh) }
        await rig.transport.waitUntilPaused()
        await #expect(throws: LiveFailure.busy) { try await rig.account().perform(.refresh) }
        await account.cancel()
        await rig.transport.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await account.state().selectedHomeUsage == previous)
        let other = rig.account()
        try await other.perform(.restore)
        await #expect(throws: LiveFailure.rateLimited) { try await other.perform(.refresh) }
        #expect(await rig.transport.requests.count == 8)
    }
}

final class HomeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date {
        self.lock.withLock { self.value }
    }

    func advance(_ seconds: TimeInterval) {
        self.lock.withLock { self.value.addTimeInterval(seconds) }
    }
}

struct HomeRig {
    let key = AccountKey(provider: .telenet)
    let store = MemorySessionStore()
    let cache = MemoryBalanceCache()
    let lease = MemoryLease()
    let transport = HomeTransport()
    let clock = HomeClock()
    init() throws {
        try self.seed(connection: ConnectionID())
    }

    func account() -> TelenetHomeAccount {
        TelenetHomeAccount(key: self.key, transport: self.transport, store: self.store, lease: self.lease,
                           cache: self.cache, now: { self.clock.now })
    }

    func seed(connection: ConnectionID) throws {
        var jar = TelenetCookieJar()
        try jar.receive(TelenetResponse(status: 200, headers: ["Set-Cookie": "session=synthetic; Path=/; Secure"]),
                        from: URL(string: "https://api.prd.telenet.be/ocapi/oauth/userdetails")!, at: self.clock.now)
        try self.store.save(JSONEncoder().encode(Seed(account: self.key, connectionID: connection, cookies: jar)))
    }

    private struct Seed: Encodable {
        let version = 1
        let account: AccountKey
        let connectionID: ConnectionID
        let cookies: TelenetCookieJar
        let established = true
        let failures = 0
        let rotationPending = false
    }
}

actor HomeTransport: TelenetTransport {
    private(set) var requests: [URLRequest] = []
    private var failure: Failure?
    private var loginResponses: [TelenetResponse] = []
    private var discoveryBody = Data(
        #"[{"productType":"internet","identifier":"home-a"},{"productType":"internet","identifier":"home-b"}]"#.utf8,
    )
    private struct Failure { let suffix: String; let code: Int; let retry: String? }
    private var shouldPause = false
    private var paused: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func fail(pathSuffix: String, status: Int, retry: String? = nil) {
        self.failure = Failure(suffix: pathSuffix, code: status, retry: retry)
    }

    func enableLogin() {
        self.loginResponses = TelenetAPITests.loginResponses()
    }

    func clearFailure() {
        self.failure = nil
    }

    func replaceServices(_ services: [String]) throws {
        self.discoveryBody = try JSONSerialization.data(withJSONObject: services.map {
            ["productType": "internet", "identifier": $0]
        })
    }

    func pauseDaily() {
        self.shouldPause = true
    }

    func waitUntilPaused() async {
        if self.paused != nil {
            return
        }
        await withCheckedContinuation { self.waiter = $0 }
    }

    func resume() {
        self.paused?.resume(); self.paused = nil
    }

    func send(_ request: URLRequest) async -> TelenetResponse {
        self.requests.append(request)
        if !self.loginResponses.isEmpty {
            return self.loginResponses.removeFirst()
        }
        let path = request.url!.path
        if path.hasSuffix("/dailyusage"), self.shouldPause {
            self.shouldPause = false
            await withCheckedContinuation { self.paused = $0; self.waiter?.resume(); self.waiter = nil }
        }
        if let failure, path.hasSuffix(failure.suffix) {
            return TelenetResponse(status: failure.code, headers: failure.retry.map { ["Retry-After": $0] } ?? [:])
        }
        let body: Data = if path.hasSuffix("product-subscriptions") {
            self.discoveryBody
        } else if path.hasSuffix("billcycle-details") {
            HomeUsageTests.cycle
        } else if path.hasSuffix("dailyusage") {
            HomeUsageTests.daily
        } else {
            HomeUsageTests.usage()
        }
        return TelenetResponse(status: 200, body: body)
    }
}
