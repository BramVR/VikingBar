import Foundation
import Testing
@testable import VikingBarCore

struct OptionalSessionTests {
    @Test(arguments: [true, false])
    func `direct optional callers serialize in either order without changing usage`(pointsFirst: Bool) async throws {
        let rig = try await PointsTests.rig()
        let usage = try await rig.session.refresh()
        await rig.transport.setResponse(path: "/mv/invoices", json: InvoiceTests.page([InvoiceTests.item()]))
        let firstPath = pointsFirst ? PointsTests.balancePath : "/mv/invoices"
        await rig.transport.pauseNext(path: firstPath, cancellable: true)
        let first = Task {
            try await pointsFirst ? rig.session.refreshPoints() : rig.session.refreshInvoices()
        }
        await rig.transport.waitUntilPaused()
        let second = Task {
            try await pointsFirst ? rig.session.refreshInvoices() : rig.session.refreshPoints()
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        let held = await rig.session.state()
        #expect(!held.isRefreshing)
        #expect(held.snapshot == usage.snapshot)
        #expect(held.nextRefreshAt == usage.nextRefreshAt)
        #expect(await rig.transport.paths().last == firstPath)
        #expect(await rig.transport.cancellations == 0)
        await rig.transport.resume()
        _ = try await first.value
        let result = try await second.value
        #expect(result.points?.balance != nil)
        #expect(result.invoices?.invoices.count == 1)
        #expect(result.snapshot == usage.snapshot)
        #expect(result.failure == usage.failure)
        #expect(result.nextRefreshAt == usage.nextRefreshAt)
        #expect(!result.isRefreshing)
    }

    @Test(arguments: [true, false])
    func `required usage promptly cancels optional reads and owns selected SIM`(points: Bool) async throws {
        let rig = try await PointsTests.rig()
        _ = try await rig.session.refresh()
        let path = points ? PointsTests.balancePath : "/mv/invoices"
        await rig.transport.pauseNext(path: path, cancellable: true)
        let optional = Task { try await points ? rig.session.refreshPoints() : rig.session.refreshInvoices() }
        await rig.transport.waitUntilPaused()
        let selected = try await rig.session.selectSubscription(id: "sim-b")
        await #expect(throws: CancellationError.self) { try await optional.value }
        #expect(await rig.transport.cancellations == 1)
        #expect(selected.selectedSubscriptionID == "sim-b")
        #expect(selected.snapshot.subscriptionName == "Second")
        #expect(!selected.isRefreshing)
        #expect(selected.invoices == nil)
        #expect(selected.points == nil)
    }

    @Test(arguments: [true, false])
    func `caller and session cancellation preserve rotating credentials before required usage`(
        cancelCaller: Bool,
    ) async throws {
        let rig = try await PointsTests.rig()
        let before = try await rig.session.refresh()
        #expect(before.scopeMismatch)
        let tokenPath = try #require(ProofEndpoint.token.request().url?.path)
        await rig.transport.setResponse(path: tokenPath, json: """
        {"access_token":"access-2","refresh_token":"refresh-2","token_type":"Bearer",
        "expires_in":599,"scope":"read"}
        """)
        await rig.transport.pauseNext(path: tokenPath, cancellable: true)
        let optional = Task { try await rig.session.refreshPoints(forceTokenRefresh: true) }
        await rig.transport.waitUntilPaused()
        if cancelCaller {
            optional.cancel()
        } else {
            await rig.session.cancel()
        }
        let required = Task { try await rig.session.refresh() }
        for _ in 0 ..< 30 {
            await Task.yield()
        }
        #expect(await rig.transport.paths().last == tokenPath)
        #expect(await rig.transport.cancellations == 0)
        let pending = try JSONDecoder().decode(StoredSession.self, from: #require(rig.store.load()))
        #expect(pending.rotationPending)
        #expect(pending.refreshToken == "refresh-1")
        await rig.transport.resume()
        await #expect(throws: CancellationError.self) { try await optional.value }
        let usage = try await required.value
        let saved = try JSONDecoder().decode(StoredSession.self, from: #require(rig.store.load()))
        #expect(!saved.rotationPending)
        #expect(saved.refreshToken == "refresh-2")
        #expect(await rig.transport.refreshInputs() == ["refresh-1"])
        #expect(!usage.scopeMismatch)
        #expect(usage.failure == nil)
        #expect(usage.points == nil)
        #expect(usage.snapshot == before.snapshot)
        #expect(usage.nextRefreshAt == before.nextRefreshAt)
    }

    @Test func `cancelled PDF read publishes no path and required usage does not replay it`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        _ = try await rig.session.refresh()
        await rig.transport.setResponse(path: "/mv/invoices", json: InvoiceTests.page([InvoiceTests.item()]))
        _ = try await rig.session.refreshInvoices()
        await rig.transport.pauseNext(path: "/mv/invoices/inv-1/pdf", cancellable: true)
        let pdf = Task { try await rig.session.downloadInvoice(id: "inv-1") }
        await rig.transport.waitUntilPaused()
        let refreshed = try await rig.session.refresh()
        await #expect(throws: CancellationError.self) { try await pdf.value }
        #expect(refreshed.invoiceDocument == nil)
        #expect(await rig.transport.paths().filter { $0.hasSuffix("/pdf") }.count == 1)
    }
}
