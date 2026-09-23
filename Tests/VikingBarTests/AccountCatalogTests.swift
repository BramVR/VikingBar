import Foundation
import Testing
@testable import VikingBarCore

struct AccountCatalogTests {
    @Test func `legacy alias initializes without touching session bytes and reserves separate namespaces`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("legacy pending rotation and cache sentinel".utf8)
        try bytes.write(to: root.appendingPathComponent("balance-v1.json"))
        let catalog = AccountCatalog(root: root)
        #expect(try catalog.snapshot().selected == .legacy)
        let first = try catalog.reserve(provider: .mobileVikings, label: "Second mobile account")
        let second = try catalog.reserve(provider: .fixtureHome, label: "Home fixture")
        #expect(try catalog.snapshot().selected == .legacy)
        let old = AccountStorage(root: root, key: .legacy)
        let new = AccountStorage(root: root, key: first.key)
        #expect(old.keychainAccount == "mobile-vikings")
        #expect(old.leaseURL == root.appendingPathComponent("session.lock"))
        #expect(try Data(contentsOf: old.cacheURL) == bytes)
        #expect(new.keychainAccount != old.keychainAccount)
        #expect(new.cacheURL != old.cacheURL)
        #expect(new.leaseURL != old.leaseURL)
        try catalog.select(first.key)
        #expect(try catalog.resolve(second.key) == second.key)
        #expect(try AccountCatalog(root: root).resolve() == first.key)
        #expect(throws: LiveFailure.invalidSelection) { try catalog.resolve(first.key, provider: .fixtureHome) }
        try new.prepare()
        let held = try FileSessionLease(url: old.leaseURL).acquire()
        defer { held.release() }
        let other = try FileSessionLease(url: new.leaseURL).acquire()
        other.release()
        #expect(throws: LiveFailure.busy) { try FileSessionLease(url: old.leaseURL).acquire() }
    }

    @Test func `invocation snapshots selection without initializing missing storage`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = AccountCatalog(root: root)
        #expect(try catalog.selectedAtInvocation() == .legacy)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let second = try catalog.reserve(provider: .mobileVikings, label: "Second")
        let bound = try catalog.selectedAtInvocation()
        try catalog.select(second.key)
        #expect(try catalog.resolve(bound) == .legacy)
        #expect(try catalog.resolve() == second.key)
    }

    @Test func `conditional rollback never replaces a newer selection`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = AccountCatalog(root: root)
        let added = try catalog.reserve(provider: .mobileVikings, label: "Added")
        let newer = try catalog.reserve(provider: .mobileVikings, label: "Newer")
        try catalog.select(added.key)
        try catalog.select(.legacy, replacing: added.key)
        #expect(try catalog.resolve() == .legacy)
        try catalog.select(newer.key)
        try catalog.select(.legacy, replacing: added.key)
        #expect(try catalog.resolve() == newer.key)
    }

    @Test func `corrupt catalog fails without overwriting or falling back`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = AccountCatalog(root: root)
        _ = try catalog.snapshot()
        let url = root.appendingPathComponent("accounts-v1.json")
        let invalid = Data("{\"version\":9000}".utf8)
        try invalid.write(to: url)
        #expect(throws: LiveFailure.storage) { try catalog.snapshot() }
        #expect(try Data(contentsOf: url) == invalid)
    }

    @Test func `independent catalog writers retain reservations and selection`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = AccountCatalog(root: root)
        let second = AccountCatalog(root: root)
        let entry = try first.reserve(provider: .mobileVikings, label: "One")
        try second.select(entry.key)
        _ = try first.reserve(provider: .mobileVikings, label: "Two")
        #expect(try second.snapshot().accounts.count == 3)
        #expect(try second.snapshot().selected == entry.key)
        #expect(throws: LiveFailure.invalidSelection) { try AccountKey(selector: "mobile-vikings/../../secret") }
    }
}
