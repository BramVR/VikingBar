import AppKit
import SwiftUI
import VikingBarCore

struct InvoicesView: View {
    private enum CopiedField: String { case recipient, iban, bic, reference }

    @Bindable var session: AppSession
    @State private var paymentExpanded = false
    @State private var selectedInvoiceID: String?
    @State private var copiedField: CopiedField?
    @State private var copyRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bills").font(.headline)
                    if let updated = self.session.liveState.invoices?.updatedAt {
                        Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                            .help(updated.formatted(date: .abbreviated, time: .shortened))
                            .accessibilityIdentifier("vikingbar.invoices.freshness")
                    }
                }
                Spacer()
                Button { self.session.loadInvoices() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                }
                .disabled(!self.session.canLoadInvoices || self.session.isLoadingInvoices)
                .accessibilityLabel(self.session.isLoadingInvoices ? "Refreshing bills" : "Refresh bills")
                .help("Refresh bills")
                .accessibilityIdentifier("vikingbar.invoices.load")
                .buttonStyle(.menuAction)
                .fixedSize()
            }
            if self.session.invoiceDetails.message != "Account invoices" {
                Text(self.session.invoiceDetails.message).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vikingbar.invoices.message")
            }
            if let error = self.session.invoiceError {
                Text(error).foregroundStyle(.red)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let row = self.selectedRow {
                        self.invoice(row)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 500)
        }
        .task(id: self.session.canLoadInvoices) {
            self.session.loadInvoices()
        }
        .onChange(of: self.session.invoiceDetails.rows.map(\.id)) { _, identifiers in
            guard !identifiers.contains(self.selectedInvoiceID ?? "") else { return }
            self.select(self.session.paymentCandidates.first?.id ?? identifiers.first)
        }
        .onDisappear { self.collapsePayment() }
    }

    @ViewBuilder private var invoiceSelection: some View {
        let rows = self.session.invoiceDetails.rows
        if rows.count > 1 {
            Picker("Billing document", selection: Binding(
                get: { self.selectedRow?.id ?? rows[0].id },
                set: { self.select($0) },
            )) {
                ForEach(rows) { row in
                    Text(row.title).tag(row.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .menuIndicator(.visible)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("vikingbar.invoices.picker")
        } else if let row = rows.first {
            Text(row.title).font(.headline)
        }
    }

    private var selectedRow: InvoicePresentation.Row? {
        let rows = self.session.invoiceDetails.rows
        guard let id = self.selectedInvoiceID ?? self.session.paymentCandidates.first?.id ?? rows.first?.id else {
            return nil
        }
        return rows.first(where: { $0.id == id }) ?? rows.first
    }

    private func invoice(_ row: InvoicePresentation.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                self.invoiceSelection
                Spacer(minLength: 4)
                Text(row.status.capitalized).font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            Text("\(row.date) · \(row.scope)").font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    self.invoiceValue("Total", value: row.total)
                    self.invoiceValue("Amount due", value: row.amountDue, prominent: true)
                }
                GridRow {
                    self.invoiceValue("Reduction", value: row.reduction)
                    self.invoiceValue("Viking Points used", value: row.points)
                }
            }
            .padding(.vertical, 4)
            .accessibilityIdentifier("vikingbar.invoice.summary")
            if let linked = row.linkedInvoice {
                Text("Linked invoice: \(linked)").font(.caption)
            }
            Button("Open PDF") { self.session.openInvoice(row.id) }
                .disabled(!self.session.canLoadInvoices || self.session.isLoadingInvoices
                    || self.session.paymentFixtureEnabled)
                .accessibilityIdentifier("vikingbar.invoice.pdf")
                .buttonStyle(.menuAction)
            Divider().padding(.vertical, 2)
            self.paymentSection(row.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vikingbar.invoice.latest")
    }

    private func invoiceValue(_ label: String, value: String, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(prominent ? .title2.bold() : .body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension InvoicesView {
    private func paymentSection(_ invoiceID: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if self.paymentExpanded {
                    self.collapsePayment()
                } else {
                    self.selectedInvoiceID = invoiceID
                    self.paymentExpanded = true
                    self.session.reviewPayment(invoiceID)
                }
            } label: {
                HStack {
                    Label("Bank transfer QR", systemImage: "qrcode")
                    Spacer()
                    Image(systemName: self.paymentExpanded ? "chevron.up" : "chevron.down")
                }
            }
            .accessibilityIdentifier("vikingbar.payment.toggle")
            .accessibilityLabel(self.paymentExpanded ? "Collapse bank transfer QR" : "Review bank transfer QR")
            .buttonStyle(.menuAction)
            if self.paymentExpanded {
                self.paymentReview
            }
        }
    }

    @ViewBuilder private var paymentReview: some View {
        switch self.session.paymentReview {
        case .idle:
            Text("Payment details changed. Collapse and review the invoice again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("vikingbar.payment.unavailable")
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking current invoice details…")
            }
            .accessibilityIdentifier("vikingbar.payment.checking")
        case let .unavailable(reason, _):
            Text(reason.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("vikingbar.payment.unavailable")
        case let .ready(qrCode, _):
            self.readyPayment(qrCode)
        }
    }

    private func readyPayment(_ qrCode: InvoicePaymentQRCode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 16) {
                if let image = NSImage(data: qrCode.png) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 112, height: 112)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Bank transfer QR for \(qrCode.details.invoiceNumber)")
                        .accessibilityIdentifier("vikingbar.payment.qr")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(InvoicePresentation.money(qrCode.details.amount)).font(.title.bold())
                    Text("Verified \(qrCode.details.sourceUpdatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                        .help(qrCode.details.sourceUpdatedAt.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityIdentifier("vikingbar.payment.freshness")
                    Text("Scan with your banking app. Review the details before authorizing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            self.copyRow("Recipient", value: qrCode.details.recipient.name, field: .recipient)
            self.copyRow(
                "IBAN", value: Self.spacedIBAN(qrCode.details.recipient.iban),
                copyValue: qrCode.details.recipient.iban, field: .iban,
            )
            self.copyRow("BIC", value: qrCode.details.recipient.bic, field: .bic)
            self.copyRow("Reference", value: qrCode.details.reference, field: .reference)
            if self.session.paymentFixtureEnabled, let copied = self.session.fixtureClipboardValue {
                Text("Fixture clipboard: \(copied)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("vikingbar.payment.fixtureClipboard")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("vikingbar.payment.ready")
    }

    private func copyRow(
        _ label: String,
        value: String,
        copyValue: String? = nil,
        field: CopiedField,
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button {
                self.copy(copyValue ?? value, field: field)
            } label: {
                Label(
                    self.copiedField == field ? "Copied" : "Copy",
                    systemImage: self.copiedField == field ? "checkmark" : "doc.on.doc",
                )
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .foregroundStyle(self.copiedField == field ? Color.cyan : Color.primary)
            }
            .buttonStyle(.plain)
            .help(self.copiedField == field ? "Copied" : "Copy \(label)")
            .accessibilityLabel("Copy \(label)")
            .accessibilityValue(self.copiedField == field ? "Copied" : value)
            .accessibilityIdentifier("vikingbar.payment.copy.\(field.rawValue)")
        }
    }

    private func select(_ id: String?) {
        guard self.selectedInvoiceID != id else { return }
        self.selectedInvoiceID = id
        self.collapsePayment()
    }

    private func collapsePayment() {
        self.paymentExpanded = false
        self.copiedField = nil
        self.session.clearPaymentReview()
    }

    private func copy(_ value: String, field: CopiedField) {
        self.session.copyPaymentField(value)
        self.copyRevision += 1
        let revision = self.copyRevision
        self.copiedField = field
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard revision == self.copyRevision else { return }
            self.copiedField = nil
        }
    }

    private static func spacedIBAN(_ value: String) -> String {
        stride(from: 0, to: value.count, by: 4).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let length = min(4, value.distance(from: start, to: value.endIndex))
            let end = value.index(start, offsetBy: length)
            return String(value[start ..< end])
        }.joined(separator: " ")
    }
}
