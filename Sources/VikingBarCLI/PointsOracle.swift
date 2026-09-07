import Foundation
import VikingBarCore

struct PointsAPIReceipt: Encodable {
    let schemaVersion = 1
    let check = "points-api"
    let passed = true
    let apiMatches = true
    let tokenRefreshed = true
    let transactionCount: Int
    let pageCount: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case apiMatches = "api_matches"
        case tokenRefreshed = "token_refreshed"
        case transactionCount = "transaction_count"
        case pageCount = "page_count"
        case check, passed
    }
}

actor PointsOracleTransport: ProofHTTPTransport {
    private let base: any ProofHTTPTransport
    private var refreshed = false
    private var balance: OraclePointsBalance?
    private var pages: [OraclePointsPage] = []

    init(base: any ProofHTTPTransport) {
        self.base = base
    }

    func send(_ request: URLRequest) async throws -> ProofHTTPResponse {
        let response = try await self.base.send(request)
        guard response.statusCode == 200, let url = request.url,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
        else { return response }
        switch path {
        case "/mv/oauth2/token/":
            self.refreshed = request.httpBody.map {
                String(data: $0, encoding: .utf8)?.split(separator: "&").contains("grant_type=refresh_token") ?? false
            } ?? false
        case "/mv/loyalty-points/balance":
            self.balance = try JSONDecoder().decode(OraclePointsBalance.self, from: response.data)
        case "/mv/loyalty-points/transactions":
            try self.pages.append(JSONDecoder().decode(OraclePointsPage.self, from: response.data))
        default: break
        }
        return response
    }

    func receipt(state: LiveSessionState) throws -> PointsAPIReceipt {
        guard self.refreshed, state.connectionID != nil, !state.isRefreshing,
              let points = state.points, points.balanceFailure == nil, points.historyFailure == nil,
              case .current = points.balanceFreshness, case .current = points.historyFreshness,
              let balance = points.balance, let expected = self.balance, let history = points.history,
              balance.available == expected.available, balance.pending == expected.pending,
              balance.blocked == expected.blocked, (1 ... 3).contains(self.pages.count),
              let last = self.pages.last, history.totalItems == last.totalItems,
              history.truncated == (last.page < last.totalPages)
        else { throw ProofFailure.malformedResponse }
        for (index, page) in self.pages.enumerated() {
            guard page.page == index + 1, page.perPage == 20, page.results.count <= 20 else {
                throw ProofFailure.malformedResponse
            }
        }
        let raw = self.pages.flatMap(\.results)
        guard raw.count == history.transactions.count else { throw ProofFailure.malformedResponse }
        for (expected, transaction) in zip(raw, history.transactions) {
            guard expected.transactionID == transaction.transactionID, expected.amount == transaction.amount,
                  expected.state == transaction.state.rawValue, expected.description == transaction.description,
                  try expected.date() == transaction.lastUpdated
            else { throw ProofFailure.malformedResponse }
        }
        try self.verifyPresentation(points: points, expected: expected, transactions: raw)
        return PointsAPIReceipt(transactionCount: raw.count, pageCount: self.pages.count)
    }

    private func verifyPresentation(
        points: CustomerPoints, expected: OraclePointsBalance, transactions: [OraclePointsTransaction],
    ) throws {
        let presentation = PointsPresentation(points: points)
        guard presentation.customerLabel == "Viking Points · Customer",
              presentation.availableText == "Available: \(NSDecimalNumber(decimal: expected.available).stringValue)",
              presentation.pendingText == "Pending: \(NSDecimalNumber(decimal: expected.pending).stringValue)",
              presentation.blockedText == "Blocked: \(NSDecimalNumber(decimal: expected.blocked).stringValue)",
              presentation.balanceStatus == "Up to date", presentation.historyStatus == "Up to date",
              presentation.transactions.count == transactions.count
        else { throw ProofFailure.malformedResponse }
        let states = [
            "completed": "Completed", "reserved": "Reserved", "cancelled": "Cancelled", "pending": "Pending",
            "blocked": "Blocked", "expired": "Expired", "rejected": "Rejected",
        ]
        for (raw, row) in zip(transactions, presentation.transactions) {
            let amount = (raw.amount > 0 ? "+" : "") + NSDecimalNumber(decimal: raw.amount).stringValue
            guard row.amountText == amount, row.stateText == (states[raw.state] ?? "Unknown state: \(raw.state)") else {
                throw ProofFailure.malformedResponse
            }
        }
    }
}

private struct OraclePointsBalance: Decodable {
    let available: Decimal
    let pending: Decimal
    let blocked: Decimal
}

private struct OraclePointsPage: Decodable {
    let page: Int
    let perPage: Int
    let totalPages: Int
    let totalItems: Int
    let results: [OraclePointsTransaction]

    enum CodingKeys: String, CodingKey {
        case page, results
        case perPage = "per_page"
        case totalPages = "total_pages"
        case totalItems = "total_items"
    }
}

private struct OraclePointsTransaction: Decodable {
    let transactionID: String?
    let amount: Decimal
    let state: String
    let lastUpdated: String
    let description: String?

    enum CodingKeys: String, CodingKey {
        case amount, state, description
        case transactionID = "transaction_id"
        case lastUpdated = "last_updated"
    }

    func date() throws -> Date {
        let parser = ISO8601DateFormatter()
        parser.formatOptions.insert(.withFractionalSeconds)
        if let date = parser.date(from: self.lastUpdated) {
            return date
        }
        parser.formatOptions.remove(.withFractionalSeconds)
        guard let date = parser.date(from: self.lastUpdated) else { throw ProofFailure.malformedResponse }
        return date
    }
}
