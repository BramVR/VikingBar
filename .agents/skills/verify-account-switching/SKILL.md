---
name: verify-account-switching
description: "Model-check app account switching, adding, reconnecting, cancelling, and late worker replies."
---

# Verify account switching

Use this skill before handing off any change to how the app switches accounts, adds or reconnects one, cancels a connection, or publishes worker and optional replies. A TLA+ model, `formal/AccountSwitching.tla`, checks every order of user actions, old tasks resuming late, worker replies, optional points reads, and CLI reconnects or selection changes. AppKit tests cannot reach most of these orders.

## Rules the model checks

- `ShowsSelectedAccount`: the menu shows only the selected account's data. Harm: one customer's usage, SIM names, or bills appear under another account.
- `SavedStatesSiloed`: every remembered account state belongs to its account. Harm: a later switch shows another account's data.
- `PointsMatchConnection`: points shown come from the shown connection. Harm: after a reconnect, possibly to another login, the previous customer's points stay visible.
- `SelectionPersisted`: once the app settles, the stored catalog selection is the account it shows, unless the CLI changed it. Harm: the next launch or CLI call opens another account, or the account from a cancelled addition.

All four hold at the sync commit.

## Coverage and sync

Sync commit: `91b1b01`. At that commit the model describes this code:

- `Sources/VikingBar/AppSession.swift`: `begin`, `isCurrent`, `start`, `refresh`, `perform`, `applyInterval` (same-connection publish only), `publish`, `failWorker`, `connect`, `connectionTarget`, `restoreAddedSelection`, `performConnection`, `failConnection`, `restorePreviousWorker`, `cancelConnection`, `restorationClient`, `restoreAndPerform`, `reconcileSelection`, `selectAccount`.
- `Sources/VikingBar/AppSessionOptional.swift`: `interruptOptional`, `pumpOptional`, `publishOptional`.
- `Sources/VikingBarCore/LiveModels.swift`: `mergePoints`, `mergeInvoices`. `Sources/VikingBarCore/UsageHistory.swift`: `mergeHistory`.
- `Sources/VikingBarCore/ProviderAccounts.swift`: `MobileVikingsAccount.state` tags each reply with its account key.

To see whether a change needs a recheck:

```sh
git diff --stat 91b1b01 -- Sources/VikingBar/AppSession.swift Sources/VikingBar/AppSessionOptional.swift Sources/VikingBarCore/LiveModels.swift Sources/VikingBarCore/UsageHistory.swift Sources/VikingBarCore/ProviderAccounts.swift
```

Also recheck when a new code path writes `liveState`, `savedAccounts`, `selectedAccount`, or the catalog selection, or adds an `await` before such a write.

## Run

```sh
./Scripts/check-formal.sh AccountSwitching   # `make check-formal` runs every model
```

It needs Java 11+ and takes about 20 seconds (14 million states). Logs are in `.build/formal/AccountSwitching*.log`. Expect one `PASS AccountSwitching` and four `PASS ... mutant` lines; any `FAIL` needs action (see below).

Read every result with the pstack `/statechart` skill on `formal/AccountSwitching.tla` and the config that produced it. For a chart, use a smaller config (`MaxOps = 2`, `MaxReconnects = 0`), and map the state to what the menu shows: whose data, and which account is selected.

## Model-to-code mapping

AppSession is `@MainActor`: code between two `await`s is one step. `begin()` cancels the old operation Task, but that Task keeps running, so every old operation stays in `op` and can resume later. Each resume checks `isCurrent(intent)`.

- `UserRefresh`: `refresh()` → `reconcileSelection` (`Reconcile`) → `perform(.refresh)` or `restoreAndPerform`.
- `UserSelect`: `selectAccount(key)` with `persist: true`. It saves `liveState` into `savedAccounts`, drops the worker, and shows the saved state. `PersistSelect` is `accountDirectory.select(key)`; its failure path goes back to the previous account.
- `Reconcile`: a stored selection differing from the shown one calls `selectAccount(persist: false)`.
- `RestoreRequest` / `RestoreResume`: `restorationClient()` makes a worker for `selectedAccount`; `.restore` is answered for that worker's account and current connection, then `publish`.
- `RefreshRequest` / `RefreshResume`: `perform`: `client.request`, `isCurrent`, account-key guard, `publish`.
- `UserConnect`: `connect(input:adding:)`. A reconnect clears the shown state; adding keeps it. `Connector` covers `previous.shutdown`, `connectionTarget`, and `connector.connect`. `AddSelect` / `RestoreAdded` are the catalog selection of the new account, undone if the intent went stale. `Connected_` and `ConnectFailed` are the two ends of `performConnection`.
- `UserCancel` / `CancelRestore` / `CancelDone`: `cancelConnection`, which awaits the old operation, restores the added selection and the previous worker.
- `OptionalStart` / `OptionalResume`: `pumpOptional` and `publishOptional` for points (history and invoices use the same guards).
- `CliReconnect` / `CliSelect`: another process reconnects an account (new `ConnectionID`) or changes `accounts-v1.json`.

Each `Faithful*` constant is `TRUE` for the code at the sync commit. Each mutant in `formal/mutants/AccountSwitching/` has an `\* expect:` line naming the rule it must break:

- `FaithfulCurrentIntentGuard` → `StaleTaskPublishes` breaks `SelectionPersisted`. A stale task acts on the current account.
- `FaithfulCurrentIntentGuard` + `FaithfulAccountKeyGuard` → `SiloGuardsDropped` breaks `ShowsSelectedAccount`. Each guard alone keeps another account's data off the menu; this defense in depth is intended. Keep both.
- `FaithfulOptionalGuard` → `OptionalUnchecked` breaks `PointsMatchConnection`.
- `FaithfulRestoreAddedSelection` → `CancelledAddKeepsSelection` breaks `SelectionPersisted`.

## When a check fails

- The main model fails: map each trace step to the code. If every step is possible, it is a real bug. Tell it in the menu's words, as in "you switch to b while a's refresh is in flight; a's reply arrives and the menu shows a's SIM under b". File an issue with the `/statechart` chart and the bug path if asked. Record it as `formal/findings/AccountSwitching/<Name>.cfg` with `\* expect:` and `\* issue:` lines. Do not weaken a rule, and do not change product code unless asked.
- A mutant passes: the model lost the power to catch that bug. Fix the model.
- A step is impossible in the code: the model is wrong. Typical causes: a user action enabled when the menu disables it (check `canRefresh`, `canSelectAccountData`, and the `activity` guards), an old task that the code awaits before continuing, or a reply computed for the wrong worker.

## When the change is intended

1. Edit the matching actions: one step per code between `await`s, with a comment that names the function.
2. Keep every rule backed by a mutant; update `\* expect:` lines.
3. Run the check; report new failures as findings.
4. Move the sync commit forward only after you confirm, file by file, that the model describes the code at the new commit.

## Assumptions and limits

- Two accounts: `a` (selected and connected at start) and `b` (switched to or added). Bounds: 4 `begin()` calls, 1 reconnect.
- One optional read stands for points, history, and invoices. PDFs, payment review, expiry timers, scheduled refresh, `applyInterval`, `stop()`, and fixture launches are not modeled.
- The model trusts each worker to answer for its own account and connection. That is the `VikingSession` and `TelenetHomeAccount` side, partly covered by `verify-token-rotation` and `verify-telenet-session`.
- Staleness is not a rule: showing an older reading of the right account is allowed.
