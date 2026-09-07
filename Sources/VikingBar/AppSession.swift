import Foundation
import Observation
import VikingBarCore

@MainActor
@Observable
final class AppSession {
    enum Activity { case idle, restoring, refreshing, selecting, connecting, stopped }

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

    private(set) var settingsError: String?
    private(set) var liveState = LiveSessionState()
    private(set) var activity: Activity = .idle
    private(set) var isHistoryLoading = false
    private(set) var historyError: String?
    private var bridgeFailure: LiveBridgeFailure?
    private var allowanceExpired = false

    let timeZone: TimeZone
    let referenceDate: Date
    @ObservationIgnored var onPresentationChange: (() -> Void)?
    @ObservationIgnored private let preferences: MenuBarPreferences
    @ObservationIgnored private let clientFactory: () throws -> any SessionClient
    @ObservationIgnored private let connectorFactory: () throws -> any AccountConnecting
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleepUntil: @Sendable (Date) async throws -> Void
    @ObservationIgnored private var client: (any SessionClient)?
    @ObservationIgnored private var connector: (any AccountConnecting)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var historyOperation: Task<Void, Never>?
    @ObservationIgnored private var scheduledRefresh: Task<Void, Never>?
    @ObservationIgnored private var scheduledExpiry: Task<Void, Never>?
    @ObservationIgnored private var snapshotRevision = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var hasStarted = false

    init(
        options: LaunchOptions,
        preferences: MenuBarPreferences,
        referenceDate: Date = Date(),
        clientFactory: @escaping () throws -> any SessionClient = { throw LiveBridgeFailure.unavailable },
        connectorFactory: @escaping () throws -> any AccountConnecting = { throw LiveBridgeFailure.connectFailed },
        now: @escaping () -> Date = Date.init,
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
        self.settingsError = preferences.errorMessage
        self.clientFactory = clientFactory
        self.connectorFactory = connectorFactory
        self.now = now
        self.sleepUntil = sleepUntil
    }

