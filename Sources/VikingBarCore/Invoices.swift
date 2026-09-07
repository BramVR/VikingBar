import Foundation

public enum InvoiceSnapshot: Codable, Equatable, Sendable {
    case unavailable
    case empty(updatedAt: Date)
    case loaded([Invoice], updatedAt: Date)
    case truncated([Invoice], updatedAt: Date)

    public var updatedAt: Date? {
        switch self {
        case let .empty(date), let .loaded(_, date), let .truncated(_, date): date
        case .unavailable: nil
        }
    }

    public var invoices: [Invoice] {
        switch self {
        case let .loaded(values, _), let .truncated(values, _): values
        case .unavailable, .empty: []
        }
    }
}

public struct Invoice: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case invoice; case creditNote = "credit_note" }
    public enum Status: String, Codable, Sendable {
        case accepted, cancelled, created, issued, paid, review, unknown
        case badDebt = "bad_dept"
        case partiallyPaid = "partially_paid"
        case pendingPayment = "pending_payment"

        public var label: String {
            self == .badDebt ? "bad debt" : self.rawValue.replacingOccurrences(of: "_", with: " ")
        }
    }

    public enum Scope: Codable, Equatable, Sendable {
        case subscription(String)
        case customer
        case grouped(knownSubscriptions: Set<String>, membershipComplete: Bool)
    }

    public enum Membership: String, Codable, Sendable { case included, excluded, unknown }

    public let id: String
    public let number: String
    public let date: String
    public let amount: Decimal
    public let amountDue: Decimal
    public let reduction: Decimal?
    public let loyaltyPointsAmount: Decimal?
    public let status: Status
    public let kind: Kind
    public let linkedInvoiceID: String?
    public let scope: Scope

    public func membership(of subscriptionID: String?) -> Membership {
        guard let subscriptionID else { return .unknown }
        switch self.scope {
        case let .subscription(id): return id == subscriptionID ? .included : .excluded
        case .customer: return .unknown
        case let .grouped(ids, _):
            return ids.contains(subscriptionID) ? .included : .unknown
        }
    }
}

struct InvoicePage: Decodable {
    let page: Int
    let perPage: Int
    let totalPages: Int
    let totalItems: Int
    let results: [InvoiceDTO]

    enum CodingKeys: String, CodingKey {
        case page, results
        case perPage = "per_page"
        case totalPages = "total_pages"
        case totalItems = "total_items"
    }
}

struct InvoiceDTO: Decodable {
    let id: String
    let number: String
    let date: String
    let grouped: Bool
    let subscriptionID: String?
    let amount: Decimal
    let amountDue: Decimal
    let reduction: Decimal?
    let loyaltyPointsAmount: Decimal?
    let status: Invoice.Status
    let type: Invoice.Kind
    let linkedInvoiceID: String?
    let bundles: [InvoiceLineDTO]
    let outOfBundleCosts: [InvoiceLineDTO]

    enum CodingKeys: String, CodingKey {
        case id, number, date, grouped, amount, reduction, status, type, bundles
        case subscriptionID = "subscription_id"
        case amountDue = "amount_due"
        case loyaltyPointsAmount = "loyalty_points_amount"
        case linkedInvoiceID = "linked_invoice_id"
        case outOfBundleCosts = "out_of_bundle_costs"
    }

    static func parsedDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    func invoice() throws -> Invoice {
        _ = try ProofEndpoint.invoicePDF(id: self.id).request()
        guard Self.parsedDate(self.date) != nil, !self.number.isEmpty,
              [self.amount, self.amountDue, self.reduction, self.loyaltyPointsAmount]
              .compactMap(\.self).allSatisfy({ !$0.isNaN }) else { throw LiveFailure.malformedResponse }
        let scope: Invoice.Scope
        if self.grouped {
            let lines = self.bundles + self.outOfBundleCosts
            let ids = Set(lines.compactMap(\.subscriptionID).filter { !$0.isEmpty })
            scope = .grouped(knownSubscriptions: ids, membershipComplete: false)
        } else if let id = self.subscriptionID, !id.isEmpty {
            scope = .subscription(id)
        } else {
            scope = .customer
        }
        return Invoice(
            id: self.id, number: self.number, date: self.date, amount: self.amount, amountDue: self.amountDue,
            reduction: self.reduction, loyaltyPointsAmount: self.loyaltyPointsAmount,
            status: self.status, kind: self.type, linkedInvoiceID: self.linkedInvoiceID, scope: scope,
        )
    }
}

public struct InvoicePresentation: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let date: String
        public let status: String
        public let total: String
        public let amountDue: String
        public let reduction: String
        public let points: String
        public let scope: String
        public let linkedInvoice: String?
    }

    public let message: String
    public let rows: [Row]

    public init(snapshot: InvoiceSnapshot?, selectedSubscriptionID: String?, timeZone: TimeZone = .current) {
        let snapshot = snapshot ?? .unavailable
        self.message = switch snapshot {
        case .unavailable: "Bills unavailable. Load bills to try again."
        case .empty: "No invoices on this account."
        case .loaded: "Account invoices"
        case .truncated: "Recent account invoices. More invoices are available in My Viking."
        }
        self.rows = snapshot.invoices.map { invoice in
            let scope: String = switch invoice.scope {
            case .subscription:
                invoice.membership(of: selectedSubscriptionID) == .included ? "Selected SIM" : "Other SIM"
            case .customer: "Customer invoice. SIM membership unknown."
            case .grouped:
                switch invoice.membership(of: selectedSubscriptionID) {
                case .included: "Grouped invoice. Includes selected SIM."
                case .excluded: "Grouped invoice. Other SIMs."
                case .unknown: "Grouped invoice. Selected SIM membership unknown."
                }
            }
            return Row(
                id: invoice.id, title: "\(invoice.kind == .creditNote ? "Credit note" : "Invoice") \(invoice.number)",
                date: Self.date(invoice.date, timeZone: timeZone), status: invoice.status.label,
                total: Self.money(invoice.amount), amountDue: Self.money(invoice.amountDue),
                reduction: Self.money(invoice.reduction),
                points: invoice.loyaltyPointsAmount.map { NSDecimalNumber(decimal: $0).stringValue } ?? "Unavailable",
                scope: scope, linkedInvoice: invoice.linkedInvoiceID,
            )
        }
    }

    public static func date(_ text: String, timeZone: TimeZone = .current) -> String {
        guard let date = InvoiceDTO.parsedDate(text) else { return "Unavailable" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_IE")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    public static func money(_ amount: Decimal?) -> String {
        guard let amount else { return "Unavailable" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_IE")
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "Unavailable"
    }
}

struct InvoiceLineDTO: Decodable {
    let subscriptionID: String?
    enum CodingKeys: String, CodingKey { case subscriptionID = "subscription_id" }
}
