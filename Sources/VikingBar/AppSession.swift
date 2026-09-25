import AppKit
import Foundation
import Observation
import VikingBarCore

// swiftlint:disable file_length

@MainActor
@Observable
final class AppSession {
    enum Activity { case idle, restoring, refreshing, selecting, switching, configuring, connecting, stopped }

    struct ConnectionAttempt: Equatable, Sendable { fileprivate let id: UUID }

    let isFixtureLaunch: Bool
    var fixture: FixtureState? {
        didSet { self.onPresentationChange?() }
    }

    var unit: DataUnit {
        didSet { self.onPresentationChange?() }
    }

    var showRemainingGB: Bool {
        didSet {
            self.preferences.setShowRemainingGB(self.showRemainingGB)
            self.settingsError = self.preferences.errorMessage
            self.onPresentationChange?()
        }
    }

    var dataDisplayMode: DataDisplayMode {
        didSet {
            self.preferences.setDataDisplayMode(self.dataDisplayMode)
            self.settingsError = self.preferences.errorMessage
            self.onPresentationChange?()
        }
    }

    var refreshInterval: RefreshInterval {
        didSet {
            self.preferences.setRefreshInterval(self.refreshInterval)
            self.settingsError = self.preferences.errorMessage
            self.configureIfIdle()
        }
    }

    private(set) var loginItemStatus: LoginItemStatus = .unavailable
    private(set) var loginItemError: String?
    private(set) var changingLoginItem = false
    @ObservationIgnored private let loginItems: any LoginItemManaging
    @ObservationIgnored private var appliedInterval: RefreshInterval = .fiveMinutes
    var fixtureAccount = FixtureAccount()
    private(set) var settingsError: String?
    var liveState = LiveSessionState()
    private(set) var accounts: [AccountEntry] = [AccountEntry(key: .legacy, label: "Mobile Vikings")]
    private(set) var selectedAccount: AccountKey = .legacy
    var addingAccount = false
    var addingProvider: ProviderID = .mobileVikings
    @ObservationIgnored private var fixtureClients: [AccountKey: any SessionClient] = [:]
    @ObservationIgnored private var savedAccounts: [AccountKey: LiveSessionState] = [:]
    @ObservationIgnored private var savedFailures: [AccountKey: LiveBridgeFailure] = [:]
    @ObservationIgnored private let accountDirectory: (any AccountDirectoryClient)?
    @ObservationIgnored private var catalogRead: Task<CatalogSnapshot, any Error>?
    private(set) var activity: Activity = .idle
    var historyError: String?
    private(set) var bridgeFailure: LiveBridgeFailure?
    private(set) var connectionError: String?
    private var allowanceExpired = false
    var invoiceError: String?
    let paymentFixtureEnabled: Bool
    private(set) var fixtureClipboardValue: String?
    var pendingOptional: [OptionalIntent] = []
    var activeOptional: OptionalIntent?
    @ObservationIgnored var optionalOperation: Task<Void, Never>?
    @ObservationIgnored var optionalRevision = 0
    @ObservationIgnored var optionalCancellation: Task<Void, Never>?
    @ObservationIgnored var paymentExpiry: Task<Void, Never>?
    @ObservationIgnored var paymentRevision = 0
    @ObservationIgnored let paymentFixtureRenderer: (any PaymentQRRendering)?
    @ObservationIgnored private let clipboardWrite: (String) -> Void

    @ObservationIgnored let openDocument: (URL) -> Bool

    var bridgeError: String? {
        self.bridgeFailure?.message
    }

