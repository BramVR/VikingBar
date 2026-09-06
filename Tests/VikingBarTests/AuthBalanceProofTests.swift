import Foundation
import Testing
@testable import VikingBarCore

private actor ProofRecorder: ProofHTTPTransport {
    private var responses: [ProofHTTPResponse]
    private var requests: [URLRequest] = []
    private let failTransport: Bool

    init(_ bodies: [String], status: Int = 200, failTransport: Bool = false) {
        self.responses = bodies.map { ProofHTTPResponse(statusCode: status, data: Data($0.utf8)) }
        self.failTransport = failTransport
    }

    func send(_ request: URLRequest) async throws -> ProofHTTPResponse {
        self.requests.append(request)
        if self.failTransport {
            throw NSError(domain: "secret-password-upstream", code: 123)
        }
        guard !self.responses.isEmpty else { throw ProofFailure.transport }
        return self.responses.removeFirst()
    }

    func recorded() -> [URLRequest] {
        self.requests
    }
}

private let proofCredentials = ProofCredentials(clientID: "client+&=", username: "u é+&", password: "p &=+?")
private let proofEpoch = Date(timeIntervalSince1970: 1000)
private let initialToken = """
{"access_token":"initial-secret","refresh_token":"refresh+&=secret",\
"token_type":"Bearer","expires_in":599,"scope":"read"}
"""
private let refreshedToken = """
{"access_token":"refreshed-secret","refresh_token":"rotated-secret",\
"token_type":"Bearer","expires_in":599,"scope":"read write personal-string"}
"""
private let proofBalance = """
{"bundles":[{"descriptions":{"title":"Private title","description":"Private text"},"category":"default",\
"valid_from":"2026-09-01T00:00:00Z","valid_until":"2026-10-01T00:00:00.123Z",\
"type":"data","total":1000,"remaining":700,"used":300}],"sim":{"pin":"private-pin"}}
"""

@Test func `proof orders grants and uses refreshed access for every subscription`() async throws {
    let transport = ProofRecorder([initialToken, refreshedToken, "[{\"id\":\"first-id\"},{\"id\":\"second-id\"}]",
                                   proofBalance, proofBalance])
    let receipt = await AuthBalanceProof(transport: transport, now: { proofEpoch }).run(credentials: proofCredentials)
    #expect(receipt.passed)
    #expect(receipt.passwordGrant && receipt.refreshGrant && receipt.scopeMismatch)
    #expect(receipt.subscriptionCount == 2 && receipt.balanceCount == 2)
    let requests = await transport.recorded()
    #expect(requests.map(\.httpMethod) == ["POST", "POST", "GET", "GET", "GET"])
    #expect(requests.map { $0.url!.path } == [
        "/mv/oauth2/token", "/mv/oauth2/token", "/mv/subscriptions",
        "/mv/subscriptions/first-id/balance", "/mv/subscriptions/second-id/balance",
    ])
    #expect(try String(data: #require(requests[0].httpBody), encoding: .utf8) ==
        "client_id=client%2B%26%3D&grant_type=password&password=p%20%26%3D%2B%3F&scope=read&username=u%20%C3%A9%2B%26")
    #expect(try String(data: #require(requests[1].httpBody), encoding: .utf8) ==
        "client_id=client%2B%26%3D&grant_type=refresh_token&refresh_token=refresh%2B%26%3Dsecret")
    #expect(requests.dropFirst(2)
        .allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-secret" })
    let json = try #require(String(data: JSONEncoder().encode(receipt), encoding: .utf8))
    for forbidden in ["secret", "personal-string", "first-id", "second-id", "private-pin", "Private", "password=p"] {
        #expect(!json.contains(forbidden))
    }
    let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(Set(object.keys) == [
        "schema_version",
        "check",
        "passed",
        "password_grant",
        "refresh_grant",
        "scope_mismatch",
        "subscription_count",
        "balance_count",
        "failure",
    ])
    #expect(object["failure"] is NSNull)
}

@Test(arguments: ["", "../other", "a/b", "%2F", "a?x=1", "a#x", "..", "a\\b", "é"])
func `proof rejects unsafe subscription paths`(identifier: String) {
    #expect(throws: ProofFailure.requestDenied) { try ProofEndpoint.balance(subscriptionID: identifier).request() }
}

@Test(arguments: [
    ("POST", "https://uwa.mobilevikings.be/mv/subscriptions/"),
    ("DELETE", "https://uwa.mobilevikings.be/mv/subscriptions/id/balance/"),
    ("GET", "http://uwa.mobilevikings.be/mv/subscriptions/"),
    ("GET", "https://evil.example/mv/subscriptions/"),
    ("GET", "https://uwa.mobilevikings.be:443/mv/subscriptions/"),
    ("GET", "https://user@uwa.mobilevikings.be/mv/subscriptions/"),
    ("GET", "https://uwa.mobilevikings.be/mv/subscriptions/?next=private"),
    ("GET", "https://uwa.mobilevikings.be/mv/subscriptions/#private"),
    ("GET", "https://uwa.mobilevikings.be/mv/subscriptions/%2E%2E/balance/"),
    ("GET", "https://uwa.mobilevikings.be/mv/subscriptions/id/sim/"),
])
func `allowlist rejects methods origins and encoded traversal`(method: String, url: String) throws {
    var request = try URLRequest(url: #require(URL(string: url)))
    request.httpMethod = method
    #expect(throws: ProofFailure.requestDenied) { try ProofEndpoint.validate(request) }
}

@Test(arguments: ["0", "-1", "null", "\"599\"", "true", "1e999"])
func `invalid expires in stops before refresh`(expiry: String) async {
    let token = initialToken.replacingOccurrences(of: "599", with: expiry)
    let transport = ProofRecorder([token])
    let receipt = await AuthBalanceProof(transport: transport, now: { proofEpoch }).run(credentials: proofCredentials)
    #expect(!receipt.passed && !receipt.passwordGrant)
    #expect(receipt.failure == .malformedResponse)
    #expect(await transport.recorded().count == 1)
}

private final class ProofClock: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(_ seconds: [Double]) {
        self.dates = seconds.map(Date.init(timeIntervalSince1970:))
    }

    func now() -> Date {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.dates.count > 1 ? self.dates.removeFirst() : self.dates[0]
    }
}

