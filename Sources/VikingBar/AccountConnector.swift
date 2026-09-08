import Darwin
import Foundation
import VikingBarCore

private struct AccountConnectReceipt: Decodable {
    let schemaVersion: Int
    let check: String
    let passed: Bool
    let connected: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case check, passed, connected
    }
}

actor AccountConnector: AccountConnecting {
    private let cliURL: URL
    private let helperURL: URL
    private var child: OwnedProcess?

    init(cliURL: URL, helperURL: URL) {
        self.cliURL = cliURL
        self.helperURL = helperURL
    }

    func connect(input: AccountConnectionInput, resultURL: URL?) async throws {
        let directCredentials: ConnectionCredentials? = if case let .credentials(credentials) = input {
            credentials
        } else {
            nil
        }
        defer { directCredentials?.discard() }
        guard self.child == nil,
              resultURL.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true
        else { throw LiveBridgeFailure.connectFailed }
        let child: OwnedProcess
        do { child = try self.launch(input: input, resultURL: resultURL) } catch {
            if directCredentials != nil {
                Self.writeFailure(error, to: resultURL)
            }
            throw error as? LiveBridgeFailure ?? .connectFailed
        }
        self.child = child
        defer { self.child = nil }
        let writer = Task.detached {
            if let directCredentials {
                try child.input.write(contentsOf: directCredentials.takePayload())
                try child.input.close()
            }
        }
        let reader = Task.detached { try await Self.readReceipt(child: child) }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(190)) } catch { return }
            await child.stop(grace: .seconds(12))
        }
        defer { timeout.cancel() }
        do {
            let data = try await withTaskCancellationHandler {
                try await writer.value
                return try await reader.value
            } onCancel: { Task { await child.stop(grace: .seconds(12)) } }
            await child.finish()
            try Task.checkCancellation()
            try Self.validateReceipt(data, exitStatus: child.process.terminationStatus)
            if directCredentials != nil, let resultURL {
                try Self.writeReceipt(data, to: resultURL)
            }
        } catch {
            await child.stop(grace: .seconds(12))
            _ = try? await writer.value
            _ = try? await reader.value
            if directCredentials != nil {
                Self.writeFailure(error, to: resultURL)
            }
            throw error as? LiveBridgeFailure ?? .connectFailed
        }
    }

    private static func readReceipt(child: OwnedProcess) async throws -> Data {
        defer { try? child.output.close() }
        do {
            var output = Data()
            while let data = try await OwnedProcess.readChunk(from: child.output, limit: 1024) {
                output.append(data)
                guard output.count <= 4096 else { throw LiveBridgeFailure.connectFailed }
            }
            return output
        } catch {
            await child.stop(grace: .seconds(12))
            throw error
        }
    }

    private static func validateReceipt(_ data: Data, exitStatus: Int32) throws {
        if exitStatus != 0 {
            struct Failure: Decodable { let error: BootstrapFailure }
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
                throw LiveBridgeFailure.bootstrap(failure.error)
            }
            throw LiveBridgeFailure.connectFailed
        }
        let receipt = try JSONDecoder().decode(AccountConnectReceipt.self, from: data)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard receipt.schemaVersion == 1, receipt.check == "connect", receipt.passed, receipt.connected,
              object.map({ Set($0.keys) }) == ["schema_version", "check", "passed", "connected"]
        else { throw LiveBridgeFailure.connectFailed }
    }

    private func launch(input: AccountConnectionInput, resultURL: URL?) throws -> OwnedProcess {
        switch input {
        case .credentials:
            return try OwnedProcess.launch(executable: self.cliURL, arguments: ["connect"])
        case let .reference(reference):
            var arguments = ["-I", self.helperURL.path, "--cli", self.cliURL.path, "--reference", reference.path]
            if let resultURL {
                arguments += ["--result", resultURL.path]
            }
            return try OwnedProcess.launch(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments)
        }
    }

    private static func writeFailure(_ error: any Error, to url: URL?) {
        guard let url else { return }
        let failure: BootstrapFailure = if case let .bootstrap(code) = error as? LiveBridgeFailure {
            code
        } else {
            error is CancellationError ? .connectCancelled : .connectFailed
        }
        struct Receipt: Encodable { let passed = false; let error: BootstrapFailure }
        if let data = try? JSONEncoder().encode(Receipt(error: failure)) {
            try? Self.writeReceipt(data, to: url)
        }
    }

    private static func writeReceipt(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LiveBridgeFailure.connectFailed }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try file.write(contentsOf: data)
            try file.close()
        } catch { throw LiveBridgeFailure.connectFailed }
    }

    func cancel() async {
        await self.child?.stop(grace: .seconds(12))
    }
}
