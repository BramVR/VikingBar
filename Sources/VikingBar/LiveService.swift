import Foundation
import VikingBarCore

enum SessionRequest: Encodable, Sendable {
    case restore, refresh, refreshPoints, refreshInvoices, cancel, shutdown
    case downloadInvoice(String)
    case selectSubscription(String)
    case selectBundle(Int)
    case configure(RefreshInterval)

    private enum CodingKeys: String, CodingKey { case command, id, index, refreshInterval }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .configure(interval):
            try values.encode("configure", forKey: .command)
            try values.encode(interval, forKey: .refreshInterval)
        case .restore: try values.encode("restore", forKey: .command)
        case .refresh: try values.encode("refresh", forKey: .command)
        case .refreshInvoices: try values.encode("refreshInvoices", forKey: .command)
        case let .downloadInvoice(id):
            try values.encode("downloadInvoice", forKey: .command)
            try values.encode(id, forKey: .id)
        case .refreshPoints: try values.encode("refreshPoints", forKey: .command)
        case .cancel: try values.encode("cancel", forKey: .command)
        case .shutdown: try values.encode("shutdown", forKey: .command)
        case let .selectSubscription(id):
            try values.encode("selectSubscription", forKey: .command)
            try values.encode(id, forKey: .id)
        case let .selectBundle(index):
            try values.encode("selectBundle", forKey: .command)
            try values.encode(index, forKey: .index)
        }
    }
}

protocol SessionClient: Sendable {
    func request(_ request: SessionRequest) async throws -> LiveSessionState
    func shutdown() async
}

enum AccountConnectionInput: Sendable {
    case credentials(ConnectionCredentials)
    case reference(URL)
}

protocol AccountConnecting: Sendable {
    func connect(input: AccountConnectionInput, resultURL: URL?) async throws
    func cancel() async
}

enum LiveBridgeFailure: Error, Sendable {
    case unavailable, invalidReply, stopped, connectFailed
    case bootstrap(BootstrapFailure)

    var message: String {
        switch self {
        case .connectFailed: "Could not connect. Check your sign-in details and try again."
        case let .bootstrap(failure):
            switch failure {
            case .credentialInput: "Enter your public client ID, username, and password."
            case .tokenRejected: "Sign-in was rejected. Check your credentials and API access approval."
            case .tokenNetwork: "Could not reach Mobile Vikings. Check your connection and try again."
            case .tokenRateLimited: "Too many sign-in attempts. Wait before trying again."
            case .tokenServer: "Mobile Vikings is unavailable. Try again later."
            case .keychainWrite: "Could not save the connection in Keychain. Check access and try again."
            case .sessionBusy: "Another account operation is running. Try again when it finishes."
            case .connectCancelled: "Connection cancelled."
            case .localFilesystem: "Could not save the account locally. Check file access and try again."
            case .tokenResponse, .connectFailed: "Could not complete sign-in. Try again later."
            }
        case .unavailable, .invalidReply, .stopped: "The account worker stopped. Refresh to try again."
        }
    }
}

enum LiveServiceEnvironment {
    static func sanitized(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = environment.filter { ["PATH", "TMPDIR", "LANG", "LC_ALL"].contains($0.key) }
        result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (result["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return result
    }
}