    let timeZone: TimeZone
    let referenceDate: Date
    @ObservationIgnored var onPresentationChange: (() -> Void)?
    @ObservationIgnored private let preferences: MenuBarPreferences
    @ObservationIgnored private let clientFactory: (AccountKey) throws -> any SessionClient
    @ObservationIgnored private let connectorFactory: (AccountKey) throws -> any AccountConnecting
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored let sleepUntil: @Sendable (Date) async throws -> Void
    @ObservationIgnored var client: (any SessionClient)?
    @ObservationIgnored private var connector: (any AccountConnecting)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    private var connectionAttempt: ConnectionAttempt?
    @ObservationIgnored private var pendingConnection: PendingConnection?
    @ObservationIgnored private var scheduledRefresh: Task<Void, Never>?
    @ObservationIgnored private var scheduledExpiry: Task<Void, Never>?
    @ObservationIgnored private var snapshotRevision = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasStarted = false
    init(
        options: LaunchOptions,
        preferences: MenuBarPreferences,
        referenceDate: Date = Date(),
        loginItems: any LoginItemManaging = DisabledLoginItemManager(),
        clientFactory: @escaping (AccountKey) throws -> any SessionClient = { _ in
            throw LiveBridgeFailure.unavailable
        },
        connectorFactory: @escaping (AccountKey) throws -> any AccountConnecting = { _ in
            throw LiveBridgeFailure.connectFailed
        },
        accountDirectory: (any AccountDirectoryClient)? = nil,
        now: @escaping () -> Date = Date.init,
        openDocument: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        paymentFixtureRenderer: (any PaymentQRRendering)? = nil,
        clipboardWrite: @escaping (String) -> Void = { value in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        },
        sleepUntil: @escaping @Sendable (Date) async throws -> Void = { deadline in
            try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
        },
    ) {
        self.isFixtureLaunch = options.fixture != nil
        self.fixture = options.fixture
        self.unit = options.unit
        self.timeZone = options.timeZone
        self.referenceDate = referenceDate
        self.preferences = preferences
        self.showRemainingGB = preferences.showRemainingGB
        self.dataDisplayMode = preferences.dataDisplayMode
        self.refreshInterval = preferences.refreshInterval
        self.loginItems = loginItems
        self.loginItemStatus = loginItems.status
        self.settingsError = preferences.errorMessage
        self.accountDirectory = options.fixture == nil ? accountDirectory : FixtureAccountDirectory()
        if options.fixture != nil {
            self.accounts = FixtureAccounts.catalog.accounts
        }
        self.clientFactory = clientFactory
        self.connectorFactory = connectorFactory
        self.now = now
        self.openDocument = openDocument
        self.paymentFixtureRenderer = paymentFixtureRenderer
        self.paymentFixtureEnabled = paymentFixtureRenderer != nil
        self.clipboardWrite = clipboardWrite
        self.sleepUntil = sleepUntil
        if self.paymentFixtureEnabled {
            self.liveState.installPaymentFixture(at: referenceDate)
        }
    }
}

extension AppSession {
    func checkLoginItem() {
        let status = self.loginItems.status
        if status != self.loginItemStatus {
            self.loginItemError = nil
        }
        self.loginItemStatus = status
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        guard !self.changingLoginItem else { return }
        self.changingLoginItem = true
        defer {
            self.changingLoginItem = false
            self.checkLoginItem()
        }
        do {
            try await self.loginItems.setEnabled(enabled)
            self.loginItemError = nil
        } catch {
            self.loginItemError = "Could not change launch at login. Check System Settings and try again."
        }
    }

    func openLoginItems() {
        self.loginItems.openSettings()
    }

    var snapshot: UsageSnapshot {
        if self.usesMobileFixture {
            return self.fixture.map { self.fixtureAccount.snapshot(state: $0, referenceDate: self.referenceDate) }
                ?? .notConnected
        }
        let previous = self.liveState.snapshot
        let expired = !self.isFixtureLaunch
            && (self.allowanceExpired || previous.expiresAt.map { $0 <= self.now() } == true)
        guard expired || self.bridgeError != nil else { return previous }
        let freshness: Freshness = switch previous.freshness {
        case let .current(date), let .stale(date): .stale(lastUpdated: date)
        case .unavailable: .unavailable
        }
        return UsageSnapshot(
            source: previous.source, subscriptionName: previous.subscriptionName,
            allowance: expired ? .unavailable : previous.allowance,
            expiresAt: previous.expiresAt,
            freshness: freshness, errorMessage: self.bridgeError ?? previous.errorMessage,
            providerName: previous.providerName,
        )
    }

