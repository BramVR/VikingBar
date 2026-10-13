import Darwin
import Foundation
import os

public struct AccountMutationFence: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let connectionID: ConnectionID?
    public init(revision: UInt64, connectionID: ConnectionID?) {
        self.revision = revision
        self.connectionID = connectionID
    }

    private enum CodingKeys: String, CodingKey { case revision, connectionID }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.revision, forKey: .revision)
        try values.encode(self.connectionID, forKey: .connectionID)
    }
}

public enum RememberedSignInStatus: String, Codable, Sendable { case disabled, available, cleanupRequired }

public struct AccountSignInPresentation: Codable, Equatable, Sendable {
    public let fence: AccountMutationFence
    public let remembered: RememberedSignInStatus
    public let nextPasswordAttemptAt: Date?
    public let attemptPending: Bool
    public let failure: LiveFailure?
}

struct AccountSignInRecord: Codable, Equatable, Sendable {
    enum Disposition: Codable, Equatable { case disconnected, active(ConnectionID), loggedOut }
    var version = 1
    let account: AccountKey
    var revision: UInt64 = 0
    var summary: AccountConnectionSummary?
    var disposition: Disposition = .disconnected
    var remembered: RememberedSignInStatus = .disabled
    var credentialGeneration: UUID?
    var nextPasswordAttemptAt: Date?
    var attemptPending = false
    var passwordAttemptID: UUID?
    var nextRenewalAt: Date?
    var rememberedFailure: LiveFailure?

    var fence: AccountMutationFence {
        let connection: ConnectionID? = if case let .active(id) = self.disposition {
            id
        } else {
            nil
        }
        return AccountMutationFence(revision: self.revision, connectionID: connection)
    }

    var presentation: AccountSignInPresentation {
        AccountSignInPresentation(fence: self.fence, remembered: self.remembered,
                                  nextPasswordAttemptAt: self.nextPasswordAttemptAt,
                                  attemptPending: self.attemptPending, failure: self.rememberedFailure)
    }
}

struct RememberedSignInEnvelope: Codable {
    var version = 1
    let account: AccountKey
    let summary: AccountConnectionSummary
    let connectionID: ConnectionID
    let generation: UUID
    let password: String
}

struct PasswordAttemptReservation: Equatable, Sendable {
    let fence: AccountMutationFence
    let id: UUID
}

struct AccountSignInPersistence: Sendable {
    let key: AccountKey
    let store: any SessionStore
    let secrets: any SessionStore

    func load() throws -> AccountSignInRecord {
        guard let data = try self.store.load() else { return AccountSignInRecord(account: self.key) }
        do {
            let record = try JSONDecoder().decode(AccountSignInRecord.self, from: data)
            guard record.version == 1, record.account == self.key else { throw LiveFailure.storage }
            return record
        } catch { throw LiveFailure.storage }
    }

    func save(_ record: AccountSignInRecord) throws {
        try self.store.save(JSONEncoder().encode(record))
    }

    func checked(_ expected: AccountMutationFence?) throws -> AccountSignInRecord {
        let record = try self.load()
        guard expected == nil || expected == record.fence else { throw LiveFailure.connectionChanged }
        return record
    }

    func reservePasswordAttempt(expected: AccountMutationFence?, now: Date) throws -> AccountSignInRecord {
        var record = try self.checked(expected)
        guard now >= record.nextPasswordAttemptAt ?? .distantPast else { throw LiveFailure.rateLimited }
        record.nextPasswordAttemptAt = now.addingTimeInterval(60)
        record.attemptPending = true
        record.passwordAttemptID = UUID()
        try self.save(record)
        return record
    }

    func checked(_ reservation: PasswordAttemptReservation, now: Date) throws -> AccountSignInRecord {
        let record = try self.checked(reservation.fence)
        guard record.attemptPending, record.passwordAttemptID == reservation.id else {
            throw LiveFailure.connectionChanged
        }
        guard now >= record.nextRenewalAt ?? .distantPast else { throw LiveFailure.rateLimited }
        return record
    }

    func accept(
        setup: AccountConnectionSummary, connection: ConnectionID,
        expected: AccountMutationFence?,
    ) throws -> AccountSignInRecord {
        var record = try self.checked(expected)
        record.revision &+= 1
        if record.remembered != .disabled {
            record.remembered = .cleanupRequired
        }
        record.credentialGeneration = nil
        record.rememberedFailure = nil
        try self.save(record)
        // A committed accepted session must outrank the durable invalidation, including a logout tombstone.
        record.revision &+= 1
        record.summary = setup
        record.disposition = .active(connection)
        record.attemptPending = false
        record.passwordAttemptID = nil
        record.nextRenewalAt = nil
        return record
    }

