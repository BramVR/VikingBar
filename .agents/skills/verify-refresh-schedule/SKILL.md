---
name: verify-refresh-schedule
description: "Model-check automatic refresh timing, wake, refresh interval, and allowance-expiry redraw changes."
---

# Verify refresh scheduling

Use this skill before handing off any change to when VikingBar refreshes on its own, how it applies the refresh-interval setting, what happens on wake, or how the menu bar redraws when an allowance expires. A TLA+ model, `formal/RefreshSchedule.tla`, checks the app's refresh timer and expiry timer while time passes, the Mac sleeps and wakes, the worker replies or dies, and the user refreshes, changes the interval, switches accounts, reconnects, or quits.

## Rules the model checks

- `NoSilentStall`: an idle, connected app with no bridge failure has a refresh timer for the shown `nextRefreshAt`. Harm: old usage is shown as current and never refreshes.
- `NoRefreshStorm`: between ticks, with no user action, the timer starts at most one automatic refresh. Harm: a tight request loop against the provider.
- `IntervalApplied`: an idle app with a worker has told it the current interval. Harm: the chosen interval is ignored.
- `ExpiredNotShown`: once the drawn allowance's `expiresAt` passes, a due expiry timer will redraw the menu bar. Harm: remaining GB of an ended bundle stays on screen.
- `ExpiredFlagMatchesShown`: `allowanceExpired` describes only the shown data. Harm: a valid allowance shows as Unavailable.