    func start() {
        guard !self.isFixtureLaunch, !self.hasStarted, self.activity != .stopped else { return }
        self.hasStarted = true
        let intent = self.begin(.restoring)
        self.operation = Task {
            do {
                if let directory = self.accountDirectory {
                    let catalog = try await self.catalogSnapshot(from: directory)
                    guard self.isCurrent(intent) else { return }
                    self.accounts = catalog.accounts
                    self.selectedAccount = catalog.selected
                }
                await self.restoreAndPerform(.refresh, intent: intent)
            } catch { await self.failWorker(intent: intent) }
        }
    }

    func refresh() {
        self.refresh(manual: true)
    }

    private func refresh(manual: Bool) {
        guard self.canRefresh else { return }
        let intent = self.begin(.refreshing)
        if self.usesMobileFixture {
            self.operation = Task {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard self.isCurrent(intent) else { return }
                self.fixtureAccount.refreshCount += 1
                self.finish()
            }
            return
        }
        self.operation = Task {
            if await self.reconcileSelection(intent: intent) {
                return
            }
            if self.client == nil || (!manual && self.selectedAccount.provider == .telenet) {
                await self.restoreAndPerform(.refresh, intent: intent, manualRefresh: manual)
            } else {
                await self.perform(.refresh, intent: intent)
            }
        }
    }

    func select(_ request: SessionRequest) {
        guard self.canSelectAccountData else { return }
        let intent = self.begin(.selecting)
        self.operation = Task {
            if self.client == nil {
                await self.restoreAndPerform(request, intent: intent)
            } else {
                await self.perform(request, intent: intent)
            }
        }
    }

    func stop() async {
        guard self.activity != .stopped else { return }
        let operation = self.operation
        _ = self.begin(.stopped)
        self.connectionAttempt = nil
        self.cancelExpiry()
        let connector = self.connector
        let client = self.client
        self.connector = nil
        self.client = nil
        await connector?.cancel()
        await client?.shutdown()
        await operation?.value
        self.operation = nil
    }

    private func begin(_ activity: Activity) -> Int {
        self.interruptOptional(clear: activity == .connecting || activity == .stopped)
        self.generation += 1
        self.operation?.cancel()
        self.scheduledRefresh?.cancel()
        self.scheduledRefresh = nil
        self.activity = activity
        return self.generation
    }

    private func isCurrent(_ intent: Int) -> Bool {
        self.generation == intent && !Task.isCancelled && self.activity != .stopped
    }

    private func perform(_ request: SessionRequest, intent: Int) async {
        await self.optionalCancellation?.value
        guard self.isCurrent(intent) else { return }
        self.optionalCancellation = nil
        do {
            guard let client = self.client else { throw LiveBridgeFailure.unavailable }
            let state = try await client.request(request)
            guard self.isCurrent(intent) else { return }
            guard state.account == nil || state.account?.key == self.selectedAccount else {
                throw LiveBridgeFailure.invalidReply
            }
            self.publish(state)
            try await self.applyInterval(client: client, intent: intent)
            guard self.isCurrent(intent) else { return }
            if case .refresh = request, self.isConnected, self.supportsPoints {
                self.enqueueOptional(.points)
            }
            guard self.isCurrent(intent) else { return }
            if self.liveState.historyContext != nil, self.liveState.failure == nil {
                self.enqueueOptional(.history)
            }
            self.finish()
        } catch {
            await self.failWorker(intent: intent)
        }
    }

