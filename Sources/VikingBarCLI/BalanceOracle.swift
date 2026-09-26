import Foundation
import VikingBarCore

struct BalanceAPIReceipt: Encodable {
    let schemaVersion = 1
    let check = "balance-api"
    let passed = true
    let apiMatches = true
    let tokenRefreshed = true
    let bundleCount: Int
    let bundleTypes: [String: Int]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case apiMatches = "api_matches"
        case tokenRefreshed = "token_refreshed"
        case bundleCount = "bundle_count"
        case bundleTypes = "bundle_types"
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
                  raw.type == actual.type.rawValue, raw.category == actual.category,
                  raw.descriptions.title == actual.title, raw.descriptions.description == actual.description,
                  try raw.startDate() == actual.validFrom, try raw.endDate() == actual.validUntil
            else { throw ProofFailure.malformedResponse }
        }
        let raw = oracle.bundles[index]
        guard raw.type == "data", try raw.startDate() <= updated, try raw.endDate() > updated,
              try raw.endDate() == state.snapshot.expiresAt
        else { throw ProofFailure.malformedResponse }
        try raw.verify(snapshot: state.snapshot)
        try oracle.verify(bundles: balance.bundles, at: updated)
        return try BalanceAPIReceipt(bundleCount: oracle.bundles.count, bundleTypes: oracle.bundleTypes())
    }
}

private struct OracleSubscription: Decodable {
    let id: String
    let type: String
}

struct OracleBalance: Decodable {
    let bundles: [OracleBundle]
    let regionality: String?
    let outOfBundleCost: Decimal?

    enum CodingKeys: String, CodingKey {
        case bundles, regionality
        case outOfBundleCost = "out_of_bundle_cost"
    }

    func bundleTypes() throws -> [String: Int] {
        let kinds = ["data", "sms", "voice", "value"]
        guard self.bundles.allSatisfy({ kinds.contains($0.type) }) else { throw ProofFailure.malformedResponse }
        return Dictionary(uniqueKeysWithValues: kinds.map { kind in (kind, self.bundles.count { $0.type == kind }) })
    }

    func verify(bundles actual: [BalanceBundle], at now: Date) throws {
        let rows = BundleRowPresentation.rows(for: actual, at: now, timeZone: OracleBundle.utc)
        guard actual.count == self.bundles.count,
              rows.map(\.index) == self.bundles.indices.filter({ self.bundles[$0].type != "data" })
        else { throw ProofFailure.malformedResponse }
        for (index, raw) in self.bundles.enumerated() {
            try raw.verify(bundle: actual[index], row: rows.first { $0.index == index }, index: index, at: now)
        }
    }
}

struct OracleBundle: Decodable {
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

extension OracleBundle {
    private enum Amounts: Equatable {
        case finite(total: Decimal, used: Decimal, remaining: Decimal)
        case unlimited(used: Decimal)
        case unavailable
    }

    private struct Kind: Sendable {
        let label: String
        let name: String
        let format: @Sendable (Decimal) -> String
    }

    static let utc = TimeZone(identifier: "UTC")!

    private static let kinds: [String: Kind] = [
        "sms": Kind(label: "SMS", name: "SMS bundle") { "\($0) SMS" },
        "voice": Kind(label: "Calls", name: "Call bundle", format: Self.duration),
        "value": Kind(label: "Credit", name: "Credit bundle", format: Self.euros),
    ]

    func verify(bundle: BalanceBundle, row: BundleRowPresentation?, index: Int, at now: Date) throws {
        let expected = try self.amounts(at: now)
        let typed: BundleBalance = self.type == "data" ? .data(bundle.allowance(at: now)) : bundle.balance(at: now)
        guard Self.amounts(of: typed, type: self.type) == expected, (row == nil) == (self.type == "data")
        else { throw ProofFailure.malformedResponse }
        if let row {
            try self.verify(row: row, amounts: expected, index: index, at: now)
        }
    }

