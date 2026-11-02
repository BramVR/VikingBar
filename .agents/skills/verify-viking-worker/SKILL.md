---
name: verify-viking-worker
description: "Model-check Mobile Vikings worker flights, cancel, optional reads, and balance cache changes."
---

# Verify the Mobile Vikings worker

Use this skill before handing off any change to the `VikingSession` actor: how `run`/`runOptional` start, cancel, or wait for flights; `generation` and `checkGeneration`; `restore`, `refresh`, `selectSubscription`, `selectBundle`, `cancel`, `bootstrap`; the points, history, invoice, and payment-review fetches; or the balance cache. A TLA+ model, `formal/VikingWorker.tla`, checks two processes (app worker and CLI) on one account, sharing the Keychain record, `session.lock`, and the balance cache file, with reconnects, token expiry, busy locks, failed requests, and `cancel()` at any await.

Token rotation and `session.lock` around the exchange are `formal/TokenRotation.tla` (`verify-token-rotation`); here a token is just its connection plus valid/expired.

## Rules the model checks

- `CacheSiloed`: the cache file never holds one connection's or subscription's data under another's label. Harm: the next launch shows the previous login's balance, points, or bills, or one SIM's usage under another SIM's name.
- `ShownSiloed`: the same for what each worker reports. Harm: the menu or CLI shows another login's or SIM's data.
- `HistoryMatchesContext`: shown history is for the selected subscription, bundle, and revision. Harm: the chart shows another SIM's or bundle's usage.
- `CacheSavesCurrentConnection`: no cache save labels a connection the Keychain no longer holds. Harm: a worker on the old login overwrites the new login's cache; the next launch opens empty.
- `RestoreShowsCurrentConnection`: `restore()` ends on the record's connection. Harm: after a reconnect the app or CLI shows the old login.
- `NoStaleDataWrite`: a cancelled or superseded call writes no data and no cache. Harm: an older read overwrites the newer result.
- `NoStuckSpinner`: `isRefreshing` only while a non-optional flight runs. Harm: a stuck refresh spinner.
- `FlightTracksRunning`: `flight` is set while a task runs its operation. Harm: restore, selectBundle, or bootstrap run alongside it.
- `OptionalNeverCancelsRefresh`: an optional read never cancels a running refresh. Harm: background reads abort the user's refresh.
- `NoStaleReviewCheck`: a cancelled or superseded payment review does not set `.checking`. Harm: the worker keeps reporting "Checking"; the app's next `configure` or `restore` reply publishes it. Was finding [#58](https://github.com/BramVR/VikingBar/issues/58) (a `cancel()` between `run`'s `checkGeneration` and the nonisolated operation closure); fixed in #60: `fetchPaymentReview` calls `checkGeneration` before setting `.checking`.

## Coverage and sync

Sync commit: `5ec752b`. At that commit the model describes:

- `Sources/VikingBarCore/VikingSession.swift`: `bootstrapWithDiagnostics`, `restore`, `refresh`, `refreshPoints`, `selectSubscription`, `selectBundle`, `cancel`, `connect`, `fetch`, `fetchBalance`, `authorize` (adopt, token reuse, held-lease exchange), `withConnectionLease`, `recordFailure`, `adopt`, `checkGeneration`.
- `VikingSessionOperation.swift`: `runOptional`, `run`, `InFlight`, `OperationKind.isOptional`.
- `VikingSessionHistory.swift`, `VikingSessionPoints.swift`, `VikingSessionInvoices.swift` (`fetchInvoices`, `fetchPaymentReview`, `renderPayment`), `VikingSessionState.swift` (`canRestore`, `publish`, `selectBundle`), `UsageHistory.swift` (`historyContext`, `reviseHistory`).
- `SessionPersistence.swift`: `FileBalanceCache.load/save`, `FileSessionLease`.
- Call serialization: `SessionCommandQueue` in `Sources/VikingBarCLI/SessionCommands.swift`.

```sh
git diff --stat 5ec752b -- Sources/VikingBarCore/VikingSession*.swift Sources/VikingBarCore/SessionPersistence.swift Sources/VikingBarCore/UsageHistory.swift Sources/VikingBarCore/LiveModels.swift Sources/VikingBarCore/ProviderAccounts.swift Sources/VikingBarCLI/SessionCommands.swift
```

Output means: read the diff against the mapping below before trusting a pass.

## Run

```sh
./Scripts/check-formal.sh VikingWorker   # `make check-formal` runs every model
```

About 35 seconds (main model 6 million states, 18 s). Expect `PASS VikingWorker` and eleven `PASS ... mutant` lines; no open findings. Read results with the pstack `/statechart` skill on `formal/VikingWorker.tla` and the config that produced it; for a chart use `MaxCalls = 2`, `Concurrent = FALSE`.

