import Foundation

public enum ProofCheck: String, Codable, Sendable {
    case authBalance = "auth-balance"
}

public struct ProofCredentials: Decodable, Sendable {
    public let clientID: String
    public let username: String
    public let password: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case username, password
    }

    public init(clientID: String, username: String, password: String) {
        self.clientID = clientID
        self.username = username
        self.password = password
    }

    public func validate() throws {
        guard !self.clientID.isEmpty, !self.username.isEmpty, !self.password.isEmpty else {
            throw ProofFailure.invalidInput
        }
    }
}

public struct ProofReceipt: Encodable, Sendable {
    public let schemaVersion = 1
    public let check: ProofCheck
    public var passed = false
    public var passwordGrant = false
    public var refreshGrant = false
    public var scopeMismatch = false
    public var subscriptionCount = 0
    public var balanceCount = 0
    public var failure: ProofFailure?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case check, passed, failure
        case passwordGrant = "password_grant"
        case refreshGrant = "refresh_grant"
        case scopeMismatch = "scope_mismatch"
        case subscriptionCount = "subscription_count"
        case balanceCount = "balance_count"
    }

    public init(check: ProofCheck = .authBalance, failure: ProofFailure? = nil) {
        self.check = check
        self.failure = failure
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.schemaVersion, forKey: .schemaVersion)
        try container.encode(self.check, forKey: .check)
        try container.encode(self.passed, forKey: .passed)
        try container.encode(self.passwordGrant, forKey: .passwordGrant)
        try container.encode(self.refreshGrant, forKey: .refreshGrant)
        try container.encode(self.scopeMismatch, forKey: .scopeMismatch)
        try container.encode(self.subscriptionCount, forKey: .subscriptionCount)
        try container.encode(self.balanceCount, forKey: .balanceCount)
        try container.encode(self.failure, forKey: .failure)
    }
}

public struct AuthBalanceProof: Sendable {
    private let transport: any ProofHTTPTransport
    private let now: @Sendable () -> Date

    public init(transport: any ProofHTTPTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    public func run(check: ProofCheck = .authBalance, credentials: ProofCredentials) async -> ProofReceipt {
        var receipt = ProofReceipt(check: check)
        do {
            try credentials.validate()
            let initial = try await self.token(fields: [
                "client_id": credentials.clientID, "username": credentials.username,
                "password": credentials.password, "grant_type": "password", "scope": "read",
            ])
            receipt.passwordGrant = true
            receipt.scopeMismatch = initial.scopeMismatch
            let refreshed = try await self.token(fields: [
                "client_id": credentials.clientID, "refresh_token": initial.refreshToken,
                "grant_type": "refresh_token",
            ])
            receipt.refreshGrant = true
            receipt.scopeMismatch = receipt.scopeMismatch || refreshed.scopeMismatch
            let subscriptions: [ProofSubscription] = try await self.get(.subscriptions, token: refreshed)
            guard !subscriptions.isEmpty else { throw ProofFailure.emptySubscriptions }
            guard Set(subscriptions.map(\.id)).count == subscriptions.count,
                  subscriptions.allSatisfy({ !$0.id.isEmpty })
            else { throw ProofFailure.malformedResponse }
            receipt.subscriptionCount = subscriptions.count
            for subscription in subscriptions {
                let balance: ProofBalance = try await self.get(
                    .balance(subscriptionID: subscription.id),
                    token: refreshed,
                )
                try balance.validate()
                receipt.balanceCount += 1
            }
            receipt.passed = receipt.balanceCount == receipt.subscriptionCount
        } catch let failure as ProofFailure {
            receipt.failure = failure
        } catch {
            receipt.failure = .malformedResponse
        }
        return receipt
    }

    private func token(fields: [String: String]) async throws -> ProofToken {
        var request = try ProofEndpoint.token.request()
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(fields.keys.sorted().map { "\(Self.form($0))=\(Self.form(fields[$0]!))" }
            .joined(separator: "&").utf8)
        // Measure lifetime from before the exchange, avoiding overestimating it by network latency.
        let started = self.now()
        let response: ProofTokenResponse = try await self.decode(request)
        let token = try ProofToken(response: response, issuedAt: started)
        guard self.now() < token.expiresAt else { throw ProofFailure.expiredToken }
        return token
    }

    private func get<Value: Decodable>(_ endpoint: ProofEndpoint, token: ProofToken) async throws -> Value {
        guard self.now() < token.expiresAt else { throw ProofFailure.expiredToken }
        var request = try endpoint.request()
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        return try await self.decode(request)
    }

    private func decode<Value: Decodable>(_ request: URLRequest) async throws -> Value {
        try ProofEndpoint.validate(request)
        let response: ProofHTTPResponse
        do { response = try await self.transport.send(request) } catch { throw ProofFailure.transport }
        guard response.statusCode == 200 else { throw ProofFailure.httpStatus }
        do { return try JSONDecoder().decode(Value.self, from: response.data) } catch {
            throw ProofFailure.malformedResponse
        }
    }

    private static func form(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 65 ... 90, 97 ... 122, 48 ... 57, 45, 46, 95, 126: String(UnicodeScalar(byte))
            default: String(format: "%%%02X", byte)
            }
        }.joined()
    }
}

struct ProofTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Double
    let scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }
}

private struct ProofToken {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scopeMismatch: Bool

    init(response: ProofTokenResponse, issuedAt: Date) throws {
        guard !response.accessToken.isEmpty, !response.refreshToken.isEmpty,
              response.tokenType.lowercased() == "bearer",
              response.expiresIn.isFinite, response.expiresIn > 0,
              !response.accessToken.contains(where: { $0.isWhitespace || $0.isNewline })
        else { throw ProofFailure.malformedResponse }
        self.accessToken = response.accessToken
        self.refreshToken = response.refreshToken
        self.expiresAt = issuedAt.addingTimeInterval(response.expiresIn)
        self.scopeMismatch = Set(response.scope.split(whereSeparator: { $0.isWhitespace })) != ["read"]
    }
}

private struct ProofSubscription: Decodable {
    let id: String
}

private struct ProofBalance: Decodable {
    let bundles: [ProofBalanceBundle]

    func validate() throws {
        let formatter = ISO8601DateFormatter()
        for bundle in self.bundles {
            guard ["sms", "data", "voice", "value"].contains(bundle.type),
                  ["default", "super_on_net", "loyalty", "unknown"].contains(bundle.category),
                  Self.date(bundle.validFrom, formatter: formatter) != nil,
                  Self.date(bundle.validUntil, formatter: formatter) != nil,
                  bundle.total.isFinite, bundle.remaining.isFinite, bundle.used.isFinite
            else { throw ProofFailure.malformedResponse }
        }
    }

    private static func date(_ value: String, formatter: ISO8601DateFormatter) -> Date? {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct ProofBalanceBundle: Decodable {
    let descriptions: ProofBalanceDescriptions
    let category: String
    let validFrom: String
    let validUntil: String
    let type: String
    let total: Double
    let remaining: Double
    let used: Double

    enum CodingKeys: String, CodingKey {
        case descriptions, category, type, total, remaining, used
        case validFrom = "valid_from"
        case validUntil = "valid_until"
    }
}

private struct ProofBalanceDescriptions: Decodable {
    let title: String
    let description: String
}
