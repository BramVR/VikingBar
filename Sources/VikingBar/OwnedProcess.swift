import Darwin
import Foundation
import os

struct OwnedProcess: Sendable {
    struct Identity: Sendable {
        let pid: Int32
        let parentPID: Int32
        let executable: URL
        let arguments: [String]
        let startedAt: Date
    }

    let process: Process
    let identity: Identity
    let input: FileHandle
    let output: FileHandle
    private let termination = OSAllocatedUnfairLock(initialState: Task<Void, Never>?.none)

    /// Read short pipe replies promptly without blocking Swift's cooperative executor.
    static func readChunk(from output: FileHandle, limit: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var bytes = [UInt8](repeating: 0, count: limit)
                while true {
                    let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                    if count == 0 {
                        continuation.resume(returning: nil); return
                    }
                    if count > 0 {
                        continuation.resume(returning: Data(bytes.prefix(count))); return
                    }
                    if errno != EINTR {
                        continuation.resume(throwing: LiveBridgeFailure.unavailable); return
                    }
                }
            }
        }
    }

    static func launch(executable: URL, arguments: [String]) throws -> Self {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = LiveServiceEnvironment.sanitized()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Cancellation can close the reader while a credential write is still in progress.
        guard Darwin.fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw LiveBridgeFailure.unavailable
        }
        try process.run()
        let identity = Identity(
            pid: process.processIdentifier, parentPID: getpid(), executable: executable,
            arguments: arguments, startedAt: Date(),
        )
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        return Self(process: process, identity: identity, input: input.fileHandleForWriting,
                    output: output.fileHandleForReading)
    }

    func stop(grace: Duration = .seconds(2)) async {
        let stopping = self.termination.withLock { task in
            if let task {
                return task
            }
            // A repeated SIGTERM can interrupt the credential helper's tmux cleanup.
            let stopping = Task.detached {
                try? self.input.close()
                guard self.process.isRunning, self.process.processIdentifier == self.identity.pid else { return }
                self.process.terminate()
                let deadline = ContinuousClock.now.advanced(by: grace)
                while self.process.isRunning, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                if self.process.isRunning {
                    Darwin.kill(self.identity.pid, SIGKILL)
                }
                self.process.waitUntilExit()
            }
            task = stopping
            return stopping
        }
        await stopping.value
    }

    func finish() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while self.process.isRunning, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { break }
        }
        if self.process.isRunning {
            await self.stop()
        }
    }
}
