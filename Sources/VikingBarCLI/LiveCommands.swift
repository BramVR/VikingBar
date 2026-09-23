import CryptoKit
import Foundation
import VikingBarCore

struct LiveReport: Encodable, Sendable {
    let schemaVersion: Int
    let state: LiveSessionState
    let snapshot: UsageSnapshot
    let menu: MenuPresentation
    let balanceDetails: LiveBalancePresentation
    let historyPresentation: HistoryPresentation
    let invoiceDetails: InvoicePresentation
    let points: PointsPresentation
    let error: String?

    init(state: LiveSessionState, error: String? = nil, schemaVersion: Int = 1) {
        self.schemaVersion = schemaVersion
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

    // swiftlint:disable:next cyclomatic_complexity
    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--cached" where !self.cached:
                self.cached = true
            case "--history" where !self.history:
                self.history = true
            case "--subscription", "--service":
                guard self.subscription == nil, index + 1 < arguments.count else { throw ProofFailure.invalidInput }
                let legacy = arguments[index] == "--subscription"
                index += 1
                self.subscription = arguments[index]
                guard !arguments[index].isEmpty, arguments[index].utf8.count <= 256,
                      !arguments[index].unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                else { throw ProofFailure.invalidInput }
                if legacy {
                    _ = try ProofEndpoint.balance(subscriptionID: arguments[index]).request()
                }
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
      vikingbar accounts list
      vikingbar accounts add [--provider mobile-vikings]
      vikingbar accounts select ACCOUNT
      vikingbar live [--account ACCOUNT] [--provider PROVIDER] [--cached | [--service ID] [--bundle INDEX] [--history]]
      vikingbar connect [--account ACCOUNT] [--provider PROVIDER]
      vikingbar fixture-accounts [--account ACCOUNT] [--service ID]
      vikingbar proof auth-balance
      vikingbar proof balance-api
      vikingbar proof history-api
      vikingbar proof invoices
      vikingbar proof payment-evidence
      vikingbar proof points-api

    Live commands default to the catalog selection and may access Keychain.
    Explicit --account targets one command without changing the selected default.
    accounts add reserves a disconnected slot; connect reconnects that slot; accounts select activates it.
    Bare connect reconnects the selected account. Failed connect never changes selection.
    --subscription remains an alias for --service. fixture-accounts uses only synthetic providers.
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

    static func connect(
        arguments: [String],
        makeSession: (AccountOptions) throws -> any ProviderAccountSession = { options in
            let catalog = try AccountCatalog.production()
            return try ProviderRegistry.production.open(options.resolve(in: catalog), catalog: catalog)
        },
    ) async {
        do {
            let options: AccountOptions
            let credentials: ProofCredentials
            do {
                options = try AccountOptions(arguments: Array(arguments.dropFirst()))
                guard options.remaining.isEmpty else { throw BootstrapFailure.credentialInput }
                credentials = try self.readCredentials()
            } catch { throw BootstrapFailure.credentialInput }
            let session: any ProviderAccountSession
            do { session = try makeSession(options) } catch { throw BootstrapFailure.localFilesystem }
            let connectionID = try await session.connect(credentials: .mobileVikings(credentials))
            self.writeJSON(ConnectReceipt(connectionID: connectionID))
        } catch {
            self.writeJSON(CommandFailure(error: (error as? BootstrapFailure ?? .connectFailed).rawValue))
            exit(1)
        }
    }

    static func live(arguments: [String]) async {
        var session: (any ProviderAccountSession)?
        do {
            let selectors = try AccountOptions(arguments: Array(arguments.dropFirst()))
            let options = try LiveOptions(arguments: selectors.remaining)
            let catalog = try AccountCatalog.production()
            let key = try selectors.resolve(in: catalog)
            let active = try ProviderRegistry.production.open(key, catalog: catalog)
            session = active
            let state = try await self.loadLive(options: options, active: active)
            self.writeJSON(LiveReport(state: state))
            let historyFailed = options.history && (state.history == nil || state.history?.failure != nil)
            if state.connectionID == nil || state.failure != nil || historyFailed {
                exit(1)
            }
        } catch {
            if let session {
                await self.writeJSON(LiveReport(state: session.state(), error: "live-failed"))
            } else {
                self.writeJSON(CommandFailure(error: "live-failed"))
            }
            exit(1)
        }
    }

    static func loadLive(options: LiveOptions, active: any ProviderAccountSession) async throws -> LiveSessionState {
        try await active.perform(.restore)
        if !options.cached {
            if let id = options.subscription {
                try await active.perform(.refreshService(id))
            } else {
                try await active.perform(.refresh)
            }
            if let bundle = options.bundle {
                try await active.perform(.selectBundle(bundle))
            }
            if options.history {
                try await active.perform(.refreshHistory)
            }
            if await active.state().account?.capabilities.points == true {
                try? await active.perform(.refreshPoints)
            }
        }
        return await active.state()
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

    static func paymentEvidenceProof() async {
        var session: VikingSession?
        do {
            let witness = try self.readPaymentEvidence()
            let active = try VikingSession.production()
            session = active
            _ = try await active.restore()
            _ = try await active.refresh(forceTokenRefresh: true)
            let refreshed = try await active.refreshInvoices()
            guard let snapshot = refreshed.invoices,
                  case let .loaded(invoices, _) = snapshot,
                  let invoice = invoices.first(where: { $0.id == witness.invoiceID }),
                  let api = InvoicePaymentEvidence(invoice: invoice),
                  InvoicePaymentEvidenceMatch.compare(api: api, reviewedPDF: witness) == .matches
            else { throw LiveFailure.malformedResponse }
            let downloaded = try await active.downloadInvoice(id: witness.invoiceID)
            guard downloaded.invoiceDocument?.invoiceID == witness.invoiceID else {
                throw LiveFailure.malformedResponse
            }
            self.writeJSON(InvoicePaymentEvidenceReceipt())
        } catch {
            if let session {
                await session.clearInvoiceDocument()
            }
            self.writeJSON(CommandFailure(error: "payment-evidence-proof-failed"))
            exit(1)
        }
    }

    private static func readPaymentEvidence() throws -> InvoicePaymentEvidence {
        var input = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
            input.append(chunk)
            guard input.count <= 65536 else { throw ProofFailure.invalidInput }
        }
        guard let object = try JSONSerialization.jsonObject(with: input) as? [String: Any],
              Set(object.keys) == ["invoiceID", "invoiceNumber", "reference", "invoiceDate", "dueDate"]
        else { throw ProofFailure.invalidInput }
        return try JSONDecoder().decode(InvoicePaymentEvidence.self, from: input)
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
