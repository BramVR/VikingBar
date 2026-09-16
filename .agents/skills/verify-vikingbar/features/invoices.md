# Latest bill and PDF

## Sub-features

- Account-level invoice listing, including grouped bills and selected-SIM membership.
- Latest billing document with separate total, amount due, reduction, applied points, date, payment status, and credit-note linkage.
- Empty, unavailable, and bounded-result states that preserve the balance.
- Explicit authenticated PDF download into a private local file.
- Fresh exact-invoice bank-transfer review with a short-lived, locally generated EPC QR and per-field copy controls.
- Independent API comparison through `make proof-live CHECK=invoices`.
- Private reviewed-PDF correspondence through `make proof-live CHECK=payment-evidence`.

## How to get to it (user POV)

Connect the live account, open the helmet, and choose **Bills**. Inspect billing documents and their account or grouped scope. Use **Load bills** to retry or refresh. Expand **Review bank transfer QR** for an eligible invoice; the app refreshes and revalidates before showing it. **Open PDF** requests and opens that document. The ordinary fixture keeps Load bills disabled. The separate `--payment-fixture` path supplies synthetic invoices, an isolated clipboard receipt, and a real bundled QR without account access.

## Driving it with the native helper and CLI

Run `make check` with the configured formatter, then `make check-proof`. These use synthetic data and isolated stores. Hold the credential slot before running `make proof-live CHECK=invoices`. The gate uses the stored account session and can access Keychain. It compares real invoice metadata with `InvoicePresentation`. If an invoice exists, it validates a PDF through the production downloader without opening a viewer. Require exit 0 and a validated redacted receipt. An account with no invoices must return an observed empty result. Missing authorization, failed requests, and skips cannot pass.

Run `make smoke-payment-fixture` for the synthetic native payment flow. Require the actual screenshot QR to decode to the fixture EPC payload, all copy controls to report exact in-memory values without using the system clipboard, collapse to remove the QR, reopen to generate it again, and light/dark captures. For real API/PDF correspondence, privately review the PDF, create the exact mode-0600 witness described in `docs/invoices.md`, and run `VIKINGBAR_PAYMENT_EVIDENCE=/private/path/reviewed-invoice.json make proof-live CHECK=payment-evidence`. The receipt must be redacted. Keep the witness, raw metadata, PDF, and captures private.

Native coverage requires the Mac UI slot as well. Follow the [verification skill](../SKILL.md) to build, record, and inspect a task-owned live app. Run doctor before driving. Press `vikingbar.bills` and inspect `vikingbar.invoices.message`. Wait for automatic loading to settle and `vikingbar.invoices.load` to become enabled. Record the displayed fetch timestamp, press Load bills, then require a newer timestamp and completed response. Inspect `vikingbar.invoice.latest` when present. Compare every displayed billing value and its scope with the production presentation. Press `vikingbar.back`, then `vikingbar.points`, and confirm that customer points remain available after invoice loading. Press `vikingbar.back`, press Refresh, and require a newer usable balance and completed points refresh. If bill loading was interrupted, require its metadata request to resume. Verify that a cancelled PDF action does not open later. Delayed-request ordering remains a separate synthetic regression; fast live responses cannot prove that case.

Only with explicit permission to open the personal PDF, press `vikingbar.invoice.pdf`. Verify the requested local PDF opens and that the file has private permissions. Otherwise record native PDF opening as unproved; the authorized CLI gate can still validate the download path without displaying its contents. Do not infer native button success from a CLI receipt.

Preserve the source SHA, binary hash, command, exit code, redacted receipt, and private native captures. Keep invoice values, identifiers, downloaded PDFs, and raw account responses out of public artifacts. Use the skill's task-owned Quit and cleanup procedure. Evidence must survive cleanup.

## Gotchas

- Grouped totals are account charges. Missing contributor IDs cannot prove that the selected SIM is excluded.
- Points applied are a numeric points value. They are distinct from the monetary reduction and unpaid amount.
- A credit note does not prove payment. Amount due belongs to the displayed document, not aggregate account debt.
- The API's subscription invoice list omits grouped invoices. Account listing is mandatory.
- A page cap cannot establish an empty account. Do not fabricate an invoice for empty-account proof.
- Metadata refresh must never fetch a PDF. Download errors must leave the balance usable.
- QR generation does not submit a transfer. Fixture decoding does not establish acceptance by a banking app.
- Real API/PDF payment-field matching, bank-app scanning, and actual macOS 14 execution remain unproved until their separate procedures pass.
- Authorized stored-session testing on 2026-09-16 decoded a real invoice QR and matched its recipient, unpaid amount, and checksum-valid reference against API metadata. The provider supplies references as 12 plain digits. This does not establish matching-PDF or banking-app acceptance. Private evidence remains outside the repository.
- Synthetic payment proof passed on macOS 26.6.2 on 2026-09-16: bundled-helper QR with Febelfin reference serialization decoded from light/dark native captures, paid/payable document selection, exact isolated copy values, icon-only copy buttons with stable checkmark feedback, visible IBAN keyboard focus and Space activation, persistent invoice summary through refresh and expansion, compact side-by-side QR with all bank details visible without scrolling, collapse/reopen, Back, and two verified Quit exits. Private receipts: `.build/proof/payment-20260916-112108-627535/`. This does not establish the live or macOS 14 requirements above.
- The authorized invoice gate passed on `ccf7c5319a36fb08f44a0098d125bddd9baa5bfc`, including metadata, presentation, and production PDF validation. After a documentation-only merge, the CLI and app executable hashes remained identical. Combined native Bills and Points coverage passed with the clean `a2b87f3b22170b5c90ac4a6528d8d61d2ae3f55d` bundle: displayed bill fields and scope, newer metadata after Load bills, Points API/native comparison, newer usage and both points timestamps after Refresh, transaction expansion/collapse, settled bill controls, and native Quit with owned-process cleanup. Captures were inspected and retained privately.
- Native PDF opening was not authorized or exercised. Live empty-account and delayed-preemption cases were not observed; their synthetic coverage does not establish live proof.

Historical invoice API and combined native passes remain recorded above. All-nine post-merge maintenance passed on main `e0f353dcfe2042932bf6e03e647782dc37b6aa99`: combined native Bills and Points, independent invoice and Points API comparisons, authenticated PDF validation without opening a viewer, native Refresh, and owned-process Quit cleanup all passed; the separate auth CLI gate also passed. Current compact Bills proof on 2026-09-14 passed automatic loading, explicit reload with a newer timestamp, visible billing fields and scope, Back, Points, and native Refresh. The independent invoice API and production PDF validation passed without opening a viewer. A Keychain prompt interrupted the release stage. A separate continuation of the exact release binaries then passed stored-session restoration, a newer balance on the same connection and selection, native Quit, and cleanup. The interrupted receipt remains failed; the composed live evidence completes the gate.
