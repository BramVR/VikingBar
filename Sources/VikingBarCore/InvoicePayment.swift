import Foundation

public struct InvoicePaymentRecipient: Codable, Equatable, Sendable {
    public let name: String
    public let iban: String
    public let bic: String

    public static let mobileVikings = Self(
        name: "Mobile Vikings NV",
        iban: "BE02737026917240",
        bic: "KREDBEBB",
    )
}

public struct InvoicePaymentCandidate: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let dueDate: String?
}

public struct InvoicePaymentDetails: Codable, Equatable, Sendable {
    public let invoiceID: String
    public let invoiceNumber: String
    public let invoiceDate: String
    public let dueDate: String?
    public let sourceUpdatedAt: Date
    public let recipient: InvoicePaymentRecipient
    public let amount: Decimal
    public let amountText: String
    public let reference: String
    public let scope: String

    public var epcReference: String {
        "+++/" + self.reference.dropFirst(3)
    }
}

public enum InvoicePaymentUnavailable: String, Codable, Equatable, Sendable {
    case refreshFailed
    case incompleteInvoiceList
    case staleInvoiceList
    case futureInvoiceList
    case noPayableInvoice
    case selectionChanged
    case invalidInvoiceDate
    case conflictingAmount
    case invalidAmount
    case missingReference
    case invalidReference
    case paymentAlreadyStarted
    case qrGenerationFailed
    case reviewExpired

    public var message: String {
        switch self {
        case .refreshFailed: "Could not refresh payment details. Bills remain available."
        case .incompleteInvoiceList: "More invoices must be checked before payment details are available."
        case .staleInvoiceList: "Invoice details are too old. Load bills and try again."
        case .futureInvoiceList: "Invoice freshness could not be verified."
        case .noPayableInvoice: "No issued invoice is currently payable."
        case .selectionChanged: "The selected invoice changed. Choose an invoice and try again."
        case .invalidInvoiceDate: "The invoice date could not be verified."
        case .conflictingAmount: "The invoice amounts conflict."
        case .invalidAmount: "The unpaid amount cannot be used for a bank transfer."
        case .missingReference: "This invoice has no payment reference."
        case .invalidReference: "The Belgian structured reference is invalid."
        case .paymentAlreadyStarted: "A payment instruction already exists for this invoice."
        case .qrGenerationFailed: "Could not create the bank transfer QR."
        case .reviewExpired: "Payment details expired. Review them again."
        }
    }
}

public enum InvoicePaymentSelection: Codable, Equatable, Sendable {
    case selected(InvoicePaymentDetails, candidates: [InvoicePaymentCandidate])
    case unavailable(InvoicePaymentUnavailable, candidates: [InvoicePaymentCandidate])

    public static let maximumSnapshotAge: TimeInterval = 300
    private static let maximumAmount = Decimal(string: "999999999.99") ?? 0

    private enum SnapshotValidation {
        case valid([Invoice], Date)
        case invalid(InvoicePaymentUnavailable)
    }

    public static func candidates(in snapshot: InvoiceSnapshot?) -> [InvoicePaymentCandidate] {
        guard case let .loaded(invoices, _) = snapshot else { return [] }
        return invoices.filter {
            $0.kind == .invoice && ($0.status == .issued || $0.status == .partiallyPaid)
                && $0.amountDue > 0 && $0.paidDate == nil && $0.sepaGenerationDate == nil
        }.sorted(by: self.precedes).map {
            InvoicePaymentCandidate(id: $0.id, title: "Invoice \($0.number)", dueDate: $0.expirationDate)
        }
    }

    public static func select(
        snapshot: InvoiceSnapshot,
        requestedInvoiceID: String?,
        selectedSubscriptionID: String?,
        now: Date,
    ) -> Self {
        let invoices: [Invoice]
        let updatedAt: Date
        switch self.validate(snapshot: snapshot, now: now) {
        case let .valid(values, date):
            invoices = values
            updatedAt = date
        case let .invalid(reason):
            return .unavailable(reason, candidates: [])
        }
        let candidates = self.candidates(in: .loaded(invoices, updatedAt: updatedAt))
        let payable = candidates.compactMap { candidate in invoices.first(where: { $0.id == candidate.id }) }
        guard !payable.isEmpty else { return .unavailable(.noPayableInvoice, candidates: []) }
        let invoice: Invoice
        if let requestedInvoiceID {
            guard let requested = payable.first(where: { $0.id == requestedInvoiceID }) else {
                return .unavailable(.selectionChanged, candidates: candidates)
            }
            invoice = requested
        } else {
            invoice = payable[0]
        }
        return self.details(
            invoice: invoice, candidates: candidates, selectedSubscriptionID: selectedSubscriptionID,
            updatedAt: updatedAt, now: now,
        )
    }