    func didWake() {
        guard !self.isFixtureLaunch, self.activity == .idle, self.isConnected,
              let deadline = self.liveState.nextRefreshAt, deadline <= self.now() else { return }
        self.refresh(manual: false)
    }

    private func configureIfIdle() {
        guard !self.isFixtureLaunch, self.activity == .idle, self.client != nil,
              self.appliedInterval != self.refreshInterval else { return }
        let intent = self.begin(.configuring)
        self.operation = Task {
            await self.optionalCancellation?.value
            guard self.isCurrent(intent) else { return }
            self.optionalCancellation = nil
            do {
                guard let client = self.client else { return }
                try await self.applyInterval(client: client, intent: intent)
                guard self.isCurrent(intent) else { return }
                self.finish()
            } catch { await self.failWorker(intent: intent) }
        }
    }

    private func applyInterval(client: any SessionClient, intent: Int) async throws {
        while self.isCurrent(intent), self.appliedInterval != self.refreshInterval {
            let desired = self.refreshInterval
            let state = try await client.request(.configure(desired))
            guard self.isCurrent(intent) else { return }
            self.appliedInterval = desired
            if state.connectionID == self.liveState.connectionID {
                self.publish(state)
            }
        }
    }

    private func publish(_ state: LiveSessionState) {
        guard state.account == nil || state.account?.key == self.selectedAccount else { return }
        var state = state
        if state.connectionID == self.liveState.connectionID {
            if state.matchingHistory == nil {
                state.mergeHistory(from: self.liveState)
            }
            state.mergePoints(from: self.liveState)
            state.mergeInvoices(from: self.liveState, includePaymentReview: false)
        } else {
            self.pendingOptional.removeAll()
        }
        self.liveState = state
        self.savedAccounts[self.selectedAccount] = state
        self.bridgeFailure = nil
        self.scheduleExpiry()
        self.onPresentationChange?()
    }

    private func failWorker(intent: Int) async {
        guard self.isCurrent(intent) else { return }
        let failed = self.client
        self.bridgeFailure = .unavailable
        self.onPresentationChange?()
        await failed?.shutdown()
        guard self.isCurrent(intent) else { return }
        self.client = nil
        self.activity = .idle
    }

    private func cancelExpiry() {
        self.snapshotRevision += 1
        self.scheduledExpiry?.cancel()
        self.scheduledExpiry = nil
    }

    func copyPaymentField(_ value: String) {
        if self.paymentFixtureEnabled {
            self.fixtureClipboardValue = value
        } else {
            self.clipboardWrite(value)
        }
        self.onPresentationChange?()
    }

    private func scheduleExpiry() {
        self.cancelExpiry()
        self.allowanceExpired = false
        guard !self.isFixtureLaunch, let expiry = self.liveState.snapshot.expiresAt, expiry > self.now() else { return }
        let revision = self.snapshotRevision
        self.scheduledExpiry = Task { [weak self, sleepUntil] in
            do { try await sleepUntil(expiry) } catch { return }
            guard let self, !Task.isCancelled, self.snapshotRevision == revision,
                  self.activity != .stopped else { return }
            self.allowanceExpired = true
            self.onPresentationChange?()
        }
    }

    private func finish() {
        self.activity = .idle
        self.operation = nil
        self.onPresentationChange?()
        if self.appliedInterval != self.refreshInterval {
            self.configureIfIdle()
            if self.activity != .idle {
                return
            }
        }
        if self.isConnected, let deadline = self.liveState.nextRefreshAt {
            let intent = self.generation
            self.scheduledRefresh = Task { [weak self, sleepUntil] in
                do { try await sleepUntil(deadline) } catch { return }
                guard let self, self.isCurrent(intent) else { return }
                self.refresh(manual: false)
            }
        }
        self.pumpOptional()
    }
}

