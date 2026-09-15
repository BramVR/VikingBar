import CryptoKit
import Foundation
import VikingBarCore

struct LiveReport: Encodable, Sendable {
    let schemaVersion = 1
    let state: LiveSessionState
    let snapshot: UsageSnapshot
    let menu: MenuPresentation
    let balanceDetails: LiveBalancePresentation
    let historyPresentation: HistoryPresentation
    let invoiceDetails: InvoicePresentation
    let points: PointsPresentation
    let error: String?

    init(state: LiveSessionState, error: String? = nil) {
        self.error = error
        self.state = state
        self.snapshot = state.snapshot
        self.menu = MenuPresentation(snapshot: state.snapshot)
        self.balanceDetails = LiveBalancePresentation(state: state)
        self.historyPresentation = HistoryPresentation(history: state.matchingHistory, unit: .gigabytes, now: Date())
        self.invoiceDetails = InvoicePresentation(
            snapshot: state.invoices,
            selectedSubscriptionID: state.selectedSubscriptionID,
        )
        self.points = PointsPresentation(points: state.points(at: Date()))
    }
}

struct ConnectReceipt: Encodable {
    let schemaVersion = 1
    let check = "connect"
    let passed = true
    let connected = true
    let connectionSHA256: String

    init(connectionID: ConnectionID) {
        self.connectionSHA256 = SHA256.hash(data: Data(connectionID.rawValue.uuidString.lowercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case connectionSHA256 = "connection_sha256"
        case check, passed, connected
    }
}

struct CommandFailure: Encodable {
    let passed = false
    let error: String
}

struct LiveOptions {
    var cached = false
    var history = false
    var subscription: String?
    var bundle: Int?

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--cached" where !self.cached:
                self.cached = true
            case "--history" where !self.history:
                self.history = true
            case "--subscription" where self.subscription == nil && index + 1 < arguments.count:
                index += 1
                self.subscription = arguments[index]
                _ = try ProofEndpoint.balance(subscriptionID: arguments[index]).request()
            case "--bundle" where self.bundle == nil && index + 1 < arguments.count:
                index += 1
                guard let bundle = Int(arguments[index]), bundle >= 0 else { throw ProofFailure.invalidInput }
                self.bundle = bundle
            default: throw ProofFailure.invalidInput
            }
            index += 1
        }
        guard !self.cached || (self.subscription == nil && self.bundle == nil && !self.history) else {
            throw ProofFailure.invalidInput
        }
    }
}

extension VikingBarCLI {
    static let liveUsage = """

    Live commands:
      vikingbar live [--cached | [--subscription ID] [--bundle INDEX] [--history]]
      vikingbar connect
      vikingbar proof auth-balance
      vikingbar proof balance-api
      vikingbar proof history-api
      vikingbar proof invoices
      vikingbar proof points-api

    Live commands use the explicitly connected account and may access Keychain.
    Bundle indices are zero-based positions in the reported provider bundle array.
    connect reads credential JSON from stdin. Use the approved connection helper.
    proof auth-balance reads credential JSON from stdin and never persists tokens.
    proof balance-api refreshes the stored session and reports redacted comparisons.
    --history reads bounded daily SIM summaries after balance refresh.
    proof history-api checks real summaries and a calculable cycle estimate using the stored session.
    proof points-api refreshes customer points and reports redacted comparisons.
    vikingbar session is the app's private JSON-lines command interface.
    """

