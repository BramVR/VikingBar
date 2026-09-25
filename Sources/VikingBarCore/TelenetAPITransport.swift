import Foundation

public struct TelenetCredentials: Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public func validate() throws {
        guard [self.username, self.password].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 }) else {
            throw ProofFailure.invalidInput
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32768,
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              Set(fields.keys) == ["username", "password"],
              let username = fields["username"], let password = fields["password"]
        else { throw ProofFailure.invalidInput }
        let credentials = Self(username: username, password: password)
        try credentials.validate()
        return credentials
    }
}

public struct TelenetResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    func header(_ name: String) -> String? {
        self.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public protocol TelenetTransport: Sendable {
    func send(_ request: URLRequest) async throws -> TelenetResponse
}

public struct TelenetRequestFailure: Error, Sendable {
    public let failure: LiveFailure
    public let retryAfter: Date?

    public init(failure: LiveFailure, retryAfter: Date? = nil) {
        self.failure = failure
        self.retryAfter = retryAfter
    }
}

public final class EphemeralTelenetTransport: NSObject, TelenetTransport, URLSessionTaskDelegate {
    public func send(_ request: URLRequest) async throws -> TelenetResponse {
        try TelenetEndpoint.validate(request)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = min(12, request.timeoutInterval)
        configuration.timeoutIntervalForResource = min(12, request.timeoutInterval)
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw LiveFailure.transport }
            guard response.url == request.url else { throw LiveFailure.requestDenied }
            guard response.expectedContentLength <= TelenetEndpoint.maximumBody else {
                throw LiveFailure.malformedResponse
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < TelenetEndpoint.maximumBody else { throw LiveFailure.malformedResponse }
                data.append(byte)
            }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            return TelenetResponse(status: response.statusCode, headers: headers, body: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let failure as LiveFailure {
            throw failure
        } catch {
            throw LiveFailure.transport
        }
    }

    public func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void,
    ) {
        completionHandler(nil)
    }
}

enum TelenetEndpoint {
    static let api = "https://api.prd.telenet.be"
    static let secure = "https://secure.telenet.be"
    static let maximumBody = 262_144
    static let authorization = api + "/ocapi/login/authorization/telenet_be?lang=nl&style_hint=care"
        + "&targetUrl=https%3A%2F%2Fwww2.telenet.be%2Fresidential%2Fnl%2Fmytelenet%2F"
    static let products = api + "/ocapi/public/api/product-service/v1/product-subscriptions?producttypes=PLAN"

    static func identifier(_ value: String) -> Bool {
        (1 ... 100).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    static func day(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    static func validate(_ request: URLRequest) throws {
        guard let url = request.url, url.absoluteString.utf8.count <= 16384,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil,
              let host = parts.host, ["api.prd.telenet.be", "secure.telenet.be"].contains(host),
              parts.percentEncodedHost == host, parts.percentEncodedPath == parts.path,
              request.httpBodyStream == nil
        else { throw LiveFailure.requestDenied }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ $0.value != nil && ($0.value?.utf8.count ?? 0) <= 8192 })
        else { throw LiveFailure.requestDenied }
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        if request.httpMethod == "POST" {
            try Self.validatePost(request, host: host, path: parts.path, query: query)
        } else {
            guard request.httpMethod == "GET", request.httpBody == nil,
                  Self.allowedGet(host: host, path: parts.path, query: query)
            else { throw LiveFailure.requestDenied }
        }
    }

    private static func validatePost(
        _ request: URLRequest, host: String, path: String, query: [String: String],
    ) throws {
        let fields: [String: Set<String>] = [
            "/idp/idx/introspect": ["stateToken"],
            "/idp/idx/identify": ["identifier", "stateHandle"],
            "/idp/idx/challenge": ["authenticator", "stateHandle"],
            "/idp/idx/challenge/answer": ["credentials", "stateHandle"],
            "/api/v1/internal/device/nonce": [],
        ]
        guard host == "secure.telenet.be", query.isEmpty, let expected = fields[path],
              let data = request.httpBody, data.count <= 32768,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(body.keys) == expected else { throw LiveFailure.requestDenied }
        for (key, value) in body {
            let leaf: Any
            if key == "authenticator" || key == "credentials" {
                let field = key == "authenticator" ? "id" : "passcode"
                guard let nested = value as? [String: String], Set(nested.keys) == [field],
                      let text = nested[field] else { throw LiveFailure.requestDenied }
                leaf = text
            } else {
                leaf = value
            }
            guard let text = leaf as? String, !text.isEmpty, text.utf8.count <= 8192 else {
                throw LiveFailure.requestDenied
            }
        }
    }

    private static func allowedGet(host: String, path: String, query: [String: String]) -> Bool {
        if host == "secure.telenet.be" {
            switch path {
            case "/oauth2/default/v1/authorize":
                return Set(query.keys) == ["client_id", "code_challenge", "code_challenge_method", "nonce",
                                           "redirect_uri", "response_type", "scope", "state"]
                    && query["redirect_uri"] == self.api + "/ocapi/login/callback/telenet_be"
                    && query["response_type"] == "code"
                    && query["scope"] == "openid profile licenses telenet.scopes offline_access"
                    && query["code_challenge_method"] == "S256"
                    && query.values.allSatisfy { !$0.isEmpty }
            case "/login/token/redirect": return Set(query.keys) == ["stateToken"] && query["stateToken"] != ""
            case "/auth/services/devicefingerprint": return query.isEmpty
            default: return false
            }
        }
        let fixed: [String: [String: String]] = [
            "/ocapi/oauth/userdetails": [:],
            "/ocapi/login/authorization/telenet_be": [
                "lang": "nl", "style_hint": "care", "targetUrl": "https://www2.telenet.be/residential/nl/mytelenet/",
            ],
            "/ocapi/public/api/product-service/v1/product-subscriptions": ["producttypes": "PLAN"],
        ]
        if let expected = fixed[path] {
            return query == expected
        }
        if path == "/ocapi/login/callback/telenet_be" {
            return Set(query.keys) == ["code", "state"] && query.values.allSatisfy { !$0.isEmpty }
        }
        return Self.allowedProduct(path: path, query: query)
    }

    private static func allowedProduct(path: String, query: [String: String]) -> Bool {
        let cyclePrefix = "/ocapi/public/api/billing-service/v1/account/products/"
        let usagePrefix = "/ocapi/public/api/product-service/v1/products/internet/"
        let routes = [(cyclePrefix, "/billcycle-details"), (usagePrefix, "/usage"), (usagePrefix, "/dailyusage")]
        for (prefix, suffix) in routes where path.hasPrefix(prefix) && path.hasSuffix(suffix) {
            let id = String(path.dropFirst(prefix.count).dropLast(suffix.count))
            guard Self.identifier(id) else { return false }
            if suffix == "/billcycle-details" {
                return query == ["producttype": "internet", "count": "3"]
            }
            let expected: Set<String> = suffix == "/dailyusage" ? ["fromDate", "toDate", "billcycle"]
                : ["fromDate", "toDate"]
            guard Set(query.keys) == expected, let start = query["fromDate"], let end = query["toDate"],
                  Self.day(start), Self.day(end), start <= end else { return false }
            return suffix != "/dailyusage" || query["billcycle"] == "CURRENT"
        }
        return false
    }
}
