import Foundation
@testable import VikingBarCore

struct CommandFailure: Encodable {
    let error: String
}

struct SyntheticHistoryTransport: ProofHTTPTransport {
    let missing: Bool

    func send(_ request: URLRequest) async throws -> ProofHTTPResponse {
        let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        guard parts.path.hasSuffix("/usage-summary") else {
            return ProofHTTPResponse(statusCode: 200, data: Data("{}".utf8))
        }
        if self.missing { return ProofHTTPResponse(statusCode: 200, data: Data("[]".utf8)) }
        let start = parts.queryItems!.first { $0.name == "from_date" }!.value!
        let amount = start.hasPrefix("2026-03-26") ? 0 : 1_000_000_000
        let rows = """
        [{"traffic_type":"data","regionality":"national","incoming":false,
          "number_of_records":1,"total_quantity":\(amount),"total_duration":60,"total_price":0}]
        """
        return ProofHTTPResponse(statusCode: 200, data: Data(rows.utf8))
    }
}

@main struct VikingBarCLI {
    static func writeJSON(_: some Encodable) { fatalError("No production commands in synthetic oracle proof") }

    static func main() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-03-31T12:00:00Z")!
        let (oracle, state) = try await Self.mappedState(now: now, missing: false)
        let presentation = HistoryPresentation(history: state.history, now: now)
        _ = try await oracle.receipt(state: state, presentation: presentation)
        guard presentation.forecast?.observedSeconds == 95 * 3600 else { fatalError("DST elapsed time lost") }
        let history = state.history!
        let first = history.observations[0]
        for bytes in [UInt64?.none, UInt64?(999)] {
            var changed = state
            var observations = history.observations
            observations[0] = HistoryObservation(interval: first.interval, bytes: bytes, fetchedAt: first.fetchedAt)
            changed.history = UsageHistory(context: history.context, observations: observations, attemptedAt: now)
            try await Self.reject(oracle, state: changed, presentation: HistoryPresentation(history: changed.history, now: now))
        }
        var changed = state
        changed.selectedSubscriptionID = "other-sim"
        try await Self.reject(oracle, state: changed, presentation: presentation)
        changed = state
        changed.historyRevision = UUID()
        try await Self.reject(oracle, state: changed, presentation: presentation)
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(presentation)) as! [String: Any]
        var forecast = object["forecast"] as! [String: Any]
        forecast["estimatedCycleBytes"] = 1
        object["forecast"] = forecast
        let wrongForecast = try JSONDecoder().decode(HistoryPresentation.self, from: JSONSerialization.data(withJSONObject: object))
        try await Self.reject(oracle, state: state, presentation: wrongForecast)
        let (emptyOracle, empty) = try await Self.mappedState(now: now, missing: true)
        do {
            _ = try await emptyOracle.receipt(state: empty, presentation: HistoryPresentation(history: empty.history, now: now))
            fatalError("Missing live evidence passed")
        } catch HistoryOracleFailure.insufficientEvidence {}
        print("history-oracle-passed")
    }

    static func reject(_ oracle: HistoryOracleTransport, state: LiveSessionState, presentation: HistoryPresentation) async throws {
        do {
            _ = try await oracle.receipt(state: state, presentation: presentation)
            fatalError("Oracle accepted a mapping, identity, or arithmetic mismatch")
        } catch ProofFailure.malformedResponse {}
    }

    static func mappedState(now: Date, missing: Bool) async throws -> (HistoryOracleTransport, LiveSessionState) {
        let formatter = ISO8601DateFormatter()
        let bundle = BalanceBundle(title: "Data", description: "Synthetic", category: "default", type: "data",
                                   total: 50_000_000_000, used: 8_000_000_000, remaining: 42_000_000_000,
                                   validFrom: formatter.date(from: "2026-03-26T23:00:00Z")!,
                                   validUntil: formatter.date(from: "2026-04-26T22:00:00Z")!)
        var state = LiveSessionState()
        state.connectionID = ConnectionID()
        state.subscriptions = [MobileSubscription(id: "sim-one", displayName: "Synthetic", type: "postpaid")]
        state.selectedSubscriptionID = "sim-one"
        state.publish(LiveBalance(bundles: [bundle], regionality: "national", outOfBundleCost: 0), at: now)
        let oracle = HistoryOracleTransport(base: SyntheticHistoryTransport(missing: missing))
        var request = try ProofEndpoint.token.request()
        request.httpBody = Data("grant_type=refresh_token".utf8)
        _ = try await oracle.send(request)
        let api = LiveAPI(transport: oracle, now: { now })
        let token = LiveToken(accessToken: "synthetic", refreshToken: "synthetic", expiresAt: now.addingTimeInterval(3600),
                              scopeMismatch: false)
        let plan = HistoryPlan(cycleStart: bundle.validFrom, cycleEnd: bundle.validUntil, now: now)
        var observations: [HistoryObservation] = []
        for interval in plan.intervals {
            let bytes = try await api.usageSummary(subscriptionID: "sim-one", interval: interval, token: token)
            observations.append(HistoryObservation(interval: interval, bytes: bytes, fetchedAt: now))
        }
        state.history = UsageHistory(context: state.historyContext!, observations: observations, attemptedAt: now)
        return (oracle, state)
    }
}