    var snapshot: UsageSnapshot {
        if self.isFixtureLaunch {
            return self.fixture?.snapshot(referenceDate: self.referenceDate) ?? .notConnected
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

    var menu: MenuPresentation {
        MenuPresentation(snapshot: self.snapshot, unit: self.unit, timeZone: self.timeZone)
    }

    var status: StatusPresentation {
        StatusPresentation(
            snapshot: self.snapshot, showRemainingGB: self.showRemainingGB,
            unit: self.unit, timeZone: self.timeZone,
        )
    }

    var activeBundleIndices: [Int] {
        guard let balance = self.liveState.balance else { return [] }
        return balance.bundles.indices.filter { balance.bundles[$0].isActive(at: self.now()) }
    }

    var canRefresh: Bool {
        !self.isFixtureLaunch && self.activity == .idle && (self.isConnected || self.canRestartWorker)
    }

    var canSelectAccountData: Bool {
        !self.isFixtureLaunch && self.activity == .idle && self.isConnected && self.client != nil
    }

    private var canRestartWorker: Bool {
        if case .unavailable? = self.bridgeFailure {
            return true
        }
        return false
    }

    private var isConnected: Bool {
        self.liveState.connectionID != nil
            && ![.notConnected, .reconnectRequired, .unauthorized].contains(self.liveState.failure)
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
        self.operation = Task {
            if self.client == nil {
                await self.restoreAndRefresh(intent: intent)
            } else {
                await self.perform(.refresh, intent: intent)
            }
        }
    }

    func selectSubscription(_ id: String) {
        guard self.liveState.selectedSubscriptionID != id else { return }
        self.select(.selectSubscription(id))
    }

    func selectBundle(_ index: Int) {
        guard self.liveState.selectedBundleIndex != index else { return }
        self.select(.selectBundle(index))
    }

    private func select(_ request: SessionRequest) {
        guard self.canSelectAccountData else { return }
        let intent = self.begin(.selecting)
        self.operation = Task { await self.perform(request, intent: intent) }
    }

    func connect(reference: URL, resultURL: URL?) {
        guard !self.isFixtureLaunch, self.activity != .stopped, self.activity != .connecting else { return }
        let intent = self.begin(.connecting)
        let previous = self.client
        self.client = nil
        self.liveState = LiveSessionState()
        self.bridgeFailure = nil
        self.scheduleExpiry()
        self.onPresentationChange?()
        self.operation = Task {
            await previous?.shutdown()
            await self.historyOperation?.value
            self.historyOperation = nil
            guard self.isCurrent(intent) else { return }
            do {
                let connector = try self.connectorFactory()
                self.connector = connector
                try await connector.connect(reference: reference, resultURL: resultURL)
                guard self.isCurrent(intent) else { return }
                self.connector = nil
                await self.restoreAndRefresh(intent: intent)
            } catch {
                guard self.isCurrent(intent) else { return }
                self.connector = nil
                self.bridgeFailure = .connectFailed
                self.finish()
            }
        }
    }

    func stop() async {
        guard self.activity != .stopped else { return }
        let operation = self.operation
        _ = self.begin(.stopped)
        self.cancelExpiry()
        let connector = self.connector
        let client = self.client
        self.connector = nil
        self.client = nil
        await connector?.cancel()
        await client?.shutdown()
        await operation?.value
        await self.historyOperation?.value
        self.historyOperation = nil
        self.operation = nil
    }

    private func begin(_ activity: Activity) -> Int {
        self.generation += 1
        self.operation?.cancel()
        self.historyOperation?.cancel()
        self.isHistoryLoading = false
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
        guard self.isCurrent(intent) else { return }
        do {
            guard let client = self.client else { throw LiveBridgeFailure.unavailable }
            await self.drainHistory(client: client)
            guard self.isCurrent(intent) else { return }
            let state = try await client.request(request)
            guard self.isCurrent(intent) else { return }
            self.publish(state)
            self.finish()
            self.startHistory(intent: intent)
        } catch {
            await self.failWorker(intent: intent)
        }
    }

    private func publish(_ state: LiveSessionState) {
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
}

extension AppSession {
    var bridgeError: String? {
        self.bridgeFailure?.message
    }

    var balanceDetails: LiveBalancePresentation {
        LiveBalancePresentation(state: self.liveState)
    }

    var historyPresentation: HistoryPresentation {
        HistoryPresentation(history: self.liveState.matchingHistory, unit: self.unit, now: self.now())
    }

    private func drainHistory(client: any SessionClient) async {
        guard let pending = self.historyOperation else { return }
        pending.cancel()
        _ = try? await client.request(.cancel)
        await pending.value
        self.historyOperation = nil
    }

    private func startHistory(intent: Int) {
        guard self.isCurrent(intent), self.liveState.historyContext != nil,
              self.liveState.failure == nil, let client = self.client else { return }
        self.isHistoryLoading = true
        self.historyError = nil
        self.historyOperation = Task {
            do {
                try Task.checkCancellation()
                let state = try await client.request(.refreshHistory)
                guard self.isCurrent(intent) else { return }
                self.liveState.mergeHistory(from: state)
            } catch {
                guard self.isCurrent(intent) else { return }
                self.historyError = "History unavailable. Refresh to try again."
            }
            guard self.isCurrent(intent) else { return }
            self.isHistoryLoading = false
            self.historyOperation = nil
            self.onPresentationChange?()
        }
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
        guard self.isConnected, let deadline = self.liveState.nextRefreshAt else { return }
        let intent = self.generation
        self.scheduledRefresh = Task { [weak self, sleepUntil] in
            do { try await sleepUntil(deadline) } catch { return }
            guard let self, self.isCurrent(intent) else { return }
            self.refresh()
        }
    }
}