    func reconcile(
        summary: AccountConnectionSummary, connection: ConnectionID,
        revision: UInt64?,
    ) throws -> AccountSignInRecord {
        var record = try self.load()
        if record.disposition == .loggedOut, (revision ?? 0) <= record.revision {
            return record
        }
        let setupChanged = record.summary != summary || record.fence.connectionID != connection
        let legacyReplacement = revision == nil && record.revision == 0 && setupChanged
        if let revision, revision >= record.revision, setupChanged {
            record.revision = revision
            record.summary = summary
            record.disposition = .active(connection)
            if record.remembered != .disabled {
                record.remembered = .cleanupRequired
            }
            record.credentialGeneration = nil
            record.attemptPending = false
            record.passwordAttemptID = nil
            record.nextRenewalAt = nil
            record.rememberedFailure = nil
            do { try self.save(record) } catch { record.rememberedFailure = .storage }
        } else if record.disposition != .loggedOut, record.summary == nil || legacyReplacement {
            record.summary = summary
            record.disposition = .active(connection)
            try self.save(record)
        }
        return record
    }

    func remember(password: String, record: inout AccountSignInRecord) throws {
        guard let summary = record.summary, let connection = record.fence.connectionID else {
            throw LiveFailure.savedSignInUnavailable
        }
        record.remembered = .cleanupRequired
        record.credentialGeneration = nil
        try self.save(record)
        let generation = UUID()
        try self.secrets.save(JSONEncoder().encode(RememberedSignInEnvelope(
            account: self.key, summary: summary, connectionID: connection, generation: generation, password: password,
        )))
        record.credentialGeneration = generation
        record.remembered = .available
        record.rememberedFailure = nil
        try self.save(record)
    }

    func finishAccepted(
        _ input: AccountSignInRecord, password: String,
        rememberPassword: Bool,
    ) -> AccountSignInRecord {
        var record = input
        do {
            try self.save(record)
            if rememberPassword {
                try self.remember(password: password, record: &record)
            } else {
                record.remembered = .cleanupRequired
                try self.save(record)
                record = try self.cleanup(record)
            }
        } catch {
            record = (try? self.load()) ?? input
            record.summary = input.summary
            record.disposition = input.disposition
            record.revision = input.revision
            record.credentialGeneration = nil
            record.remembered = .cleanupRequired
            record.rememberedFailure = .storage
            if rememberPassword {
                do {
                    try self.secrets.delete()
                    record.remembered = .disabled
                } catch {}
            }
            try? self.save(record)
        }
        return record
    }

    func credentials(record: AccountSignInRecord) throws -> RememberedSignInEnvelope {
        guard record.remembered == .available, let data = try self.secrets.load() else {
            throw LiveFailure.savedSignInUnavailable
        }
        let envelope: RememberedSignInEnvelope
        do { envelope = try JSONDecoder().decode(RememberedSignInEnvelope.self, from: data) } catch {
            throw LiveFailure.savedSignInUnavailable
        }
        guard envelope.version == 1, envelope.account == self.key, envelope.summary == record.summary,
              envelope.connectionID == record.fence.connectionID,
              envelope.generation == record.credentialGeneration, !envelope.password.isEmpty
        else { throw LiveFailure.savedSignInUnavailable }
        return envelope
    }

    func disable(expected: AccountMutationFence) throws -> AccountSignInRecord {
        var record = try self.checked(expected)
        record.revision &+= 1
        record.remembered = .cleanupRequired
        record.credentialGeneration = nil
        try self.save(record)
        return try self.cleanup(record)
    }

    func logout(expected: AccountMutationFence) throws -> AccountSignInRecord {
        var record = try self.checked(expected)
        record.revision &+= 1
        record.disposition = .loggedOut
        record.remembered = .cleanupRequired
        record.credentialGeneration = nil
        record.attemptPending = false
        record.passwordAttemptID = nil
        try self.save(record)
        return record
    }

    func cleanup(_ input: AccountSignInRecord) throws -> AccountSignInRecord {
        var record = input
        try self.secrets.delete()
        record.remembered = .disabled
        record.rememberedFailure = nil
        try self.save(record)
        return record
    }
}

public final class EphemeralSessionStore: SessionStore, Sendable {
    private let value = OSAllocatedUnfairLock<Data?>(initialState: nil)
    public init() {}
    public func load() throws -> Data? {
        self.value.withLock { $0 }
    }

    public func save(_ data: Data) throws {
        self.value.withLock { $0 = data }
    }

    public func delete() throws {
        self.value.withLock { $0 = nil }
    }
}

public struct FileAccountSignInStore: SessionStore {
    private let url: URL
    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: self.url.path) else { return nil }
        guard try self.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw LiveFailure.storage
        }
        return try Data(contentsOf: self.url)
    }

    public func save(_ data: Data) throws {
        let temporary = self.url.deletingLastPathComponent().appendingPathComponent(".sign-in-\(UUID()).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LiveFailure.storage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlink(temporary.path) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, self.url.path) == 0 else { throw LiveFailure.storage }
    }

    public func delete() throws {
        guard unlink(self.url.path) == 0 || errno == ENOENT else { throw LiveFailure.storage }
    }
}
