import Foundation
import Testing
@testable import VikingBarCLI
@testable import VikingBarCore

struct TelenetHomeOracleTests {
    private static let cycle = Data(#"{"billCycles":[{"startDate":"2026-10-01","endDate":"2026-10-31"}]}"#.utf8)
    private static let usage = Data("""
    {"internet":{"category":"FUP","totalUsage":{"units":20.25},"allocatedUsage":{"units":3000}}}
    """.utf8)

    private static func daily(quoted: Bool) -> Data {
        let quantities = ["1.2345678901234567", "24.751954559999997", "1.0341550000000002", "0.000000001", "0"]
        let rows = quantities.enumerated().map { index, quantity in
            let value = quoted ? "\"\(quantity)\"" : quantity
            return """
            {"date":"2026-10-0\(index + 1)T00:00:00+02:00","total":\(value),"peak":\(value),"offPeak":0}
            """
        }.joined(separator: ",")
        return Data("{\"internetUsage\":[{\"totalUsage\":{\"peak\":3,\"offPeak\":2},\"dailyUsages\":[\(rows)]}]}".utf8)
    }

    private static func state(daily: Data, now: Date) throws -> LiveSessionState {
        let key = ServiceKey(account: AccountKey(provider: .telenet), kind: .home, providerID: "synthetic-home")
        let connection = ConnectionID()
        let home = try HomeUsageDecoder.decode(
            TelenetHomePayload(cycle: self.cycle, usage: self.usage, dailyUsage: daily),
            key: key, connectionID: connection, fetchedAt: now,
        )
        var state = LiveSessionState()
        state.connectionID = connection
        state.homeUsage = home
        state.snapshot = home.snapshot()
        state.account = AccountContext(
            key: key.account, providerName: "Telenet", services: [AccountService(key: key, name: "Synthetic home")],
            selectedService: key, capabilities: .usageOnly,
        )
        return state
    }

    private static func oracle(daily: Data, now: Date) async throws -> TelenetOracleTransport {
        let transport = OracleResponses([
            TelenetResponse(status: 200, body: self.cycle),
            TelenetResponse(status: 200, body: self.usage),
            TelenetResponse(status: 200, body: daily),
        ])
        let oracle = TelenetOracleTransport(base: transport, now: { now })
        let prefix = "https://api.prd.telenet.be/ocapi/public/api/"
        let paths = [
            "billing-service/v1/account/products/synthetic-home/billcycle-details",
            "product-service/v1/products/internet/synthetic-home/usage?fromDate=2026-10-01&toDate=2026-10-31",
            "product-service/v1/products/internet/synthetic-home/dailyusage?fromDate=2026-10-01&toDate=2026-10-31",
        ]
        for path in paths {
            var request = try URLRequest(url: #require(URL(string: prefix + path)))
            request.httpMethod = "GET"
            _ = try await oracle.send(request)
        }
        return oracle
    }

    @Test(arguments: [false, true])
    func `oracle matches precise numeric and string daily quantities`(quoted: Bool) async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z"))
        let daily = Self.daily(quoted: quoted)
        let state = try Self.state(daily: daily, now: now)
        let oracle = try await Self.oracle(daily: daily, now: now)
        let counts = try await oracle.verify(state: state, originalConnection: #require(state.connectionID))
        #expect(counts.0 == 1)
        #expect(counts.1 == 5)
    }

    @Test(arguments: ["2.2345678901234567", "true"])
    func `oracle still rejects changed quantities and booleans`(replacement: String) async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z"))
        let daily = Self.daily(quoted: false)
        let state = try Self.state(daily: daily, now: now)
        let changed = try #require(String(bytes: daily, encoding: .utf8))
            .replacingOccurrences(of: "1.2345678901234567", with: replacement)
        let oracle = try await Self.oracle(daily: Data(changed.utf8), now: now)
        await #expect(throws: LiveFailure.malformedResponse) {
            try await oracle.verify(state: state, originalConnection: #require(state.connectionID))
        }
    }
}

private actor OracleResponses: TelenetTransport {
    private var responses: [TelenetResponse]

    init(_ responses: [TelenetResponse]) {
        self.responses = responses
    }

    func send(_: URLRequest) throws -> TelenetResponse {
        guard !self.responses.isEmpty else { throw LiveFailure.requestDenied }
        return self.responses.removeFirst()
    }
}
