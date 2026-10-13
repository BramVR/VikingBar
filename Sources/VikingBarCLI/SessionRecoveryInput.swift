import Darwin
import Foundation
import VikingBarCore

struct RecoveryInput {
    let key: AccountKey
    let storage: AccountStorage
    let phase: String
    let timeout: TimeInterval
    let credentials: ProviderCredentials?
    let root: URL

    init(check: String, data: Data) throws {
        guard data.count <= 32768,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let phase = object["phase"] as? String,
              ["exercise", "prepare", "inspect", "disable", "logout"].contains(phase),
              Set(object.keys) == Set(["account", "root", "phase", "timeout_seconds"]
                  + (phase == "exercise" ? ["credentials"] : [])),
              let selector = object["account"] as? String,
              let root = object["root"] as? String, root.hasPrefix("/"),
              let timeout = object["timeout_seconds"] as? Int, (60 ... 3300).contains(timeout)
        else { throw ProofFailure.invalidInput }
        let key = try AccountKey(selector: selector)
        let provider: ProviderID = check == "telenet-remembered-sign-in" ? .telenet : .mobileVikings
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let permissions = try rootURL.deletingLastPathComponent().resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        let attributes = try FileManager.default.attributesOfItem(atPath: rootURL.deletingLastPathComponent().path)
        guard ["mobile-session-recovery", "mobile-remembered-sign-in", "telenet-remembered-sign-in"].contains(check),
              key.provider == provider, key != .legacy,
              rootURL.standardizedFileURL.path == root,
              rootURL.lastPathComponent == "session-recovery-" + key.slot.uuidString.lowercased(),
              permissions.isDirectory == true, permissions.isSymbolicLink != true,
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
              phase != "prepare" || !FileManager.default.fileExists(atPath: root)
        else { throw ProofFailure.invalidInput }
        if phase != "prepare" {
            try Self.verifyOwnership(key: key, root: rootURL)
        }
        self.key = key
        self.root = rootURL
        self.storage = AccountStorage(root: URL(fileURLWithPath: root, isDirectory: true), key: key)
        self.phase = phase
        self.timeout = TimeInterval(timeout)
        if phase == "exercise" {
            guard let fields = object["credentials"] as? [String: String] else { throw ProofFailure.invalidInput }
            self.credentials = try ProviderCredentials.decode(JSONSerialization.data(withJSONObject: fields),
                                                              for: provider)
        } else {
            self.credentials = nil
        }
    }

    func publishOwnership() throws {
        let url = self.root.appendingPathComponent("session-recovery-owner.json")
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LiveFailure.storage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: JSONEncoder().encode(Owner(version: 1, account: self.key, root: self.root.path)))
        try handle.synchronize()
    }

    private struct Owner: Codable, Equatable {
        let version: Int
        let account: AccountKey
        let root: String
    }

    private static func verifyOwnership(key: AccountKey, root: URL) throws {
        let storage = AccountStorage(root: root, key: key)
        var directory = storage.directory
        while directory.path.count >= root.path.count {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
            else { throw ProofFailure.invalidInput }
            directory.deleteLastPathComponent()
        }
        let marker = root.appendingPathComponent("session-recovery-owner.json")
        let values = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: marker.path)
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= 32768,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
        else { throw ProofFailure.invalidInput }
        let data = try Data(contentsOf: marker)
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys) == ["version", "account", "root"],
              let account = fields["account"] as? [String: Any], Set(account.keys) == ["provider", "slot"],
              try JSONDecoder().decode(Owner.self, from: data) == Owner(version: 1, account: key, root: root.path)
        else { throw ProofFailure.invalidInput }
    }
}
