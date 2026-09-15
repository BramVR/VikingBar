import Foundation

public struct HistoryBundleIdentity: Codable, Equatable, Sendable {
    public let title: String
    public let description: String
    public let category: String
    public let type: String
    public let cycleStart: Date
    public let cycleEnd: Date

    public init(bundle: BalanceBundle) {
        self.title = bundle.title
        self.description = bundle.description
        self.category = bundle.category
        self.type = bundle.type
        self.cycleStart = bundle.validFrom
        self.cycleEnd = bundle.validUntil
    }
}

public struct HistoryContext: Codable, Equatable, Sendable {
    public let connectionID: ConnectionID
    public let subscriptionID: String
    public let bundleIndex: Int
    public let bundle: HistoryBundleIdentity
    public let revision: UUID

    public init(
        connectionID: ConnectionID, subscriptionID: String, bundleIndex: Int,
        bundle: HistoryBundleIdentity, revision: UUID,
    ) {
        self.connectionID = connectionID
        self.subscriptionID = subscriptionID
        self.bundleIndex = bundleIndex
        self.bundle = bundle
        self.revision = revision
    }

    func matchesCycle(_ other: Self) -> Bool {
        self.connectionID == other.connectionID && self.subscriptionID == other.subscriptionID
            && self.bundleIndex == other.bundleIndex && self.bundle == other.bundle
    }
}

public struct HistoryInterval: Codable, Equatable, Sendable {
    public let dayStart: Date
    public let start: Date
    public let end: Date
    public let isCompleteDay: Bool
    public let isToday: Bool

    public init(dayStart: Date, start: Date, end: Date, isCompleteDay: Bool, isToday: Bool) {
        self.dayStart = dayStart
        self.start = start
        self.end = end
        self.isCompleteDay = isCompleteDay
        self.isToday = isToday
    }
}

public struct HistoryObservation: Codable, Equatable, Sendable {
    public let interval: HistoryInterval
    public let bytes: UInt64?
    public let fetchedAt: Date?
    public let isStale: Bool

    public init(interval: HistoryInterval, bytes: UInt64?, fetchedAt: Date?, isStale: Bool = false) {
        self.interval = interval
        self.bytes = bytes
        self.fetchedAt = fetchedAt
        self.isStale = isStale
    }

    public func stale(at now: Date) -> Bool {
        guard let fetchedAt else { return true }
        let yesterday = HistoryPlan.calendar.date(
            byAdding: .day,
            value: -1,
            to: HistoryPlan.calendar.startOfDay(for: now),
        )!
        let lifetime: TimeInterval = self.interval.dayStart >= yesterday ? 300 : 86400
        return self.isStale || now < fetchedAt || now.timeIntervalSince(fetchedAt) >= lifetime
    }
}

public struct UsageHistory: Codable, Equatable, Sendable {
    public let context: HistoryContext
    public let observations: [HistoryObservation]
    public let chartSeries: HistoryChartSeries?
    public let attemptedAt: Date
    public let failure: LiveFailure?
    public let truncated: Bool

    public init(
        context: HistoryContext, observations: [HistoryObservation], chartSeries: HistoryChartSeries? = nil,
        attemptedAt: Date,
        failure: LiveFailure? = nil, truncated: Bool = false,
    ) {
        self.context = context
        self.observations = observations
        self.chartSeries = chartSeries
        self.attemptedAt = attemptedAt
        self.failure = failure
        self.truncated = truncated
    }
}

public struct HistoryChartSeries: Codable, Equatable, Sendable {
    public let observations: [HistoryObservation]
    public let failure: LiveFailure?

    public init(observations: [HistoryObservation], failure: LiveFailure? = nil) {
        self.observations = observations
        self.failure = failure
    }
}

public struct HistoryPlan: Sendable {
    public let intervals: [HistoryInterval]
    public let truncated: Bool

    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Brussels")!
        return calendar
    }

    public init(cycleStart: Date, cycleEnd: Date, now: Date) {
        let calendar = Self.calendar
        let today = calendar.startOfDay(for: now)
        let until = min(cycleEnd, now)
        var day = calendar.startOfDay(for: cycleStart)
        var intervals: [HistoryInterval] = []
        while day < until, intervals.count < 62, cycleStart < cycleEnd {
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let start = max(day, cycleStart)
            let end = min(next, until)
            if start < end {
                intervals.append(HistoryInterval(
                    dayStart: day, start: start, end: end,
                    isCompleteDay: start == day && end == next && next <= today,
                    isToday: day == today,
                ))
            }
            day = next
        }
        self.intervals = intervals
        self.truncated = day < until
    }
}

public struct HistoryRequestPlan: Sendable {
    public let cycleIntervals: [HistoryInterval]
    public let chartDayStarts: [Date]
    public let chartIntervals: [HistoryInterval]
    public let requestIntervals: [HistoryInterval]
    public let cycleTruncated: Bool

    public init(context: HistoryContext, now: Date) {
        let cycle = HistoryPlan(
            cycleStart: context.bundle.cycleStart,
            cycleEnd: context.bundle.cycleEnd,
            now: now,
        )
        let chart = Self.rollingChartIntervals(now: now)
        let union = cycle.intervals + chart.filter { candidate in
            candidate.start < candidate.end && !cycle.intervals.contains(where: { $0 == candidate })
        }
        if cycle.truncated || union.count > 62 {
            self.cycleIntervals = []
            self.requestIntervals = chart.filter { $0.start < $0.end }
            self.cycleTruncated = true
        } else {
            self.cycleIntervals = cycle.intervals
            self.requestIntervals = union
            self.cycleTruncated = false
        }
        self.chartDayStarts = chart.map(\.dayStart)
        self.chartIntervals = chart
    }

    static func rollingChartIntervals(now: Date) -> [HistoryInterval] {
        let calendar = HistoryPlan.calendar
        let today = calendar.startOfDay(for: now)
        return (-29 ... 0).map {
            let dayStart = calendar.date(byAdding: .day, value: $0, to: today)!
            let next = calendar.date(byAdding: .day, value: 1, to: dayStart)!
            let end = min(next, now)
            return HistoryInterval(
                dayStart: dayStart, start: dayStart, end: end,
                isCompleteDay: end == next, isToday: dayStart == today,
            )
        }
    }
}

public extension LiveSessionState {
    var matchingHistory: UsageHistory? {
        self.history?.context == self.historyContext ? self.history : nil
    }

    var historyContext: HistoryContext? {
        guard let connectionID, let selectedSubscriptionID, let selectedBundleIndex,
              let bundle = self.selectedBundle, let historyRevision else { return nil }
        return HistoryContext(
            connectionID: connectionID, subscriptionID: selectedSubscriptionID, bundleIndex: selectedBundleIndex,
            bundle: HistoryBundleIdentity(bundle: bundle), revision: historyRevision,
        )
    }

    @discardableResult
    mutating func mergeHistory(from state: LiveSessionState) -> Bool {
        guard let history = state.history, let context = self.historyContext,
              history.context == context, state.historyContext == context else { return false }
        self.history = history
        return true
    }

    internal mutating func reviseHistory() {
        self.historyRevision = UUID()
        guard let previous = self.history, let context = self.historyContext,
              context.matchesCycle(previous.context)
        else {
            self.history = nil
            return
        }
        self.history = UsageHistory(
            context: context, observations: previous.observations, chartSeries: previous.chartSeries,
            attemptedAt: previous.attemptedAt,
            failure: previous.failure, truncated: previous.truncated,
        )
    }
}
