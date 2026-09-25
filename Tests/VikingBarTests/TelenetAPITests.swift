import Foundation
import Testing
@testable import VikingBarCore

struct TelenetAPITests {
    @Test
    func `credentials accept only the two exact nonempty fields`() throws {
        let credentials = try TelenetCredentials.decode(Data(#"{"username":"reader","password":"test secret"}"#.utf8))
        #expect(credentials.username == "reader")
        #expect(credentials.password == "test secret")
        let invalid = [#"{"username":"reader","password":""}"#,
                       #"{"username":"reader","password":5}"#,
                       #"{"username":"reader","password":"test","client_id":"extra"}"#]
        for input in invalid {
            #expect(throws: ProofFailure.invalidInput) { try TelenetCredentials.decode(Data(input.utf8)) }
        }
    }

    @Test
    func `read returns separate policy and downloaded payloads only for discovered homes`() async throws {
        let transport = TelenetScript([
            Self.json(#"[{"productType":"BUNDLE","products":[{"productType":"INTERNET","identifier":"home-1"}]}]"#),
            Self.cycle, Self.usage, Self.daily,
        ])
        let api = TelenetAPI(transport: transport)
        await #expect(throws: LiveFailure.invalidSelection) { try await api.read(serviceID: "other") }
        #expect(try await api.discover() == ["home-1"])
        let payload = try await api.read(serviceID: "home-1")
        #expect(payload.usage == Data(#"{"internet":{"category":"FUP","totalUsage":{"units":3}}}"#.utf8))
        #expect(payload.dailyUsage == Data(#"{"internetUsage":[{"totalUsage":{"peak":4,"offPeak":5}}]}"#.utf8))
        #expect(payload.dailyFailure == nil)
        let requests = await transport.requests
        #expect(requests.map { $0.url!.path } == [
            "/ocapi/public/api/product-service/v1/product-subscriptions",
            "/ocapi/public/api/billing-service/v1/account/products/home-1/billcycle-details",
            "/ocapi/public/api/product-service/v1/products/internet/home-1/usage",
            "/ocapi/public/api/product-service/v1/products/internet/home-1/dailyusage",
        ])
        #expect(requests.last?.url?.query == "billcycle=CURRENT&fromDate=2026-09-01&toDate=2026-09-30")
    }

    @Test
    func `optional daily failure preserves policy reading and unshortened retry after`() async throws {
        let now = Date(timeIntervalSince1970: 1000)
        let transport = TelenetScript([
            Self.discovery, Self.cycle, Self.usage,
            TelenetResponse(status: 429, headers: ["Retry-After": "172800"]),
        ])
        let api = TelenetAPI(transport: transport, now: { now })
        _ = try await api.discover()
        let payload = try await api.read(serviceID: "home-1")
        #expect(payload.dailyFailure == .rateLimited)
        #expect(payload.dailyRetryAfter == Date(timeIntervalSince1970: 173_800))
        #expect(payload.usage == Self.usage.body)
        #expect(payload.dailyUsage == nil)
    }

    @Test
    func `daily authentication failure requires reconnect without another password attempt`() async throws {
        let transport = TelenetScript([Self.discovery, Self.cycle, Self.usage, TelenetResponse(status: 401)])
        let api = TelenetAPI(transport: transport)
        _ = try await api.discover()
        await #expect(throws: LiveFailure.unauthorized) { try await api.read(serviceID: "home-1") }
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "GET", "GET"])
    }

    @Test
    func `invalid civil dates stop before reading any usage`() async throws {
        for dates in [("2026-02-30", "2026-03-30"), ("2026-10-01", "2026-09-30")] {
            let cycle = Self.json("{\"billCycles\":[{\"startDate\":\"\(dates.0)\",\"endDate\":\"\(dates.1)\"}]}")
            let transport = TelenetScript([Self.discovery, cycle])
            let api = TelenetAPI(transport: transport)
            _ = try await api.discover()
            await #expect(throws: LiveFailure.malformedResponse) { try await api.read(serviceID: "home-1") }
            #expect(await transport.requests.count == 2)
        }
    }

