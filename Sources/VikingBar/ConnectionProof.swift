import Darwin
import Foundation

private struct ConnectionProofCandidate: Encodable {
    let schemaVersion = 1
    let pid: Int32
    let parentPID: Int32

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case pid, parentPID
    }
}

private struct ConnectionProofAcknowledgement: Decodable {
    let schemaVersion: Int
    let pid: Int32

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case pid
    }
}

enum ConnectionProof {
    static func register(child: OwnedProcess, resultURL: URL) async throws {
        let directory = resultURL.deletingLastPathComponent()
        let ready = directory.appending(path: "direct-connect-child-ready.json")
        guard !FileManager.default.fileExists(atPath: ready.path) else { throw LiveBridgeFailure.connectFailed }
        let candidate = ConnectionProofCandidate(pid: child.identity.pid, parentPID: child.identity.parentPID)
        try self.write(JSONEncoder().encode(candidate), to: directory.appending(path: "direct-connect-child.json"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while child.process.isRunning, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if try self.acknowledged(pid: child.identity.pid, at: ready) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LiveBridgeFailure.connectFailed
    }

    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".vikingbar-proof-\(UUID()).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LiveBridgeFailure.connectFailed }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? file.close()
            Darwin.unlink(temporary.path)
        }
        do {
            try file.write(contentsOf: data)
            try file.synchronize()
            try file.close()
            guard Darwin.link(temporary.path, url.path) == 0 else { throw LiveBridgeFailure.connectFailed }
        } catch { throw LiveBridgeFailure.connectFailed }
    }

    private static func acknowledged(pid: Int32, at url: URL) throws -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT {
            return false
        }
        guard descriptor >= 0 else { throw LiveBridgeFailure.connectFailed }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 4096,
              let data = try file.read(upToCount: 4097), data.count <= 4096
        else { throw LiveBridgeFailure.connectFailed }
        let acknowledgement = try JSONDecoder().decode(ConnectionProofAcknowledgement.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard object.map({ Set($0.keys) }) == ["schema_version", "pid"],
              acknowledgement.schemaVersion == 1, acknowledgement.pid == pid
        else { throw LiveBridgeFailure.connectFailed }
        return true
    }
}
