import Foundation

struct HistoryReader: Sendable {
    let api: LiveAPI
    let token: LiveToken
    let context: HistoryContext
    let previous: UsageHistory?
    let force: Bool

    func read(validate: @Sendable () async throws -> Void) async throws -> UsageHistory {
        let started = Date(timeIntervalSince1970: floor(self.api.now().timeIntervalSince1970))
        let clock = ContinuousClock()
        let timing = ReadTiming(started: started, clock: clock, deadline: clock.now.advanced(by: .seconds(45)))
        let plan = HistoryRequestPlan(context: self.context, now: started)
        let previousCycle = self.previous?.observations ?? []
        let previousChart = self.previous?.chartSeries?.observations ?? []
        let cycle = try await self.readCycle(
            plan: plan, previous: previousCycle + previousChart, timing: timing, validate: validate,
        )
        let chart = try await self.readChart(
            plan: plan, previous: previousChart + previousCycle, cycle: cycle, timing: timing,
            validate: validate,
        )
        return UsageHistory(
            context: self.context,
            observations: cycle.observations,
            chartSeries: chart,
            attemptedAt: started,
            failure: cycle.failure,
            truncated: plan.cycleTruncated,
        )
    }

    private func readCycle(
        plan: HistoryRequestPlan,
        previous: [HistoryObservation],
        timing: ReadTiming,
        validate: @Sendable () async throws -> Void,
    ) async throws -> CycleResult {
        var observations = plan.cycleIntervals.map {
            self.previousObservation(for: $0, in: previous)
        }
        var failure: LiveFailure?
        var resolved: [HistoryObservation] = []
        for index in observations.indices where !plan.cycleTruncated {
            do {
                observations[index] = try await self.readObservation(
                    interval: plan.cycleIntervals[index], previous: observations[index], timing: timing,
                    validate: validate,
                )
                resolved.append(observations[index])
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error as? LiveFailure ?? .transport
                observations[index] = Self.stale(observations[index])
                resolved.append(observations[index])
                break
            }
        }
        return CycleResult(observations: observations, resolved: resolved, failure: failure)
    }

    private func readChart(
        plan: HistoryRequestPlan,
        previous: [HistoryObservation],
        cycle: CycleResult,
        timing: ReadTiming,
        validate: @Sendable () async throws -> Void,
    ) async throws -> HistoryChartSeries {
        var observations = plan.chartIntervals.map {
            self.previousObservation(for: $0, in: previous)
        }
        for index in observations.indices {
            if let shared = cycle.resolved.first(where: { $0.interval == plan.chartIntervals[index] }) {
                observations[index] = shared
            }
        }
        guard cycle.failure == nil else {
            return HistoryChartSeries(observations: observations, failure: cycle.failure)
        }
        var failure: LiveFailure?
        for index in observations.indices {
            let interval = plan.chartIntervals[index]
            guard interval.start < interval.end else { continue }
            if let shared = cycle.resolved.first(where: { $0.interval == interval }) {
                observations[index] = shared
                continue
            }
            do {
                observations[index] = try await self.readObservation(
                    interval: interval, previous: observations[index], timing: timing, validate: validate,
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error as? LiveFailure ?? .transport
                observations[index] = Self.stale(observations[index])
                break
            }
        }
        return HistoryChartSeries(observations: observations, failure: failure)
    }

    private func readObservation(
        interval: HistoryInterval,
        previous: HistoryObservation,
        timing: ReadTiming,
        validate: @Sendable () async throws -> Void,
    ) async throws -> HistoryObservation {
        try Task.checkCancellation()
        try await validate()
        if !self.force, previous.bytes != nil, !previous.stale(at: timing.started) {
            return previous
        }
        guard timing.clock.now < timing.deadline else { throw LiveFailure.transport }
        let remaining = timing.clock.now.duration(to: timing.deadline).components
        let timeout = min(10, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
        let bytes = try await self.api.usageSummary(
            subscriptionID: self.context.subscriptionID,
            interval: interval,
            token: self.token,
            timeout: timeout,
        )
        try Task.checkCancellation()
        try await validate()
        return HistoryObservation(interval: interval, bytes: bytes, fetchedAt: self.api.now())
    }

    private func previousObservation(
        for interval: HistoryInterval,
        in observations: [HistoryObservation],
    ) -> HistoryObservation {
        if let exact = observations.first(where: { $0.interval == interval }) {
            return exact
        }
        if let partial = observations.first(where: {
            $0.interval.dayStart == interval.dayStart && $0.interval.start == interval.start
                && $0.interval.end < interval.end && $0.bytes != nil
        }) {
            return HistoryObservation(
                interval: partial.interval, bytes: partial.bytes, fetchedAt: partial.fetchedAt, isStale: true,
            )
        }
        return HistoryObservation(interval: interval, bytes: nil, fetchedAt: nil)
    }

    private static func stale(_ observation: HistoryObservation) -> HistoryObservation {
        HistoryObservation(
            interval: observation.interval,
            bytes: observation.bytes,
            fetchedAt: observation.fetchedAt,
            isStale: true,
        )
    }
}

private struct ReadTiming: Sendable {
    let started: Date
    let clock: ContinuousClock
    let deadline: ContinuousClock.Instant
}

private struct CycleResult: Sendable {
    let observations: [HistoryObservation]
    let resolved: [HistoryObservation]
    let failure: LiveFailure?
}