extension AppSession {
    @discardableResult
    func connect(input: AccountConnectionInput, resultURL: URL?, adding: Bool? = nil) -> ConnectionAttempt? {
        guard !self.isFixtureLaunch, self.activity != .stopped, self.activity != .connecting,
              self.activity != .switching
        else {
            if case let .credentials(credentials) = input {
                credentials.discard()
            }
            return nil
        }
        let intent = self.begin(.connecting)
        let attempt = ConnectionAttempt(id: UUID())
        self.connectionAttempt = attempt
        let previous = self.client
        self.client = nil
        let priorState = self.liveState
        let priorFailure = self.bridgeFailure
        let priorAccount = self.selectedAccount
        let adding = adding ?? self.addingAccount
        self.connectionError = nil
        if !adding {
            self.liveState = LiveSessionState()
            self.bridgeFailure = nil
        }
        self.scheduleExpiry()
        self.onPresentationChange?()
        let context = PendingConnection(
            intent: intent,
            adding: adding,
            provider: adding ? self.addingProvider : priorAccount.provider,
            account: priorAccount,
            state: priorState,
            previous: previous,
            failure: priorFailure,
        )
        self.pendingConnection = context
        self.operation = Task { await self.performConnection(input: input, resultURL: resultURL, context: context) }
        return attempt
    }

    private struct PendingConnection {
        let intent: Int
        let adding: Bool
        let provider: ProviderID
        let account: AccountKey
        let state: LiveSessionState
        let previous: (any SessionClient)?
        let failure: LiveBridgeFailure?
        var target: AccountKey?
    }

    private func connectionTarget(_ context: PendingConnection) async throws -> AccountKey {
        guard context.adding else { return context.account }
        guard let directory = self.accountDirectory else { throw LiveBridgeFailure.unavailable }
        _ = await self.catalogRead?.result
        let reserved = try await directory.reserve(provider: context.provider)
        self.accounts = try await directory.snapshot().accounts
        return reserved.key
    }

    private func restoreAddedSelection(_ context: PendingConnection, target: AccountKey?) async throws {
        guard let target else { return }
        try await self.accountDirectory?.select(context.account, replacing: target)
    }

    private func performConnection(
        input: AccountConnectionInput, resultURL: URL?, context: PendingConnection,
    ) async {
        defer {
            if case let .credentials(credentials) = input {
                credentials.discard()
            }
        }
        await context.previous?.shutdown()
        guard self.isCurrent(context.intent) else { return }
        do {
            let target = try await self.connectionTarget(context)
            guard self.isCurrent(context.intent) else { return }
            self.pendingConnection?.target = target
            let connector = try self.connectorFactory(target)
            self.connector = connector
            try await connector.connect(input: input, resultURL: resultURL)
            guard self.isCurrent(context.intent) else { return }
            if context.adding {
                try await self.accountDirectory?.select(target)
                guard self.isCurrent(context.intent) else {
                    try await self.restoreAddedSelection(context, target: target)
                    return
                }
            }
            self.savedAccounts[context.account] = context.state
            self.selectedAccount = target
            self.addingAccount = false
            self.liveState = LiveSessionState()
            self.connector = nil
            await self.restoreAndPerform(.refresh, intent: context.intent)
            if self.isCurrent(context.intent) {
                self.pendingConnection = nil
            }
        } catch { await self.failConnection(error, context: context) }
    }

    private func failConnection(_ error: any Error, context: PendingConnection) async {
        guard self.isCurrent(context.intent) else { return }
        self.connector = nil
        self.pendingConnection = nil
        self.liveState = context.adding ? context.state : LiveSessionState()
        self.selectedAccount = context.account
        let failure = error as? LiveBridgeFailure ?? .connectFailed
        if context.adding {
            self.connectionError = "Could not add account. " + failure.message
            guard await self.restorePreviousWorker(context, intent: context.intent) else { return }
        } else {
            self.bridgeFailure = failure
        }
        self.finish()
    }

