import Foundation

struct LiveToken: Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scopeMismatch: Bool
}

struct LiveAPI: Sendable {
    let transport: any ProofHTTPTransport
    let now: @Sendable () -> Date

    func token(fields: [String: String]) async throws -> LiveToken {
        var request = try ProofEndpoint.token.request()
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.keys.sorted().map { "\(Self.form($0))=\(Self.form(fields[$0]!))" }
            .joined(separator: "&").utf8)
        let started = self.now()
        let data = try await self.send(request, tokenExchange: true)
        let response: ProofTokenResponse
        do { response = try JSONDecoder().decode(ProofTokenResponse.self, from: data) } catch {
            throw LiveFailure.malformedResponse
        }
        guard !response.accessToken.isEmpty, !response.refreshToken.isEmpty,
              !response.accessToken.contains(where: { $0.isWhitespace || $0.isNewline }),
              response.tokenType.lowercased() == "bearer", response.expiresIn.isFinite, response.expiresIn > 0
        else { throw LiveFailure.malformedResponse }
        return LiveToken(
            accessToken: response.accessToken, refreshToken: response.refreshToken,
            expiresAt: started.addingTimeInterval(response.expiresIn),
            scopeMismatch: Set(response.scope.split(whereSeparator: { $0.isWhitespace })) != ["read"],
        )
    }

    func subscriptions(token: LiveToken) async throws -> [MobileSubscription] {
        let data = try await self.get(.subscriptions, token: token)
        return try Self.decodeSubscriptions(data)
    }

    func balance(subscriptionID: String, token: LiveToken) async throws -> LiveBalance {
        try await Self.decodeBalance(self.get(.balance(subscriptionID: subscriptionID), token: token))
    }

    func get(_ endpoint: ProofEndpoint, token: LiveToken) async throws -> Data {
        try Task.checkCancellation()
        guard self.now() < token.expiresAt else { throw LiveFailure.tokenExpired }
        var request = try endpoint.request()
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        return try await self.send(request)
    }

    func send(_ request: URLRequest, tokenExchange: Bool = false) async throws -> Data {
        do { try ProofEndpoint.validate(request) } catch { throw LiveFailure.requestDenied }
        let response: ProofHTTPResponse
        do { response = try await self.transport.send(request) } catch is CancellationError {
            throw CancellationError()
        } catch { throw LiveFailure.transport }
        switch response.statusCode {
        case 200: return response.data
        case 400 where tokenExchange, 401, 403: throw LiveFailure.unauthorized
        case 429: throw LiveFailure.rateLimited
        case 500 ... 599: throw LiveFailure.serverUnavailable
        default: throw LiveFailure.malformedResponse
        }
    }

    static func decodeSubscriptions(_ data: Data) throws -> [MobileSubscription] {
        do {
            let values = try JSONDecoder().decode([SubscriptionResponse].self, from: data)
            guard Set(values.map(\.id)).count == values.count else { throw LiveFailure.malformedResponse }
            return try values.compactMap { value in
                guard ["postpaid", "prepaid", "fixed-internet", "third-party"].contains(value.type) else {
                    throw LiveFailure.malformedResponse
                }
                _ = try ProofEndpoint.balance(subscriptionID: value.id).request()
                guard ["postpaid", "prepaid"].contains(value.type) else { return nil }
                return MobileSubscription(
                    id: value.id,
                    displayName: [value.sim?.alias, value.sim?.msisdn].compactMap(\.self)
                        .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                        ?? "SIM \(value.id)", type: value.type,
                )
            }
        } catch { throw LiveFailure.malformedResponse }
    }

    static func decodeBalance(_ data: Data) throws -> LiveBalance {
        do {
            let response = try JSONDecoder().decode(BalanceResponse.self, from: data)
            let bundles = try response.bundles.map { value in
                guard ["data", "sms", "voice", "value"].contains(value.type),
                      ["default", "super_on_net", "loyalty", "unknown"].contains(value.category),
                      let from = Self.date(value.validFrom), let until = Self.date(value.validUntil), until >= from,
                      !value.total.isNaN, !value.used.isNaN, !value.remaining.isNaN
                else { throw LiveFailure.malformedResponse }
                return BalanceBundle(
                    title: value.descriptions.title, description: value.descriptions.description,
                    category: value.category, type: value.type, total: value.total, used: value.used,
                    remaining: value.remaining, validFrom: from, validUntil: until,
                )
            }
            let regionalities = ["national", "roam_like_at_home", "rest_of_world"]
            if let region = response.regionality, !regionalities.contains(region) {
                throw LiveFailure.malformedResponse
            }
            return LiveBalance(
                bundles: bundles, regionality: response.regionality, outOfBundleCost: response.outOfBundleCost,
            )
        } catch { throw LiveFailure.malformedResponse }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func form(_ text: String) -> String {
        text.utf8.map { byte in
            switch byte {
            case 65 ... 90, 97 ... 122, 48 ... 57, 45, 46, 95, 126: String(UnicodeScalar(byte))
            default: String(format: "%%%02X", byte)
            }
        }.joined()
    }
}

private struct SubscriptionResponse: Decodable {
    let id: String
    let type: String
    let sim: SIMIdentity?
}

private struct SIMIdentity: Decodable {
    let alias: String?
    let msisdn: String?
}

private struct BalanceResponse: Decodable {
    let bundles: [BundleResponse]
    let regionality: String?
    let outOfBundleCost: Decimal?

    enum CodingKeys: String, CodingKey {
        case bundles, regionality
        case outOfBundleCost = "out_of_bundle_cost"
    }
}

private struct BundleResponse: Decodable {
    let descriptions: BundleDescriptions
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
}

private struct BundleDescriptions: Decodable {
    let title: String
    let description: String
}