Both expiry rules were open finding [#57](https://github.com/BramVR/VikingBar/issues/57) (a failed account switch restored the previous account without `scheduleExpiry`); fixed in [#59](https://github.com/BramVR/VikingBar/pull/59) (`a797ae0`) and now checked in `formal/RefreshSchedule.cfg`.

## Coverage and sync

Sync commit: `a797ae0`. At that commit the model describes:

- `Sources/VikingBar/AppSession.swift`: `start`, `refresh(manual:)`, `begin`, `perform`, `didWake`, `configureIfIdle`, `applyInterval`, `publish`, `failWorker`, `scheduleExpiry`, `cancelExpiry`, `finish`, `restoreAndPerform`, `restorationClient`, `selectAccount`, `stop`, `snapshot`, and the reconnect path of `connect`/`performConnection`/`failConnection`.
- `Sources/VikingBar/AppSessionOptional.swift`: `pumpOptional`'s catch. `Sources/VikingBar/AppSessionPresentation.swift`: `canRefresh`, `isConnected`. `Sources/VikingBar/VikingBarApp.swift`: wake observer, `onPresentationChange`.
- Worker replies: `Sources/VikingBarCore/VikingSession.swift` (`restore`, `configure`, `markStale`), `VikingSessionState.swift` (`publish`, `updateRefreshDeadline`, `freshDeadline`), `DisplayPreferences.swift` (`RefreshInterval.deadline`), `TelenetHomeAccount.swift` (`restore`, `read`, `finishFailure`, `nextRefreshAt` only).

```sh
git diff --stat a797ae0 -- Sources/VikingBar/AppSession.swift Sources/VikingBar/AppSessionOptional.swift Sources/VikingBar/AppSessionPresentation.swift Sources/VikingBar/VikingBarApp.swift Sources/VikingBarCore/VikingSession.swift Sources/VikingBarCore/VikingSessionState.swift Sources/VikingBarCore/DisplayPreferences.swift Sources/VikingBarCore/TelenetHomeAccount.swift
```

## Run

```sh
./Scripts/check-formal.sh RefreshSchedule   # `make check-formal` runs every model
```

It takes about 50 seconds (main model 20 million states, about 40 s). Expect `PASS RefreshSchedule` and seven `PASS ... mutant` lines. Read every result with the pstack `/statechart` skill on `formal/RefreshSchedule.tla` and the config that produced it; for a chart, use `MaxTime = 2`, `MaxActions = 2`.

## Model-to-code mapping

- `RefreshTimer`: the `scheduledRefresh` task from `finish()`: `sleepUntil(deadline)`, `isCurrent`, `refresh(manual: false)`. `begin` cancels it.
- `DidWake`: `didWake()`: idle, connected, `nextRefreshAt <= now`. `Wake` queues it; `Sleep` stops timers firing (they fire after wake, continuous clock).
- `ExpiryTimer`: the `scheduledExpiry` task: `allowanceExpired = true`, redraw. `Arm` is `scheduleExpiry()`; a new arm replaces the old revision.
- `Publish`: `publish(_:)`; `Draw`: `onPresentationChange` → `updateStatus` → `StatusPresentation(snapshot)`.
- `StartRefresh`: `refresh(manual:)`: `restoreAndPerform` without a worker or for an automatic Telenet refresh, else `perform`. `UserInterval`: `refreshInterval` didSet → `configureIfIdle`.
- `RestoreStart` / `ConfigureStep` / `RestoreReply`: `restorationClient` (new worker at five minutes), `applyInterval` loop, `.restore` and the `shouldWait` check. `Perform`: `.refresh`, then `applyInterval`. `Done` / `Finish`: `finish()`.
- `Persist`: `selectAccount`'s `accountDirectory.select` and its catch (restore previous account, `scheduleExpiry`, `failWorker`). `FailWorker` / `FailShutdown`: `failWorker` around `await failed?.shutdown()`.
- `Connect`: reconnect via `connector.connect`; `OptionalFails`: an optional read's bridge throw drops the worker, keeps the timer. `UserStop`: `stop()`.
- Worker replies: success sets `nextRefreshAt = min(now + interval, expiry)`; failure sets backoff or nil with reconnect required; restore may return a passed deadline, nil, or now; configure may return a passed deadline.

Mutants in `formal/mutants/RefreshSchedule/`, each with an `\* expect:` line:

- `FaithfulFinishSchedules` → `FinishSkipsTimer` breaks `NoSilentStall`.
- `FaithfulFailureBackoff` → `FailureKeepsDeadline` breaks `NoRefreshStorm`.
- `FaithfulFinishConfigures` → `FinishSkipsConfigure` breaks `IntervalApplied`.
- `FaithfulPublishArmsExpiry` → `PublishSkipsExpiry` breaks `ExpiredNotShown` (with `PersistCanFail = FALSE`).
- `FaithfulExpiryReset` → `ExpiredFlagKept` breaks `ExpiredFlagMatchesShown` (with `PersistCanFail = FALSE`).
- `FaithfulSelectFailureArmsExpiry` → `SelectFailureSkipsExpiry` breaks `ExpiredNotShown`; `SelectFailureStaleExpiry` breaks `ExpiredFlagMatchesShown` (pre-#59 catch without `scheduleExpiry`).

## When a check fails

Map each trace step to the code. A possible trace that harms the user is a real bug: tell it in the code's words. If asked, file an issue with the `/statechart` chart and the numbered bug path, and record it as `formal/findings/RefreshSchedule/<Name>.cfg` with `\* expect:` and `\* issue:` lines. Do not weaken a rule, and do not change product code unless asked. If a step is impossible in the code, fix the model and cite the line. A mutant that passes means the model lost its power; fix the model. A finding that stops failing means the code changed: if fixed on purpose, delete its cfg and add the rule to `formal/RefreshSchedule.cfg`.

## When the change is intended

Edit the matching actions, one per observable effect, with a comment naming the Swift. Keep a mutant per rule. Run the check. Move the sync commit forward only after you confirm the model describes the code at the new commit.

## Assumptions and limits

- One operation at a time: cancelled operations do nothing visible because every resumption checks `isCurrent` (see `verify-account-switching`). Worker effects of a cancelled request are not modeled.
- A request and its reply are one step. Account selection data siloing, adding accounts, and cancel are left to `formal/AccountSwitching.tla`; Telenet record internals to `formal/TelenetSession.tla`.
- Bounds: 3 ticks, 1 sleep, 3 user actions, intervals of 1 and 2 ticks, backoff of 1 tick. Optional reads appear only as their failure.
- `NoRefreshStorm` counts timer refreshes only; `didWake` fires once per wake. The worker's command queue is serial, so in-worker `busy` replies are not modeled.
- The bar harm is the status item title; the popover recomputes `snapshot` when SwiftUI redraws it.
