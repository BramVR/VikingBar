import Foundation
@testable import VikingBarCore

struct CommandFailure: Encodable {
    let error: String
}

struct SyntheticHistoryTransport: ProofHTTPTransport {
    let missing: Bool
    let grouped: Bool

    func send(_ request: URLRequest) async throws -> ProofHTTPResponse {
        let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        guard parts.path.hasSuffix("/usage-summary") else {
            return ProofHTTPResponse(statusCode: 200, data: Data("{}".utf8))
        }
        if self.missing { return ProofHTTPResponse(statusCode: 200, data: Data("[]".utf8)) }
        let start = parts.queryItems!.first { $0.name == "from_date" }!.value!
        let amount = start.hasPrefix("2026-03-26") ? 0 : 1_000_000_000
        let unrelated = """
        {"number_of_records":7,"total_quantity":900,"total_duration":8,"total_price":10}
        """
        if !self.grouped {
            let rows = """
            [{"traffic_type":"data","regionality":"national","incoming":false,
              "number_of_records":1,"total_quantity":\(amount),"total_duration":60,"total_price":0}]
            """
            return ProofHTTPResponse(statusCode: 200, data: Data(rows.utf8))
        }
        let grouped = """
        {"incoming":{"data":\(unrelated),"sms":\(unrelated),"unknown":\(unrelated),"voice":\(unrelated)},
         "outgoing":{"data":{"number_of_records":1,"total_quantity":\(amount),"total_duration":60,
                               "total_price":0},
                     "sms":\(unrelated),"unknown":\(unrelated),"voice":\(unrelated)}}
        """
        return ProofHTTPResponse(statusCode: 200, data: Data(grouped.utf8))
    }
}

@main struct VikingBarCLI {
    static func writeJSON(_: some Encodable) { fatalError("No production commands in synthetic oracle proof") }

    static func main() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-03-31T12:00:00Z")!
        let (oracle, state) = try await Self.mappedState(now: now, missing: false)
        let presentation = HistoryPresentation(history: state.history, now: now)
        _ = try await oracle.receipt(state: state, presentation: presentation)
        let (arrayOracle, arrayState) = try await Self.mappedState(now: now, missing: false, grouped: false)
        _ = try await arrayOracle.receipt(
            state: arrayState,
            presentation: HistoryPresentation(history: arrayState.history, now: now),
        )
        guard presentation.forecast?.observedSeconds == 95 * 3600 else { fatalError("DST elapsed time lost") }
        let history = state.history!
        guard presentation.days.count == 30,
              presentation.days.first!.dayStart < history.context.bundle.cycleStart,
              presentation.boundary?.position == 24.5,
              presentation.totalObservedBytes == 4_000_000_000
        else { fatalError("Rolling month or cycle-only total lost") }
        let (middayOracle, middayState) = try await Self.mappedState(now: now, missing: false, middayStart: true)
        let middayPresentation = HistoryPresentation(history: middayState.history, now: now)
        _ = try await middayOracle.receipt(state: middayState, presentation: middayPresentation)
        guard middayPresentation.boundary?.position == 25,
              middayPresentation.days[25].bytes == 0,
              middayState.history?.observations.first?.bytes == 1_000_000_000,
              middayPresentation.forecast?.observedSeconds == 83 * 3600
        else { fatalError("Full chart day was confused with partial cycle evidence") }
        let first = history.observations[0]
        for bytes in [UInt64?.none, UInt64?(999)] {
            var changed = state
            var observations = history.observations
            observations[0] = HistoryObservation(interval: first.interval, bytes: bytes, fetchedAt: first.fetchedAt)
            changed.history = UsageHistory(
                context: history.context, observations: observations, chartSeries: history.chartSeries, attemptedAt: now,
            )
            try await Self.reject(oracle, state: changed, presentation: HistoryPresentation(history: changed.history, now: now))
        }
        var wrongChart = history.chartSeries!.observations
        let oldest = wrongChart[0]
        wrongChart[0] = HistoryObservation(interval: oldest.interval, bytes: 999, fetchedAt: now)
        var mismapped = state
        mismapped.history = UsageHistory(
            context: history.context, observations: history.observations,
            chartSeries: HistoryChartSeries(observations: wrongChart), attemptedAt: now,
        )
        try await Self.reject(oracle, state: mismapped, presentation: HistoryPresentation(history: mismapped.history, now: now))
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

    static func mappedState(
        now: Date, missing: Bool, grouped: Bool = true, middayStart: Bool = false,
    ) async throws -> (HistoryOracleTransport, LiveSessionState) {
        let formatter = ISO8601DateFormatter()
        let bundle = BalanceBundle(title: "Data", description: "Synthetic", category: "default", type: "data",
                                   total: 50_000_000_000, used: 8_000_000_000, remaining: 42_000_000_000,
                                   validFrom: formatter.date(from: middayStart ? "2026-03-27T11:00:00Z" : "2026-03-26T23:00:00Z")!,
                                   validUntil: formatter.date(from: "2026-04-26T22:00:00Z")!)
        var state = LiveSessionState()
        state.connectionID = ConnectionID()
        state.subscriptions = [MobileSubscription(id: "sim-one", displayName: "Synthetic", type: "postpaid")]
        state.selectedSubscriptionID = "sim-one"
        state.publish(
            LiveBalance(bundles: [bundle], regionality: "national", outOfBundleCost: 0),
            at: now,
            interval: .fiveMinutes,
        )
        let oracle = HistoryOracleTransport(base: SyntheticHistoryTransport(missing: missing, grouped: grouped))
        var request = try ProofEndpoint.token.request()
        request.httpBody = Data("grant_type=refresh_token".utf8)
        _ = try await oracle.send(request)
        let api = LiveAPI(transport: oracle, now: { now })
        let token = LiveToken(accessToken: "synthetic", refreshToken: "synthetic", expiresAt: now.addingTimeInterval(3600),
                              scopeMismatch: false)
        state.history = try await HistoryReader(
            api: api, token: token, context: state.historyContext!, previous: nil, force: true,
        ).read {}
        return (oracle, state)
    }
}
