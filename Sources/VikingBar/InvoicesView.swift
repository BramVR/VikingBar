import SwiftUI

struct InvoicesView: View {
    @Bindable var session: AppSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(self.session.invoiceDetails.message)
                    .font(.headline)
                    .accessibilityIdentifier("vikingbar.invoices.message")
                if let updated = self.session.liveState.invoices?.updatedAt {
                    Text("Last fetched \(updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(self.session.isLoadingInvoices ? "Loading bills…" : "Load bills") {
                    self.session.loadInvoices()
                }
                .disabled(!self.session.canLoadInvoices || self.session.isLoadingInvoices)
                .accessibilityIdentifier("vikingbar.invoices.load")
                if let error = self.session.invoiceError {
                    Text(error).foregroundStyle(.red)
                }
                ForEach(Array(self.session.invoiceDetails.rows.prefix(1))) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.title).font(.headline)
                        Text("\(row.date) · \(row.status)")
                        Text(row.scope).font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Total", value: row.total)
                        LabeledContent("Amount due", value: row.amountDue)
                        LabeledContent("Reduction", value: row.reduction)
                        LabeledContent("Viking Points used", value: row.points)
                        if let linked = row.linkedInvoice {
                            Text("Linked invoice: \(linked)").font(.caption)
                        }
                        Button("Open PDF") { self.session.openInvoice(row.id) }
                            .disabled(!self.session.canLoadInvoices || self.session.isLoadingInvoices)
                            .accessibilityIdentifier("vikingbar.invoice.pdf")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("vikingbar.invoice.latest")
                    Divider()
                }
            }
            .padding(20)
            .task(id: self.session.canLoadInvoices) {
                self.session.loadInvoices()
            }
        }
    }
}
