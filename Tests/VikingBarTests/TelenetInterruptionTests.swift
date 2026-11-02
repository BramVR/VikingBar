import Foundation
import Testing
@testable import VikingBarCore

struct TelenetInterruptionTests {
    @Test func `refresh interrupted after its reservation keeps the stored session working`() async throws {
        let rig = try HomeRig()
        try await rig.account().perform(.refresh)
        rig.clock.advance(61)
        let interrupted = try await rig.interrupt(pausing: "/dailyusage") { try await $0.perform(.refresh) }
        let restarted = rig.account()
        try await restarted.perform(.restore)
        #expect(await restarted.state().failure == nil)
        await #expect(throws: LiveFailure.rateLimited) { try await restarted.perform(.refresh) }
        rig.clock.advance(61)
        try await restarted.perform(.refresh)
        #expect(await restarted.state().failure == nil)
        #expect(await restarted.state().selectedHomeUsage?.fetchedAt == rig.clock.now)
        await interrupted.finish()
    }

    @Test func `replacement login interrupted before Telenet answers keeps the previous session`() async throws {
        let rig = try HomeRig()
        let first = rig.account()
        try await first.perform(.refresh)
        let original = await first.state()
        rig.clock.advance(61)
        await rig.transport.enableLogin()
        let interrupted = try await rig.interrupt(pausing: "/challenge/answer") {
            _ = try await $0.connect(credentials: .telenet(TelenetCredentials(username: "reader", password: "correct")))
        }
        await rig.transport.disableLogin()
        let restarted = rig.account()
        try await restarted.perform(.restore)
        #expect(await restarted.state().connectionID == original.connectionID)
        #expect(await restarted.state().failure == nil)
        rig.clock.advance(61)
        try await restarted.perform(.refresh)
        #expect(await restarted.state().connectionID == original.connectionID)
        #expect(await restarted.state().selectedHomeUsage?.fetchedAt == rig.clock.now)
        await interrupted.finish()
    }

    @Test func `reconnect interrupted after login keeps the new session working`() async throws {
        let rig = try HomeRig()
        let first = rig.account()
        try await first.perform(.refresh)
        let original = await first.state()
        rig.clock.advance(61)
        await rig.transport.enableLogin()
        let interrupted = try await rig.interrupt(pausing: "/dailyusage") {
            _ = try await $0.connect(credentials: .telenet(TelenetCredentials(username: "reader", password: "correct")))
        }
        let restarted = rig.account()
        try await restarted.perform(.restore)
        let connection = await restarted.state().connectionID
        #expect(connection != original.connectionID)
        #expect(await restarted.state().failure == nil)
        rig.clock.advance(61)
        try await restarted.perform(.refresh)
        #expect(await restarted.state().connectionID == connection)
        #expect(await restarted.state().selectedHomeUsage?.fetchedAt == rig.clock.now)
        await interrupted.finish()
    }

    @Test func `refresh whose final saves fail keeps the stored session working`() async throws {
        let rig = try HomeRig()
        try await rig.account().perform(.refresh)
        rig.clock.advance(61)
        let outage = TelenetHomeAccount(
            key: rig.key, transport: rig.transport, store: SaveOutageStore(base: rig.store, allowedSaves: 1),
            lease: rig.lease, cache: rig.cache, now: { rig.clock.now },
        )
        await #expect(throws: LiveFailure.storage) { try await outage.perform(.refresh) }
        let restarted = rig.account()
        try await restarted.perform(.restore)
        #expect(await restarted.state().failure == nil)
        rig.clock.advance(61)
        try await restarted.perform(.refresh)
        #expect(await restarted.state().selectedHomeUsage?.fetchedAt == rig.clock.now)
    }
}

struct InterruptedRequest {
    let account: TelenetHomeAccount
    let transport: HomeTransport
    let task: Task<Void, any Error>

    func finish() async {
        await self.account.cancel()
        await self.transport.resume()
        _ = try? await self.task.value
    }
}

extension HomeRig {
    /// Leaves the request in flight and frees the lease, as when the process ends mid-request.
    func interrupt(
        pausing pathSuffix: String, _ operation: @escaping @Sendable (TelenetHomeAccount) async throws -> Void,
    ) async throws -> InterruptedRequest {
        let account = self.account()
        await self.transport.pause(pathSuffix: pathSuffix)
        let task = Task { try await operation(account) }
        await self.transport.waitUntilPaused()
        self.lease.release()
        return InterruptedRequest(account: account, transport: self.transport, task: task)
    }
}

/// Accepts the first saves, then fails every later Keychain write.
private final class SaveOutageStore: SessionStore, @unchecked Sendable {
    private let base: MemorySessionStore
    private let lock = NSLock()
    private var allowedSaves: Int

    init(base: MemorySessionStore, allowedSaves: Int) {
        self.base = base
        self.allowedSaves = allowedSaves
    }

    func load() -> Data? {
        self.base.load()
    }

    func save(_ data: Data) throws {
        try self.lock.withLock {
            guard self.allowedSaves > 0 else { throw LiveFailure.storage }
            self.allowedSaves -= 1
            try self.base.save(data)
        }
    }
}
