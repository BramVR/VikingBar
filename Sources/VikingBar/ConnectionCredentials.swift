import Foundation
import os
import VikingBarCore

final class ConnectionCredentials: Sendable {
    enum Validation: Error { case missingFields, tooLong }

    private let payload: OSAllocatedUnfairLock<Data?>

    convenience init(clientID: String, username: String, password: String) throws {
        try self.init(provider: .mobileVikings, clientID: clientID, username: username, password: password)
    }

    init(
        provider: ProviderID, clientID: String, username: String, password: String,
        rememberPassword: Bool = false, expected: AccountMutationFence? = nil,
    ) throws {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let data: Data
        switch provider {
        case .mobileVikings:
            let credentials = ProofCredentials(
                clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                username: username, password: password,
            )
            do { try credentials.validate() } catch { throw Validation.missingFields }
            data = try JSONEncoder().encode(credentials)
        case .telenet:
            guard !username.isEmpty, !password.isEmpty else { throw Validation.missingFields }
            guard username.utf8.count <= 8192, password.utf8.count <= 8192 else { throw Validation.tooLong }
            data = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        default:
            throw Validation.missingFields
        }
        self.payload = try OSAllocatedUnfairLock(initialState: Self.connectionPayload(
            data, provider: provider, rememberPassword: rememberPassword, expected: expected,
        ))
    }

    private static func connectionPayload(
        _ data: Data, provider: ProviderID, rememberPassword: Bool, expected: AccountMutationFence?,
    ) throws -> Data {
        guard data.count <= 65536 else { throw Validation.tooLong }
        do { _ = try ProviderCredentials.decode(data, for: provider) } catch { throw Validation.missingFields }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Validation.missingFields
        }
        if rememberPassword {
            object["remember_password"] = true
        }
        if let expected {
            object["expected_fence"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected))
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func takePayload() throws -> Data {
        try self.payload.withLock { payload in
            guard let data = payload else { throw LiveBridgeFailure.bootstrap(.credentialInput) }
            payload = nil
            return data
        }
    }

    func discard() {
        self.payload.withLock { $0 = nil }
    }
}