@Test func `expiry during exchange prevents accepting stale token`() async {
    let transport = ProofRecorder([initialToken])
    let clock = ProofClock([1000, 1599])
    let receipt = await AuthBalanceProof(transport: transport, now: { clock.now() }).run(credentials: proofCredentials)
    #expect(receipt.failure == .expiredToken)
    #expect(await transport.recorded().count == 1)
}

@Test func `expiry before later balance fails without skipping subscription`() async {
    let transport = ProofRecorder([initialToken, refreshedToken, "[{\"id\":\"one\"},{\"id\":\"two\"}]", proofBalance])
    let clock = ProofClock([1000, 1000, 1000, 1000, 1000, 1000, 1599])
    let receipt = await AuthBalanceProof(transport: transport, now: { clock.now() }).run(credentials: proofCredentials)
    #expect(receipt.failure == .expiredToken)
    #expect(!receipt.passed && receipt.subscriptionCount == 2 && receipt.balanceCount == 1)
    #expect(await transport.recorded().count == 4)
}

@Test(arguments: ["{}", "null", "[{}]", "[{\"id\":123}]", "[{\"id\":\"\"}]",
                  "[{\"id\":\"one\"},{\"id\":\"one\"}]", "private-password"])
func `malformed subscriptions fail without balance calls`(body: String) async {
    let transport = ProofRecorder([initialToken, refreshedToken, body])
    let receipt = await AuthBalanceProof(transport: transport, now: { proofEpoch }).run(credentials: proofCredentials)
    #expect(receipt.failure == .malformedResponse)
    #expect(!receipt.passed && receipt.balanceCount == 0)
    #expect(await transport.recorded().count == 3)
}

@Test func `empty subscriptions are failed required proof`() async {
    let transport = ProofRecorder([initialToken, refreshedToken, "[]"])
    let receipt = await AuthBalanceProof(transport: transport, now: { proofEpoch }).run(credentials: proofCredentials)
    #expect(receipt.failure == .emptySubscriptions)
    #expect(!receipt.passed && receipt.subscriptionCount == 0)
}

@Test(arguments: ["{}", "null", "{\"bundles\":null}", "{\"bundles\":[{}]}",
                  proofBalance.replacingOccurrences(of: "2026-09-01T00:00:00Z", with: "invalid-date"),
                  proofBalance.replacingOccurrences(of: "\"used\":300", with: "\"used\":\"private\"")])
func `malformed required balance fields cannot pass`(body: String) async {
    let transport = ProofRecorder([initialToken, refreshedToken, "[{\"id\":\"one\"}]", body])
    let receipt = await AuthBalanceProof(transport: transport, now: { proofEpoch }).run(credentials: proofCredentials)
    #expect(receipt.failure == .malformedResponse)
    #expect(!receipt.passed && receipt.balanceCount == 0)
}

@Test func `documented empty bundles are valid balance response`() async {
    let transport = ProofRecorder([initialToken, initialToken, "[{\"id\":\"one\"}]", "{\"bundles\":[]}"])
    let receipt = await AuthBalanceProof(transport: transport, now: { proofEpoch }).run(credentials: proofCredentials)
    #expect(receipt.passed && !receipt.scopeMismatch && receipt.balanceCount == 1)
}

@Test(arguments: [301, 302, 307, 400, 401, 403, 500])
func `HTTP failures never expose response bodies`(status: Int) async throws {
    let transport = ProofRecorder(["secret-password-upstream"], status: status)
    let receipt = await AuthBalanceProof(transport: transport).run(credentials: proofCredentials)
    #expect(receipt.failure == .httpStatus)
    let output = try #require(String(data: JSONEncoder().encode(receipt), encoding: .utf8))
    #expect(!output.contains("secret"))
}

@Test func `transport errors never expose upstream descriptions`() async throws {
    let transport = ProofRecorder([], failTransport: true)
    let receipt = await AuthBalanceProof(transport: transport).run(credentials: proofCredentials)
    #expect(receipt.failure == .transport)
    let output = try #require(String(data: JSONEncoder().encode(receipt), encoding: .utf8))
    #expect(!output.contains("secret"))
}

@Test func `invalid credentials fail before transport`() async {
    let transport = ProofRecorder([])
    let receipt = await AuthBalanceProof(transport: transport).run(
        credentials: ProofCredentials(clientID: "", username: "", password: ""),
    )
    #expect(receipt.failure == .invalidInput)
    #expect(await transport.recorded().isEmpty)
}

@Test func `redirect delegate refuses followup request`() async throws {
    let transport = EphemeralProofTransport()
    let url = try #require(URL(string: "https://uwa.mobilevikings.be/mv/oauth2/token/"))
    let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil))
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: url)
    await withCheckedContinuation { continuation in
        let redirected = URLRequest(url: url)
        transport
            .urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { request in
                #expect(request == nil)
                continuation.resume()
            }
    }
}
