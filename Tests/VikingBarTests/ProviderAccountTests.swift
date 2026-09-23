import Foundation
import Testing
@testable import VikingBarCore

struct ProviderAccountTests {
    @Test func `two mobile slots keep credentials rotations selections and caches isolated`() async throws {
        let first = Rig()
        let second = Rig()
        let key = AccountKey(provider: .mobileVikings)
        let one = MobileVikingsAccount(key: .legacy, session: first.session)
        let two = MobileVikingsAccount(key: key, session: second.session)
        let firstConnection = try await one.connect(credentials: .mobileVikings(ProofCredentials(
            clientID: "client-a", username: "account-a",
            password: "synthetic-a",
        )))
        let secondConnection = try await two.connect(credentials: .mobileVikings(ProofCredentials(
            clientID: "client-b", username: "account-b",
            password: "synthetic-b",
        )))
        try await one.perform(.refresh)
        await second.transport.setResponse(path: "/mv/subscriptions/sim-a/balance", json:
            "{\"bundles\":[\(LiveModelsTests.bundle().replacingOccurrences(of: "75", with: "55"))]}")
        try await two.perform(.refresh)
        let old = await one.state()
        let other = await two.state()
        #expect(old.account?.selectedService?.providerID == other.account?.selectedService?.providerID)
        #expect(old.account?.selectedService != other.account?.selectedService)
        #expect(old.connectionSummary?.username == "account-a")
        #expect(other.connectionSummary?.username == "account-b")
        #expect(firstConnection != secondConnection)
        #expect(old.snapshot.allowance == .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 75))
        #expect(other.snapshot.allowance == .finite(totalBytes: 100, usedBytes: 25, remainingBytes: 55))
        await #expect(throws: LiveFailure.invalidSelection) {
            try await two.perform(.selectService(#require(old.account?.selectedService)))
        }
        let bytes = second.store.load()
        first.store.failOnSave = first.store.saveCount + 2
        await #expect(throws: LiveFailure.reconnectRequired) { try await first.session.refresh(forceTokenRefresh: true)
        }
        #expect(second.store.load() == bytes)
        try await two.perform(.refresh)
        #expect(await two.state().failure == nil)
        let restored = try await second.newSession().restore()
        #expect(restored.connectionID == secondConnection)
        #expect(restored.selectedSubscriptionID == other.selectedSubscriptionID)
        let reconnected = try await two.connect(credentials: .mobileVikings(ProofCredentials(
            clientID: "client-b", username: "account-b",
            password: "synthetic-b",
        )))
        #expect(reconnected != secondConnection)
        #expect(await two.state().account?.key == key)
        #expect(await one.state().connectionID == firstConnection)
    }

    @Test func `targeted refresh bypasses failing prior SIM balance while discovering subscriptions`() async throws {
        let rig = Rig()
        let account = MobileVikingsAccount(key: .legacy, session: rig.session)
        _ = try await account.connect(credentials: .mobileVikings(ProofCredentials(
            clientID: "synthetic-client", username: "synthetic-account", password: "synthetic-password",
        )))
        await rig.transport.setResponse(path: "/mv/subscriptions", json:
            "[{\"id\":\"sim-a\",\"type\":\"prepaid\",\"sim\":{\"alias\":\"Original\"}}]")
        try await account.perform(.refresh)
        #expect(await account.state().selectedSubscriptionID == "sim-a")
        await rig.transport.setResponse(path: "/mv/subscriptions/sim-a/balance", json: "invalid-old-balance")
        await rig.transport.setResponse(path: "/mv/subscriptions", json: LiveModelsTests.subscriptions)
        let before = await rig.transport.paths().count
        try await account.perform(.refreshService("sim-b"))
        let state = await account.state()
        #expect(state.selectedSubscriptionID == "sim-b")
        #expect(state.account?.selectedService?.providerID == "sim-b")
        #expect(state.failure == nil)
        #expect(await Array(rig.transport.paths().dropFirst(before)) == [
            "/mv/subscriptions", "/mv/subscriptions/sim-b/balance",
        ])
    }

    @Test func `synthetic home uses typed services without mobile DTOs and rejects unsupported operations`(
    ) async throws {
        let session = FixtureProviderAccount(key: FixtureAccounts.home, date: LiveModelsTests.now)
        _ = try await session.connect(credentials: .fixture)
        let state = await session.state()
        #expect(state.subscriptions.isEmpty)
        #expect(state.balance == nil)
        #expect(state.account?.selectedService?.kind == .home)
        #expect(state.snapshot.allowance == .finite(
            totalBytes: 1_000_000_000_000, usedBytes: 20_000_000_000, remainingBytes: 980_000_000_000,
        ))
        await #expect(throws: LiveFailure.requestDenied) { try await session.perform(.refreshPoints) }
        await #expect(throws: LiveFailure.requestDenied) { try await session.perform(.refreshInvoices) }
        await #expect(throws: LiveFailure.invalidSelection) {
            try await session.perform(.selectService(ServiceKey(
                account: FixtureAccounts.secondMobile, kind: .home, providerID: "shared-service",
            )))
        }
        try await session.perform(.selectService(ServiceKey(
            account: FixtureAccounts.home, kind: .home, providerID: "second-service",
        )))
        #expect(await session.state().snapshot.allowance == .finite(
            totalBytes: 1_000_000_000_000, usedBytes: 40_000_000_000, remainingBytes: 960_000_000_000,
        ))
    }

    @Test func `same connection UUID never authorizes merging another account metadata`() async throws {
        let home = FixtureProviderAccount(key: FixtureAccounts.home, date: LiveModelsTests.now)
        let mobile = FixtureProviderAccount(key: FixtureAccounts.secondMobile, date: LiveModelsTests.now)
        try await home.perform(.restore)
        try await mobile.perform(.restore)
        var target = await home.state()
        var source = await mobile.state()
        #expect(target.connectionID == source.connectionID)
        source.points = FixtureState.finite.points(referenceDate: LiveModelsTests.now)
        source.invoices = .empty(updatedAt: LiveModelsTests.now)
        target.mergePoints(from: source)
        target.mergeInvoices(from: source)
        #expect(target.points == nil)
        #expect(target.invoices == nil)
    }
}
