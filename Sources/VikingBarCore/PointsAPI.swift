import Foundation

extension LiveAPI {
    func pointsBalance(token: LiveToken) async throws -> PointsBalance {
        let data = try await self.get(.pointsBalance, token: token)
        do {
            let value = try JSONDecoder().decode(PointsBalance.self, from: data)
            guard !value.available.isNaN, !value.pending.isNaN, !value.blocked.isNaN else {
                throw LiveFailure.malformedResponse
            }
            return value
        } catch { throw LiveFailure.malformedResponse }
    }

    func pointsHistory(token: LiveToken) async throws -> PointsHistory {
        var transactions: [PointsTransaction] = []
        var totalItems: Int?
        var totalPages: Int?
        for page in 1 ... 3 {
            let data = try await self.get(.pointsTransactions(page: page), token: token)
            let response: PointsPageResponse
            do { response = try JSONDecoder().decode(PointsPageResponse.self, from: data) } catch {
                throw LiveFailure.malformedResponse
            }
            let expectedPages = response.totalItems / 20 + (response.totalItems % 20 == 0 ? 0 : 1)
            guard response.totalItems == 0 ? response.totalPages <= 1 : response.totalPages == expectedPages,
                  response.page == page, response.perPage == 20, response.totalItems >= 0,
                  response.totalPages >= 0, response.results.count <= 20,
                  response.totalItems == 0 ? response.totalPages <= 1 : response.totalPages >= page,
                  totalItems == nil || totalItems == response.totalItems,
                  totalPages == nil || totalPages == response.totalPages
            else { throw LiveFailure.malformedResponse }
            totalItems = response.totalItems
            totalPages = response.totalPages
            let rows = try response.results.map { value in
                guard !value.amount.isNaN, !value.state.rawValue.isEmpty,
                      let date = Self.date(value.lastUpdated) else { throw LiveFailure.malformedResponse }
                return PointsTransaction(
                    transactionID: value.transactionID, amount: value.amount, state: value.state,
                    lastUpdated: date, description: value.description,
                )
            }
            transactions.append(contentsOf: rows)
            guard transactions.count <= response.totalItems else { throw LiveFailure.malformedResponse }
            if page >= response.totalPages {
                guard transactions.count == response.totalItems else { throw LiveFailure.malformedResponse }
                return PointsHistory(transactions: transactions, totalItems: response.totalItems, truncated: false)
            }
            guard rows.count == 20 else { throw LiveFailure.malformedResponse }
        }
        return PointsHistory(transactions: transactions, totalItems: totalItems ?? 0, truncated: true)
    }
}

private struct PointsPageResponse: Decodable {
    let results: [PointsTransactionResponse]
    let page: Int
    let perPage: Int
    let totalPages: Int
    let totalItems: Int

    enum CodingKeys: String, CodingKey {
        case results, page
        case perPage = "per_page"
        case totalPages = "total_pages"
        case totalItems = "total_items"
    }
}

private struct PointsTransactionResponse: Decodable {
    let transactionID: String?
    let amount: Decimal
    let state: PointsTransactionState
    let lastUpdated: String
    let description: String?

    enum CodingKeys: String, CodingKey {
        case amount, state, description
        case transactionID = "transaction_id"
        case lastUpdated = "last_updated"
    }
}
