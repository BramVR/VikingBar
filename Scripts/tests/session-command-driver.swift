import Foundation
@testable import VikingBarCore

private actor SyntheticSession {
    private var current = LiveSessionState()

    func execute(_ command: SessionCommand) async throws {
        switch command.command {
        case .configure:
            self.current.nextRefreshAt = Date(timeIntervalSince1970: Double(command.refreshInterval!.rawValue))
        case .refresh, .refreshHistory:
            FileHandle.standardError.write(Data("refresh-started\n".utf8))
            try await Task.sleep(for: .seconds(30))
            self.current.selectedSubscriptionID = "unexpected-completion"
        case .refreshInvoices:
            self.current.invoices = .empty(updatedAt: Date(timeIntervalSince1970: 0))
        case .reviewInvoicePayment:
            self.current.paymentReview = .unavailable(.noPayableInvoice, candidates: [])
        case .clearPaymentReview:
            self.current.paymentReview = nil
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
        case .selectService:
            self.current.selectedSubscriptionID = command.service?.providerID
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

private actor DiscoveringSession: ProviderAccountSession {
    nonisolated let key = FixtureAccounts.home
    private var current = LiveSessionState()
    func connect(credentials: ProviderCredentials) async throws -> ConnectionID { throw LiveFailure.requestDenied }
    func cancel() async {}
    func state() async -> LiveSessionState { self.current }
    func perform(_ operation: AccountOperation) async throws {
        switch operation {
        case .restore:
            self.install(["cached-service"])
        case .refresh:
            throw LiveFailure.transport
        case let .refreshService(id):
            self.install(["cached-service", "home/new-service"])
            guard self.current.account!.services.contains(where: { $0.key.providerID == id }) else {
                throw LiveFailure.invalidSelection
            }
            try await self.perform(.selectService(ServiceKey(account: self.key, kind: .home, providerID: id)))
        case let .selectService(service):
            guard service.kind == .home, service.account == self.key else { throw LiveFailure.invalidSelection }
            self.current.account = AccountContext(key: self.key, providerName: "Synthetic discovery",
                services: self.current.account!.services, selectedService: service, capabilities: .usageOnly)
        default: throw LiveFailure.requestDenied
        }
    }
    private func install(_ ids: [String]) {
        self.current.account = AccountContext(key: self.key, providerName: "Synthetic discovery",
            services: ids.map { AccountService(key: ServiceKey(account: self.key, kind: .home, providerID: $0), name: $0) },
            selectedService: nil, capabilities: .usageOnly)
    }
}

@main
struct VikingBarCLI {
    static func main() async {
        if CommandLine.arguments.contains("--live-discovery") {
            do {
                let options = try LiveOptions(arguments: ["--service", "home/new-service"])
                let state = try await self.loadLive(options: options, active: DiscoveringSession())
                self.writeJSON(LiveReport(state: state))
            } catch { exit(1) }
            return
        }
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
