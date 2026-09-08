# Latest bill and PDF

## Sub-features

- Account-level invoice listing, including grouped bills and selected-SIM membership.
- Latest billing document with separate total, amount due, reduction, applied points, date, payment status, and credit-note linkage.
- Empty, unavailable, and bounded-result states that preserve the balance.
- Explicit authenticated PDF download into a private local file.
- Independent API comparison through `make proof-live CHECK=invoices`.

## How to get to it (user POV)

Connect the live account, open the helmet, and choose **Bills**. Inspect the latest billing document and its account or grouped scope. Use **Load bills** to retry or refresh. **Open PDF** requests and opens that document. The fixture-only launch has no Bills action and cannot exercise live invoice behavior.

## Driving it with the native helper and CLI

Run `make check` with the configured formatter, then `make check-proof`. These use synthetic data and isolated stores. Hold the credential slot before running `make proof-live CHECK=invoices`. The gate uses the stored account session and can access Keychain. It compares real invoice metadata with `InvoicePresentation`. If an invoice exists, it validates a PDF through the production downloader without opening a viewer. Require exit 0 and a validated redacted receipt. An account with no invoices must return an observed empty result. Missing authorization, failed requests, and skips cannot pass.

Native coverage requires the Mac UI slot as well. Follow the [verification skill](../SKILL.md) to build, record, and inspect a task-owned live app. Run doctor before driving. Press `vikingbar.bills`, inspect `vikingbar.invoices.message`, then press `vikingbar.invoices.load`. Require a completed response and inspect `vikingbar.invoice.latest` when present. Compare every displayed billing value and its scope with the production presentation. Press `vikingbar.back`, then `vikingbar.points`, and confirm that customer points remain available after invoice loading. Press `vikingbar.back`, press Refresh, and require a newer usable balance and completed points refresh. If bill loading was interrupted, require its metadata request to resume. Verify that a cancelled PDF action does not open later. Delayed-request ordering remains a separate synthetic regression; fast live responses cannot prove that case.

Only with explicit permission to open the personal PDF, press `vikingbar.invoice.pdf`. Verify the requested local PDF opens and that the file has private permissions. Otherwise record native PDF opening as unproved; the authorized CLI gate can still validate the download path without displaying its contents. Do not infer native button success from a CLI receipt.

Preserve the source SHA, binary hash, command, exit code, redacted receipt, and private native captures. Keep invoice values, identifiers, downloaded PDFs, and raw account responses out of public artifacts. Use the skill's task-owned Quit and cleanup procedure. Evidence must survive cleanup.

## Gotchas

- Grouped totals are account charges. Missing contributor IDs cannot prove that the selected SIM is excluded.
- Points applied are a numeric points value. They are distinct from the monetary reduction and unpaid amount.
- A credit note does not prove payment. Amount due belongs to the displayed document, not aggregate account debt.
- The API's subscription invoice list omits grouped invoices. Account listing is mandatory.
- A page cap cannot establish an empty account. Do not fabricate an invoice for empty-account proof.
- Metadata refresh must never fetch a PDF. Download errors must leave the balance usable.
- The authorized invoice gate passed on `ccf7c5319a36fb08f44a0098d125bddd9baa5bfc`, including metadata, presentation, and production PDF validation. After a documentation-only merge, the CLI and app executable hashes remained identical. Combined native Bills and Points coverage passed with the clean `a2b87f3b22170b5c90ac4a6528d8d61d2ae3f55d` bundle: displayed bill fields and scope, newer metadata after Load bills, Points API/native comparison, newer usage and both points timestamps after Refresh, transaction expansion/collapse, settled bill controls, and native Quit with owned-process cleanup. Captures were inspected and retained privately.
- Native PDF opening was not authorized or exercised. Live empty-account and delayed-preemption cases were not observed; their synthetic coverage does not establish live proof.

The compact Bills destination requires fresh native proof after integration. Previous tab-layout captures do not establish the new navigation, scroll bounds, or Back behavior.
