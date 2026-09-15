import Foundation

public struct HistoryForecast: Codable, Equatable, Sendable {
    public let estimatedCycleBytes: Double
    public let observedBytes: UInt64
    public let observedSeconds: Double
    public let completeDays: Int
}

public struct HistoryDayPresentation: Codable, Equatable, Sendable {
    public let dayStart: Date
    public let bytes: UInt64?
    public let value: Double?
    public let isMissing: Bool
    public let isStale: Bool
    public let isToday: Bool
    public let isPartial: Bool
    public let label: String
    public let fullDateText: String
    public let valueText: String
    public let statusText: String
}

public struct HistoryBoundaryPresentation: Codable, Equatable, Sendable {
    public let instant: Date
    public let dayStart: Date
    public let label: String
    public let dateText: String
    public let position: Double

    public init(instant: Date, dayStart: Date, label: String, dateText: String, position: Double) {
        self.instant = instant
        self.dayStart = dayStart
        self.label = label
        self.dateText = dateText
        self.position = position
    }
}

public struct HistoryPresentation: Codable, Equatable, Sendable {
    public let days: [HistoryDayPresentation]
    public let boundary: HistoryBoundaryPresentation?
    public let forecast: HistoryForecast?
    public let totalObservedBytes: UInt64?
    public let totalText: String
    public let statusText: String
    public let scopeText: String
    public let forecastText: String
    public let unit: String

    public init(history: UsageHistory?, unit: DataUnit = .gigabytes, now: Date = Date()) {
        self.unit = unit.rawValue
        self.scopeText = "SIM data across all regions and bundles. Selected bundle balance has a different scope; "
            + "provider updates may lag. Days use Europe/Brussels."
        let divisor = unit == .gigabytes ? 1_000_000_000.0 : 1_073_741_824.0
        let labelFormatter = Self.dateFormatter(format: "d MMM")
        let fullDateFormatter = Self.dateFormatter(format: "d MMMM yyyy")
        let chartIntervals = HistoryRequestPlan.rollingChartIntervals(now: now)
        self.days = chartIntervals.map { interval in
            let observation = Self.chartObservation(for: interval, in: history?.chartSeries)
            return Self.day(
                observation, unit: unit, now: now,
                labelFormatter: labelFormatter, fullDateFormatter: fullDateFormatter,
            )
        }
        self.boundary = history.flatMap { Self.boundary($0.context.bundle.cycleStart, in: chartIntervals) }
        self.totalObservedBytes = history?.truncated == true
            ? nil
            : Self.sum((history?.observations ?? []).compactMap(\.bytes))
        self.totalText = self.totalObservedBytes.map { "Observed this cycle: \(unit.format(bytes: $0))" }
            ?? "Observed this cycle unavailable."
        self.forecast = history.flatMap { Self.estimate($0, now: now) }
        if let forecast = self.forecast {
            let amount = String(
                format: "%.2f %@", locale: Locale(identifier: "en_US_POSIX"),
                forecast.estimatedCycleBytes / divisor, unit.rawValue,
            )
            self.forecastText = "Estimated SIM data this cycle: \(amount)"
        } else {
            self.forecastText = "Estimate needs fresh, continuous evidence and at least 3 complete days."
        }
        if history == nil {
            self.statusText = "History not loaded."
        } else if history?.truncated == true {
            self.statusText = "Cycle exceeds 62 days. Cycle total and estimate unavailable."
        } else if let failure = history?.failure {
            self.statusText = "History unavailable. \(failure.message)"
        } else if let failure = history?.chartSeries?.failure {
            self.statusText = "Some chart days are unavailable. \(failure.message)"
        } else if self.days.contains(where: \.isStale) {
            self.statusText = "History contains stale observations."
        } else if self.days.contains(where: \.isMissing) {
            self.statusText = "Missing days are gaps, not zero usage."
        } else {
            self.statusText = "Daily SIM data. Today is partial."
        }
    }

    private static func chartObservation(
        for interval: HistoryInterval,
        in series: HistoryChartSeries?,
    ) -> HistoryObservation {
        if let exact = series?.observations.first(where: { $0.interval == interval }) {
            return exact
        }
        if let partial = series?.observations.first(where: {
            $0.interval.dayStart == interval.dayStart && $0.interval.start == interval.start
                && $0.interval.end < interval.end && $0.bytes != nil
        }) {
            return partial
        }
        return HistoryObservation(interval: interval, bytes: nil, fetchedAt: nil)
    }

