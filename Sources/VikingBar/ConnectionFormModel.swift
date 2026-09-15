import Foundation
import Observation
import VikingBarCore

@MainActor
@Observable
final class ConnectionFormModel {
    var clientID = ""
    var username = ""
    var password = ""
    private(set) var error: String?

    init(account: AccountConnectionSummary? = nil) {
        self.clientID = account?.clientID ?? ""
        self.username = account?.username ?? ""
    }

    func takeCredentials(isFixture: Bool) -> ConnectionCredentials? {
        defer { self.password = "" }
        do {
            let credentials = try ConnectionCredentials(
                clientID: self.clientID, username: self.username, password: self.password,
            )
            guard !isFixture else {
                credentials.discard()
                self.error = "Fixture mode does not connect to an account."
                return nil
            }
            self.error = nil
            return credentials
        } catch {
            self.error = switch error as? ConnectionCredentials.Validation {
            case .tooLong: "Sign-in details are too long."
            default: "Enter all three fields."
            }
            return nil
        }
    }

    func useReference(isFixture: Bool) -> Bool {
        self.clear()
        guard !isFixture else {
            self.error = "Fixture mode does not read 1Password."
            return false
        }
        return true
    }

    func clear() {
        self.password = ""
        self.error = nil
    }
}
