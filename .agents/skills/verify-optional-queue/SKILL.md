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
- `StuckQueueReported` (open finding `OptionalFailureHidesStoppedWorker`, [#56](https://github.com/BramVR/VikingBar/issues/56)): queued work that cannot run because the client is gone comes with the worker-stopped message. The code breaks it: an optional read whose worker dies sets `client = nil` without `bridgeFailure`, so Bills shows "Could not load bills. Try again." with its retry disabled, and later reads wait for the next scheduled refresh.
- Open finding `ConfigureRepublishesStaleQR` ([#58](https://github.com/BramVR/VikingBar/issues/58)) (breaks `QRMatchesView` with `UserBeatsConfigure = TRUE`): the worker keeps `.ready` after a collapse; `configure` returns it; `publish` takes it; `reviewPayment` returns early while bills load, so the old QR shows for another invoice, with no expiry timer. The user must reopen Bills during the configure round trip, so the main config assumes they cannot.

## Coverage and sync

Sync commit: `91b1b01`. At that commit the model describes:

- `Sources/VikingBar/AppSessionOptional.swift`: `loadInvoices`, `reviewPayment` (non-fixture), `clearPaymentReview`, `clearPaymentExpiry`, `schedulePaymentExpiry`, `openInvoice`, `enqueueOptional`, `interruptOptional`, `pumpOptional`, `publishOptional`.
- `Sources/VikingBar/AppSession.swift`: `begin`, `finish`, `perform`, `publish`, `failWorker`, `configureIfIdle`, `applyInterval`, `restoreAndPerform`, `selectAccount`, `refresh`.
- `Sources/VikingBar/InvoicesView.swift`: `paymentExpanded`, `select`, `collapsePayment`, `.task(id: canLoadInvoices)`, `.onDisappear`.
- `Sources/VikingBar/SessionProcessClient.swift` (replies carry state even for failed commands) and `Sources/VikingBarCLI/SessionCommands.swift` (`SessionCommandQueue`).
- `Sources/VikingBarCore`: `VikingSessionInvoices.swift`, `VikingSessionOperation.swift` (`run`, `runOptional`), `VikingSession.swift` (`configure`, `cancel`), `ProviderAccounts.swift` (`perform`), `LiveModels.swift` (`mergeInvoices`), `InvoicePayment.swift` (lifetime).

```sh
git diff --stat 91b1b01 -- Sources/VikingBar/AppSessionOptional.swift Sources/VikingBar/AppSession.swift \
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

About 30 seconds; the main config explores 2.5 million states. Expect `PASS OptionalQueue`, five `PASS ... mutant` lines, and two `OPEN` lines. Read every result with the pstack `/statechart` skill on `formal/OptionalQueue.tla` and the config that produced it; for a chart use `MaxOps = 2`, `MaxOptStarts = 2`, `MaxCrashes = 0`.

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

## When a check fails

Map each trace step to the code. A possible trace is a real bug; report it in the code's words. If asked, file an issue with the `/statechart` chart and the bug path, and record it as `formal/findings/OptionalQueue/<Name>.cfg` with `\* expect:` and `\* issue:` lines. Do not weaken a rule or change product code unless asked. If a step is impossible in the code, fix the model and cite the code. A passing mutant means the model lost power. A finding that stops failing means the code changed: move its rule into `formal/OptionalQueue.cfg`.

## When the change is intended

Edit the matching actions, one per main-actor step or worker command, with a comment naming the Swift. Keep a mutant per rule. Run the check. Move the sync commit only after you confirm the model describes the code at the new commit.

## Assumptions and limits

- Two invoices, both listed and payable; accounts a and b, one connection each (connection ids encode the account). CLI reconnects are not modeled.
- Only the current operation Task is kept; superseded ones exit at `isCurrent` (AccountSwitching model), but their commands still run in the worker.
- Waiting on cancellation: perform/configure and optional Tasks wait for every cancel sent so far (the code chains through `optionalCancellation`; `pumpOptional` can drop the link).
- A fresh worker's `applyInterval` configure is folded into `appliedInterval = desired`. Reconcile, Telenet, history, subscriptions, bundle selection, and `stop` are not modeled.
- `MaxTime = 1`, `Lifetime = 1`; a due expiry timer fires before time advances. Optional Task slots are bounded; states past a bound are cut off and the rules hold vacuously there, so a finding needing more slots needs a larger config.
- The fixture renderer path of `reviewPayment` is not modeled: its Task's `.unavailable` branch has no revision check, so a late result can land after a collapse (fixture only, hidden until the next expand resets it).
