import Darwin
import Foundation

public protocol PaymentQRRendering: Sendable {
    func render(_ details: InvoicePaymentDetails, now: Date) async throws -> InvoicePaymentQRCode
}

public enum PaymentQRHelperError: Error, Equatable, Sendable {
    case unavailable
    case rejected
    case invalidReply
}

public struct UnavailablePaymentQRRenderer: PaymentQRRendering {
    public init() {}

    public func render(_: InvoicePaymentDetails, now _: Date) async throws -> InvoicePaymentQRCode {
        throw PaymentQRHelperError.unavailable
    }
}

public struct PaymentQRHelper: PaymentQRRendering, Sendable {
    private struct Request: Encodable {
        let payee: String
        let iban: String
        let bic: String
        let amount: String
        let reference: String
    }

    private struct Reply: Decodable {
        let payee: String
        let iban: String
        let bic: String
        let amount: String
        let reference: String
        let referenceKind: String
        let payload: String
        let png: Data
    }

    public let executableURL: URL
    let timeout: Duration

    public init(executableURL: URL, timeout: Duration = .seconds(10)) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public static func productionExecutableURL(
        executablePath: String = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0],
    ) -> URL {
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
        let directory = executable.deletingLastPathComponent()
        let inAppBundle = directory.lastPathComponent == "MacOS"
            && directory.deletingLastPathComponent().lastPathComponent == "Contents"
        if inAppBundle {
            return directory.deletingLastPathComponent().appending(path: "Resources/payment-qr")
        }
        if ["debug", "release"].contains(directory.lastPathComponent) {
            let parent = directory.deletingLastPathComponent()
            let build = parent.lastPathComponent == ".build" ? parent : parent.deletingLastPathComponent()
            if build.lastPathComponent == ".build" {
                return build.appending(path: "payment-qr/payment-qr")
            }
        }
        return directory.appending(path: "payment-qr")
    }

    public func render(_ details: InvoicePaymentDetails, now: Date) async throws -> InvoicePaymentQRCode {
        let executableURL = self.executableURL
        let input = try JSONEncoder().encode(Request(
            payee: details.recipient.name,
            iban: details.recipient.iban,
            bic: details.recipient.bic,
            amount: details.amountText,
            reference: details.reference,
        ))
        guard input.count <= 65536 else { throw PaymentQRHelperError.rejected }
        let runner = PaymentQRHelperProcess(executableURL: executableURL, input: input)
        let timeout = self.timeout
        let output = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await runner.run() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw PaymentQRHelperError.unavailable
                }
                defer {
                    group.cancelAll()
                    runner.stop()
                }
                guard let result = try await group.next() else { throw PaymentQRHelperError.unavailable }
                return result
            }
        } onCancel: {
            runner.stop()
        }
        let reply: Reply
        do { reply = try JSONDecoder().decode(Reply.self, from: output) } catch {
            throw PaymentQRHelperError.invalidReply
        }
        guard reply.payee == details.recipient.name,
              reply.iban == details.recipient.iban,
              reply.bic == details.recipient.bic,
              reply.amount == details.amountText,
              reply.reference == details.reference,
              reply.referenceKind == "structured",
              reply.png.count <= 1_048_576,
              reply.png.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        else { throw PaymentQRHelperError.invalidReply }
        let result = InvoicePaymentQRCode(
            details: details,
            payload: reply.payload,
            png: reply.png,
            generatedAt: now,
            expiresAt: now.addingTimeInterval(InvoicePaymentQRCode.lifetime),
        )
        guard result.validatePayload() else { throw PaymentQRHelperError.invalidReply }
        return result
    }
}

final class PaymentQRHelperProcess: @unchecked Sendable {
    private let executableURL: URL
    private let input: Data
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(executableURL: URL, input: Data) {
        self.executableURL = executableURL
        self.input = input
    }

    func run() async throws -> Data {
        try await Task.detached {
            guard self.executableURL.isFileURL,
                  FileManager.default.isExecutableFile(atPath: self.executableURL.path)
            else { throw PaymentQRHelperError.unavailable }
            let process = Process()
            let standardInput = Pipe()
            let standardOutput = Pipe()
            process.executableURL = self.executableURL
            process.arguments = []
            process.environment = [:]
            process.standardInput = standardInput
            process.standardOutput = standardOutput
            process.standardError = FileHandle.nullDevice
            try self.lock.withLock {
                guard !self.cancelled else { throw CancellationError() }
                self.process = process
                do { try process.run() } catch {
                    self.process = nil
                    throw PaymentQRHelperError.unavailable
                }
            }
            defer { self.lock.withLock { self.process = nil } }
            guard fcntl(standardInput.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                self.stop()
                throw PaymentQRHelperError.unavailable
            }
            do {
                try standardInput.fileHandleForWriting.write(contentsOf: self.input)
                try standardInput.fileHandleForWriting.close()
            } catch {
                self.stop()
                throw PaymentQRHelperError.unavailable
            }
            var data = Data()
            while let chunk = try standardOutput.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                data.append(chunk)
                if data.count > 2_097_152 {
                    self.stop()
                    throw PaymentQRHelperError.invalidReply
                }
            }
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw PaymentQRHelperError.rejected
            }
            return data
        }.value
    }

    func stop() {
        self.lock.withLock {
            self.cancelled = true
            guard let process = self.process, process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                guard process.isRunning, process.processIdentifier == pid else { return }
                kill(pid, SIGKILL)
            }
        }
    }
}
