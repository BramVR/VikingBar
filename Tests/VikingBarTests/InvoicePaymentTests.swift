import CoreImage
import Foundation
import Testing
@testable import VikingBarCore
import Vision

struct InvoicePaymentTests {
    private static let reference = "+++123/4567/89002+++"

    @Test func `plain provider reference preserves digits and validates checksum`() {
        #expect(InvoicePaymentSelection.belgianStructuredReference("123456789002") == "+++123/4567/89002+++")
        #expect(InvoicePaymentSelection.belgianStructuredReference("123456789003") == nil)
        #expect(InvoicePaymentSelection.belgianStructuredReference("12345678900") == nil)
        #expect(InvoicePaymentSelection.belgianStructuredReference("1234567890020") == nil)
        #expect(InvoicePaymentSelection.belgianStructuredReference("123 456789002") == nil)
    }

    @Test func `helper resolves app archive and SwiftPM development locations`() {
        let cases = [
            ("/app/VikingBar.app/Contents/MacOS/vikingbar", "/app/VikingBar.app/Contents/Resources/payment-qr"),
            ("/tools/vikingbar", "/tools/payment-qr"),
            ("/repo/.build/debug/vikingbar", "/repo/.build/payment-qr/payment-qr"),
            ("/repo/.build/arm64-apple-macosx/release/vikingbar", "/repo/.build/payment-qr/payment-qr"),
        ]
        for (executable, helper) in cases {
            #expect(PaymentQRHelper.productionExecutableURL(executablePath: executable).path == helper)
        }
    }

    @Test func `partial grouped invoice keeps exact due amount and account scope`() throws {
        let invoice = try Self.invoice(
            amount: "100.00", due: "42.50", grouped: true,
            extra: ",\"reference_number\":\"\(Self.reference)\",\"expiration_date\":\"2026-09-10T00:00:00Z\"",
        )
        let selection = InvoicePaymentSelection.select(
            snapshot: .loaded([invoice], updatedAt: LiveModelsTests.now),
            requestedInvoiceID: nil,
            selectedSubscriptionID: "sim-a",
            now: LiveModelsTests.now,
        )
        guard case let .selected(details, candidates) = selection else {
            Issue.record("Expected selected payment")
            return
        }
        #expect(details.amount == Decimal(string: "42.50"))
        #expect(details.amountText == "42.50")
        #expect(details.reference == Self.reference)
        #expect(details.recipient == .mobileVikings)
        #expect(details.scope == "Grouped invoice. Selected SIM membership unknown.")
        #expect(candidates.map(\.id) == ["inv-1"])
    }

    @Test func `next payable orders due date then invoice date number and id`() throws {
        let invoices = try [
            Self.invoice(id: "z", number: "10", date: "2026-09-01T00:00:00Z", due: "5.00",
                         extra: Self.fields(expiration: nil)),
            Self.invoice(id: "b", number: "10", date: "2026-08-01T00:00:00Z", due: "5.00",
                         extra: Self.fields(expiration: "2026-09-20T00:00:00Z")),
            Self.invoice(id: "a", number: "2", date: "2026-08-01T00:00:00Z", due: "5.00",
                         extra: Self.fields(expiration: "2026-09-20T00:00:00Z")),
            Self.invoice(id: "first", number: "99", date: "2026-09-01T00:00:00Z", due: "5.00",
                         extra: Self.fields(expiration: "2026-09-10T00:00:00Z")),
        ]
        let selection = InvoicePaymentSelection.select(
            snapshot: .loaded(invoices, updatedAt: LiveModelsTests.now), requestedInvoiceID: nil,
            selectedSubscriptionID: nil, now: LiveModelsTests.now,
        )
        guard case let .selected(details, candidates) = selection else {
            Issue.record("Expected selection")
            return
        }
        #expect(details.invoiceID == "first")
        #expect(candidates.map(\.id) == ["first", "a", "b", "z"])
    }