    static func writeJSON(_ value: some Encodable) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = SessionDateCoding.encodingStrategy
        guard let data = try? encoder.encode(value) else { exit(2) }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func readCredentials() throws -> ProofCredentials {
        var input = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
            input.append(chunk)
            guard input.count <= 65536 else { throw ProofFailure.invalidInput }
        }
        let credentials = try JSONDecoder().decode(ProofCredentials.self, from: input)
        try credentials.validate()
        return credentials
    }

    static func connect(arguments: [String]) async {
        do {
            guard arguments == ["connect"] else { throw BootstrapFailure.credentialInput }
            let connectionID = try await self.bootstrapFromInput()
            self.writeJSON(ConnectReceipt(connectionID: connectionID))
        } catch {
            self.writeJSON(CommandFailure(error: (error as? BootstrapFailure ?? .connectFailed).rawValue))
            exit(1)
        }
    }

    private static func bootstrapFromInput() async throws -> ConnectionID {
        let credentials: ProofCredentials
        do { credentials = try self.readCredentials() } catch { throw BootstrapFailure.credentialInput }
        let session: VikingSession
        do { session = try VikingSession.production() } catch { throw BootstrapFailure.localFilesystem }
        let state = try await session.bootstrapWithDiagnostics(credentials: credentials)
        guard let connectionID = state.connectionID, state.failure == nil else { throw BootstrapFailure.connectFailed }
        return connectionID
    }

    static func live(arguments: [String]) async {
        var session: VikingSession?
        do {
            let options = try LiveOptions(arguments: Array(arguments.dropFirst()))
            let active = try VikingSession.production()
            session = active
            _ = try await active.restore()
            if !options.cached {
                _ = try await active.refresh(subscriptionID: options.subscription)
                if let bundle = options.bundle {
                    _ = try await active.selectBundle(index: bundle)
                }
                if options.history {
                    _ = try await active.refreshHistory()
                }
            }
            if !options.cached {
                _ = try? await active.refreshPoints()
            }
            let state = await active.state()
            self.writeJSON(LiveReport(state: state))
            let historyFailed = options.history && (state.history == nil || state.history?.failure != nil)
            if state.connectionID == nil || state.failure != nil || historyFailed {
                exit(1)
            }
        } catch {
            if let session {
                let state = await session.state()
                self.writeJSON(LiveReport(state: state, error: "live-failed"))
            } else {
                self.writeJSON(CommandFailure(error: "live-failed"))
            }
            exit(1)
        }
    }

    static func invoiceProof() async {
        do {
            let transport = InvoiceOracleTransport(base: EphemeralProofTransport())
            let session = try VikingSession.production(transport: transport)
            _ = try await session.restore()
            _ = try await session.refresh(forceTokenRefresh: true)
            let invoices = try await session.refreshInvoices()
            if let latest = invoices.invoices?.invoices.first {
                _ = try await session.downloadInvoice(id: latest.id)
            }
            let state = await session.state()
            let presentation = InvoicePresentation(
                snapshot: state.invoices,
                selectedSubscriptionID: state.selectedSubscriptionID,
            )
            try await self.writeJSON(transport.receipt(state: state, presentation: presentation))
        } catch {
            self.writeJSON(CommandFailure(error: "invoices-proof-failed"))
            exit(1)
        }
    }

    static func pointsProof() async {
        do {
            let transport = PointsOracleTransport(base: EphemeralProofTransport())
            let session = try VikingSession.production(transport: transport)
            _ = try await session.restore()
            _ = try await session.refreshPoints(forceTokenRefresh: true)
            let state = await session.state()
            let receipt = try await transport.receipt(state: state)
            self.writeJSON(receipt)
        } catch {
            let diagnostic = (error as? LiveFailure) == .busy ? "session-busy" : "points-api-failed"
            self.writeJSON(CommandFailure(error: diagnostic))
            exit(1)
        }
    }

    static func balanceProof() async {
        do {
            let transport = BalanceOracleTransport(base: EphemeralProofTransport())
            let session = try VikingSession.production(transport: transport)
            _ = try await session.restore()
            _ = try await session.refresh(forceTokenRefresh: true)
            let state = await session.state()
            let receipt = try await transport.receipt(state: state)
            self.writeJSON(receipt)
        } catch {
            let diagnostic = (error as? LiveFailure) == .busy ? "session-busy" : "balance-api-failed"
            self.writeJSON(CommandFailure(error: diagnostic))
            exit(1)
        }
    }
}
