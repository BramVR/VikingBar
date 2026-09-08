---
summary: "Invoice scope, payment fields, and explicit private PDF downloads."
read_when:
  - Changing invoice presentation or API requests
  - Verifying invoice metadata or PDF downloads
---

# Invoices

The **Bills** tab shows the latest account billing document. A grouped invoice can cover several subscriptions. VikingBar labels its total as a grouped amount and reports the selected SIM's relationship separately. Missing subscription identifiers do not establish membership.

The account invoice list is necessary because the subscription invoice endpoint omits grouped invoices. The API orders documents by date and invoice number, newest first. Credit notes remain credit notes, with their linked invoice identified separately. An amount due describes that document, not the account's total debt.

Invoice total, unpaid amount, reduction, points applied, payment state, and date retain their separate meanings. VikingBar uses the provider's reported unpaid amount. It does not recompute debt by subtracting discounts or points again. Missing optional values remain unavailable. Zero unpaid amount does not override the reported payment state.

Invoice and points requests share an optional queue. Opening Bills during a points request retains the invoice request until the worker is free. Data refresh takes priority and resumes pending metadata afterward. An interrupted PDF action requires another click. A failed or inaccessible invoice request does not erase a successful data balance. An empty invoice response is different from unavailable invoice data. Metadata retrieval stops after five pages of 20 documents or 15 seconds. A limited result cannot prove that the account has no invoices. The menu shows the fetch time so cached details remain identifiable.

## PDF handling

Only an explicit PDF action requests the document. Metadata refresh never downloads PDFs. The worker authenticates the PDF request with an HTTP header through the same allowlisted transport as other account reads. It rejects redirects and never puts a bearer token in a URL or diagnostic.

The worker requires a PDF content type, PDF markers, and a document that CoreGraphics can parse. Responses cannot exceed 10 MiB. The authenticated transport uses a 30-second request timeout and a 60-second resource timeout. Metadata responses cannot exceed 2 MiB.

The worker creates an owner-only temporary directory named `vikingbar-invoice-XXXXXX` and writes `invoice.pdf` with mode `0600`. The directory has mode `0700`. Provider filenames and response URLs do not select a local destination. Creation is exclusive and does not follow a file symlink. Failed writes remove only the generated file and directory.

Successful documents remain in the OS temporary directory for the requested open action. VikingBar does not automatically delete an opened document; use the PDF viewer's save action to keep a permanent copy. The app opens the local document only after the user's PDF action. The invoice proof uses the production downloader without opening a PDF viewer. Cached sessions omit the temporary document path.

PDFs contain personal billing information. Keep downloaded documents and proof artifacts local. Do not attach them to issues, pull requests, or hosted CI logs.

## Verification boundary

`make check` and `swift test` exercise synthetic invoice data and isolated stores. They require no account access. `make proof-live CHECK=invoices` requires a connected account and the coordinator's credential slot. The real gate compares invoice metadata with the production menu presentation and validates the authenticated PDF through the production download path when an invoice exists. A real empty account requires an observed empty result. A failed, inaccessible, or skipped real request cannot pass.

Native menu coverage also requires the Mac UI slot. Follow the [project verification skill](../.agents/skills/verify-vikingbar/SKILL.md). Synthetic coverage does not establish native or live API success.

The endpoint schema is documented in the [official API specification](https://docs.uwa.mobilevikings.be/swagger.json). Live invoice coverage remains pending until the authorized gate completes.