    private func amounts(at now: Date) throws -> Amounts {
        let integral = self.type != "value"
        func representable(_ amount: Decimal) -> Bool {
            var source = amount
            var whole = Decimal()
            NSDecimalRound(&whole, &source, 0, .down)
            return !amount.isNaN && amount >= 0 && (!integral || (whole == amount && amount <= Decimal(UInt64.max)))
        }
        guard try self.startDate() <= now, try now < self.endDate(), representable(self.used) else {
            return .unavailable
        }
        if self.total == -1 {
            return .unlimited(used: self.used)
        }
        guard representable(self.total), representable(self.remaining) else { return .unavailable }
        return .finite(total: self.total, used: self.used, remaining: self.remaining)
    }

    private static func amounts(of balance: BundleBalance, type: String) -> Amounts? {
        switch (type, balance) {
        case let ("data", .data(.finite(total, used, remaining))):
            .finite(total: Decimal(total), used: Decimal(used), remaining: Decimal(remaining))
        case let ("data", .data(.unlimited(used))): .unlimited(used: Decimal(used))
        case ("data", .data(.unavailable)): .unavailable
        case let ("sms", .sms(metered)): Self.amounts(of: metered) { Decimal($0.count) }
        case let ("voice", .voice(metered)): Self.amounts(of: metered) { Decimal($0.seconds) }
        case let ("value", .value(metered)): Self.amounts(of: metered, \.euros)
        default: nil
        }
    }

    private static func amounts<Amount>(of metered: Metered<Amount>, _ decimal: (Amount) -> Decimal) -> Amounts {
        switch metered {
        case let .finite(total, used, remaining):
            .finite(total: decimal(total), used: decimal(used), remaining: decimal(remaining))
        case let .unlimited(used): .unlimited(used: decimal(used))
        case .unavailable: .unavailable
        }
    }

    private func verify(row: BundleRowPresentation, amounts: Amounts, index: Int, at now: Date) throws {
        guard let kind = Self.kinds[self.type] else { throw ProofFailure.malformedResponse }
        let texts: [String] = switch amounts {
        case let .finite(total, used, remaining):
            [kind.format(remaining), "\(kind.format(used)) used", "\(kind.format(total)) total",
             remaining == 0 ? "exhausted" : "finite"]
        case let .unlimited(used): ["Unlimited", "\(kind.format(used)) used", "Unlimited allowance", "unlimited"]
        case .unavailable: ["Unavailable", "Usage unavailable", "Allowance unavailable", "unavailable"]
        }
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.timeZone = Self.utc
        dates.dateFormat = "d MMM yyyy, HH:mm z"
        let start = try self.startDate()
        let end = try self.endDate()
        let validity: [String] = if now < start {
            ["Starts \(dates.string(from: start))", "upcoming"]
        } else if now >= end {
            ["Expired \(dates.string(from: end))", "expired"]
        } else {
            ["Expires \(dates.string(from: end))", texts[3]]
        }
        let percentage: Double? = if case let .finite(total, _, remaining) = amounts, total != 0 {
            min(100, NSDecimalNumber(decimal: remaining / total * 100).doubleValue)
        } else {
            nil
        }
        let title = self.descriptions.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (row.percentageRemaining == nil) == (percentage == nil),
              abs((row.percentageRemaining ?? 0) - (percentage ?? 0)) < 0.000001,
              row.index == index, row.kind.rawValue == self.type,
              row.title == (title.isEmpty ? "\(kind.name) \(index + 1)" : title),
              row.description == self.descriptions.description,
              [row.remainingText, row.usedText, row.totalText] == Array(texts[0 ..< 3]),
              row.detailText == "\(kind.label) · \(self.category)",
              [row.validityText, row.state.rawValue] == validity
        else { throw ProofFailure.malformedResponse }
    }

    private static func duration(_ seconds: Decimal) -> String {
        let total = NSDecimalNumber(decimal: seconds).uint64Value
        let minutes = total / 60
        let rest = total % 60
        if total == 0 {
            return "0 min"
        }
        if minutes == 0 {
            return "\(rest) s"
        }
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }

    private static func euros(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.locale = Locale(identifier: "en_IE")
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? ""
    }
}
