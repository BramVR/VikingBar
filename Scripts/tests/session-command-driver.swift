import Foundation
@testable import VikingBarCore

private actor SyntheticSession {
    private var current = LiveSessionState()

    func execute(_ command: SessionCommand) async throws {
        switch command.command {
        case .refresh:
            FileHandle.standardError.write(Data("refresh-started\n".utf8))
            try await Task.sleep(for: .seconds(30))
            self.current.selectedSubscriptionID = "unexpected-completion"
        case .selectBundle:
            self.current.selectedBundleIndex = command.index
        case .restore:
            self.current.selectedSubscriptionID = "restored"
        case .selectSubscription:
            self.current.selectedSubscriptionID = command.id
        case .cancel, .shutdown:
            fatalError("Control commands must bypass execution")
        }
    }

    func state() -> LiveSessionState {
        self.current
    }

    func cancel() {
        self.current.selectedSubscriptionID = "cancelled"
    }
}

@main
struct VikingBarCLI {
    static func main() async {
        let session = SyntheticSession()
        let passed = await self.runSession(
            input: .standardInput,
            makeSession: {
                SessionCommandHandler(
                    execute: { try await session.execute($0) },
                    state: { await session.state() },
                    cancel: { await session.cancel() },
                )
            },
            report: { self.writeJSON($0) },
        )
        if !passed {
            self.writeJSON(CommandFailure(error: "invalid-session-command"))
            exit(1)
        }
    }
}