    private static func validate(snapshot: InvoiceSnapshot, now: Date) -> SnapshotValidation {
        let invoices: [Invoice]
        let updatedAt: Date
        switch snapshot {
        case .unavailable: return .invalid(.refreshFailed)
        case let .empty(date):
            guard date <= now else { return .invalid(.futureInvoiceList) }
            guard now.timeIntervalSince(date) <= self.maximumSnapshotAge else { return .invalid(.staleInvoiceList) }
            return .invalid(.noPayableInvoice)
        case .truncated: return .invalid(.incompleteInvoiceList)
        case let .loaded(values, date):
            invoices = values
            updatedAt = date
        }
        guard updatedAt <= now else { return .invalid(.futureInvoiceList) }
        guard now.timeIntervalSince(updatedAt) <= self.maximumSnapshotAge else { return .invalid(.staleInvoiceList) }
        return .valid(invoices, updatedAt)
    }

    private static func details(
        invoice: Invoice, candidates: [InvoicePaymentCandidate], selectedSubscriptionID: String?,
        updatedAt: Date, now: Date,
    ) -> Self {
        guard let invoiceDate = InvoiceDTO.parsedDate(invoice.date), invoiceDate <= now else {
            return .unavailable(.invalidInvoiceDate, candidates: candidates)
        }
        if let due = invoice.expirationDate, InvoiceDTO.parsedDate(due) == nil {
            return .unavailable(.invalidInvoiceDate, candidates: candidates)
        }
        guard invoice.amount > 0, invoice.amountDue <= invoice.amount else {
            return .unavailable(.conflictingAmount, candidates: candidates)
        }
        guard let amountText = self.amountText(invoice.amountDue) else {
            return .unavailable(.invalidAmount, candidates: candidates)
        }
        guard let reference = invoice.referenceNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty
        else { return .unavailable(.missingReference, candidates: candidates) }
        guard let reference = self.belgianStructuredReference(reference) else {
            return .unavailable(.invalidReference, candidates: candidates)
        }
        let scope = InvoicePresentation.scope(invoice, selectedSubscriptionID: selectedSubscriptionID)
        return .selected(InvoicePaymentDetails(
            invoiceID: invoice.id,
            invoiceNumber: invoice.number,
            invoiceDate: invoice.date,
            dueDate: invoice.expirationDate,
            sourceUpdatedAt: updatedAt,
            recipient: .mobileVikings,
            amount: invoice.amountDue,
            amountText: amountText,
            reference: reference,
            scope: scope,
        ), candidates: candidates)
    }

    private static func precedes(_ left: Invoice, _ right: Invoice) -> Bool {
        let leftDue = left.expirationDate.flatMap(InvoiceDTO.parsedDate)
        let rightDue = right.expirationDate.flatMap(InvoiceDTO.parsedDate)
        if leftDue != rightDue {
            if leftDue == nil {
                return false
            }
            if rightDue == nil {
                return true
            }
            return leftDue! < rightDue!
        }
        let leftDate = InvoiceDTO.parsedDate(left.date) ?? .distantFuture
        let rightDate = InvoiceDTO.parsedDate(right.date) ?? .distantFuture
        if leftDate != rightDate {
            return leftDate < rightDate
        }
        let numberOrder = left.number.compare(right.number, options: .numeric)
        if numberOrder != .orderedSame {
            return numberOrder == .orderedAscending
        }
        return left.id < right.id
    }

    private static func amountText(_ amount: Decimal) -> String? {
        guard !amount.isNaN, amount > 0, amount <= self.maximumAmount else { return nil }
        var source = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 2, .plain)
        guard rounded == amount else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount))
    }

    static func belgianStructuredReference(_ source: String) -> String? {
        if source.utf8.count == 12, source.utf8.allSatisfy({ (48 ... 57).contains($0) }) {
            return self.belgianStructuredReference(
                "+++\(source.prefix(3))/\(source.dropFirst(3).prefix(4))/\(source.suffix(5))+++",
            )
        }
        guard let expression = try? NSRegularExpression(pattern: #"^\+\+\+/?(\d{3})/(\d{4})/(\d{5})\+\+\+$"#)
        else { return nil }
        let range = NSRange(source.startIndex ..< source.endIndex, in: source)
        guard let match = expression.firstMatch(in: source, range: range), match.range == range,
              let first = Range(match.range(at: 1), in: source),
              let second = Range(match.range(at: 2), in: source),
              let third = Range(match.range(at: 3), in: source)
        else { return nil }
        let digits = String(source[first]) + String(source[second]) + String(source[third])
        guard let base = Int(digits.prefix(10)), let check = Int(digits.suffix(2)) else { return nil }
        let remainder = base % 97 == 0 ? 97 : base % 97
        guard remainder == check else { return nil }
        return "+++\(digits.prefix(3))/\(digits.dropFirst(3).prefix(4))/\(digits.suffix(5))+++"
    }
}

