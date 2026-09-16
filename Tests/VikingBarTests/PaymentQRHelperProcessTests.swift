import Darwin
import Foundation
import Testing
@testable import VikingBarCore

@Suite(.serialized)
struct PaymentQRHelperProcessTests {
    @Test func `cancel before launch never starts helper`() async throws {
        let fixture = try HelperFixture(source: """
        #!/bin/sh
        printf started > '@@MARKER@@'
        """)
        defer { fixture.remove() }
        try? FileManager.default.removeItem(at: fixture.marker)
        let process = PaymentQRHelperProcess(executableURL: fixture.url, input: Data())
        process.stop()
        await #expect(throws: CancellationError.self) { try await process.run() }
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
    }

    @Test func `early helper exit cannot terminate caller with SIGPIPE`() async throws {
        let fixture = try HelperFixture(source: "#!/bin/sh\nexit 1\n")
        defer { fixture.remove() }
        let process = PaymentQRHelperProcess(
            executableURL: fixture.url,
            input: Data(repeating: 0x41, count: 1_048_576),
        )
        await #expect(throws: (any Error).self) { try await process.run() }
    }

    @Test func `timeout kills a helper that ignores TERM`() async throws {
        let fixture = try HelperFixture(source: """
        #!/bin/sh
        trap '' TERM
        printf '%s' $$ > '@@MARKER@@'
        exec /bin/sleep 30
        """)
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: fixture.marker)
        }
        try? FileManager.default.removeItem(at: fixture.marker)
        let helper = PaymentQRHelper(executableURL: fixture.url, timeout: .seconds(2))
        await #expect(throws: PaymentQRHelperError.unavailable) {
            try await helper.render(Self.details, now: Date(timeIntervalSince1970: 1000))
        }
        let pidText = try String(contentsOf: fixture.marker, encoding: .utf8)
        let pid = try #require(Int(pidText))
        for _ in 0 ..< 100 where kill(Int32(pid), 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(Int32(pid), 0) == -1 && errno == ESRCH)
    }

    private static let details = InvoicePaymentDetails(
        invoiceID: "inv-1", invoiceNumber: "2026-10", invoiceDate: "2026-09-01T00:00:00Z",
        dueDate: "2026-09-20T00:00:00Z", sourceUpdatedAt: Date(timeIntervalSince1970: 1000),
        recipient: .mobileVikings, amount: Decimal(string: "42.50")!, amountText: "42.50",
        reference: "+++123/4567/89002+++", scope: "Customer invoice. SIM membership unknown.",
    )
}

private struct HelperFixture {
    let marker: URL
    let folder: URL
    let url: URL

    init(source: String) throws {
        self.folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        self.url = self.folder.appending(path: "helper")
        self.marker = self.folder.appending(path: "started")
        try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: false)
        try source.replacingOccurrences(of: "@@MARKER@@", with: self.marker.path)
            .write(to: self.url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.url.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.folder)
    }
}