    private func restorePreviousWorker(_ context: PendingConnection, intent: Int) async -> Bool {
        guard self.isCurrent(intent) else { return false }
        self.activity = .restoring
        do {
            let client = try self.clientFactory(context.account)
            self.client = client
            self.appliedInterval = .fiveMinutes
            try await self.applyInterval(client: client, intent: intent)
            guard self.isCurrent(intent) else { return false }
            let restored = try await client.request(.restore)
            guard self.isCurrent(intent) else { return false }
            guard restored.account == nil || restored.account?.key == context.account else {
                throw LiveBridgeFailure.invalidReply
            }
            self.publish(restored)
            self.bridgeFailure = context.failure
            return true
        } catch {
            await self.failWorker(intent: intent)
            return false
        }
    }

    func isConnecting(_ attempt: ConnectionAttempt) -> Bool {
        self.activity == .connecting && self.connectionAttempt == attempt
    }

    @discardableResult
    func cancelConnection(_ attempt: ConnectionAttempt) async -> Bool {
        guard self.isConnecting(attempt) else { return false }
        self.connectionAttempt = nil
        self.connectionError = nil
        let context = self.pendingConnection
        let previousFailure = context?.adding == true ? context?.failure : nil
        self.pendingConnection = nil
        let operation = self.operation
        let intent = self.begin(.connecting)
        let connector = self.connector
        let client = self.client
        self.client = nil
        await connector?.cancel()
        await client?.shutdown()
        await operation?.value
        guard self.isCurrent(intent) else { return false }
        self.connector = nil
        if let context, context.adding {
            do {
                try await self.restoreAddedSelection(context, target: context.target)
            } catch {
                self.connectionError = "Could not restore the previous account selection. Select it again."
            }
            guard self.isCurrent(intent) else { return false }
            self.selectedAccount = context.account
            self.liveState = context.state
            self.scheduleExpiry()
            guard await self.restorePreviousWorker(context, intent: intent) else { return false }
        }
        self.bridgeFailure = previousFailure
        self.finish()
        return true
    }
}

extension AppSession {
    var historyPresentation: HistoryPresentation {
        if let home = self.liveState.selectedHomeUsage {
            let stale = if case .stale = self.snapshot.freshness {
                true
            } else {
                false
            }
            return HistoryPresentation(
                home: home, dailyFailure: self.liveState.homeFailure, stale: stale,
                unit: self.unit, now: self.now(),
            )
        }
        if self.selectedServiceKind == .home {
            return HistoryPresentation(home: nil, unit: self.unit, now: self.now())
        }
        return HistoryPresentation(history: self.liveState.matchingHistory, unit: self.unit, now: self.now())
    }
}

extension AppSession {
    private func restorationClient() throws -> any SessionClient {
        if let client = self.client {
            return client
        }
        self.appliedInterval = .fiveMinutes
        guard self.isFixtureLaunch else { return try self.clientFactory(self.selectedAccount) }
        if let existing = self.fixtureClients[self.selectedAccount] {
            return existing
        }
        let registry = FixtureAccounts.registry(at: self.referenceDate)
        let registration = try registry.registration(self.selectedAccount.provider)
        let client = try FixtureSessionClient(session: registration.makeSession(AccountStorage(
            root: URL(fileURLWithPath: "/unused-fixture"), key: self.selectedAccount,
        )))
        self.fixtureClients[self.selectedAccount] = client
        return client
    }

    private func restoreAndPerform(
        _ request: SessionRequest, intent: Int, manualRefresh: Bool = false,
    ) async {
        guard self.isCurrent(intent) else { return }
        do {
            let client = try self.restorationClient()
            self.client = client
            try await self.applyInterval(client: client, intent: intent)
            guard self.isCurrent(intent) else { return }
            let restored = try await client.request(.restore)
            guard self.isCurrent(intent) else { return }
            self.publish(restored)
            guard self.isConnected else { self.finish(); return }
            if case .refresh = request {
                let shouldWait = self.selectedAccount.provider == .telenet ? !manualRefresh : restored.failure != nil
                if let deadline = restored.nextRefreshAt, deadline > self.now(), shouldWait {
                    self.finish()
                    return
                }
            }
            self.activity = if case .refresh = request {
                .refreshing
            } else {
                .selecting
            }
            await self.perform(request, intent: intent)
        } catch {
            await self.failWorker(intent: intent)
        }
    }
}

