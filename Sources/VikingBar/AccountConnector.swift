import Foundation

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

    func connect(reference: URL, resultURL: URL?) async throws {
        guard self.child == nil,
              resultURL.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true
        else { throw LiveBridgeFailure.connectFailed }
        var arguments = ["-I", self.helperURL.path, "--cli", self.cliURL.path, "--reference", reference.path]
        if let resultURL {
            arguments += ["--result", resultURL.path]
        }
        let child: OwnedProcess
        do {
            child = try OwnedProcess.launch(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments)
        } catch { throw LiveBridgeFailure.connectFailed }
        self.child = child
        let reader = Task.detached {
            defer { try? child.output.close() }
            var output = Data()
            while let data = try await OwnedProcess.readChunk(from: child.output, limit: 1024) {
                output.append(data)
                guard output.count <= 4096 else { throw LiveBridgeFailure.connectFailed }
            }
            return output
        }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(190)) } catch { return }
            await child.stop(grace: .seconds(12))
        }
        do {
            let data = try await withTaskCancellationHandler {
                try await reader.value
            } onCancel: { Task { await child.stop(grace: .seconds(12)) } }
            await child.finish()
            try Task.checkCancellation()
            guard child.process.terminationStatus == 0 else { throw LiveBridgeFailure.connectFailed }
            let receipt = try JSONDecoder().decode(AccountConnectReceipt.self, from: data)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard receipt.schemaVersion == 1, receipt.check == "connect", receipt.passed, receipt.connected,
                  object.map({ Set($0.keys) }) == ["schema_version", "check", "passed", "connected"]
            else { throw LiveBridgeFailure.connectFailed }
            timeout.cancel()
            self.child = nil
        } catch {
            timeout.cancel()
            await child.stop(grace: .seconds(12))
            _ = try? await reader.value
            self.child = nil
            throw LiveBridgeFailure.connectFailed
        }
    }

    func cancel() async {
        await self.child?.stop(grace: .seconds(12))
    }
}
