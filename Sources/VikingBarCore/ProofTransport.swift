import Foundation

public enum ProofFailure: String, Codable, Error, Sendable {
    case invalidInput = "invalid_input"
    case requestDenied = "request_denied"
    case transport
    case httpStatus = "http_status"
    case malformedResponse = "malformed_response"
    case expiredToken = "expired_token"
    case emptySubscriptions = "empty_subscriptions"
}

public struct ProofHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data
    public let contentType: String?

    public init(statusCode: Int, data: Data, contentType: String? = nil) {
        self.statusCode = statusCode
        self.data = data
        self.contentType = contentType
    }
}

public protocol ProofHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ProofHTTPResponse
}

/// Approved authentication and read-only account operations.
public enum ProofEndpoint: Sendable {
    case token
    case subscriptions
    case balance(subscriptionID: String)
    case usageSummary(subscriptionID: String, from: Date, until: Date)
    case pointsBalance
    case pointsTransactions(page: Int)
    case invoices(page: Int)
    case invoicePDF(id: String)

    public func request() throws -> URLRequest {
        if case let .usageSummary(subscriptionID, from, until) = self {
            return try Self.summaryRequest(subscriptionID: subscriptionID, from: from, until: until)
        }
        let path = try self.path()
        guard let url = URL(string: "https://uwa.mobilevikings.be/mv\(path)") else {
            throw ProofFailure.requestDenied
        }
        var request = URLRequest(url: url)
        request.httpMethod = if case .token = self {
            "POST"
        } else {
            "GET"
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if case .invoicePDF = self {
            // The PDF endpoint rejects application/pdf in Accept.
            request.setValue("*/*", forHTTPHeaderField: "Accept")
        }
        return request
    }

    private func path() throws -> String {
        let path: String
        switch self {
        case .token: path = "/oauth2/token/"
        case .subscriptions: path = "/subscriptions"
        case .pointsBalance: path = "/loyalty-points/balance"
        case .usageSummary: throw ProofFailure.requestDenied
        case let .pointsTransactions(page):
            path = try Self.pagePath("/loyalty-points/transactions", page: page, limit: 3)
        case let .invoices(page):
            path = try Self.pagePath("/invoices", page: page, limit: 5)
        case let .invoicePDF(id):
            guard Self.validIdentifier(id) else { throw ProofFailure.requestDenied }
            path = "/invoices/\(id)/pdf"
        case let .balance(subscriptionID):
            guard Self.validIdentifier(subscriptionID) else { throw ProofFailure.requestDenied }
            path = "/subscriptions/\(subscriptionID)/balance"
        }
        return path
    }

    public static func validate(_ request: URLRequest) throws {
        guard let url = request.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "uwa.mobilevikings.be",
              parts.port == nil, parts.user == nil, parts.password == nil,
              parts.fragment == nil
        else { throw ProofFailure.requestDenied }
        let path = parts.percentEncodedPath
        let paginated = ["/mv/invoices", "/mv/loyalty-points/transactions"].contains(path)
        if let query = parts.percentEncodedQuery, paginated {
            try Self.validatePageQuery(path: path, query: query, method: request.httpMethod)
            return
        }
        if request.httpMethod == "GET", parts.query == nil, path == "/mv/loyalty-points/balance" {
            return
        }
        if request.httpMethod == "POST", parts.query == nil, path == "/mv/oauth2/token/" {
            return
        }
        if request.httpMethod == "GET", parts.query == nil, path == "/mv/subscriptions" {
            return
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard request.httpMethod == "GET", segments.count == 5,
              segments[0].isEmpty, segments[1] == "mv", Self.validIdentifier(String(segments[3]))
        else { throw ProofFailure.requestDenied }
        let allowed = (segments[2] == "subscriptions" && segments[4] == "balance")
            || (segments[2] == "invoices" && segments[4] == "pdf")
        if allowed, parts.query == nil {
            return
        }
        guard segments[2] == "subscriptions", segments[4] == "usage-summary", request.httpBody == nil,
              let query = parts.queryItems, query.count == 4,
              Set(query.map(\.name)) == ["traffic_type", "direction", "from_date", "until_date"],
              query.first(where: { $0.name == "traffic_type" })?.value == "data",
              query.first(where: { $0.name == "direction" })?.value == "outgoing",
              let fromText = query.first(where: { $0.name == "from_date" })?.value,
              let untilText = query.first(where: { $0.name == "until_date" })?.value,
              let from = Self.summaryDate(fromText), let until = Self.summaryDate(untilText),
              from < until, until.timeIntervalSince(from) <= 90000
        else { throw ProofFailure.requestDenied }
    }

    private static func pagePath(_ path: String, page: Int, limit: Int) throws -> String {
        guard (1 ... limit).contains(page) else { throw ProofFailure.requestDenied }
        return "\(path)?page=\(page)&per_page=20"
    }

    private static func validatePageQuery(path: String, query: String, method: String?) throws {
        let limit: Int
        switch path {
        case "/mv/invoices": limit = 5
        case "/mv/loyalty-points/transactions": limit = 3
        default: throw ProofFailure.requestDenied
        }
        guard method == "GET", (1 ... limit).contains(where: { query == "page=\($0)&per_page=20" })
        else { throw ProofFailure.requestDenied }
    }

    private static func summaryRequest(subscriptionID: String, from: Date, until: Date) throws -> URLRequest {
        guard self.validIdentifier(subscriptionID), from < until,
              until.timeIntervalSince(from) <= 90000 else { throw ProofFailure.requestDenied }
        var parts =
            URLComponents(string: "https://uwa.mobilevikings.be/mv/subscriptions/\(subscriptionID)/usage-summary")!
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        parts.queryItems = [
            URLQueryItem(name: "traffic_type", value: "data"),
            URLQueryItem(name: "direction", value: "outgoing"),
            URLQueryItem(name: "from_date", value: formatter.string(from: from)),
            URLQueryItem(name: "until_date", value: formatter.string(from: until)),
        ]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try Self.validate(request)
        return request
    }

    private static func summaryDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard text.hasSuffix("Z"), let date = formatter.date(from: text),
              formatter.string(from: date) == text else { return nil }
        return date
    }

    private static func validIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

public final class EphemeralProofTransport: NSObject, ProofHTTPTransport, URLSessionTaskDelegate {
    public func send(_ request: URLRequest) async throws -> ProofHTTPResponse {
        try ProofEndpoint.validate(request)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = request.url?.path.hasSuffix("/usage-summary") == true
            ? request.timeoutInterval : 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ProofFailure.transport }
            guard response.url == request.url else { throw ProofFailure.requestDenied }
            let limit = request.url?.path.hasSuffix("/pdf") == true ? 10_485_760 : 2_097_152
            guard response.expectedContentLength <= limit else { throw ProofFailure.malformedResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw ProofFailure.malformedResponse }
                data.append(byte)
            }
            return ProofHTTPResponse(
                statusCode: response.statusCode, data: data,
                contentType: response.value(forHTTPHeaderField: "Content-Type"),
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ProofFailure.transport
        }
    }

    public func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void,
    ) {
        completionHandler(nil)
    }
}
