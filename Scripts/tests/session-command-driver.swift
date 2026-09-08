import Foundation
@testable import VikingBarCore

private actor SyntheticSession {
    private var current = LiveSessionState()

    func execute(_ command: SessionCommand) async throws {
        switch command.command {
        case .configure:
            self.current.nextRefreshAt = Date(timeIntervalSince1970: Double(command.refreshInterval!.rawValue))
        case .refresh:
            FileHandle.standardError.write(Data("refresh-started\n".utf8))
            try await Task.sleep(for: .seconds(30))
            self.current.selectedSubscriptionID = "unexpected-completion"
        case .refreshInvoices:
            self.current.invoices = .empty(updatedAt: Date(timeIntervalSince1970: 0))
        case .downloadInvoice:
            self.current.invoiceDocument = InvoiceDocument(
                invoiceID: command.id!, fileURL: URL(fileURLWithPath: "/synthetic/invoice.pdf"),
            )
        case .selectBundle:
            self.current.selectedBundleIndex = command.index
        case .restore:
            self.current.selectedSubscriptionID = "restored"
        case .refreshPoints:
            if CommandLine.arguments.contains("--hold-points") {
                FileHandle.standardError.write(Data("points-started\n".utf8))
                try await Task.sleep(for: .seconds(30))
            }
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
