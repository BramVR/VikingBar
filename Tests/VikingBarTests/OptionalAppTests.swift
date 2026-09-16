import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct OptionalAppTests {
    @Test func `held points keep usage controls and deadline available while Bills queues once`() async throws {
        let client = try OptionalModelClient()
        client.hold = ["points", "invoices"]
        let sleeper = ModelTestSleeper()
        let model = try Self.model(client, sleeper: sleeper)
        model.start()
        try await AppSessionTests.until { client.pending["points"] != nil }
        try await AppSessionTests.until { sleeper.deadlines.contains(client.state.nextRefreshAt!) }
        let usage = model.liveState
        let deadlines = sleeper.deadlines
        #expect(model.canRefresh)
        #expect(model.canSelectAccountData)
        model.loadInvoices()
        model.loadInvoices()
        #expect(model.isLoadingInvoices)
        #expect(client.requests == ["restore", "refresh", "points"])
        var pointsReply = client.state
        pointsReply.points = FixtureState.finite.points(referenceDate: LiveModelsTests.now)
        pointsReply.snapshot = .notConnected
        pointsReply.failure = .serverUnavailable
        pointsReply.nextRefreshAt = .distantFuture
        pointsReply.selectedSubscriptionID = "wrong-sim"
        pointsReply.invoices = nil
        client.release("points", .success(pointsReply))
        try await AppSessionTests.until { client.pending["invoices"] != nil }
        #expect(model.snapshot == usage.snapshot)
        #expect(model.liveState.failure == usage.failure)
        #expect(model.liveState.selectedSubscriptionID == usage.selectedSubscriptionID)
        #expect(model.liveState.nextRefreshAt == usage.nextRefreshAt)
        #expect(sleeper.deadlines == deadlines)
        var invoiceReply = pointsReply
        invoiceReply.points = nil
        invoiceReply.invoices = client.state.invoices
        client.release("invoices", .success(invoiceReply))
        try await AppSessionTests.until { !model.isLoadingInvoices }
        #expect(model.liveState.points == pointsReply.points)
        #expect(model.liveState.invoices == client.state.invoices)
        #expect(model.snapshot == usage.snapshot)
        #expect(sleeper.deadlines == deadlines)
        #expect(client.requests == ["restore", "refresh", "points", "invoices"])
        await model.stop()
    }

    @Test(arguments: [true, false])
    func `manual and scheduled refresh wait for cancel acknowledgement then retry queued metadata`(
        manual: Bool,
    ) async throws {
        let client = try OptionalModelClient()
        client.hold = ["points", "cancel"]
        let sleeper = ModelTestSleeper()
        let model = try Self.model(client, sleeper: sleeper)
        model.start()
        try await AppSessionTests.until { client.pending["points"] != nil }
        try await AppSessionTests.until { sleeper.deadlines.contains(client.state.nextRefreshAt!) }
        model.loadInvoices()
        if manual {
            model.refresh()
        } else {
            sleeper.wake()
        }
        try await AppSessionTests.until { client.pending["cancel"] != nil }
        #expect(client.requests == ["restore", "refresh", "points", "cancel"])
        #expect(model.isLoadingInvoices)
        #expect(model.activity == .refreshing)
        client.hold.remove("points")
        client.release("points", .failure(CancellationError()))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(client.requests.filter { $0 == "refresh" }.count == 1)
        client.release("cancel", .success(client.state))
        try await AppSessionTests.until { client.requests.last == "invoices" && !model.isLoadingInvoices }
        #expect(client.requests == ["restore", "refresh", "points", "cancel", "refresh", "points", "invoices"])
        #expect(model.liveState.nextRefreshAt == client.state.nextRefreshAt)
        #expect(model.canRefresh)
        await model.stop()
    }

    @Test func `interrupted invoice metadata runs before new points and preserves their independent fields`(
    ) async throws {
        let client = try OptionalModelClient()
        let model = try Self.model(client)
        model.start()
        try await AppSessionTests.until { client.requests.last == "points" }
        client.hold = ["invoices", "cancel"]
        model.loadInvoices()
        try await AppSessionTests.until { client.pending["invoices"] != nil }
        model.refresh()
        try await AppSessionTests.until { client.pending["cancel"] != nil }
        client.release("invoices", .failure(CancellationError()))
        client.hold.remove("invoices")
        client.release("cancel", .success(client.state))
        try await AppSessionTests.until { client.requests.count == 8 }
        #expect(client.requests == [
            "restore",
            "refresh",
            "points",
            "invoices",
            "cancel",
            "refresh",
            "invoices",
            "points",
        ])
        #expect(model.liveState.invoices == client.state.invoices)
        #expect(model.liveState.points == client.state.points)
        #expect(model.liveState.failure == nil)
        await model.stop()
    }

    @Test func `optional worker failure retains queued Bills for one Refresh recovery`() async throws {
        let client = try OptionalModelClient()
        client.hold = ["points"]
        let model = try Self.model(client)
        model.start()
        try await AppSessionTests.until { client.pending["points"] != nil }
        let usage = model.liveState
        model.loadInvoices()
        client.release("points", .failure(LiveBridgeFailure.invalidReply))
        try await AppSessionTests.until { client.shutdowns == 1 }
        #expect(client.requests == ["restore", "refresh", "points"])
        #expect(model.isLoadingInvoices)
        #expect(model.snapshot == usage.snapshot)
        #expect(model.liveState.failure == usage.failure)
        #expect(model.liveState.nextRefreshAt == usage.nextRefreshAt)
        #expect(model.bridgeError == nil)
        client.hold.remove("points")
        model.refresh()
        try await AppSessionTests.until { client.requests.count == 7 }
        #expect(client.requests == ["restore", "refresh", "points", "restore", "refresh", "invoices", "points"])
        #expect(model.liveState.invoices == client.state.invoices)
        #expect(model.canRefresh)
        await model.stop()
    }

    @Test(arguments: [true, false])
    func `interrupted queued or active PDF never opens or replays and asks for retry`(queued: Bool) async throws {
        let client = try OptionalModelClient()
        client.hold = queued ? ["points", "cancel"] : ["pdf", "cancel"]
        var opened: [URL] = []
        let model = try Self.model(client, open: { opened.append($0); return true })
        model.start()
        try await AppSessionTests.until { client.requests.last == "points" }
        model.openInvoice("inv-1")
        if !queued {
            try await AppSessionTests.until { client.pending["pdf"] != nil }
        }
        model.refresh()
        try await AppSessionTests.until { client.pending["cancel"] != nil }
        #expect(model.invoiceError == "Invoice PDF interrupted. Try again.")
        var old = client.state
        old.invoiceDocument = client.document
        client.release(queued ? "points" : "pdf", .success(old))
        client.hold.remove("points")
        client.release("cancel", .success(client.state))
        try await AppSessionTests.until { model.activity == .idle }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(opened.isEmpty)
        #expect(client.requests.filter { $0 == "pdf" }.count == (queued ? 0 : 1))
        #expect(model.invoiceError == "Invoice PDF interrupted. Try again.")
        await model.stop()
    }

    @Test func `reconnect clears queued old customer metadata and rejects delayed points`() async throws {
        let client = try OptionalModelClient()
        client.hold = ["points"]
        let model = try Self.model(client)
        model.start()
        try await AppSessionTests.until { client.pending["points"] != nil }
        model.loadInvoices()
        model.connect(input: .reference(URL(fileURLWithPath: "/synthetic/reference")), resultURL: nil)
        try await AppSessionTests.until { model.activity == .idle }
        #expect(model.liveState.connectionID == nil)
        #expect(model.liveState.points == nil)
        #expect(model.liveState.invoices == nil)
        #expect(!model.isLoadingInvoices)
        #expect(!client.requests.contains("invoices"))
        await model.stop()
    }

    @Test func `history and Bills survive foreground refresh in the shared points queue`() async throws {
        let client = try OptionalModelClient()
        client.state.subscriptions = [MobileSubscription(id: "sim-a", displayName: "Synthetic", type: "postpaid")]
        try client.state.publish(
            LiveAPI.decodeBalance(Data(LiveModelsTests.balanceJSON.utf8)),
            at: LiveModelsTests.now,
            interval: .fiveMinutes,
        )
        client.hold = ["points", "history", "cancel"]
        let model = try Self.model(client)
        model.start()
        try await AppSessionTests.until { client.pending["points"] != nil }
        model.loadInvoices()
        #expect(model.isHistoryLoading)
        #expect(model.isLoadingInvoices)
        client.release("points", .success(client.state))
        try await AppSessionTests.until { client.pending["history"] != nil }
        #expect(model.canRefresh)
        let balance = model.snapshot
        model.refresh()
        try await AppSessionTests.until { client.pending["cancel"] != nil }
        #expect(client.requests == ["restore", "refresh", "points", "history", "cancel"])
        var old = client.state
        old.history = try UsageHistory(
            context: #require(old.historyContext),
            observations: [],
            attemptedAt: LiveModelsTests.now,
        )
        client.state.historyRevision = UUID()
        client.release("history", .success(old))
        client.hold.removeAll()
        client.release("cancel", .success(client.state))
        try await AppSessionTests
            .until { client.requests.count == 9 && !model.isLoadingInvoices && !model.isHistoryLoading }
        #expect(client.requests == [
            "restore",
            "refresh",
            "points",
            "history",
            "cancel",
            "refresh",
            "history",
            "invoices",
            "points",
        ])
        #expect(model.liveState.history == nil)
        #expect(model.snapshot == balance)
        #expect(model.liveState.invoices == client.state.invoices)
        #expect(model.liveState.points == client.state.points)
        await model.stop()
    }

    static func model(
        _ client: OptionalModelClient, sleeper: ModelTestSleeper = ModelTestSleeper(),
        open: @escaping (URL) -> Bool = { _ in false },
    ) throws -> AppSession {
        try AppSession(
            options: LaunchOptions(arguments: []), preferences: MenuBarPreferences(fileURL: nil),
            clientFactory: { client }, connectorFactory: { ModelTestConnector(fails: true) },
            now: { LiveModelsTests.now }, openDocument: open,
            sleepUntil: { try await sleeper.sleep(until: $0) },
        )
    }
}

