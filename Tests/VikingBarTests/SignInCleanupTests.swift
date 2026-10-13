import Foundation
import Testing
@testable import VikingBarCore

struct SignInCleanupTests {
    @Test func `mobile cleanup retry deletes the session after password deletion already succeeded`() async throws {
        let rig = Rig()
        let connected = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                                       rememberPassword: true)
        _ = try await rig.session.refresh()
        rig.store.failDelete = true
        await #expect(throws: LiveFailure.storage) {
            try await rig.session.logout(expected: #require(connected.signIn?.fence))
        }
        let failed = await rig.session.state()
        #expect(failed.connectionID == nil)
        #expect(failed.signIn?.remembered == .cleanupRequired)
        #expect(failed.signIn?.failure == .storage)
        #expect(rig.secrets.load() == nil)
        rig.store.failDelete = false
        let cleaned = try await rig.session.disableRememberedSignIn(expected: #require(failed.signIn?.fence))
        #expect(cleaned.connectionID == nil)
        #expect(cleaned.signIn?.remembered == .disabled)
        #expect(cleaned.signIn?.failure == nil)
        #expect(rig.store.load() == nil)
        #expect(try await rig.newSession().restore().connectionID == nil)
    }

    @Test func `telenet cleanup retry deletes its remaining session without authenticating`() async throws {
        let rig = try HomeRig()
        await rig.transport.enableLogin()
        let account = rig.account()
        _ = try await account.connect(credentials: .telenet(.init(username: "reader", password: "synthetic")),
                                      rememberPassword: true, expected: nil)
        let connected = await account.state()
        let requests = await rig.transport.requests.count
        rig.store.failDelete = true
        await #expect(throws: LiveFailure.storage) {
            try await account.logout(expected: #require(connected.signIn?.fence))
        }
        let failed = await account.state()
        #expect(failed.connectionID == nil)
        #expect(failed.signIn?.remembered == .cleanupRequired)
        #expect(failed.signIn?.failure == .storage)
        #expect(rig.secrets.load() == nil)
        rig.store.failDelete = false
        try await account.disableRememberedSignIn(expected: #require(failed.signIn?.fence))
        let cleaned = await account.state()
        #expect(cleaned.signIn?.remembered == .disabled)
        #expect(cleaned.signIn?.failure == nil)
        #expect(rig.store.load() == nil)
        #expect(await rig.transport.requests.count == requests)
    }

    @Test func `stopping remembrance leaves the accepted session and usage usable`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrapWithDiagnostics(credentials: LiveSessionTests.credentials,
                                                           rememberPassword: true)
        let connected = try await rig.session.refresh()
        let disabled = try await rig.session.disableRememberedSignIn(expected: #require(connected.signIn?.fence))
        #expect(disabled.connectionID == connected.connectionID)
        #expect(disabled.snapshot.allowance == .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 75))
        #expect(disabled.signIn?.remembered == .disabled)
        #expect(rig.secrets.load() == nil)
        let restarted = rig.newSession()
        let restored = try await restarted.restore()
        #expect(restored.signIn?.remembered == .disabled)
        #expect(restored.signIn?.fence == disabled.signIn?.fence)
        let refreshed = try await restarted.refresh()
        #expect(refreshed.connectionID == connected.connectionID)
        #expect(refreshed.snapshot.allowance == .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 75))
    }
}
