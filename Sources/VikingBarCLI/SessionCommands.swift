import Foundation
import VikingBarCore

struct SessionCommand: Decodable, Sendable {
    enum Name: String, Decodable, Sendable {
        case restore, refresh, refreshHistory, refreshPoints, refreshInvoices, downloadInvoice
        case reviewInvoicePayment, clearPaymentReview
        case selectSubscription, selectBundle, configure, cancel, shutdown
    }

    let command: Name
    let id: String?
    let index: Int?
    let refreshInterval: RefreshInterval?

    func execute(on session: VikingSession) async throws {
        await session.clearInvoiceDocument()
        if try await self.executePayment(on: session) {
            return
        }
        try await self.executeStandard(on: session)
    }

    private func executePayment(on session: VikingSession) async throws -> Bool {
        if case .reviewInvoicePayment = self.command {
            _ = try await session.reviewInvoicePayment(id: self.id)
            return true
        }
        if case .clearPaymentReview = self.command {
            await session.clearPaymentReview()
            return true
        }
        return false
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func executeStandard(on session: VikingSession) async throws {
        switch self.command {
        case .configure: _ = await session.configure(refreshInterval: self.refreshInterval!)
        case .restore: _ = try await session.restore()
        case .refresh: _ = try await session.refresh()
        case .refreshHistory: _ = try await session.refreshHistory()
        case .refreshInvoices: _ = try await session.refreshInvoices()
        case .downloadInvoice: _ = try await session.downloadInvoice(id: self.id!)
        case .refreshPoints: _ = try await session.refreshPoints()
        case .selectSubscription: _ = try await session.selectSubscription(id: self.id!)
        case .selectBundle: _ = try await session.selectBundle(index: self.index!)
        case .cancel, .shutdown: await session.cancel()
        case .reviewInvoicePayment, .clearPaymentReview: preconditionFailure()
        }
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
                _ = try ProofEndpoint.invoicePDF(id: id).request()
            }
            guard Set(object.keys) == keys else { throw ProofFailure.invalidInput }
            return
        }
        try self.validateStandard(object: object)
    }

    private func validateStandard(object: [String: Any]) throws {
        let keys: Set<String>
        switch self.command {
        case .configure:
            keys = ["command", "refreshInterval"]
            guard self.refreshInterval != nil else { throw ProofFailure.invalidInput }
        case .downloadInvoice, .selectSubscription:
            keys = ["command", "id"]
            guard let id = self.id else { throw ProofFailure.invalidInput }
            let endpoint: ProofEndpoint = self.command == .downloadInvoice
                ? .invoicePDF(id: id) : .balance(subscriptionID: id)
            _ = try endpoint.request()
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
}

struct SessionCommandHandler: Sendable {
    let execute: @Sendable (SessionCommand) async throws -> Void
    let state: @Sendable () async -> LiveSessionState
    let cancel: @Sendable () async -> Void

    static func production() throws -> Self {
        let session = try VikingSession.production()
        return Self(
            execute: { try await $0.execute(on: session) },
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
            self.report(LiveReport(state: state, error: failure))
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
    static func sessionLoop() async {
        let passed = await self.runSession(
            input: .standardInput,
            makeSession: { try .production() },
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