extension AppSession {
    var usesMobileFixture: Bool {
        self.isFixtureLaunch && self.selectedAccount == FixtureAccounts.mobile
    }

    var supportsPoints: Bool {
        self.liveState.account?.capabilities.points ?? (self.selectedAccount.provider == .mobileVikings)
    }

    var supportsInvoices: Bool {
        self.liveState.account?.capabilities.invoices ?? (self.selectedAccount.provider == .mobileVikings)
    }

    var providerName: String {
        self.liveState.account?.providerName ?? (self.selectedAccount.provider == .mobileVikings
            ? "Mobile Vikings" : self.selectedAccount.provider == .telenet ? "Telenet" : "Home fixture")
    }

    var selectedServiceKind: ServiceKind {
        self.liveState.account?.selectedService?
            .kind ?? (self.selectedAccount.provider == .mobileVikings ? .mobile : .home)
    }

    func reloadAccounts() {
        guard !self.isFixtureLaunch, self.activity == .idle else { return }
        let intent = self.generation
        Task { _ = await self.reconcileSelection(intent: intent) }
    }

    private func catalogSnapshot(from directory: any AccountDirectoryClient) async throws -> CatalogSnapshot {
        if let pending = self.catalogRead {
            return try await pending.value
        }
        let pending = Task { try await directory.snapshot() }
        self.catalogRead = pending
        defer { self.catalogRead = nil }
        return try await pending.value
    }

    private func reconcileSelection(intent: Int) async -> Bool {
        guard self.isCurrent(intent) else { return true }
        guard let directory = self.accountDirectory else { return false }
        do {
            let snapshot = try await self.catalogSnapshot(from: directory)
            guard self.isCurrent(intent) else { return true }
            self.accounts = snapshot.accounts
            if snapshot.selected != self.selectedAccount {
                self.selectAccount(snapshot.selected, persist: false)
                return true
            }
        } catch {
            await self.failWorker(intent: intent)
            return true
        }
        return false
    }

    func selectAccount(_ key: AccountKey, persist: Bool = true) {
        guard key != self.selectedAccount, self.accounts.contains(where: { $0.key == key }),
              self.activity != .connecting, self.activity != .switching, self.activity != .stopped else { return }
        let previousKey = self.selectedAccount
        self.savedAccounts[previousKey] = self.liveState
        self.savedFailures[previousKey] = self.bridgeFailure
        let intent = self.begin(.switching)
        self.pendingOptional.removeAll()
        let previous = self.client
        self.client = nil
        self.selectedAccount = key
        self.liveState = self.savedAccounts[key] ?? LiveSessionState()
        self.liveState.setPaymentReview(nil)
        self.bridgeFailure = self.savedFailures[key]
        self.historyError = nil
        self.invoiceError = nil
        self.scheduleExpiry()
        self.onPresentationChange?()
        self.operation = Task {
            await previous?.shutdown()
            guard self.isCurrent(intent) else { return }
            do {
                if persist {
                    _ = await self.catalogRead?.result
                    guard self.isCurrent(intent) else { return }
                    try await self.accountDirectory?.select(key)
                }
                guard self.isCurrent(intent) else { return }
                if self.usesMobileFixture {
                    self.finish()
                } else {
                    await self.restoreAndPerform(.refresh, intent: intent)
                }
            } catch {
                guard self.isCurrent(intent) else { return }
                self.selectedAccount = previousKey
                self.liveState = self.savedAccounts[previousKey] ?? LiveSessionState()
                await self.failWorker(intent: intent)
            }
        }
    }
}
