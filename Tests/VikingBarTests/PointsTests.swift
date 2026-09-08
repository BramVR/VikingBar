import Foundation
import Testing
@testable import VikingBarCore

struct PointsTests {
    @Test func `points preserve decimals signed rows all states and unknown states`() async throws {
        let rig = try await Self.rig()
        let usage = try await rig.session.refresh()
        let state = try await rig.session.refreshPoints()
        let points = try #require(state.points)
        #expect(points.balance?.available == Decimal(string: "12.34567890123456789"))
        #expect(points.balance?.pending == 3.5)
        #expect(points.balance?.blocked == 2.25)
        #expect(points.history?.transactions.map(\.state.rawValue) == Self.states)
        #expect(points.history?.transactions[1].amount == -2.5)
        #expect(points.history?.transactions.last?.transactionID == nil)
        #expect(state.snapshot == usage.snapshot)
        #expect(state.failure == nil)
        let presentation = PointsPresentation(points: points)
        #expect(presentation.availableText == "Available: 12.34567890123456789")
        #expect(presentation.transactions[0].amountText == "+1.25")
        #expect(presentation.transactions[1].amountText == "-2.5")
        #expect(presentation.transactions.last?.stateText == "Unknown state: future-state")
        let data = try JSONEncoder().encode(state)
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(!json.contains("secret-metadata"))
    }

    @Test func `history failure retains stale rows and publishes balance independently`() async throws {
        let rig = try await Self.rig()
        let good = try await rig.session.refreshPoints()
        await rig.transport.setResponse(path: Self.historyPath, json: "{}")
        await rig.transport.setResponse(path: Self.balancePath, json: "{\"available\":0,\"pending\":1,\"blocked\":2}")
        let failed = try await rig.session.refreshPoints()
        #expect(failed.points?.balance?.available == 0)
        #expect(failed.points?.balanceFailure == nil)
        #expect(failed.points?.history == good.points?.history)
        #expect(failed.points?.historyFreshness == .stale(lastUpdated: LiveModelsTests.now))
        #expect(failed.points?.historyFailure == .malformedResponse)
    }

    @Test func `balance failure retains stale balance and publishes history independently`() async throws {
        let rig = try await Self.rig()
        let good = try await rig.session.refreshPoints()
        await rig.transport.setResponse(path: Self.balancePath, json: "{\"available\":0,\"pending\":0}")
        await rig.transport.setResponse(path: Self.historyPath, json: Self.page(rows: [], totalItems: 0))
        let failed = try await rig.session.refreshPoints()
        #expect(failed.points?.balance == good.points?.balance)
        #expect(failed.points?.balanceFreshness == .stale(lastUpdated: LiveModelsTests.now))
        #expect(failed.points?.balanceFailure == .malformedResponse)
        #expect(failed.points?.history?.transactions.isEmpty == true)
        #expect(failed.points?.historyFailure == nil)
        #expect(PointsPresentation(points: failed.points).historySummary == "No transactions")
    }

    @Test func `optional authorization failure leaves successful usage untouched`() async throws {
        let rig = try await Self.rig()
        let usage = try await rig.session.refresh()
        await rig.transport.failNext(code: 503)
        let state = try await rig.session.refreshPoints(forceTokenRefresh: true)
        #expect(state.snapshot == usage.snapshot)
        #expect(state.failure == nil)
        #expect(state.nextRefreshAt == usage.nextRefreshAt)
        #expect(state.points?.balanceFailure == .reconnectRequired)
        #expect(state.points?.historyFailure == .reconnectRequired)
    }

    @Test func `points failure distinguishes unavailable from zero`() async throws {
        let rig = try await Self.rig()
        await rig.transport.setResponse(path: Self.balancePath, json: "{}")
        let state = try await rig.session.refreshPoints()
        #expect(state.points?.balance == nil)
        #expect(PointsPresentation(points: state.points).availableText == "Available: unavailable")
        #expect(state.points?.history != nil)
    }

