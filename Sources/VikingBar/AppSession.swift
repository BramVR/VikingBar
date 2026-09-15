import AppKit
import Foundation
import Observation
import VikingBarCore

// swiftlint:disable file_length

@MainActor
@Observable
final class AppSession {
    enum Activity { case idle, restoring, refreshing, selecting, configuring, connecting, stopped }

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
    private(set) var activity: Activity = .idle
    private(set) var bridgeFailure: LiveBridgeFailure?
    private var allowanceExpired = false
    var invoiceError: String?
    var pendingOptional: [OptionalIntent] = []
    var activeOptional: OptionalIntent?
    @ObservationIgnored var optionalOperation: Task<Void, Never>?
    @ObservationIgnored var optionalRevision = 0
    @ObservationIgnored var optionalCancellation: Task<Void, Never>?

    @ObservationIgnored let openDocument: (URL) -> Bool

    var bridgeError: String? {
        self.bridgeFailure?.message
    }

    let timeZone: TimeZone
    let referenceDate: Date
    @ObservationIgnored var onPresentationChange: (() -> Void)?
    @ObservationIgnored private let preferences: MenuBarPreferences
    @ObservationIgnored private let clientFactory: () throws -> any SessionClient
    @ObservationIgnored private let connectorFactory: () throws -> any AccountConnecting
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private let sleepUntil: @Sendable (Date) async throws -> Void
    @ObservationIgnored var client: (any SessionClient)?
    @ObservationIgnored private var connector: (any AccountConnecting)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    private var connectionAttempt: ConnectionAttempt?
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
        clientFactory: @escaping () throws -> any SessionClient = { throw LiveBridgeFailure.unavailable },
        connectorFactory: @escaping () throws -> any AccountConnecting = { throw LiveBridgeFailure.connectFailed },
        now: @escaping () -> Date = Date.init,
        openDocument: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
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
        self.clientFactory = clientFactory
        self.connectorFactory = connectorFactory
        self.now = now
        self.openDocument = openDocument
        self.sleepUntil = sleepUntil
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
        if self.isFixtureLaunch {
            return self.fixture.map { self.fixtureAccount.snapshot(state: $0, referenceDate: self.referenceDate) }
                ?? .notConnected
        }
        let previous = self.liveState.snapshot
        let expired = self.allowanceExpired || previous.expiresAt.map { $0 <= self.now() } == true
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
        )
    }

    func start() {
        guard !self.isFixtureLaunch, !self.hasStarted, self.activity != .stopped else { return }
        self.hasStarted = true
        let intent = self.begin(.restoring)
        self.operation = Task { await self.restoreAndRefresh(intent: intent) }
    }

    func refresh() {
        guard self.canRefresh else { return }
        let intent = self.begin(.refreshing)
        if self.isFixtureLaunch {
            self.operation = Task {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard self.isCurrent(intent) else { return }
                self.fixtureAccount.refreshCount += 1
                self.finish()
            }
            return
        }
        self.operation = Task {
            if self.client == nil {
                await self.restoreAndRefresh(intent: intent)
            } else {
                await self.perform(.refresh, intent: intent)
            }
        }
    }

    func select(_ request: SessionRequest) {
        guard self.canSelectAccountData else { return }
        let intent = self.begin(.selecting)
        self.operation = Task { await self.perform(request, intent: intent) }
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

    private func restoreAndRefresh(intent: Int) async {
        guard self.isCurrent(intent) else { return }
        do {
            let client = try self.clientFactory()
            self.client = client
            self.appliedInterval = .fiveMinutes
            try await self.applyInterval(client: client, intent: intent)
            guard self.isCurrent(intent) else { return }
            let restored = try await client.request(.restore)
            guard self.isCurrent(intent) else { return }
            self.publish(restored)
            guard self.isConnected else { self.finish(); return }
            if restored.failure != nil, let deadline = restored.nextRefreshAt, deadline > self.now() {
                self.finish()
                return
            }
            self.activity = .refreshing
            await self.perform(.refresh, intent: intent)
        } catch {
            await self.failWorker(intent: intent)
        }
    }

    private func perform(_ request: SessionRequest, intent: Int) async {
        await self.optionalCancellation?.value
        guard self.isCurrent(intent) else { return }
        self.optionalCancellation = nil
        do {
            guard let client = self.client else { throw LiveBridgeFailure.unavailable }
            let state = try await client.request(request)
            guard self.isCurrent(intent) else { return }
            self.publish(state)
            try await self.applyInterval(client: client, intent: intent)
            guard self.isCurrent(intent) else { return }
            if case .refresh = request, self.isConnected {
                self.enqueueOptional(.points)
            }
            self.finish()
        } catch {
            await self.failWorker(intent: intent)
        }
    }

    func didWake() {
        guard !self.isFixtureLaunch, self.activity == .idle, self.isConnected,
              let deadline = self.liveState.nextRefreshAt, deadline <= self.now() else { return }
        self.refresh()
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
        var state = state
        if state.connectionID == self.liveState.connectionID {
            state.mergePoints(from: self.liveState)
            state.mergeInvoices(from: self.liveState)
        } else {
            self.pendingOptional.removeAll()
        }
        self.liveState = state
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
                self.refresh()
            }
        }
        self.pumpOptional()
    }
}

extension AppSession {
    @discardableResult
    func connect(input: AccountConnectionInput, resultURL: URL?) -> ConnectionAttempt? {
        guard !self.isFixtureLaunch, self.activity != .stopped, self.activity != .connecting else {
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
        self.liveState = LiveSessionState()
        self.bridgeFailure = nil
        self.scheduleExpiry()
        self.onPresentationChange?()
        self.operation = Task {
            defer {
                if case let .credentials(credentials) = input {
                    credentials.discard()
                }
            }
            await previous?.shutdown()
            guard self.isCurrent(intent) else { return }
            do {
                let connector = try self.connectorFactory()
                self.connector = connector
                try await connector.connect(input: input, resultURL: resultURL)
                guard self.isCurrent(intent) else { return }
                self.connector = nil
                await self.restoreAndRefresh(intent: intent)
            } catch {
                guard self.isCurrent(intent) else { return }
                self.connector = nil
                self.bridgeFailure = error as? LiveBridgeFailure ?? .connectFailed
                self.finish()
            }
        }
        return attempt
    }

    func isConnecting(_ attempt: ConnectionAttempt) -> Bool {
        self.activity == .connecting && self.connectionAttempt == attempt
    }

    @discardableResult
    func cancelConnection(_ attempt: ConnectionAttempt) async -> Bool {
        guard self.isConnecting(attempt) else { return false }
        self.connectionAttempt = nil
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
        self.bridgeFailure = nil
        self.finish()
        return true
    }
}
