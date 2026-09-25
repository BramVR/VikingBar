import Darwin
import Foundation

public struct ProviderID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.count <= 48,
              rawValue.utf8.allSatisfy({ (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45 })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.singleValueContainer()
        let raw = try values.decode(String.self)
        guard let value = Self(rawValue: raw) else { throw LiveFailure.invalidSelection }
        self = value
    }

    public static let mobileVikings = ProviderID(rawValue: "mobile-vikings")!
    public static let telenet = ProviderID(rawValue: "telenet")!
    public static let fixtureHome = ProviderID(rawValue: "fixture-home")!
}

public struct AccountKey: Codable, Hashable, Sendable, Identifiable {
    public let provider: ProviderID
    public let slot: UUID
    public var id: String {
        "\(self.provider.rawValue)/\(self.slot.uuidString.lowercased())"
    }

    public init(provider: ProviderID, slot: UUID = UUID()) {
        self.provider = provider
        self.slot = slot
    }

    public init(selector: String) throws {
        let parts = selector.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let provider = ProviderID(rawValue: String(parts[0])),
              let slot = UUID(uuidString: String(parts[1])) else { throw LiveFailure.invalidSelection }
        self.init(provider: provider, slot: slot)
    }

    public static let legacy = AccountKey(
        provider: .mobileVikings, slot: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    )
}

public enum ServiceKind: String, Codable, Sendable { case mobile, home }

public struct ServiceKey: Codable, Hashable, Sendable {
    public let account: AccountKey
    public let kind: ServiceKind
    public let providerID: String
    public init(account: AccountKey, kind: ServiceKind, providerID: String) {
        self.account = account
        self.kind = kind
        self.providerID = providerID
    }
}

public struct AccountEntry: Codable, Equatable, Sendable, Identifiable {
    public let key: AccountKey
    public let label: String
    public var id: String {
        self.key.id
    }

    public init(key: AccountKey, label: String) {
        self.key = key
        self.label = label
    }
}

public struct CatalogSnapshot: Codable, Equatable, Sendable {
    public var version = 1
    public var revision: UInt64 = 0
    public var accounts: [AccountEntry]
    public var selected: AccountKey
    public init(accounts: [AccountEntry], selected: AccountKey) {
        self.accounts = accounts
        self.selected = selected
    }
}

public struct AccountStorage: Sendable {
    public let key: AccountKey
    public let directory: URL
    public var keychainAccount: String {
        self.key == .legacy ? "mobile-vikings" : self.key.id
    }

    public var leaseURL: URL {
        self.directory.appendingPathComponent("session.lock")
    }

    public var cacheURL: URL {
        self.directory.appendingPathComponent("balance-v1.json")
    }

    public init(root: URL, key: AccountKey) {
        self.key = key
        self.directory = key == .legacy ? root : root.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(key.provider.rawValue, isDirectory: true)
            .appendingPathComponent(key.slot.uuidString.lowercased(), isDirectory: true)
    }

    public func prepare() throws {
        try AccountCatalog.prepareDirectory(self.directory)
    }
}

/// Catalog transactions never open credentials or hold a lease during provider work.
public struct AccountCatalog: Sendable {
    public let root: URL
    public init(root: URL) {
        self.root = root
    }

    public static func production() throws -> Self {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false,
        ).appendingPathComponent("VikingBar", isDirectory: true)
        return Self(root: root)
    }

    public func snapshot() throws -> CatalogSnapshot {
        try self.transaction { _ in }
    }

    public func reserve(provider: ProviderID, label: String) throws -> AccountEntry {
        let entry = AccountEntry(key: AccountKey(provider: provider), label: label)
        _ = try self.transaction { $0.accounts.append(entry) }
        return entry
    }

    public func select(_ key: AccountKey, replacing expected: AccountKey? = nil) throws {
        _ = try self.transaction { snapshot in
            guard snapshot.accounts.contains(where: { $0.key == key }) else { throw LiveFailure.invalidSelection }
            if expected == nil || snapshot.selected == expected {
                snapshot.selected = key
            }
        }
    }

    public func resolve(_ explicit: AccountKey? = nil, provider: ProviderID? = nil) throws -> AccountKey {
        let snapshot = try self.snapshot()
        let key = explicit ?? snapshot.selected
        guard snapshot.accounts.contains(where: { $0.key == key }),
              provider == nil || provider == key.provider else { throw LiveFailure.invalidSelection }
        return key
    }

    public func selectedAtInvocation(provider: ProviderID? = nil) throws -> AccountKey {
        let key = try self.readExisting()?.selected ?? .legacy
        guard provider == nil || provider == key.provider else { throw LiveFailure.invalidSelection }
        return key
    }

    private func readExisting() throws -> CatalogSnapshot? {
        let url = self.root.appendingPathComponent("accounts-v1.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw LiveFailure.storage
            }
            let snapshot = try JSONDecoder().decode(CatalogSnapshot.self, from: Data(contentsOf: url))
            guard snapshot.version == 1, !snapshot.accounts.isEmpty,
                  Set(snapshot.accounts.map(\.key)).count == snapshot.accounts.count,
                  snapshot.accounts.contains(where: { $0.key == snapshot.selected })
            else {
                throw LiveFailure.storage
            }
            return snapshot
        } catch { throw LiveFailure.storage }
    }

    private func transaction(_ edit: (inout CatalogSnapshot) throws -> Void) throws -> CatalogSnapshot {
        try Self.prepareDirectory(self.root)
        let lease = try FileSessionLease(url: self.root.appendingPathComponent("catalog.lock")).acquire()
        defer { lease.release() }
        let url = self.root.appendingPathComponent("accounts-v1.json")
        let stored = try self.readExisting()
        let exists = stored != nil
        var snapshot = stored ?? CatalogSnapshot(
            accounts: [AccountEntry(key: .legacy, label: "Mobile Vikings")], selected: .legacy,
        )
        let previous = snapshot
        try edit(&snapshot)
        if !exists || snapshot != previous {
            snapshot.revision += 1
            let temporary = self.root.appendingPathComponent(".catalog-\(UUID()).tmp")
            let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw LiveFailure.storage }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close(); unlink(temporary.path) }
            try handle.write(contentsOf: JSONEncoder().encode(snapshot))
            try handle.synchronize()
            guard rename(temporary.path, url.path) == 0 else { throw LiveFailure.storage }
        }
        return snapshot
    }

    static func prepareDirectory(_ url: URL) throws {
        var ancestor = url
        while ancestor.path != "/" {
            let systemAlias = ["/var", "/tmp"].contains(ancestor.path)
                && (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) == "private" + ancestor
                .path
            if FileManager.default.fileExists(atPath: ancestor.path), !systemAlias {
                let values = try ancestor.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw LiveFailure.storage }
            }
            ancestor.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
