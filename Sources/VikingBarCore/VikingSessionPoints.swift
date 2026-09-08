import Foundation

extension VikingSession {
    func fetchPoints(generation: UInt64, forceTokenRefresh: Bool) async throws -> LiveSessionState {
        let connectionID = self.current.connectionID
        let token: LiveToken
        do {
            token = try await self.authorize(
                force: forceTokenRefresh, generation: generation, expectedConnectionID: connectionID,
                preserveUsage: true,
            )
        } catch {
            try self.checkGeneration(generation)
            return try self.withConnectionLease(expected: connectionID) { _ in
                var points = self.current.points ?? CustomerPoints()
                points.markUnavailable(error as? LiveFailure ?? .transport)
                self.current.points = points
                try? self.cache.save(self.current)
                return self.current
            }
        }
        try await self.fetchPointsBalance(token: token, connectionID: connectionID, generation: generation)
        try await self.fetchPointsHistory(token: token, connectionID: connectionID, generation: generation)
        return self.current
    }

    private func fetchPointsBalance(token: LiveToken, connectionID: ConnectionID?, generation: UInt64) async throws {
        do {
            let balance = try await self.api.pointsBalance(token: token)
            try self.withConnectionLease(expected: connectionID) { _ in
                try self.checkGeneration(generation)
                var points = self.current.points ?? CustomerPoints()
                points.balance = balance
                points.balanceFreshness = .current(lastUpdated: self.api.now())
                points.balanceFailure = nil
                self.current.points = points
                try? self.cache.save(self.current)
            }
        } catch {
            try self.checkGeneration(generation)
            try self.withConnectionLease(expected: connectionID) { _ in
                var points = self.current.points ?? CustomerPoints()
                points.balanceFreshness = CustomerPoints.stale(points.balanceFreshness)
                points.balanceFailure = error as? LiveFailure ?? .transport
                self.current.points = points
                try? self.cache.save(self.current)
            }
        }
    }

    private func fetchPointsHistory(token: LiveToken, connectionID: ConnectionID?, generation: UInt64) async throws {
        do {
            let history = try await self.api.pointsHistory(token: token)
            try self.withConnectionLease(expected: connectionID) { _ in
                try self.checkGeneration(generation)
                var points = self.current.points ?? CustomerPoints()
                points.history = history
                points.historyFreshness = .current(lastUpdated: self.api.now())
                points.historyFailure = nil
                self.current.points = points
                try? self.cache.save(self.current)
            }
        } catch {
            try self.checkGeneration(generation)
            try self.withConnectionLease(expected: connectionID) { _ in
                var points = self.current.points ?? CustomerPoints()
                points.historyFreshness = CustomerPoints.stale(points.historyFreshness)
                points.historyFailure = error as? LiveFailure ?? .transport
                self.current.points = points
                try? self.cache.save(self.current)
            }
        }
    }
}
