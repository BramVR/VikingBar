import Foundation
import VikingBarCore

private struct SyntheticBalanceTransport: ProofHTTPTransport {
    let balance: Data

    func send(_ request: URLRequest) async throws -> ProofHTTPResponse {
        let value = switch request.url.flatMap({
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
        }) {
        case "/mv/oauth2/token/": Data("{}".utf8)
        case "/mv/subscriptions": Data(#"[{"id":"sim-one","type":"postpaid","sim":{"pin":"not-exported"}}]"#.utf8)
        case "/mv/subscriptions/sim-one/balance": self.balance
        default: throw ProofFailure.requestDenied
        }
        return ProofHTTPResponse(statusCode: 200, data: value)
    }
}

@main
struct BalanceOracleDriver {
    static func main() async {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let payload = try JSONSerialization.jsonObject(with: input) as! [String: Any]
            let balance = try JSONSerialization.data(withJSONObject: payload["balance"]!)
            let state = try Self.decoder.decode(
                LiveSessionState.self, from: JSONSerialization.data(withJSONObject: payload["state"]!),
            )
            let oracle = BalanceOracleTransport(base: SyntheticBalanceTransport(balance: balance))
            if payload["refresh"] as? Bool != false {
                var request = try ProofEndpoint.token.request()
                request.httpBody = Data("grant_type=refresh_token".utf8)
                _ = try await oracle.send(request)
            }
            _ = try await oracle.send(ProofEndpoint.subscriptions.request())
            _ = try await oracle.send(ProofEndpoint.balance(subscriptionID: "sim-one").request())
            var receipt: Any = NSNull()
            do {
                let value = try await oracle.receipt(state: state)
                receipt = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
            } catch ProofFailure.malformedResponse {}
            let cases = try Self.cases(payload["cases"] as? [[String: Any]] ?? [], raw: balance, state: state)
            let output = try JSONSerialization.data(withJSONObject: ["receipt": receipt, "cases": cases])
            FileHandle.standardOutput.write(output)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(2)
        }
    }

    private static func cases(_ values: [[String: Any]], raw: Data, state: LiveSessionState) throws -> [Bool] {
        let oracle = try JSONDecoder().decode(OracleBalance.self, from: raw)
        guard let bundles = state.balance?.bundles, case let .current(updated) = state.snapshot.freshness else {
            throw ProofFailure.invalidInput
        }
        let rows = BundleRowPresentation.rows(for: bundles, at: updated, timeZone: OracleBundle.utc)
        return try values.map { value in
            let index = value["index"] as! Int
            let bundle = try Self.merged(bundles[index], value["bundle"] as? [String: Any])
            let overrides = value["row"] as? [String: Any]
            let row = try rows.first { $0.index == index }.map { try Self.merged($0, overrides) }
                ?? overrides.map { try Self.decoder.decode(
                    BundleRowPresentation.self, from: JSONSerialization.data(withJSONObject: $0),
                ) }
            do {
                try oracle.bundles[index].verify(bundle: bundle, row: row, index: index, at: updated)
                return true
            } catch ProofFailure.malformedResponse {
                return false
            }
        }
    }

    private static func merged<Value: Codable>(_ value: Value, _ overrides: [String: Any]?) throws -> Value {
        guard let overrides else { return value }
        var object = try JSONSerialization.jsonObject(with: Self.encoder.encode(value)) as! [String: Any]
        object.merge(overrides) { $1 }
        return try Self.decoder.decode(Value.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
