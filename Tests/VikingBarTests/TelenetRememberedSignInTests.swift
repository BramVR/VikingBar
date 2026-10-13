import Foundation
import Testing
@testable import VikingBarCore

struct TelenetRememberedSignInTests {
    @Test func `cancelled home acceptance cannot advance the durable login fence`() async throws {
        let rig = try HomeRig()
        let account = rig.account()
        try await account.perform(.restore)
        let persistence = AccountSignInPersistence(key: rig.key, store: rig.metadata, secrets: rig.secrets)
        let before = try persistence.load()
        let previous = try JSONDecoder().decode(TelenetSessionRecord.self, from: #require(rig.store.load()))
        let api = TelenetAPI(transport: rig.transport, now: { rig.clock.now })
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await account.acceptLogin(api: api, credentials: .init(username: "replacement",
                                                                              password: "synthetic"),
                                                 previous: previous, metadata: before, rememberPassword: true)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try persistence.load() == before)
        #expect(try JSONDecoder().decode(TelenetSessionRecord.self,
                                         from: #require(rig.store.load())).connectionID == previous.connectionID)
        #expect(rig.secrets.load() == nil)
    }

    @Test(arguments: [false, true])
    func `accepted home usage survives password storage and publication faults`(publication: Bool) async throws {
        let rig = try HomeRig()
        if publication {
            rig.metadata.failOnSave = 6
        } else {
            rig.secrets.failOnSave = 1
        }
        await rig.transport.enableLogin()
        let account = rig.account()
        let connection = try await account.connect(
            credentials: .telenet(.init(username: "reader", password: "synthetic")),
            rememberPassword: true,
            expected: nil,
        )
        let connected = await account.state()
        #expect(connected.connectionID == connection)
        #expect(connected.connectionSummary?.username == "reader")
        #expect(connected.selectedHomeUsage?.downloaded?.totalGB == 60)
        #expect(connected.signIn?.remembered == .disabled)
        #expect(connected.signIn?.failure == .storage)
        #expect(rig.secrets.saveCount == 1)
        let restarted = rig.account()
        try await restarted.perform(.restore)
        let restored = await restarted.state()
        #expect(restored.connectionID == connection)
        #expect(restored.selectedHomeUsage?.downloaded?.totalGB == 60)
        #expect(restored.signIn?.remembered == .disabled)
        rig.clock.advance(61)
        try await restarted.perform(.refresh)
        #expect(await restarted.state().selectedHomeUsage?.fetchedAt == rig.clock.now)
    }
}