    private static func boundary(
        _ instant: Date,
        in chartIntervals: [HistoryInterval],
    ) -> HistoryBoundaryPresentation? {
        let calendar = HistoryPlan.calendar
        let dayStart = calendar.startOfDay(for: instant)
        guard let index = chartIntervals.firstIndex(where: { $0.dayStart == dayStart }),
              let visibleEnd = chartIntervals.last?.end, instant <= visibleEnd,
              let next = calendar.date(byAdding: .day, value: 1, to: dayStart),
              instant >= dayStart, instant < next else { return nil }
        let duration = next.timeIntervalSince(dayStart)
        let fraction = instant.timeIntervalSince(dayStart) / duration
        let format = instant == dayStart ? "d MMMM yyyy" : "d MMMM yyyy, HH:mm"
        return HistoryBoundaryPresentation(
            instant: instant,
            dayStart: dayStart,
            label: "Cycle started",
            dateText: Self.dateFormatter(format: format).string(from: instant),
            position: Double(index) - 0.5 + fraction,
        )
    }

    private static func dateFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = HistoryPlan.calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    private static func day(
        _ observation: HistoryObservation,
        unit: DataUnit,
        now: Date,
        labelFormatter: DateFormatter,
        fullDateFormatter: DateFormatter,
    ) -> HistoryDayPresentation {
        let divisor = unit == .gigabytes ? 1_000_000_000.0 : 1_073_741_824.0
        let isToday = HistoryPlan.calendar.isDate(observation.interval.dayStart, inSameDayAs: now)
        let partial = isToday ? " · today, partial" : (observation.interval.isCompleteDay ? "" : " · partial")
        let stale = observation.bytes != nil && observation.stale(at: now)
        let amount = observation.bytes.map { unit.format(bytes: $0) } ?? "Missing"
        let statusText = if observation.bytes == nil {
            "No data (missing)"
        } else if observation.bytes == 0 {
            "Confirmed zero usage"
        } else {
            "Data usage confirmed"
        }
        return HistoryDayPresentation(
            dayStart: observation.interval.dayStart, bytes: observation.bytes,
            value: observation.bytes.map { Double($0) / divisor }, isMissing: observation.bytes == nil,
            isStale: stale, isToday: isToday, isPartial: !observation.interval.isCompleteDay,
            label: labelFormatter.string(from: observation.interval.dayStart),
            fullDateText: fullDateFormatter.string(from: observation.interval.dayStart),
            valueText: amount + (stale ? " · stale" : "") + partial, statusText: statusText,
        )
    }

    private static func sum(_ amounts: [UInt64]) -> UInt64? {
        guard !amounts.isEmpty else { return nil }
        var total: UInt64 = 0
        for amount in amounts {
            let added = total.addingReportingOverflow(amount)
            guard !added.overflow else { return nil }
            total = added.partialValue
        }
        return total
    }

    private static func estimate(_ history: UsageHistory, now: Date) -> HistoryForecast? {
        let cycle = history.context.bundle
        let today = HistoryPlan.calendar.startOfDay(for: now)
        guard !history.truncated, history.failure == nil, cycle.cycleStart < today,
              now < cycle.cycleEnd, now >= history.attemptedAt else { return nil }
        let plan = HistoryPlan(cycleStart: cycle.cycleStart, cycleEnd: cycle.cycleEnd, now: now)
        let elapsed = plan.intervals.filter { !$0.isToday }
        guard elapsed.filter(\.isCompleteDay).count >= 3 else { return nil }
        var amounts: [UInt64] = []
        for interval in elapsed {
            let matches = history.observations.filter { $0.interval == interval }
            guard matches.count == 1, let observation = matches.first, let bytes = observation.bytes,
                  !observation.stale(at: now) else { return nil }
            amounts.append(bytes)
        }
        guard let observed = Self.sum(amounts), elapsed.first?.start == cycle.cycleStart,
              elapsed.last?.end == today else { return nil }
        let seconds = today.timeIntervalSince(cycle.cycleStart)
        let estimate = Double(observed) / seconds * cycle.cycleEnd.timeIntervalSince(cycle.cycleStart)
        guard estimate.isFinite, estimate >= 0 else { return nil }
        return HistoryForecast(
            estimatedCycleBytes: estimate, observedBytes: observed, observedSeconds: seconds,
            completeDays: elapsed.filter(\.isCompleteDay).count,
        )
    }
}