    @Test
    func `discovery rejects duplicate unsafe and excessive identifiers`() async throws {
        let row = #"{"productType":"internet","identifier":"home-1"}"#
        let invalid = ["[" + row + "," + row + "]",
                       #"[{"productType":"internet","identifier":"../bad"}]"#,
                       "[" + (1 ... 9).map { #"{"productType":"internet","identifier":"home-\#($0)"}"# }
                           .joined(separator: ",") + "]"]
        for body in invalid {
            let api = TelenetAPI(transport: TelenetScript([Self.json(body)]))
            await #expect(throws: LiveFailure.malformedResponse) { try await api.discover() }
        }
    }

    @Test
    func `read redirects are rejected and retry dates are retained`() async throws {
        let redirected = TelenetAPI(transport: TelenetScript([
            TelenetResponse(status: 302, headers: ["Location": "https://secure.telenet.be/login"]),
        ]))
        await #expect(throws: LiveFailure.reconnectRequired) { try await redirected.discover() }
        let limited = TelenetAPI(transport: TelenetScript([
            TelenetResponse(status: 503, headers: ["Retry-After": "Thu, 24 Sep 2026 12:00:00 GMT"]),
        ]))
        do {
            _ = try await limited.discover()
            Issue.record("Expected server-unavailable failure")
        } catch let error as TelenetRequestFailure {
            #expect(error.failure == .serverUnavailable)
            #expect(error.retryAfter == ISO8601DateFormatter().date(from: "2026-09-24T12:00:00Z"))
        }
    }

    @Test
    func `response body and request budget remain bounded with an injected transport`() async throws {
        let oversized = TelenetAPI(transport: TelenetScript([
            TelenetResponse(status: 200, body: Data(repeating: 65, count: 262_145)),
        ]))
        await #expect(throws: LiveFailure.malformedResponse) { try await oversized.discover() }
        let api = TelenetAPI(transport: TelenetScript(Array(repeating: Self.discovery, count: 64)))
        for _ in 0 ..< 64 {
            #expect(try await api.discover() == ["home-1"])
        }
        await #expect(throws: LiveFailure.requestDenied) { try await api.discover() }
    }

    @Test
    func `request allowlist excludes writes mobile data foreign redirects and malformed queries`() throws {
        let allowed = [
            "https://api.prd.telenet.be/ocapi/public/api/product-service/v1/products/internet/home-1/usage"
                + "?fromDate=2026-09-01&toDate=2026-09-30",
            "https://api.prd.telenet.be/ocapi/public/api/product-service/v1/products/internet/home-1/dailyusage"
                + "?billcycle=CURRENT&fromDate=2026-09-01&toDate=2026-09-30",
        ]
        for address in allowed {
            try TelenetEndpoint.validate(URLRequest(url: #require(URL(string: address))))
        }
        let denied = [
            "https://api.prd.telenet.be:443/ocapi/oauth/userdetails",
            "https://user@api.prd.telenet.be/ocapi/oauth/userdetails",
            "https://api.prd.telenet.be/ocapi/oauth/userdetails#fragment",
            "https://evil.test/ocapi/oauth/userdetails",
            "https://api.prd.telenet.be/ocapi/public/api/customer-web-billing-mobile-line-selector/v1/mobile-lines",
            allowed[0] + "&fromDate=2026-09-01",
            allowed[0].replacingOccurrences(of: "home-1", with: "%2e%2e"),
            allowed[1].replacingOccurrences(of: "CURRENT", with: "PREVIOUS"),
        ]
        for address in denied {
            #expect(throws: LiveFailure.requestDenied) {
                try TelenetEndpoint.validate(URLRequest(url: #require(URL(string: address))))
            }
        }
        var write = try URLRequest(url: #require(URL(string: allowed[0])))
        write.httpMethod = "POST"
        write.httpBody = Data("{}".utf8)
        #expect(throws: LiveFailure.requestDenied) { try TelenetEndpoint.validate(write) }
    }
}

extension TelenetAPITests {
    @Test
    func `cookie persistence excludes unrelated domains insecure values and wrong host paths`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let url = try #require(URL(string: "https://api.prd.telenet.be/ocapi/oauth/userdetails"))
        var jar = TelenetCookieJar()
        try jar.receive(
            TelenetResponse(status: 200, headers: ["Set-Cookie":
                    "session=kept; Path=/ocapi; Secure; Expires=Thu, 24 Sep 2026 12:00:00 GMT, "
                    + "broad=discarded; Domain=.be; Path=/; Secure, insecure=discarded; Path=/"]),
            from: url,
            at: now,
        )
        #expect(jar.header(for: url, at: now) == "session=kept")
        #expect(jar.usable(at: now))
        #expect(try jar.header(
            for: #require(URL(string: "https://secure.telenet.be/ocapi/oauth/userdetails")),
            at: now,
        ) == nil)
        #expect(try jar.header(for: #require(URL(string: "https://api.prd.telenet.be/ocapievil")), at: now) == nil)
        let saved = try JSONEncoder().encode(jar)
        #expect(try #require(String(data: saved, encoding: .utf8)).contains("discarded") == false)
        let restored = try JSONDecoder().decode(TelenetCookieJar.self, from: saved)
        #expect(restored.header(for: url, at: now) == "session=kept")
        #expect(!restored.usable(at: Date.distantFuture))
        #expect(restored.header(for: url, at: .distantFuture) == nil)
    }

    @Test
    func `parent cookies preserve domain scope only across allowed hosts`() throws {
        let now = Date()
        let api = try #require(URL(string: "https://api.prd.telenet.be/ocapi/oauth/userdetails"))
        let secure = try #require(URL(string: "https://secure.telenet.be/ocapi/oauth/userdetails"))
        var jar = TelenetCookieJar()
        try jar.receive(
            TelenetResponse(status: 200, headers: ["Set-Cookie":
                    "shared=parent; Domain=.telenet.be; Path=/; Secure, "
                    + "production=api; Domain=.prd.telenet.be; Path=/; Secure, local=host; Path=/; Secure"]),
            from: api,
            at: now,
        )
        let restored = try JSONDecoder().decode(TelenetCookieJar.self, from: JSONEncoder().encode(jar))
        #expect(restored.header(for: api, at: now) == "shared=parent; production=api; local=host")
        #expect(restored.header(for: secure, at: now) == "shared=parent")
        #expect(try restored.header(for: #require(URL(string: "https://www2.telenet.be/")), at: now) == nil)
        #expect(try restored.header(for: #require(URL(string: "https://evil.telenet.be/")), at: now) == nil)
        try jar.receive(TelenetResponse(status: 200, headers: ["Set-Cookie":
                "production=forged; Domain=.prd.telenet.be; Path=/; Secure"]), from: secure, at: now)
        #expect(jar.header(for: api, at: now) == "shared=parent; production=api; local=host")
    }

    @Test
    func `login performs one password answer and validates callback state`() async throws {
        let transport = TelenetScript(Self.loginResponses())
        let api = TelenetAPI(transport: transport)
        try await api.login(credentials: TelenetCredentials(username: "reader", password: "test secret"))
        #expect(await api.cookies.usable(at: Date()))
        let requests = await transport.requests
        let answer = try #require(requests.first { $0.url?.path == "/idp/idx/challenge/answer" })
        #expect(try JSONSerialization.jsonObject(with: #require(answer.httpBody)) as? NSDictionary == [
            "credentials": ["passcode": "test secret"], "stateHandle": "challenged",
        ] as NSDictionary)
        let introspect = try #require(requests.first { $0.url?.path == "/idp/idx/introspect" })
        #expect(try JSONSerialization.jsonObject(with: #require(introspect.httpBody)) as? NSDictionary
            == ["stateToken": "test+state"] as NSDictionary)
        #expect(requests.last?.value(forHTTPHeaderField: "Cookie") == "session=synthetic")
        await #expect(throws: LiveFailure.reconnectRequired) {
            try await api.login(credentials: TelenetCredentials(username: "reader", password: "test secret"))
        }
        let mismatched = TelenetAPI(transport: TelenetScript(Self.loginResponses(callbackState: "foreign")))
        await #expect(throws: LiveFailure.requestDenied) {
            try await mismatched.login(credentials: TelenetCredentials(username: "reader", password: "test secret"))
        }
    }

    @Test
    func `unrecognized authentication stops after one answer and does not follow arbitrary links`() async throws {
        var responses = Self.loginResponses()
        responses[8] = Self.json(#"{"stateHandle":"mfa","remediation":{"value":[]}}"#)
        let transport = TelenetScript(responses)
        let api = TelenetAPI(transport: transport)
        await #expect(throws: LiveFailure.reconnectRequired) {
            try await api.login(credentials: TelenetCredentials(username: "reader", password: "test secret"))
        }
        #expect(await transport.requests.filter { $0.url?.path == "/idp/idx/challenge/answer" }.count == 1)
        responses = Self.loginResponses()
        responses[8] = Self.json(#"{"success":{"href":"https://evil.test/steal"}}"#)
        let evil = TelenetAPI(transport: TelenetScript(responses))
        await #expect(throws: LiveFailure.requestDenied) {
            try await evil.login(credentials: TelenetCredentials(username: "reader", password: "test secret"))
        }
    }

    private static let discovery = Self.json(#"[{"productType":"internet","identifier":"home-1"}]"#)
    private static let cycle = Self.json(#"{"billCycles":[{"startDate":"2026-09-01","endDate":"2026-09-30"}]}"#)
    private static let usage = Self.json(#"{"internet":{"category":"FUP","totalUsage":{"units":3}}}"#)
    private static let daily = Self.json(#"{"internetUsage":[{"totalUsage":{"peak":4,"offPeak":5}}]}"#)

    private static func json(_ text: String) -> TelenetResponse {
        TelenetResponse(status: 200, body: Data(text.utf8))
    }

    static func loginResponses(callbackState: String = "expected") -> [TelenetResponse] {
        var authorize = URLComponents(string: "https://secure.telenet.be/oauth2/default/v1/authorize")!
        authorize.queryItems = [
            "client_id": "synthetic", "code_challenge": "challenge", "code_challenge_method": "S256",
            "nonce": "nonce", "redirect_uri": "https://api.prd.telenet.be/ocapi/login/callback/telenet_be",
            "response_type": "code", "scope": "openid profile licenses telenet.scopes offline_access",
            "state": "expected",
        ].map { URLQueryItem(name: $0.key, value: $0.value) }
        let callback = "https://api.prd.telenet.be/ocapi/login/callback/telenet_be?code=synthetic&state=" +
            callbackState
        return [
            TelenetResponse(status: 401, body: Data("synthetic,challenge".utf8)),
            TelenetResponse(status: 302, headers: ["Location": authorize.string!]),
            Self.json(#"<script>{"stateToken":"test\x2bstate"}</script>"#),
            Self.json(#"{"stateHandle":"introspected"}"#),
            Self.json("{}"), Self.json("{}"),
            Self.json(#"{"stateHandle":"identified","authenticators":{"value":[{"type":"password","id":"pw"}]}}"#),
            Self.json(#"{"stateHandle":"challenged"}"#),
            Self.json(#"{"success":{"href":"https://secure.telenet.be/login/token/redirect?stateToken=done"}}"#),
            TelenetResponse(status: 302, headers: ["Location": callback]),
            TelenetResponse(status: 302, headers: [
                "Set-Cookie": "session=synthetic; Path=/; Secure", "Location": "https://www2.telenet.be/",
            ]),
            Self.json(#"{"authenticated":true}"#),
        ]
    }
}

private actor TelenetScript: TelenetTransport {
    private var responses: [TelenetResponse]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [TelenetResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) throws -> TelenetResponse {
        self.requests.append(request)
        guard !self.responses.isEmpty else { throw LiveFailure.transport }
        return self.responses.removeFirst()
    }
}
