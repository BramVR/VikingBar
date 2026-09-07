import Foundation

public enum BootstrapFailure: String, Codable, Error, CaseIterable, Sendable, CustomStringConvertible {
    case credentialInput = "credential-input"
    case localFilesystem = "local-filesystem"
    case sessionBusy = "session-busy"
    case tokenNetwork = "token-network"
    case tokenRejected = "token-rejected"
    case tokenResponse = "token-response"
    case tokenRateLimited = "token-rate-limited"
    case tokenServer = "token-server"
    case keychainWrite = "keychain-write"
    case connectCancelled = "connect-cancelled"
    case connectFailed = "connect-failed"

    public var description: String {
        self.rawValue
    }

    var liveFailure: LiveFailure {
        switch self {
        case .credentialInput, .tokenResponse: .malformedResponse
        case .localFilesystem, .keychainWrite: .storage
        case .sessionBusy: .busy
        case .tokenRejected: .unauthorized
        case .tokenRateLimited: .rateLimited
        case .tokenServer: .serverUnavailable
        case .tokenNetwork, .connectCancelled, .connectFailed: .transport
        }
    }

    static func tokenFailure(_ error: any Error) -> Self {
        if error is CancellationError {
            return .connectCancelled
        }
        switch error as? LiveFailure {
        case .transport: return .tokenNetwork
        case .unauthorized: return .tokenRejected
        case .malformedResponse: return .tokenResponse
        case .rateLimited: return .tokenRateLimited
        case .serverUnavailable: return .tokenServer
        default: return .connectFailed
        }
    }
}
