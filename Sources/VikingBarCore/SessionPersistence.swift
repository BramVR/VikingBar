import Darwin
import Foundation
import Security

public protocol SessionStore: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

public protocol SessionLease: Sendable {
    func acquire() throws -> any SessionLeaseHandle
}

public protocol SessionLeaseHandle: Sendable {
    func release()
}

public protocol BalanceCache: Sendable {
    func load(connectionID: ConnectionID) throws -> LiveSessionState?
    func save(_ state: LiveSessionState) throws
}

public struct KeychainSessionStore: SessionStore {
    public init() {}

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "be.bram.vikingbar.oauth",
         kSecAttrAccount as String: "mobile-vikings"]
    }

    public func load() throws -> Data? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        if code == errSecItemNotFound {
            return nil
        }
        guard code == errSecSuccess, let data = result as? Data else { throw LiveFailure.storage }
        return data
    }

    public func save(_ data: Data) throws {
        let code = SecItemUpdate(self.query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if code == errSecItemNotFound {
            var item = self.query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw LiveFailure.storage }
        } else if code != errSecSuccess {
            throw LiveFailure.storage
        }
    }
}

public struct FileSessionLease: SessionLease {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func acquire() throws -> any SessionLeaseHandle {
        let descriptor = open(self.url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LiveFailure.storage }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            throw error == EWOULDBLOCK ? LiveFailure.busy : LiveFailure.storage
        }
        return FileLeaseHandle(descriptor: descriptor)
    }
}

private final class FileLeaseHandle: SessionLeaseHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let descriptor {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            self.descriptor = nil
        }
    }

    deinit { self.release() }
}

public struct FileBalanceCache: BalanceCache {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load(connectionID: ConnectionID) throws -> LiveSessionState? {
        guard FileManager.default.fileExists(atPath: self.url.path) else { return nil }
        do {
            let record = try JSONDecoder().decode(CachedBalance.self, from: Data(contentsOf: self.url))
            guard record.version == 1, record.state.connectionID == connectionID else { return nil }
            var state = record.state
            state.invoiceDocument = nil
            state.connectionSummary = nil
            return state
        } catch { throw LiveFailure.storage }
    }

    public func save(_ state: LiveSessionState) throws {
        do {
            var cached = state
            cached.invoiceDocument = nil
            // Restore account identity from Keychain, not the balance cache.
            cached.connectionSummary = nil
            let data = try JSONEncoder().encode(CachedBalance(version: 1, state: cached))
            let temporary = self.url.deletingLastPathComponent().appendingPathComponent(".balance-\(UUID()).tmp")
            let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw LiveFailure.storage }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer {
                try? handle.close()
                unlink(temporary.path)
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard rename(temporary.path, self.url.path) == 0 else { throw LiveFailure.storage }
        } catch { throw LiveFailure.storage }
    }
}

private struct CachedBalance: Codable {
    let version: Int
    let state: LiveSessionState
}

struct StoredSession: Codable {
    var version = 1
    let clientID: String
    let username: String?
    let connectionID: ConnectionID
    var refreshToken: String
    var generation: UInt64
    var rotationPending: Bool

    var connectionSummary: AccountConnectionSummary {
        AccountConnectionSummary(clientID: self.clientID, username: self.username)
    }
}