    @Test func `history fetch is capped at three pages and sixty records`() async throws {
        let transport = PointsPageTransport(totalItems: 81)
        let api = LiveAPI(transport: transport, now: { LiveModelsTests.now })
        let history = try await api.pointsHistory(token: Self.token)
        #expect(history.transactions.count == 60)
        #expect(history.totalItems == 81)
        #expect(history.truncated)
        #expect(await transport.pages == [1, 2, 3])
        var points = CustomerPoints()
        points.history = history
        #expect(PointsPresentation(points: points)
            .historySummary == "Showing 60 of 81 transactions. History truncated.")
    }

    @Test func `later page failure does not replace previous complete history`() async throws {
        let transport = PointsPageTransport(totalItems: 21, failPage: 2)
        let api = LiveAPI(transport: transport, now: { LiveModelsTests.now })
        await #expect(throws: LiveFailure.serverUnavailable) { try await api.pointsHistory(token: Self.token) }
        #expect(await transport.pages == [1, 2])
    }

    @Test func `pagination rejects inconsistent metadata and malformed transaction dates`() async throws {
        let rig = try await Self.rig()
        for json in [
            Self.page(rows: [Self.row(state: "completed", amount: "1")], totalItems: 2),
            Self.page(rows: ["{\"amount\":1,\"state\":\"completed\",\"last_updated\":\"bad\"}"], totalItems: 1),
            "{\"results\":[],\"page\":1,\"per_page\":100,\"total_pages\":0,\"total_items\":0}",
        ] {
            await rig.transport.setResponse(path: Self.historyPath, json: json)
            let state = try await rig.session.refreshPoints()
            #expect(state.points?.history == nil)
            #expect(state.points?.historyFailure == .malformedResponse)
        }
    }

    @Test func `points cache restores compatibly and remains customer scoped across SIM selections`() async throws {
        let rig = try await Self.rig()
        _ = try await rig.session.refresh()
        let good = try await rig.session.refreshPoints()
        let selected = try await rig.session.selectSubscription(id: "sim-b")
        #expect(selected.points == good.points)
        let restored = try await rig.newSession().restore()
        #expect(restored.points == good.points)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        object.removeValue(forKey: "points")
        let legacy = try JSONDecoder().decode(
            LiveSessionState.self,
            from: JSONSerialization.data(withJSONObject: object),
        )
        #expect(legacy.points == nil)
    }

    @Test func `new connection clears points and cancelled fetch cannot publish them`() async throws {
        let rig = try await Self.rig()
        _ = try await rig.session.refreshPoints()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        #expect(await rig.session.state().points == nil)
        await rig.transport.pauseNext(path: Self.balancePath)
        let fetch = Task { try await rig.session.refreshPoints() }
        await rig.transport.waitUntilPaused()
        await rig.session.cancel()
        await rig.transport.resume()
        await #expect(throws: CancellationError.self) { try await fetch.value }
        #expect(await rig.session.state().points == nil)
    }

    @Test func `external connection replacement discards old points response`() async throws {
        let rig = try await Self.rig()
        _ = try await rig.session.refresh()
        _ = try await rig.session.refreshPoints()
        await rig.transport.pauseNext(path: Self.historyPath)
        let fetch = Task { try await rig.session.refreshPoints() }
        await rig.transport.waitUntilPaused()
        let replacement = try await rig.newSession().bootstrap(credentials: LiveSessionTests.credentials)
        await rig.transport.resume()
        await #expect(throws: LiveFailure.connectionChanged) { try await fetch.value }
        let state = await rig.session.state()
        #expect(state.connectionID == replacement.connectionID)
        #expect(state.points == nil)
        #expect(state.balance == nil)
    }

    @Test func `allowlist accepts only bounded points reads`() throws {
        for endpoint in [ProofEndpoint.pointsBalance, .pointsTransactions(page: 1), .pointsTransactions(page: 3)] {
            try ProofEndpoint.validate(endpoint.request())
        }
        #expect(throws: ProofFailure.requestDenied) { try ProofEndpoint.pointsTransactions(page: 4).request() }
        let deniedPaths = ["balance?secret=1", "transactions", "transactions?page=0&per_page=20",
                           "transactions?page=1&per_page=21", "transactions?page=1&per_page=20&deals_metadata=1",
                           "transactions?page=1&per_page=20&page=2", "receiver", "transfer"]
        for suffix in deniedPaths {
            let request =
                try URLRequest(url: #require(URL(string: "https://uwa.mobilevikings.be/mv/loyalty-points/\(suffix)")))
            #expect(throws: ProofFailure.requestDenied) { try ProofEndpoint.validate(request) }
        }
        var write = try ProofEndpoint.pointsBalance.request()
        write.httpMethod = "POST"
        #expect(throws: ProofFailure.requestDenied) { try ProofEndpoint.validate(write) }
    }

    static let balancePath = "/mv/loyalty-points/balance"
    static let historyPath = "/mv/loyalty-points/transactions"
    static let states = [
        "completed",
        "reserved",
        "cancelled",
        "pending",
        "blocked",
        "expired",
        "rejected",
        "future-state",
    ]
    static let token = LiveToken(
        accessToken: "synthetic", refreshToken: "synthetic", expiresAt: .distantFuture, scopeMismatch: false,
    )

    static func rig() async throws -> Rig {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        await rig.transport.setResponse(
            path: Self.balancePath,
            json: """
            {"available":12.34567890123456789,"pending":3.5,"blocked":2.25,"total_earned":"secret-metadata"}
            """,
        )
        await rig.transport.setResponse(path: Self.historyPath, json: Self.page(
            rows: Self.states.enumerated().map { Self.row(state: $1, amount: $0.isMultiple(of: 2) ? "1.25" : "-2.5") },
            totalItems: Self.states.count,
        ))
        return rig
    }

    static func row(state: String, amount: String) -> String {
        """
        {"amount":\(amount),"state":"\(state)","last_updated":"2026-09-07T10:30:00.123Z",
        "description":"Synthetic","deals_logo":"secret-metadata"}
        """
    }

    static func page(rows: [String], totalItems: Int, page: Int = 1) -> String {
        """
        {"results":[\(rows.joined(separator: ","))],"page":\(page),"per_page":20,
        "total_pages":\((totalItems + 19) / 20),"total_items":\(totalItems)}
        """
    }
}

private actor PointsPageTransport: ProofHTTPTransport {
    let totalItems: Int
    let failPage: Int?
    private(set) var pages: [Int] = []

    init(totalItems: Int, failPage: Int? = nil) {
        self.totalItems = totalItems
        self.failPage = failPage
    }

    func send(_ request: URLRequest) throws -> ProofHTTPResponse {
        try ProofEndpoint.validate(request)
        let url = try #require(request.url)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let pageText = try #require(parts.queryItems?.first(where: { $0.name == "page" })?.value)
        let page = try #require(Int(pageText))
        self.pages.append(page)
        if page == self.failPage {
            return ProofHTTPResponse(statusCode: 503, data: Data())
        }
        let count = min(20, self.totalItems - (page - 1) * 20)
        let rows = (0 ..< count).map { PointsTests.row(state: "completed", amount: "\((page - 1) * 20 + $0)") }
        return ProofHTTPResponse(
            statusCode: 200,
            data: Data(PointsTests.page(rows: rows, totalItems: self.totalItems, page: page).utf8),
        )
    }
}
