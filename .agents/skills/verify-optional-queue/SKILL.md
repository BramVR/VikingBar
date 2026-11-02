---
name: verify-optional-queue
description: "Model-check optional request queue, Bills loading, invoice PDF, and payment QR review changes."
---

# Verify the optional queue and payment review

Use this skill before handing off any change to how the app queues optional reads (points, bills, history, invoice PDF, bank transfer QR), interrupts them, or shows the payment review in Bills. A TLA+ model, `formal/OptionalQueue.tla`, checks the app's main-actor steps against serialized worker processes. It covers stale optional Tasks, chained cancels, refresh and configure publishes, one account switch, a worker dying, the Bills view appearing and disappearing, and the QR expiry timer.

## Rules the model checks

- `QRMatchesView`: a visible QR (Bills shown, payment expanded, review `.ready`) is for the expanded invoice and the shown connection. Harm: the user scans a transfer for another bill or another customer.
- `QRNotExpired`: a visible QR is not past `expiresAt` unless its expiry timer is armed. Harm: paying an amount verified more than five minutes ago.
- `PdfMatchesRequest`: an opened PDF is the requested invoice of the shown connection. Harm: another bill or another customer's bill opens.
- `PumpNotForgotten`: idle, connected, with a client and no optional operation, the queue is empty. Harm: reads never run and "Refreshing bills" stays on.
- `StuckQueueReported`: settled with queued work, either a client can run it or the worker-stopped message shows. Harm: "Refreshing bills"/history loading stays on with Bills, PDF and QR disabled and no error. Former finding [#56](https://github.com/BramVR/VikingBar/issues/56), fixed in #62: `pumpOptional`'s `catch` now runs `failOptional` for the read and every queued one and empties `pendingOptional` before `client = nil`.
- `QRMatchesView` also covers former finding [#58](https://github.com/BramVR/VikingBar/issues/58), fixed in #60: `publish` keeps the app's `paymentReview` for the same connection (`mergeInvoices(from: liveState)`) and clears it for another, so a `.ready` QR the worker kept after a collapse no longer comes back through `configure`/`refresh`. The main config sets `UserBeatsConfigure = TRUE` (the user may reach Bills during a configure round trip).

## Coverage and sync

Sync commit: `a797ae0`. At that commit the model describes:

- `Sources/VikingBar/AppSessionOptional.swift`: `loadInvoices`, `reviewPayment` (non-fixture), `clearPaymentReview`, `clearPaymentExpiry`, `schedulePaymentExpiry`, `openInvoice`, `enqueueOptional`, `interruptOptional`, `pumpOptional`, `publishOptional`.
- `Sources/VikingBar/AppSession.swift`: `begin`, `finish`, `perform`, `publish`, `failWorker`, `configureIfIdle`, `applyInterval`, `restoreAndPerform`, `selectAccount`, `refresh`.
- `Sources/VikingBar/InvoicesView.swift`: `paymentExpanded`, `select`, `collapsePayment`, `.task(id: canLoadInvoices)`, `.onDisappear`.
- `Sources/VikingBar/SessionProcessClient.swift` (replies carry state even for failed commands) and `Sources/VikingBarCLI/SessionCommands.swift` (`SessionCommandQueue`).
- `Sources/VikingBarCore`: `VikingSessionInvoices.swift`, `VikingSessionOperation.swift` (`run`, `runOptional`), `VikingSession.swift` (`configure`, `cancel`), `ProviderAccounts.swift` (`perform`), `LiveModels.swift` (`mergeInvoices`), `InvoicePayment.swift` (lifetime).

```sh
git diff --stat a797ae0 -- Sources/VikingBar/AppSessionOptional.swift Sources/VikingBar/AppSession.swift \
  Sources/VikingBar/InvoicesView.swift Sources/VikingBar/SessionProcessClient.swift \
  Sources/VikingBarCLI/SessionCommands.swift Sources/VikingBarCore/VikingSessionInvoices.swift \
  Sources/VikingBarCore/VikingSessionOperation.swift Sources/VikingBarCore/VikingSession.swift \
  Sources/VikingBarCore/ProviderAccounts.swift Sources/VikingBarCore/LiveModels.swift \
  Sources/VikingBarCore/InvoicePayment.swift
```

## Run

```sh
./Scripts/check-formal.sh OptionalQueue   # `make check-formal` runs every model
```

About 30 seconds; the main config explores 2.6 million states. Expect `PASS OptionalQueue` and seven `PASS ... mutant` lines. Read every result with the pstack `/statechart` skill on `formal/OptionalQueue.tla` and the config that produced it; for a chart use `MaxOps = 2`, `MaxOptStarts = 2`, `MaxCrashes = 0`.

## Model-to-code mapping

- `s`: the app as one record, so `Interrupt`, `Pump`, `Begin`, `Finish`, `Publish`, `ClearReview` compose like the Swift calls. `paymentRevision` and `optionalRevision` become "timer armed" and per-Task `cur` flags.
- `ShowBills`/`BillsTask`/`HideBills`: destination `.bills`, `.task(id: canLoadInvoices)` (runs before any click), `.onDisappear`.
- `Expand`/`Collapse`/`Pick`/`RefreshBills`/`OpenPdf`: toggle, picker `select`, Refresh bills, Open PDF, with the view's enablement.
- `ChangeInterval`: the Settings picker (Bills not shown), `refreshInterval.didSet` -> `configureIfIdle`.
- `Refresh`: DataCard button, scheduled refresh, or wake. `SelectAccount`: the Account destination.
- `CfgWait`/`CfgAns`, `RefWait`/`RefAns`/`RefCfgAns`, `SwShutdown`/`Restore`/`RstAns`: operation Task steps between awaits.
- `OptSend`/`OptResume`: `pumpOptional`'s Task before and after `client.request`, including `catch` and `defer`.
- `CancelSend`: the `optionalCancellation` Task; the worker cancels on arrival.
- `WorkerStep`: one command in a worker process; `WorkerCrash`: the process dies; `TimerFire`/`Tick`: `paymentExpiry` and time.

Mutants in `formal/mutants/OptionalQueue/`, each with an `\* expect:` line:

- `FaithfulOptionalGuard` -> `StaleReplyPublished` breaks `QRMatchesView`; `StaleDocumentOpened` breaks `PdfMatchesRequest`.
- `FaithfulExpiryTimer` -> `ExpiryNotScheduled` breaks `QRNotExpired`.
- `FaithfulDocumentChecks` -> `DocumentUnchecked` breaks `PdfMatchesRequest`.
- `FaithfulPumpOnSettle` -> `PumpSkipped` breaks `PumpNotForgotten`.
- `FaithfulStopFailsQueue` -> `OptionalFailureHidesStoppedWorker` breaks `StuckQueueReported` (code before #62: the `catch` failed only the active read and kept `pendingOptional`).
- `FaithfulDropStaleReview` -> `ConfigureRepublishesStaleQR` breaks `QRMatchesView` (code before #60: `publish` took the worker's `paymentReview`). Needs `UserBeatsConfigure = TRUE`, `MaxOps = 2`, `MaxOptStarts = 3`.

## When a check fails

Map each trace step to the code. A possible trace is a real bug; report it in the code's words. If asked, file an issue with the `/statechart` chart and the bug path, and record it as `formal/findings/OptionalQueue/<Name>.cfg` with `\* expect:` and `\* issue:` lines. Do not weaken a rule or change product code unless asked. If a step is impossible in the code, fix the model and cite the code. A passing mutant means the model lost power. A finding that stops failing means the code changed: move its rule into `formal/OptionalQueue.cfg`.

## When the change is intended

Edit the matching actions, one per main-actor step or worker command, with a comment naming the Swift. Keep a mutant per rule. Run the check. Move the sync commit only after you confirm the model describes the code at the new commit.

## Assumptions and limits

- The worker's `fetchPaymentReview` generation check (#60) is the VikingWorker model; here a cancel marks queued commands cancelled on arrival.
- Two invoices, both listed and payable; accounts a and b, one connection each (connection ids encode the account). CLI reconnects are not modeled.
- Only the current operation Task is kept; superseded ones exit at `isCurrent` (AccountSwitching model), but their commands still run in the worker.
- Waiting on cancellation: perform/configure and optional Tasks wait for every cancel sent so far (the code chains through `optionalCancellation`; `pumpOptional` can drop the link).
- A fresh worker's `applyInterval` configure is folded into `appliedInterval = desired`. Reconcile, Telenet, history, subscriptions, bundle selection, and `stop` are not modeled.
- `MaxTime = 1`, `Lifetime = 1`; a due expiry timer fires before time advances. Optional Task slots are bounded; states past a bound are cut off and the rules hold vacuously there, so a finding needing more slots needs a larger config.
- The fixture renderer path of `reviewPayment` is not modeled: its Task's `.unavailable` branch has no revision check, so a late result can land after a collapse (fixture only, hidden until the next expand resets it).
