import Foundation

extension TelenetAPI {
    func authenticate(_ credentials: TelenetCredentials) async throws {
        let first = try await self.send("GET", TelenetEndpoint.api + "/ocapi/oauth/userdetails")
        guard first.status == 401 else { throw LiveFailure.unauthorized }
        guard first.body.count <= 4096, first.body.filter({ $0 == 44 }).count == 1 else {
            throw LiveFailure.malformedResponse
        }
        let authorization = try await self.send("GET", TelenetEndpoint.authorization)
        guard [302, 303].contains(authorization.status) else { throw LiveFailure.unauthorized }
        let location = try Self.location(authorization, paths: ["/oauth2/default/v1/authorize"])
        guard let state = URLComponents(string: location)?.queryItems?.first(where: { $0.name == "state" })?.value
        else { throw LiveFailure.requestDenied }
        let page = try await self.send("GET", location)
        guard page.status == 200 else { throw LiveFailure.unauthorized }
        let token = try Self.stateToken(page.body)
        var handle = try await self.authState("introspect", body: ["stateToken": token])
        let fingerprint = try await self.send("GET", TelenetEndpoint.secure + "/auth/services/devicefingerprint")
        guard fingerprint.status == 200 else { throw LiveFailure.unauthorized }
        let nonce = try await self.send("POST", TelenetEndpoint.secure + "/api/v1/internal/device/nonce", body: [:])
        guard nonce.status == 200 else { throw LiveFailure.unauthorized }
        let identified = try await self.authObject("identify", body: [
            "identifier": credentials.username, "stateHandle": handle,
        ])
        handle = try Self.state(identified)
        let id = try Self.passwordAuthenticator(identified)
        handle = try await self.authState("challenge", body: ["authenticator": ["id": id], "stateHandle": handle])
        let answer = try await self.authObject("challenge/answer", body: [
            "credentials": ["passcode": credentials.password], "stateHandle": handle,
        ])
        guard let success = answer["success"] as? [String: Any], let href = success["href"] as? String else {
            throw LiveFailure.reconnectRequired
        }
        try await self.callback(href, state: state)
        let user = try await self.send("GET", TelenetEndpoint.api + "/ocapi/oauth/userdetails")
        guard let object = try Self.json(user) as? [String: Any], !object.isEmpty else {
            throw LiveFailure.malformedResponse
        }
    }

    private func authObject(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let response = try await self.send("POST", TelenetEndpoint.secure + "/idp/idx/" + path, body: body)
        guard let object = try Self.json(response) as? [String: Any] else { throw LiveFailure.malformedResponse }
        return object
    }

    private static func passwordAuthenticator(_ identified: [String: Any]) throws -> String {
        guard let authenticators = identified["authenticators"] as? [String: Any],
              let values = authenticators["value"] as? [[String: Any]] else { throw LiveFailure.malformedResponse }
        let passwords = values.filter { ($0["type"] as? String) == "password" }
        guard passwords.count == 1, let id = passwords.first?["id"] as? String else {
            throw LiveFailure.reconnectRequired
        }
        return id
    }

    private func authState(_ path: String, body: [String: Any]) async throws -> String {
        try await Self.state(self.authObject(path, body: body))
    }

    private func callback(_ href: String, state: String) async throws {
        var current = href
        for _ in 0 ..< 3 {
            guard let url = URL(string: current) else { throw LiveFailure.requestDenied }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            try TelenetEndpoint.validate(request)
            let isCallback = url.path == "/ocapi/login/callback/telenet_be"
            guard isCallback || url.path == "/login/token/redirect" else { throw LiveFailure.requestDenied }
            if isCallback {
                guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "state" })?.value == state else { throw LiveFailure.requestDenied }
            }
            let response = try await self.send("GET", current)
            if isCallback {
                guard [200, 302, 303].contains(response.status) else { throw LiveFailure.unauthorized }
                return
            }
            guard [302, 303].contains(response.status) else { throw LiveFailure.unauthorized }
            current = try Self.location(response, paths: ["/ocapi/login/callback/telenet_be"])
        }
        throw LiveFailure.unauthorized
    }

    private static func location(_ response: TelenetResponse, paths: Set<String>) throws -> String {
        guard let value = response.header("Location"), let url = URL(string: value), paths.contains(url.path) else {
            throw LiveFailure.requestDenied
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try TelenetEndpoint.validate(request)
        return value
    }

    private static func stateToken(_ data: Data) throws -> String {
        guard let page = String(data: data, encoding: .utf8) else { throw LiveFailure.malformedResponse }
        let pattern = #""stateToken"\s*:\s*"((?:[^"\\]|\\.){1,8192})""#
        let expression = try NSRegularExpression(pattern: pattern)
        guard let match = expression.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)),
              let range = Range(match.range(at: 1), in: page) else { throw LiveFailure.malformedResponse }
        let escaped = String(page[range]).replacingOccurrences(
            of: #"\\x([0-9a-fA-F]{2})"#, with: #"\\u00$1"#, options: .regularExpression,
        )
        guard let token = try? JSONSerialization.jsonObject(
            with: Data(("\"" + escaped + "\"").utf8), options: .fragmentsAllowed,
        ) as? String, !token.isEmpty, token.utf8.count <= 8192 else { throw LiveFailure.malformedResponse }
        return token
    }
}
