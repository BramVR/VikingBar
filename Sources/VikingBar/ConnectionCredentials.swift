import Foundation
import os
import VikingBarCore

final class ConnectionCredentials: Sendable {
    enum Validation: Error { case missingFields, tooLong }

    private let payload: OSAllocatedUnfairLock<Data?>

    init(clientID: String, username: String, password: String) throws {
        let credentials = ProofCredentials(
            clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password,
        )
        do { try credentials.validate() } catch { throw Validation.missingFields }
        let data = try JSONEncoder().encode(credentials)
        guard data.count <= 65536 else { throw Validation.tooLong }
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
