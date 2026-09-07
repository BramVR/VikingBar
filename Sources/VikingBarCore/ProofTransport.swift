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

/// The explicit read-only account request allowlist.
public enum ProofEndpoint: Sendable {
    case token
    case subscriptions
    case balance(subscriptionID: String)
    case invoices(page: Int)
    case invoicePDF(id: String)

    public func request() throws -> URLRequest {
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
            request.setValue("application/pdf", forHTTPHeaderField: "Accept")
        }
        return request
    }

    private func path() throws -> String {
        let path: String
        switch self {
        case .token: path = "/oauth2/token/"
        case .subscriptions: path = "/subscriptions"
        case let .invoices(page):
            guard (1 ... 5).contains(page) else { throw ProofFailure.requestDenied }
            path = "/invoices?page=\(page)&per_page=20"
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
        if request.httpMethod == "GET", path == "/mv/invoices", let query = parts.percentEncodedQuery {
            guard (1 ... 5).contains(where: { query == "page=\($0)&per_page=20" }) else {
                throw ProofFailure.requestDenied
            }
            return
        }
        guard parts.query == nil else { throw ProofFailure.requestDenied }
        if request.httpMethod == "POST", path == "/mv/oauth2/token/" {
            return
        }
        if request.httpMethod == "GET", path == "/mv/subscriptions" {
            return
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard request.httpMethod == "GET", segments.count == 5,
              segments[0].isEmpty, segments[1] == "mv", Self.validIdentifier(String(segments[3]))
        else { throw ProofFailure.requestDenied }
        let allowed = (segments[2] == "subscriptions" && segments[4] == "balance")
            || (segments[2] == "invoices" && segments[4] == "pdf")
        guard allowed else { throw ProofFailure.requestDenied }
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
        configuration.timeoutIntervalForResource = 60
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