public enum InvoicePaymentFixture {
    public static func snapshot(at now: Date) -> InvoiceSnapshot {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let invoice = Invoice(
            id: "fixture-payment-invoice", number: "FIXTURE-2026-001",
            date: formatter.string(from: now.addingTimeInterval(-86400)),
            amount: Decimal(string: "42.50")!, amountDue: Decimal(string: "42.50")!,
            reduction: nil, loyaltyPointsAmount: nil, status: .issued, kind: .invoice,
            linkedInvoiceID: nil,
            scope: .grouped(knownSubscriptions: [], membershipComplete: false),
            referenceNumber: "+++123/4567/89002+++",
            expirationDate: formatter.string(from: now.addingTimeInterval(1_209_600)),
            sepaGenerationDate: nil, paidDate: nil,
        )
        let paidInvoice = Invoice(
            id: "fixture-paid-invoice", number: "FIXTURE-2026-002", date: formatter.string(from: now),
            amount: Decimal(string: "24.50")!, amountDue: 0,
            reduction: nil, loyaltyPointsAmount: nil, status: .paid, kind: .invoice, linkedInvoiceID: nil,
            scope: .customer, referenceNumber: nil, expirationDate: nil,
            sepaGenerationDate: nil, paidDate: formatter.string(from: now),
        )
        return .loaded([paidInvoice, invoice], updatedAt: now)
    }
}

public struct InvoicePaymentQRCode: Codable, Equatable, Sendable {
    public let details: InvoicePaymentDetails
    public let payload: String
    public let png: Data
    public let generatedAt: Date
    public let expiresAt: Date

    public static let lifetime: TimeInterval = 300

    public init(
        details: InvoicePaymentDetails,
        payload: String,
        png: Data,
        generatedAt: Date,
        expiresAt: Date,
    ) {
        self.details = details
        self.payload = payload
        self.png = png
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
    }

    public func validatePayload() -> Bool {
        let fields = self.payload.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 12, fields[0] == "BCD", fields[1] == "002", fields[2] == "1",
              fields[3] == "SCT", fields[4] == self.details.recipient.bic,
              fields[5] == self.details.recipient.name, fields[6] == self.details.recipient.iban,
              fields[7] == "EUR\(self.details.amountText)", fields[8].isEmpty,
              fields[9] == self.details.epcReference, fields[10].isEmpty, fields[11].isEmpty
        else { return false }
        return InvoicePaymentSelection.belgianStructuredReference(fields[9]) == self.details.reference
    }
}

public enum PaymentReview: Codable, Equatable, Sendable {
    case idle
    case checking(invoiceID: String?)
    case ready(InvoicePaymentQRCode, candidates: [InvoicePaymentCandidate])
    case unavailable(InvoicePaymentUnavailable, candidates: [InvoicePaymentCandidate])
}

public struct InvoicePaymentEvidence: Codable, Equatable, Sendable {
    public let invoiceID: String
    public let invoiceNumber: String
    public let reference: String
    public let invoiceDate: String
    public let dueDate: String?

    public init(invoiceID: String, invoiceNumber: String, reference: String, invoiceDate: String, dueDate: String?) {
        self.invoiceID = invoiceID
        self.invoiceNumber = invoiceNumber
        self.reference = reference
        self.invoiceDate = invoiceDate
        self.dueDate = dueDate
    }

    public init?(invoice: Invoice) {
        guard let reference = invoice.referenceNumber else { return nil }
        self.init(
            invoiceID: invoice.id,
            invoiceNumber: invoice.number,
            reference: reference,
            invoiceDate: invoice.date,
            dueDate: invoice.expirationDate,
        )
    }
}

public enum InvoicePaymentEvidenceMatch: Equatable, Sendable {
    case matches
    case mismatch

    public static func compare(api: InvoicePaymentEvidence, reviewedPDF: InvoicePaymentEvidence) -> Self {
        api == reviewedPDF ? .matches : .mismatch
    }
}

public struct InvoicePaymentEvidenceReceipt: Codable, Equatable, Sendable {
    public let schemaVersion = 1
    public let check = "payment-evidence"
    public let passed = true
    public let endpointMatches = true
    public let pdfDownloaded = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case endpointMatches = "endpoint_matches"
        case pdfDownloaded = "pdf_downloaded"
        case check, passed
    }
}
