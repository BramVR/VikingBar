import Foundation
import VikingBarCore

enum SessionRequest: Encodable, Sendable {
    case restore, refresh, cancel, shutdown
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

protocol AccountConnecting: Sendable {
    func connect(reference: URL, resultURL: URL?) async throws
    func cancel() async
}

enum LiveBridgeFailure: Error, Sendable {
    case unavailable, invalidReply, stopped, connectFailed

    var message: String {
        switch self {
        case .connectFailed: "Could not connect. Check the approved credential setup and try again."
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
