import Foundation
import VikingBarCore

actor SessionProcessClient: SessionClient {
    private struct Reply: Decodable {
        let schemaVersion: Int
        let state: LiveSessionState
    }

    private enum Lifecycle { case idle, running, stopping, stopped }

    private let executableURL: URL
    private var lifecycle = Lifecycle.idle
    private var child: OwnedProcess?
    private var reader: Task<Void, Never>?
    private var pending: [CheckedContinuation<LiveSessionState, any Error>] = []
    private var buffer = Data()

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func request(_ request: SessionRequest) async throws -> LiveSessionState {
        guard self.lifecycle != .stopping, self.lifecycle != .stopped else { throw LiveBridgeFailure.stopped }
        if self.lifecycle == .idle {
            try self.start()
        }
        return try await self.send(request)
    }

    func shutdown() async {
        guard self.lifecycle != .stopped else {
            await self.reader?.value
            return
        }
        if self.lifecycle == .stopping {
            await self.reader?.value
            return
        }
        guard let child else {
            self.lifecycle = .stopped
            return
        }
        self.lifecycle = .stopping
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            await child.stop()
        }
        _ = try? await self.send(.shutdown)
        try? child.input.close()
        await child.finish()
        timeout.cancel()
        await self.reader?.value
        self.lifecycle = .stopped
        self.child = nil
    }

    private func start() throws {
        let child: OwnedProcess
        do { child = try OwnedProcess.launch(executable: self.executableURL, arguments: ["session"]) } catch {
            throw LiveBridgeFailure.unavailable
        }
        self.child = child
        self.lifecycle = .running
        self.reader = Task.detached { [weak self, output = child.output] in
            do {
                while let data = try await OwnedProcess.readChunk(from: output, limit: 4096) {
                    guard let self else { return }
                    await self.receive(data)
                }
            } catch {}
            try? output.close()
            await self?.ended()
        }
    }

    private func send(_ request: SessionRequest) async throws -> LiveSessionState {
        guard let child, child.process.isRunning, self.pending.count < 16 else {
            throw LiveBridgeFailure.unavailable
        }
        var data = try JSONEncoder().encode(request)
        guard data.count <= 65536 else { throw LiveBridgeFailure.invalidReply }
        data.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            self.pending.append(continuation)
            do { try child.input.write(contentsOf: data) } catch {
                self.failPending(.unavailable)
                Task { await child.stop() }
            }
        }
    }

    private func receive(_ data: Data) async {
        guard self.lifecycle != .stopped else { return }
        self.buffer.append(data)
        do {
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer.prefix(upTo: newline)
                guard line.count <= 1_048_576, !self.pending.isEmpty else { throw LiveBridgeFailure.invalidReply }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = SessionDateCoding.decodingStrategy
                let reply = try decoder.decode(Reply.self, from: line)
                guard reply.schemaVersion == 1 else { throw LiveBridgeFailure.invalidReply }
                self.buffer.removeSubrange(...newline)
                self.pending.removeFirst().resume(returning: reply.state)
            }
            guard self.buffer.count <= 1_048_576 else { throw LiveBridgeFailure.invalidReply }
        } catch {
            self.failPending(.invalidReply)
            self.lifecycle = .stopped
            await self.child?.stop()
        }
    }

    private func ended() {
        self.failPending(.stopped)
        self.lifecycle = .stopped
    }

    private func failPending(_ error: LiveBridgeFailure) {
        let pending = self.pending
        self.pending.removeAll()
        self.buffer.removeAll()
        for continuation in pending {
            continuation.resume(throwing: error)
        }
    }
}