@MainActor
final class OptionalModelClient: SessionClient {
    var state = AppSessionTests.connected()
    var requests: [String] = []
    var hold: Set<String> = []
    var pending: [String: CheckedContinuation<LiveSessionState, any Error>] = [:]
    var shutdowns = 0
    var completeOnShutdown = false
    private var restored = false
    let document = InvoiceDocument(invoiceID: "inv-1", fileURL: URL(fileURLWithPath: "/private/synthetic/invoice.pdf"))

    init() throws {
        self.state.selectedSubscriptionID = "sim-a"
        self.state.invoices = try .loaded([InvoiceTests.invoice()], updatedAt: LiveModelsTests.now)
        self.state.points = FixtureState.finite.points(referenceDate: LiveModelsTests.now)
        self.state.nextRefreshAt = LiveModelsTests.now.addingTimeInterval(300)
    }

    func request(_ request: SessionRequest) async throws -> LiveSessionState {
        let name = self.name(for: request)
        self.requests.append(name)
        if name == "restore" {
            self.restored = true
        }
        if name == "configure", !self.restored {
            return LiveSessionState()
        }
        if self.hold.contains(name) {
            return try await withCheckedThrowingContinuation {
                #expect(self.pending[name] == nil)
                self.pending[name] = $0
            }
        }
        var state = self.state
        if name == "pdf" {
            state.invoiceDocument = self.document
        }
        return state
    }

    private func name(for request: SessionRequest) -> String {
        if case .reviewInvoicePayment = request {
            return "payment"
        }
        if case .clearPaymentReview = request {
            return "clearPayment"
        }
        return self.standardName(for: request)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func standardName(for request: SessionRequest) -> String {
        switch request {
        case .restore: "restore"
        case .refresh: "refresh"
        case .configure: "configure"
        case .refreshPoints: "points"
        case .refreshHistory: "history"
        case .refreshInvoices: "invoices"
        case .downloadInvoice: "pdf"
        case .reviewInvoicePayment, .clearPaymentReview: preconditionFailure()
        case .cancel: "cancel"
        case .shutdown: "shutdown"
        case .selectSubscription, .selectBundle: "selection"
        }
    }

    func release(_ name: String, _ result: Result<LiveSessionState, any Error>) {
        self.pending.removeValue(forKey: name)?.resume(with: result)
    }

    func shutdown() async {
        self.shutdowns += 1
        self.restored = false
        let pending = self.pending
        self.pending.removeAll()
        for continuation in pending.values {
            if self.completeOnShutdown {
                continuation.resume(returning: self.state)
            } else {
                continuation.resume(throwing: CancellationError())
            }
        }
    }
}
