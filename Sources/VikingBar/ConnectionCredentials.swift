import Foundation
import os
import VikingBarCore

final class ConnectionCredentials: Sendable {
    enum Validation: Error { case missingFields, tooLong }

    private let payload: OSAllocatedUnfairLock<Data?>

    convenience init(clientID: String, username: String, password: String) throws {
        try self.init(provider: .mobileVikings, clientID: clientID, username: username, password: password)
    }

    init(provider: ProviderID, clientID: String, username: String, password: String) throws {
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
        guard data.count <= 65536 else { throw Validation.tooLong }
        do { _ = try ProviderCredentials.decode(data, for: provider) } catch { throw Validation.missingFields }
        self.payload = OSAllocatedUnfairLock(initialState: data)
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
