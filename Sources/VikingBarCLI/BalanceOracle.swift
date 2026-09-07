import Foundation
import VikingBarCore

struct BalanceAPIReceipt: Encodable {
    let schemaVersion = 1
    let check = "balance-api"
    let passed = true
    let apiMatches = true
    let tokenRefreshed = true
    let bundleCount: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case apiMatches = "api_matches"
        case tokenRefreshed = "token_refreshed"
        case bundleCount = "bundle_count"
        case check, passed
    }
}

actor BalanceOracleTransport: ProofHTTPTransport {
    private let base: any ProofHTTPTransport
    private var refreshed = false
    private var subscriptionIDs: [String] = []
    private var balances: [String: OracleBalance] = [:]

    init(base: any ProofHTTPTransport) {
        self.base = base
    }

    func send(_ request: URLRequest) async throws -> ProofHTTPResponse {
        let response = try await self.base.send(request)
        guard response.statusCode == 200, let url = request.url,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
        else { return response }
        if path == "/mv/oauth2/token/" {
            self.refreshed = request.httpBody.map {
                String(data: $0, encoding: .utf8)?.split(separator: "&").contains("grant_type=refresh_token") ?? false
            } ?? false
        } else if path == "/mv/subscriptions" {
            let values = try JSONDecoder().decode([OracleSubscription].self, from: response.data)
            self.subscriptionIDs = values.filter { ["prepaid", "postpaid"].contains($0.type) }.map(\.id)
        } else if path.hasSuffix("/balance"), let id = path.split(separator: "/").dropLast().last {
            self.balances[String(id)] = try JSONDecoder().decode(OracleBalance.self, from: response.data)
        }
        return response
    }

    func receipt(state: LiveSessionState) throws -> BalanceAPIReceipt {
        guard self.refreshed, state.failure == nil, !state.isRefreshing,
              Set(self.subscriptionIDs) == Set(state.subscriptions.map(\.id)),
              let id = state.selectedSubscriptionID, self.subscriptionIDs.contains(id),
              let oracle = self.balances[id], let balance = state.balance,
              oracle.bundles.count == balance.bundles.count,
              oracle.regionality == balance.regionality, oracle.outOfBundleCost == balance.outOfBundleCost,
              let index = state.selectedBundleIndex, oracle.bundles.indices.contains(index),
              case let .current(updated) = state.snapshot.freshness
        else { throw ProofFailure.malformedResponse }
        for (raw, actual) in zip(oracle.bundles, balance.bundles) {
            guard raw.total == actual.total, raw.used == actual.used, raw.remaining == actual.remaining,
                  raw.type == actual.type, raw.category == actual.category,
                  raw.descriptions.title == actual.title, raw.descriptions.description == actual.description,
                  try raw.startDate() == actual.validFrom, try raw.endDate() == actual.validUntil
            else { throw ProofFailure.malformedResponse }
        }
        let raw = oracle.bundles[index]
        guard raw.type == "data", try raw.startDate() <= updated, try raw.endDate() > updated,
              try raw.endDate() == state.snapshot.expiresAt
        else { throw ProofFailure.malformedResponse }
        try raw.verify(snapshot: state.snapshot)
        return BalanceAPIReceipt(bundleCount: oracle.bundles.count)
    }
}

private struct OracleSubscription: Decodable {
    let id: String
    let type: String
}

private struct OracleBalance: Decodable {
    let bundles: [OracleBundle]
    let regionality: String?
    let outOfBundleCost: Decimal?

    enum CodingKeys: String, CodingKey {
        case bundles, regionality
        case outOfBundleCost = "out_of_bundle_cost"
    }
}

private struct OracleBundle: Decodable {
    struct Descriptions: Decodable {
        let title: String
        let description: String
    }

    let descriptions: Descriptions
    let category: String
    let type: String
    let total: Decimal
    let used: Decimal
    let remaining: Decimal
    let validFrom: String
    let validUntil: String

    enum CodingKeys: String, CodingKey {
        case descriptions, category, type, total, used, remaining
        case validFrom = "valid_from"
        case validUntil = "valid_until"
    }

    func startDate() throws -> Date {
        try Self.parseDate(self.validFrom)
    }

    func endDate() throws -> Date {
        try Self.parseDate(self.validUntil)
    }

    private static func parseDate(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions.insert(.withFractionalSeconds)
        guard let date = formatter.date(from: text) else { throw ProofFailure.malformedResponse }
        return date
    }

    func verify(snapshot: UsageSnapshot) throws {
        let menu = MenuPresentation(snapshot: snapshot)
        let expectedUsed = "\(Self.gigabytes(self.used)) used"
        guard menu.usedText == expectedUsed else { throw ProofFailure.malformedResponse }
        if self.total == -1 {
            guard case let .unlimited(used) = snapshot.allowance, Decimal(used) == self.used,
                  menu.remainingText == "Unlimited", menu.percentageUsed == nil,
                  menu.percentageRemaining == nil, menu.totalText == "Unlimited allowance"
            else { throw ProofFailure.malformedResponse }
        } else {
            guard case let .finite(total, used, remaining) = snapshot.allowance,
                  Decimal(total) == self.total, Decimal(used) == self.used, Decimal(remaining) == self.remaining,
                  menu.remainingText == Self.gigabytes(self.remaining),
                  menu.totalText == "\(Self.gigabytes(self.total)) total"
            else { throw ProofFailure.malformedResponse }
            let percentage = total == 0 ? nil : Double(used) / Double(total) * 100
            if let percentage, let actual = menu.percentageUsed {
                guard abs(percentage - actual) < 0.000001 else { throw ProofFailure.malformedResponse }
            } else if percentage != nil || menu.percentageUsed != nil {
                throw ProofFailure.malformedResponse
            }
        }
    }

    private static func gigabytes(_ bytes: Decimal) -> String {
        String(format: "%.2f GB", locale: Locale(identifier: "en_US_POSIX"),
               NSDecimalNumber(decimal: bytes / 1_000_000_000).doubleValue)
    }
}