## Model-to-code mapping

- One TLC step is actor code between two awaits. `call[i]` is one public call plus its `run()` task; old tasks keep running after cancel until they check.
- `Concurrent = TRUE` (main config) lets a process start calls while others run, the actor's own contract. Production serializes calls per process (`SessionCommandQueue`) except `cancel`; the `CancelledReviewChecks` mutant uses `Concurrent = FALSE` to show the old bug was reachable there.
- `RefreshStart`, `SelectStart`, `OptStart`, `OptWait`, `Run`: `refresh` (join or busy on a non-optional flight), `selectSubscription`, `runOptional`'s wait loop (generation and connection checks), `run` (cancel previous, capture generation, `isRefreshing`, `flight`).
- `Prev`: the task awaits the previous task and checks the generation. `prev` -> `body` is the hop into the nonisolated operation closure.
- `RefreshAuth`, `PointsAuth`, `Exchange`: `authorize`. `Subs_`, `Balance`: `fetchBalance`'s two awaits and lease blocks. `Points`: both points reads, merged. `HistBody`, `HistRead`, `HistPublish`: `fetchHistory`/`checkHistory`. `InvBody`, `Invoices`, `InvCatch`: `fetchInvoices` and `fetchPaymentReview` (render merged into the invoices answer). `ConnBody`, `ConnToken`: `connect`.
- `Commit`: run's do/catch/defer: success clears `isRefreshing`, the catch runs `recordFailure` for a current non-optional call, the defer clears `flight` if the id matches.
- `Restore`, `Bundle`, `ConnectStart`, `Cancel`, `Expire`: `restore`, `selectBundle`, `bootstrapWithDiagnostics`, `cancel`, token expiry.

Mutants in `formal/mutants/VikingWorker/`, each with an `\* expect:` line:

- `FaithfulCheckBeforeWrite` -> `StaleWrite` breaks `NoStaleDataWrite`.
- `FaithfulLeaseConnCheck` -> `LeaseConnUnchecked` breaks `CacheSavesCurrentConnection`.
- `FaithfulAdoptResets` -> `AdoptKeepsData` breaks `ShownSiloed`; `AdoptKeepsDataCache` breaks `CacheSiloed`.
- `FaithfulClearOnSubChange` -> `SubChangeKeepsBalance` breaks `ShownSiloed`.
- `FaithfulHistoryContextCheck` -> `HistoryContextUnchecked` breaks `HistoryMatchesContext`.
- `FaithfulCacheKeyed` -> `CacheUnkeyed` breaks `RestoreShowsCurrentConnection`.
- `FaithfulDeferChecksId` -> `DeferClearsAnyFlight` breaks `FlightTracksRunning`.
- `FaithfulDeferClearsSpinner` -> `SpinnerClearedOnSuccessOnly` breaks `NoStuckSpinner`.
- `FaithfulOptionalWaits` -> `OptionalSkipsWait` breaks `OptionalNeverCancelsRefresh`.
- `FaithfulCancelDropsReview` (`fetchPaymentReview`'s first `checkGeneration`, #60) -> `CancelledReviewChecks` breaks `NoStaleReviewCheck`.

## When a check fails

Map each trace step to the code. A trace every step of which the code allows is a real bug; tell it in the code's words. Check UI reachability: production calls are serialized per process, so a `Concurrent`-only trace is a contract break, not a user bug. If asked, file an issue with the `/statechart` chart and the bug path, and record it as `formal/findings/VikingWorker/<Name>.cfg` with `\* expect:` and `\* issue:` lines. Do not weaken a rule or change product code unless asked. If a step is impossible in the code, fix the model and cite the line. A mutant that passes means the model lost its power.

## When the change is intended

Edit the matching actions, one per await, with a comment naming the Swift. Keep a mutant per rule. Run the check. Move the sync commit only after confirming the model describes the code at the new commit.

## Assumptions and limits

- Two processes, three calls, two connections, three history revisions, one external cancel. Subscriptions never disappear; the bundle index is folded into the history revision.
- Data is abstracted to its source (connection, subscription, revision). Failure messages, freshness, `nextRefreshAt`, backoff, `scopeMismatch`, invoice PDFs, and the 300 s history throttle are not modeled.
- `fetch`'s `tokenExpired` retry, Keychain `rotationPending`, and record generations are left to `TokenRotation`; a token exchange is one held-lease await.
- `fetchInvoices` adopts before its generation check; the model checks first. `renderPayment` is merged into the invoices answer. Neither changes what is written.
- Outer-task cancellation without `cancel()` is not modeled; production always sends both.