    @Test func `known nonpayable documents do not hide a real payable invoice`() throws {
        let invoices = try [
            Self.invoice(id: "zero", date: "2026-07-01T00:00:00Z", due: "0", extra: Self.fields()),
            Self.invoice(id: "sepa", date: "2026-07-02T00:00:00Z", due: "10", extra: Self.fields(
                suffix: ",\"sepa_generation_date\":\"2026-09-01T00:00:00Z\"",
            )),
            Self.invoice(id: "payable", date: "2026-07-03T00:00:00Z", due: "8.25", extra: Self.fields()),
            Self.invoice(id: "paid-date", date: "2026-07-04T00:00:00Z", due: "9", extra: Self.fields(
                suffix: ",\"paid_date\":\"2026-09-01T00:00:00Z\"",
            )),
            Self.invoice(id: "credit", date: "2026-07-05T00:00:00Z", due: "9", type: "credit_note",
                         extra: Self.fields()),
        ]
        let selection = InvoicePaymentSelection.select(
            snapshot: .loaded(invoices, updatedAt: LiveModelsTests.now), requestedInvoiceID: nil,
            selectedSubscriptionID: nil, now: LiveModelsTests.now,
        )
        guard case let .selected(details, candidates) = selection else {
            Issue.record("Expected payable invoice")
            return
        }
        #expect(details.invoiceID == "payable")
        #expect(candidates.map(\.id) == ["payable"])
        #expect(InvoicePaymentSelection.select(
            snapshot: .loaded(invoices, updatedAt: LiveModelsTests.now), requestedInvoiceID: "sepa",
            selectedSubscriptionID: nil, now: LiveModelsTests.now,
        ) == .unavailable(.selectionChanged, candidates: candidates))
    }

    @Test func `payment validation fails closed for reference precision and conflicting metadata`() throws {
        let cases: [(Invoice, InvoicePaymentUnavailable)] = try [
            (Self.invoice(extra: ""), .missingReference),
            (Self.invoice(extra: ",\"reference_number\":\"+++123/4567/89003+++\""), .invalidReference),
            (Self.invoice(due: "1.001", extra: Self.fields()), .invalidAmount),
            (Self.invoice(amount: "1.00", due: "2.00", extra: Self.fields()), .conflictingAmount),
            (Self.invoice(amount: "0", due: "1.00", extra: Self.fields()), .conflictingAmount),
            (Self.invoice(date: "2026-10-01T00:00:00Z", extra: Self.fields()), .invalidInvoiceDate),
        ]
        for (invoice, reason) in cases {
            let selection = InvoicePaymentSelection.select(
                snapshot: .loaded([invoice], updatedAt: LiveModelsTests.now), requestedInvoiceID: invoice.id,
                selectedSubscriptionID: nil, now: LiveModelsTests.now,
            )
            guard case let .unavailable(actual, _) = selection else {
                Issue.record("Expected unavailable \(reason)")
                continue
            }
            #expect(actual == reason)
        }
    }

    @Test func `incomplete stale and future invoice lists never produce payment details`() throws {
        let invoice = try Self.invoice(extra: Self.fields())
        let old = LiveModelsTests.now.addingTimeInterval(-InvoicePaymentSelection.maximumSnapshotAge - 1)
        let future = LiveModelsTests.now.addingTimeInterval(1)
        let cases: [(InvoiceSnapshot, InvoicePaymentUnavailable)] = [
            (InvoiceSnapshot.truncated([invoice], updatedAt: LiveModelsTests.now), .incompleteInvoiceList),
            (.loaded([invoice], updatedAt: old), .staleInvoiceList),
            (.loaded([invoice], updatedAt: future), .futureInvoiceList),
        ]
        for (snapshot, reason) in cases {
            guard case let .unavailable(actual, _) = InvoicePaymentSelection.select(
                snapshot: snapshot, requestedInvoiceID: nil, selectedSubscriptionID: nil, now: LiveModelsTests.now,
            ) else {
                Issue.record("Expected unavailable \(reason)")
                continue
            }
            #expect(actual == reason)
        }
    }

    @Test func `PDF evidence requires endpoint identity reference and source dates`() {
        let api = InvoicePaymentEvidence(
            invoiceID: "inv-1", invoiceNumber: "2026-10", reference: Self.reference,
            invoiceDate: "2026-09-01", dueDate: "2026-09-15",
        )
        #expect(InvoicePaymentEvidenceMatch.compare(api: api, reviewedPDF: api) == .matches)
        let mismatch = InvoicePaymentEvidence(
            invoiceID: "inv-2", invoiceNumber: "2026-10", reference: Self.reference,
            invoiceDate: "2026-09-02", dueDate: "2026-09-15",
        )
        #expect(InvoicePaymentEvidenceMatch.compare(api: api, reviewedPDF: mismatch) == .mismatch)
    }

    @Test func `only issued and partially paid invoice statuses are payable`() throws {
        let statuses = ["accepted", "cancelled", "created", "issued", "paid", "review", "unknown",
                        "bad_dept", "partially_paid", "pending_payment"]
        for status in statuses {
            let invoice = try Self.invoice(status: status, extra: Self.fields())
            let candidates = InvoicePaymentSelection.candidates(
                in: .loaded([invoice], updatedAt: LiveModelsTests.now),
            )
            #expect(candidates.isEmpty == !["issued", "partially_paid"].contains(status))
        }
    }

    @Test func `helper rejects invalid bank and transfer fields`() async throws {
        let helper = PaymentQRHelper(
            executableURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: ".build/payment-qr/payment-qr"),
        )
        let selected = try Self.details()
        let valid = try #require(selected)
        let cases = [
            Self.changed(valid, recipient: InvoicePaymentRecipient(
                name: valid.recipient.name, iban: "BE02737026917241", bic: valid.recipient.bic,
            )),
            Self.changed(valid, reference: ""),
            Self.changed(valid, reference: "+++123/4567/89003+++"),
            Self.changed(
                valid, amount: Decimal(sign: .plus, exponent: -3, significand: 1001), amountText: "1.001",
            ),
            Self.changed(valid, amount: 0, amountText: "0.00"),
            Self.changed(valid, amount: -1, amountText: "-1.00"),
        ]
        for details in cases {
            await #expect(throws: PaymentQRHelperError.rejected) {
                try await helper.render(details, now: LiveModelsTests.now)
            }
        }
    }

    @Test func `packaged helper returns independently decodable exact EPC payload`() async throws {
        let invoice = try Self.invoice(amount: "100", due: "42.50", extra: Self.fields())
        let selection = InvoicePaymentSelection.select(
            snapshot: .loaded([invoice], updatedAt: LiveModelsTests.now), requestedInvoiceID: nil,
            selectedSubscriptionID: nil, now: LiveModelsTests.now,
        )
        guard case let .selected(details, _) = selection else {
            Issue.record("Expected selected payment")
            return
        }
        let helper = PaymentQRHelper(
            executableURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: ".build/payment-qr/payment-qr"),
        )
        let qrCode = try await helper.render(details, now: LiveModelsTests.now)
        #expect(qrCode
            .payload ==
            "BCD\n002\n1\nSCT\nKREDBEBB\nMobile Vikings NV\nBE02737026917240\nEUR42.50\n\n+++/123/4567/89002+++\n\n")
        #expect(qrCode.validatePayload())
        let image = try #require(CIImage(data: qrCode.png))
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(ciImage: image)
        try handler.perform([request])
        let decoded = try #require((request.results?.first as? VNBarcodeObservation)?.payloadStringValue)
        #expect(decoded == qrCode.payload)
    }

    private static func details() throws -> InvoicePaymentDetails? {
        let invoice = try self.invoice(amount: "100", due: "42.50", extra: self.fields())
        guard case let .selected(details, _) = InvoicePaymentSelection.select(
            snapshot: .loaded([invoice], updatedAt: LiveModelsTests.now), requestedInvoiceID: nil,
            selectedSubscriptionID: nil, now: LiveModelsTests.now,
        ) else { return nil }
        return details
    }

    private static func changed(
        _ source: InvoicePaymentDetails, recipient: InvoicePaymentRecipient? = nil,
        amount: Decimal? = nil, amountText: String? = nil, reference: String? = nil,
    ) -> InvoicePaymentDetails {
        InvoicePaymentDetails(
            invoiceID: source.invoiceID, invoiceNumber: source.invoiceNumber, invoiceDate: source.invoiceDate,
            dueDate: source.dueDate, sourceUpdatedAt: source.sourceUpdatedAt,
            recipient: recipient ?? source.recipient, amount: amount ?? source.amount,
            amountText: amountText ?? source.amountText, reference: reference ?? source.reference,
            scope: source.scope,
        )
    }

    private static func fields(expiration: String? = "2026-09-20T00:00:00Z", suffix: String = "") -> String {
        let due = expiration.map { ",\"expiration_date\":\"\($0)\"" } ?? ""
        return ",\"reference_number\":\"\(Self.reference)\"\(due)\(suffix)"
    }

    private static func invoice(
        id: String = "inv-1", number: String = "2026-10",
        date: String = "2026-09-01T10:00:00+02:00", amount: String = "24.50", due: String = "12.25",
        status: String = "partially_paid", grouped: Bool = false, type: String = "invoice", extra: String,
    ) throws -> Invoice {
        try InvoiceTests.invoice(InvoiceTests.item(
            id: id, number: number, date: date, amount: amount, due: due,
            type: type, status: status, grouped: grouped, extra: extra,
        ))
    }
}
