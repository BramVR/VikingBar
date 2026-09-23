import Foundation
import VikingBarCore

struct SessionCommand: Decodable, Sendable {
    enum Name: String, Decodable, Sendable {
        case restore, refresh, refreshHistory, refreshPoints, refreshInvoices, downloadInvoice
        case reviewInvoicePayment, clearPaymentReview
        case selectSubscription, selectService, selectBundle, configure, cancel, shutdown
    }

    let command: Name
    let id: String?
    let index: Int?
    let refreshInterval: RefreshInterval?
    let service: ServiceKey?

    // swiftlint:disable:next cyclomatic_complexity
    func operation(account: AccountKey) throws -> AccountOperation {
        switch self.command {
        case .configure: .configure(self.refreshInterval!)
        case .restore: .restore
        case .refresh: .refresh
        case .refreshHistory: .refreshHistory
        case .refreshPoints: .refreshPoints
        case .refreshInvoices: .refreshInvoices
        case .downloadInvoice: .downloadInvoice(self.id!)
        case .reviewInvoicePayment: .reviewInvoicePayment(self.id)
        case .clearPaymentReview: .clearPaymentReview
        case .selectSubscription: .selectService(ServiceKey(account: account, kind: .mobile, providerID: self.id!))
        case .selectService: try self.serviceOperation(account: account)
        case .selectBundle: .selectBundle(self.index!)
        case .cancel, .shutdown: .cancel
        }
    }

    private func serviceOperation(account: AccountKey) throws -> AccountOperation {
        guard let service, service.account == account else { throw LiveFailure.invalidSelection }
        return .selectService(service)
    }

    static func parse(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProofFailure.invalidInput
        }
        try value.validate(object: object)
        return value
    }

    private func validate(object: [String: Any]) throws {
        if case .reviewInvoicePayment = self.command {
            let keys: Set = self.id == nil ? ["command"] : ["command", "id"]
            if let id = self.id {
                try Self.validateID(id)
            }
            guard Set(object.keys) == keys else { throw ProofFailure.invalidInput }
            return
        }
        try self.validateStandard(object: object)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func validateStandard(object: [String: Any]) throws {
        let keys: Set<String>
        switch self.command {
        case .configure:
            keys = ["command", "refreshInterval"]
            guard self.refreshInterval != nil else { throw ProofFailure.invalidInput }
        case .downloadInvoice, .selectSubscription:
            keys = ["command", "id"]
            guard let id = self.id else { throw ProofFailure.invalidInput }
            try Self.validateID(id)
        case .selectService:
            keys = ["command", "service"]
            guard let service else { throw ProofFailure.invalidInput }
            try Self.validateID(service.providerID)
        case .selectBundle:
            keys = ["command", "index"]
            guard let index = self.index, index >= 0 else { throw ProofFailure.invalidInput }
        case .restore, .refresh, .refreshHistory, .refreshPoints, .refreshInvoices, .clearPaymentReview,
             .cancel, .shutdown:
            keys = ["command"]
        case .reviewInvoicePayment: preconditionFailure()
        }
        guard Set(object.keys) == keys else { throw ProofFailure.invalidInput }
    }

    private static func validateID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 256,
              id.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 47 && $0 != 92 })
        else {
            throw ProofFailure.invalidInput
        }
    }
}

struct SessionCommandHandler: Sendable {
    let execute: @Sendable (SessionCommand) async throws -> Void
    let state: @Sendable () async -> LiveSessionState
    let cancel: @Sendable () async -> Void

    static func production(key: AccountKey, catalog: AccountCatalog) throws -> Self {
        let session = try ProviderRegistry.production.open(key, catalog: catalog)
        return Self(
            execute: { try await session.perform($0.operation(account: key)) },
            state: { await session.state() },
            cancel: { await session.cancel() },
        )
    }
}

private actor SessionCommandQueue {
    private let makeSession: @Sendable () throws -> SessionCommandHandler
    private let report: @Sendable (LiveReport) -> Void
    private var session: SessionCommandHandler?
    private var tail: Task<Void, Never>?
    private var pending: [UUID: Task<Void, Never>] = [:]

    init(
        makeSession: @escaping @Sendable () throws -> SessionCommandHandler,
        report: @escaping @Sendable (LiveReport) -> Void,
    ) {
        self.makeSession = makeSession
        self.report = report
    }

    func accept(_ command: SessionCommand) async throws {
        let control = command.command == .cancel || command.command == .shutdown
        if control {
            await self.cancel()
        } else if self.session == nil {
            self.session = try self.makeSession()
        }
        let previous = self.tail
        let session = self.session
        let id = UUID()
        let task = Task {
            await previous?.value
            var failure: String?
            if !control {
                do {
                    try Task.checkCancellation()
                    try await session?.execute(command)
                } catch { failure = "session-command-failed" }
            }
            let state = await session?.state() ?? LiveSessionState()
            self.report(LiveReport(state: state, error: failure, schemaVersion: 2))
            self.pending[id] = nil
        }
        self.pending[id] = task
        self.tail = task
    }

    func cancel() async {
        for task in self.pending.values {
            task.cancel()
        }
        await self.session?.cancel()
    }

    func drain() async {
        await self.tail?.value
    }
}

extension VikingBarCLI {
    static func sessionLoop(arguments: [String]) async {
        let options: AccountOptions
        let key: AccountKey
        do {
            options = try AccountOptions(arguments: arguments)
            guard options.remaining.isEmpty else { throw ProofFailure.invalidInput }
            key = try options.account ?? AccountCatalog.production().selectedAtInvocation(provider: options.provider)
        } catch {
            self.writeJSON(CommandFailure(error: "invalid-session-command"))
            exit(2)
        }
        let passed = await self.runSession(
            input: .standardInput,
            makeSession: {
                let catalog = try AccountCatalog.production()
                return try .production(key: catalog.resolve(key, provider: options.provider), catalog: catalog)
            },
            report: { self.writeJSON($0) },
        )
        if !passed {
            self.writeJSON(CommandFailure(error: "invalid-session-command"))
            exit(1)
        }
    }

    static func runSession(
        input: FileHandle,
        makeSession: @escaping @Sendable () throws -> SessionCommandHandler,
        report: @escaping @Sendable (LiveReport) -> Void,
    ) async -> Bool {
        let queue = SessionCommandQueue(makeSession: makeSession, report: report)
        let lines = AsyncThrowingStream<Data, Error> { continuation in
            DispatchQueue.global().async {
                do {
                    while let line = try self.commandLine(input: input) {
                        if case .terminated = continuation.yield(line) {
                            return
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
        do {
            for try await line in lines {
                let command = try SessionCommand.parse(line)
                try await queue.accept(command)
                if command.command == .shutdown {
                    await queue.drain()
                    return true
                }
            }
            await queue.cancel()
            await queue.drain()
            return true
        } catch {
            await queue.cancel()
            await queue.drain()
            return false
        }
    }

    private static func commandLine(input: FileHandle) throws -> Data? {
        var line = Data()
        while let byte = try input.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 0x0A {
                return line
            }
            line.append(byte)
            guard line.count <= 65536 else { throw ProofFailure.invalidInput }
        }
        guard line.isEmpty else { throw ProofFailure.invalidInput }
        return nil
    }
}
