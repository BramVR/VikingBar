import Foundation
@testable import VikingBarCore

private struct SyntheticPointsTransport: ProofHTTPTransport {
    let balance: Data
    let pages: [Data]

    func send(_ request: URLRequest) async throws -> ProofHTTPResponse {
        switch request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }) {
        case "/mv/loyalty-points/balance":
            return ProofHTTPResponse(statusCode: 200, data: self.balance)
        case "/mv/loyalty-points/transactions":
            let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            let page = Int(parts?.queryItems?.first(where: { $0.name == "page" })?.value ?? "0") ?? 0
            guard (1 ... self.pages.count).contains(page) else { throw ProofFailure.invalidInput }
            return ProofHTTPResponse(statusCode: 200, data: self.pages[page - 1])
        case "/mv/oauth2/token/":
            return ProofHTTPResponse(statusCode: 200, data: Data("{}".utf8))
        default: throw ProofFailure.requestDenied
        }
    }
}

@main
struct PointsOracleDriver {
    static func main() async {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let payload = try JSONSerialization.jsonObject(with: input) as! [String: Any]
            let balance = try JSONSerialization.data(withJSONObject: payload["balance"]!)
            let pages = try (payload["pages"] as! [Any]).map { try JSONSerialization.data(withJSONObject: $0) }
            let oracle = PointsOracleTransport(base: SyntheticPointsTransport(balance: balance, pages: pages))
            if payload["refresh"] as? Bool != false {
                var request = try ProofEndpoint.token.request()
                request.httpBody = Data("grant_type=refresh_token".utf8)
                _ = try await oracle.send(request)
            }
            _ = try await oracle.send(ProofEndpoint.pointsBalance.request())
            for index in pages.indices {
                _ = try await oracle.send(ProofEndpoint.pointsTransactions(page: index + 1).request())
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var state = LiveSessionState()
            state.connectionID = ConnectionID()
            state.points = try decoder.decode(CustomerPoints.self,
                                              from: JSONSerialization.data(withJSONObject: payload["points"]!))
            let receipt = try await oracle.receipt(state: state)
            let data = try JSONEncoder().encode(receipt)
            FileHandle.standardOutput.write(data)
        } catch {
            FileHandle.standardOutput.write(Data("{\"passed\":false}".utf8))
            exit(1)
        }
    }
}
