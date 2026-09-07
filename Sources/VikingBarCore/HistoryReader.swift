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
        let deadline = clock.now.advanced(by: .seconds(45))
        let plan = HistoryPlan(
            cycleStart: self.context.bundle.cycleStart, cycleEnd: self.context.bundle.cycleEnd, now: started,
        )
        var observations = plan.intervals.map { self.previousObservation(for: $0) }
        var failure: LiveFailure?
        var failedIndex: Int?
        for index in observations.indices {
            try Task.checkCancellation()
            try await validate()
            let observation = observations[index]
            if !self.force, observation.bytes != nil, !observation.stale(at: started) {
                continue
            }
            guard clock.now < deadline else { failure = .transport; failedIndex = index; break }
            do {
                let remaining = clock.now.duration(to: deadline).components
                let timeout = min(10, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
                let bytes = try await self.api.usageSummary(
                    subscriptionID: self.context.subscriptionID, interval: plan.intervals[index], token: self.token,
                    timeout: timeout,
                )
                try Task.checkCancellation()
                try await validate()
                observations[index] = HistoryObservation(
                    interval: plan.intervals[index], bytes: bytes, fetchedAt: self.api.now(),
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error as? LiveFailure ?? .transport
                failedIndex = index
                break
            }
        }
        if let failedIndex {
            let old = observations[failedIndex]
            observations[failedIndex] = HistoryObservation(
                interval: old.interval, bytes: old.bytes, fetchedAt: old.fetchedAt, isStale: true,
            )
        }
        return UsageHistory(
            context: self.context, observations: observations, attemptedAt: started,
            failure: failure, truncated: plan.truncated,
        )
    }

    private func previousObservation(for interval: HistoryInterval) -> HistoryObservation {
        if let exact = self.previous?.observations.first(where: { $0.interval == interval }) {
            return exact
        }
        if let partial = self.previous?.observations.first(where: {
            $0.interval.dayStart == interval.dayStart && $0.interval.start == interval.start
                && $0.interval.end < interval.end && $0.bytes != nil
        }) {
            return HistoryObservation(
                interval: partial.interval, bytes: partial.bytes, fetchedAt: partial.fetchedAt, isStale: true,
            )
        }
        return HistoryObservation(interval: interval, bytes: nil, fetchedAt: nil)
    }
}
