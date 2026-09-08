import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
final class ModelTestClient: SessionClient {
    var state: LiveSessionState
    var requests: [String] = []
    var shutdowns = 0
    var holdRestore = false
    var pendingRestore: CheckedContinuation<LiveSessionState, any Error>?
    var holdRefresh = false
    var holdPoints = false
    var pendingPoints: CheckedContinuation<LiveSessionState, any Error>?
    var holdShutdown = false
    var pendingShutdown: CheckedContinuation<Void, Never>?
    var pendingRefresh: CheckedContinuation<LiveSessionState, any Error>?

    init(state: LiveSessionState = LiveSessionState()) {
        self.state = state
    }

    func request(_ request: SessionRequest) async throws -> LiveSessionState {
        switch request {
        case .restore:
            self.requests.append("restore")
            if self.holdRestore {
                return try await withCheckedThrowingContinuation { self.pendingRestore = $0 }
            }
        case .refreshPoints:
            self.requests.append("refreshPoints")
            if self.holdPoints {
                return try await withCheckedThrowingContinuation { self.pendingPoints = $0 }
            }
        case .refresh:
            self.requests.append("refresh")
            if self.holdRefresh {
                return try await withCheckedThrowingContinuation { self.pendingRefresh = $0 }
            }
        default: self.requests.append("other")
        }
        return self.state
    }

    func releaseRefresh(_ result: Result<LiveSessionState, any Error>) {
        self.pendingRefresh?.resume(with: result)
        self.pendingRefresh = nil
    }

    func shutdown() async {
        self.shutdowns += 1
        self.pendingRestore?.resume(throwing: LiveBridgeFailure.stopped)
        self.pendingRestore = nil
        if self.holdShutdown {
            await withCheckedContinuation { self.pendingShutdown = $0 }
        }
    }
}

@MainActor
final class ModelTestConnector: AccountConnecting {
    var fails: Bool
    var connects = 0
    var cancels = 0
    var input: AccountConnectionInput?
    var reference: URL?
    var resultURL: URL?
    var holdConnect = false
    var pendingConnect: CheckedContinuation<Void, Never>?

    init(fails: Bool) {
        self.fails = fails
    }

    func connect(input: AccountConnectionInput, resultURL: URL?) async throws {
        self.connects += 1
        self.input = input
        switch input {
        case let .reference(reference): self.reference = reference
        case let .credentials(credentials): _ = try credentials.takePayload()
        }
        self.resultURL = resultURL
        if self.holdConnect {
            await withCheckedContinuation { self.pendingConnect = $0 }
        }
        if self.fails {
            throw LiveBridgeFailure.connectFailed
        }
    }

    func cancel() async {
        self.cancels += 1
        self.pendingConnect?.resume()
        self.pendingConnect = nil
    }
}

@MainActor
final class ModelTestSleeper {
    var deadlines: [Date] = []
    var ignoresCancellation = false
    private var pending: [Int: (Date, CheckedContinuation<Void, any Error>)] = [:]

    func sleep(until deadline: Date) async throws {
        let id = self.deadlines.count
        self.deadlines.append(deadline)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { self.pending[id] = (deadline, $0) }
        } onCancel: {
            Task { @MainActor in
                if !self.ignoresCancellation {
                    self.pending.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
                }
            }
        }
    }

    func wake() {
        guard let id = self.pending.min(by: { $0.value.0 < $1.value.0 })?.key else { return }
        self.pending.removeValue(forKey: id)?.1.resume()
    }

    func wakeAll() {
        let pending = self.pending
        self.pending.removeAll()
        for (_, continuation) in pending.values {
            continuation.resume()
        }
    }
}
