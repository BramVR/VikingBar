---
summary: "Invoice scope, payment fields, and explicit private PDF downloads."
read_when:
  - Changing invoice presentation or API requests
  - Verifying invoice metadata or PDF downloads
---

# Invoices

The **Bills** action opens the latest account billing document. A grouped invoice can cover several subscriptions. VikingBar labels its total as a grouped amount and reports the selected SIM's relationship separately. Missing subscription identifiers do not establish membership.

Use **Back** to return to the selected balance. Bills and Points share the compact popover navigation; Settings remains in the footer.

The account invoice list is necessary because the subscription invoice endpoint omits grouped invoices. The API orders documents by date and invoice number, newest first. Credit notes remain credit notes, with their linked invoice identified separately. An amount due describes that document, not the account's total debt.

Invoice total, unpaid amount, reduction, points applied, payment state, and date retain their separate meanings. VikingBar uses the provider's reported unpaid amount. It does not recompute debt by subtracting discounts or points again. Missing optional values remain unavailable. Zero unpaid amount does not override the reported payment state.

For issued and partially paid invoices without an existing paid date or SEPA instruction, **Review bank transfer QR** performs a fresh complete metadata request and reselects the exact invoice. It uses the positive, exact two-decimal unpaid amount and a checksum-valid Belgian structured reference. Plain 12-digit provider references are validated and formatted with slashes and plus signs without changing their digits. The recipient is fixed to Mobile Vikings NV, IBAN `BE02737026917240`, BIC `KREDBEBB`. A missing or malformed reference, conflicting total, future invoice date, stale or incomplete list, changed selection, or existing payment instruction fails closed. No invoice number fallback is used.

The initial choice is the next payable invoice: earliest due date, then invoice date, numeric invoice number, and endpoint ID. Invoices without a due date sort after dated invoices. The billing-document picker preserves access to every fetched invoice and credit note, including newer paid documents. Changing it clears any existing QR; eligibility is checked separately.

The QR is generated locally by the bundled `payment-qr` helper from pinned `goinvoiceqr` source. It makes no network request and receives bounded private JSON on stdin. VikingBar independently checks the returned canonical fields and EPC payload before showing the image. The review expires after five minutes and is cleared immediately on collapse, invoice choice, refresh, connection change, failure, or cancellation. The compact QR beside the amount and invoice details keeps the recipient, IBAN, BIC, and reference visible together. Icon-only copy controls expose each value individually, with accessible labels and checkmark feedback; IBAN copying removes spaces. The compact invoice summary stays visible during refresh and payment review, including total, amount due, reduction, applied points, date, status, and scope. The refresh icon reloads metadata; the QR expands below the summary. The app does not authorize or submit a payment; the banking app remains responsible for review and authorization.

The helper validates the reference with upstream code, then supplies its Belgian QR serialization (`+++/123/4567/89002+++`) to the upstream EPC builder and QR renderer. This adds the slash required by the [Febelfin implementation guideline](https://febelfin.be/media/pages/publicaties/2023/febelfin-standaarden-voor-online-bankieren/93f44d7850-1744012292/febelfin-ig-qroninvoice.pdf), effective February 2026. The displayed/copied reference retains the upstream validated conventional form (`+++123/4567/89002+++`); its digits and checksum are identical. A real banking-app scan remains required.

Invoice and points requests share an optional queue. Opening Bills during a points request retains the invoice request until the worker is free. Data refresh takes priority and resumes pending metadata afterward. An interrupted PDF action requires another click. A failed or inaccessible invoice request does not erase a successful data balance. An empty invoice response is different from unavailable invoice data. Metadata retrieval stops after five pages of 20 documents or 15 seconds. A limited result cannot prove that the account has no invoices. The menu shows the fetch time so cached details remain identifiable.

## PDF handling

Only an explicit PDF action requests the document. Metadata refresh never downloads PDFs. The worker authenticates the PDF request with an HTTP header through the same allowlisted transport as other account reads. It rejects redirects and never puts a bearer token in a URL or diagnostic.

The PDF endpoint rejects `Accept: application/pdf`, so its request uses `Accept: */*`. The worker still requires a PDF content type, PDF markers, and a document that CoreGraphics can parse. Responses cannot exceed 10 MiB. The authenticated transport uses a 30-second request timeout and a 60-second resource timeout. Metadata responses cannot exceed 2 MiB.

The worker creates an owner-only temporary directory named `vikingbar-invoice-XXXXXX` and writes `invoice.pdf` with mode `0600`. The directory has mode `0700`. Provider filenames and response URLs do not select a local destination. Creation is exclusive and does not follow a file symlink. Failed writes remove only the generated file and directory.

Successful documents remain in the OS temporary directory for the requested open action. VikingBar does not automatically delete an opened document; use the PDF viewer's save action to keep a permanent copy. The app opens the local document only after the user's PDF action. The invoice proof uses the production downloader without opening a PDF viewer. Cached sessions omit the temporary document path.

PDFs contain personal billing information. Keep downloaded documents and proof artifacts local. Do not attach them to issues, pull requests, or hosted CI logs.

## Verification boundary

`make check` and `swift test` exercise synthetic invoice data and isolated stores. They require no account access. `make proof-live CHECK=invoices` requires a connected account and the coordinator's credential slot. The real gate compares invoice metadata with the production menu presentation and validates the authenticated PDF through the production download path when an invoice exists. A real empty account requires an observed empty result. A failed, inaccessible, or skipped real request cannot pass.

Native menu coverage also requires the Mac UI slot. Follow the [project verification skill](../.agents/skills/verify-vikingbar/SKILL.md). Synthetic coverage does not establish native or live API success.

`make smoke-payment-fixture` runs the opt-in synthetic fixture, uses the actual bundled helper, decodes the QR from the native screenshot, exercises collapse and reopen, verifies isolated in-memory copy values, and covers light and dark appearance. It never reads an account or the system clipboard.

For a reviewed real PDF, create a private mode-0600 JSON witness outside source control with exactly `invoiceID`, `invoiceNumber`, `reference`, `invoiceDate`, and nullable `dueDate`, preserving the endpoint strings and the PDF's printed values. Then, under the normal stored-session authorization, run:

```sh
VIKINGBAR_PAYMENT_EVIDENCE=/private/path/reviewed-invoice.json make proof-live CHECK=payment-evidence
```

The command refreshes the real account metadata, matches the exact endpoint invoice ID and all four reviewed values, and explicitly downloads that invoice through the production PDF path. Its receipt contains only pass flags. The operator's PDF review is the trust boundary; VikingBar does not extract or promote suggestions from PDF text. Bank-app review-screen scanning and execution on an actual macOS 14 host remain separate manual evidence and are not established by fixture or build tests.

The endpoint schema is documented in the [official API specification](https://docs.uwa.mobilevikings.be/swagger.json). The [invoice feature map](../.agents/skills/verify-vikingbar/features/invoices.md) records completed live coverage and its limits.
