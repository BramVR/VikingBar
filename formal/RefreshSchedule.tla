-------------------------- MODULE RefreshSchedule --------------------------
(***************************************************************************)
(* The app's automatic refresh timer, the refresh-interval setting, and    *)
(* the allowance-expiry redraw of the menu bar, while time passes, the Mac *)
(* sleeps and wakes, the worker fails, and the user refreshes, changes the *)
(* interval, switches accounts, reconnects, or quits.                      *)
(*                                                                         *)
(* Code (Sources/VikingBar):                                               *)
(*   AppSession.swift   start, refresh(manual:), begin, perform, didWake,  *)
(*                      configureIfIdle, applyInterval, publish,           *)
(*                      failWorker, scheduleExpiry, cancelExpiry, finish,  *)
(*                      connect/performConnection/failConnection (re-      *)
(*                      connect only), restoreAndPerform,                  *)
(*                      restorationClient, selectAccount, stop, snapshot   *)
(*   AppSessionOptional.swift   pumpOptional's catch (drops the worker)    *)
(*   AppSessionPresentation.swift   canRefresh, isConnected               *)
(*   VikingBarApp.swift   didWakeNotification -> didWake;                  *)
(*                        onPresentationChange -> updateStatus             *)
(* Code (Sources/VikingBarCore), as replies the app receives:              *)
(*   VikingSession.swift      restore (freshDeadline, revalidateBundle),   *)
(*                            configure, markStale (backoff)               *)
(*   VikingSessionState.swift publish, updateRefreshDeadline               *)
(*   DisplayPreferences.swift RefreshInterval.deadline                     *)
(*   TelenetHomeAccount.swift restore, read, finishFailure (nextRefreshAt) *)
(*                                                                         *)
(* AppSession is @MainActor: code between two awaits is one step. Only the *)
(* current operation is modeled: every resumption checks isCurrent(intent) *)
(* (formal/AccountSwitching.tla checks that), so a cancelled operation     *)
(* does nothing visible. A worker request and its reply are one step.      *)
(* Account a is Mobile Vikings, b is Telenet. Times are ticks 1..MaxTime;  *)
(* Far is beyond the horizon (or no expiry). Timers fire only while the    *)
(* Mac is awake; Task.sleep uses the continuous clock, so a timer whose    *)
(* time passed during sleep fires after wake.                              *)
(*                                                                         *)
(* Faithful* constants are TRUE for the code as written; each mutant in    *)
(* formal/mutants/RefreshSchedule turns one off.                           *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxTime,          \* ticks explored
    MaxSleeps,        \* system sleeps explored
    MaxActions,       \* user actions explored (refresh, interval, select, reconnect, optional failure)
    \* Environment: accountDirectory.select(key) can throw (the CLI holds
    \* catalog.lock, the account vanished, the CLI timed out).
    PersistCanFail,
    \* finish(): `if self.isConnected, let deadline = liveState.nextRefreshAt
    \* { scheduledRefresh = Task { sleepUntil(deadline); refresh(manual: false) } }`
    FaithfulFinishSchedules,
    \* VikingSession.markStale / TelenetHomeAccount.finishFailure: a failure
    \* moves nextRefreshAt to now + backoff (nil only for reconnect failures).
    FaithfulFailureBackoff,
    \* publish(): self.scheduleExpiry() re-arms the expiry timer.
    FaithfulPublishArmsExpiry,
    \* scheduleExpiry(): self.allowanceExpired = false.
    FaithfulExpiryReset,
    \* finish(): `if appliedInterval != refreshInterval { configureIfIdle() }`.
    FaithfulFinishConfigures,
    \* selectAccount's catch: self.scheduleExpiry() after restoring the
    \* previous account's liveState (fix for #57).
    FaithfulSelectFailureArmsExpiry

A == {"a", "b"}
Telenet(k) == k = "b"
None == 0
Far == MaxTime + 1
Times == 1..MaxTime
Intervals == {1, 2}
DefaultInterval == 1          \* restorationClient: appliedInterval = .fiveMinutes
Min(x, y) == IF x < y THEN x ELSE y
Cap(t) == Min(t, Far)

\* What the app holds of a worker state: isConnected, a usable allowance,
\* its expiresAt (Far = none), nextRefreshAt (None = nil), and failure.
Empty == [conn |-> FALSE, has |-> FALSE, exp |-> Far, next |-> None, fail |-> FALSE]
Data == [conn : BOOLEAN, has : BOOLEAN, exp : Times \cup {Far},
         next : {None} \cup Times \cup {Far}, fail : BOOLEAN]

VARIABLES
    now, awake, sleeps,
    wakePending,  \* a didWakeNotification Task waiting for the main actor
    selected,     \* selectedAccount
    live,         \* liveState
    saved,        \* savedAccounts
    savedFail,    \* savedFailures (bridge failure per account)
    cache,        \* worker state per account (balance cache / Telenet record)
    client,       \* a worker exists for the selected account
    bridgeFail,   \* bridgeFailure != nil
    activity,
    pc,           \* the current operation's next step
    manual,       \* restoreAndPerform(manualRefresh:)
    prev,         \* selectAccount's previousKey
    desired,      \* refreshInterval (the setting)
    applied,      \* appliedInterval (what the worker was told)
    scheduled,    \* scheduledRefresh deadline, or None
    expTimer,     \* scheduledExpiry deadline (current revision), or None
    expired,      \* allowanceExpired
    bar,          \* history: what the menu bar last drew
    autoStreak,   \* history: timer refreshes since the last tick or user action
    actions       \* user actions taken (bound only)

vars == <<now, awake, sleeps, wakePending, selected, live, saved, savedFail, cache, client,
          bridgeFail, activity, pc, manual, prev, desired, applied, scheduled, expTimer,
          expired, bar, autoStreak, actions>>

-----------------------------------------------------------------------------
(* Helpers.                                                                *)

\* onPresentationChange -> updateStatus: StatusPresentation(snapshot). The
\* snapshot hides the allowance once allowanceExpired or expiresAt <= now.
Draw(l, e) == [allow |-> l.has /\ ~e /\ now < l.exp, exp |-> l.exp]

\* scheduleExpiry(): cancelExpiry (revision += 1), reset the flag, arm a
\* timer for liveState.snapshot.expiresAt when it is in the future.
Arm(l) == IF l.has /\ now < l.exp /\ l.exp # Far THEN l.exp ELSE None

\* publish(state): liveState = state, savedAccounts, bridgeFailure = nil,
\* scheduleExpiry(), onPresentationChange.
Publish(r) ==
    /\ live' = r
    /\ saved' = [saved EXCEPT ![selected] = r]
    /\ bridgeFail' = FALSE
    /\ expTimer' = IF FaithfulPublishArmsExpiry THEN Arm(r) ELSE expTimer
    /\ expired' = IF FaithfulExpiryReset THEN FALSE ELSE expired
    /\ bar' = Draw(r, expired')

Usable(c) == c.has /\ now < c.exp

\* Replies the worker gives. c is the worker's state for the account.
\* refresh: success (VikingSessionState.publish / TelenetHomeAccount.read),
\* a transient failure (markStale backoff), or a reconnect failure.
RefreshReplies(c) ==
    { [conn |-> TRUE, has |-> TRUE, exp |-> e, next |-> Min(Cap(now + applied), e), fail |-> FALSE]
        : e \in {Cap(now + 1), Far} }
    \cup { [conn |-> c.conn, has |-> Usable(c), exp |-> c.exp,
            next |-> IF FaithfulFailureBackoff THEN Cap(now + 1) ELSE c.next, fail |-> TRUE] }
    \cup { [conn |-> FALSE, has |-> Usable(c), exp |-> c.exp, next |-> None, fail |-> TRUE] }

\* restore: the cached state. A passed deadline without failure becomes nil
\* (Vikings freshDeadline) or now (revalidateBundle), or stays (Telenet).
\* Or restore fails: markStale backoff, or reconnect required / no record.
RestoreReplies(c) ==
    { [c EXCEPT !.has = Usable(c), !.next = n]
        : n \in {c.next} \cup (IF ~c.fail /\ c.next # None /\ c.next <= now THEN {None, now} ELSE {}) }
    \cup { [c EXCEPT !.has = Usable(c), !.fail = TRUE,
                     !.next = IF FaithfulFailureBackoff THEN Cap(now + 1) ELSE c.next] }
    \cup { [c EXCEPT !.has = Usable(c), !.conn = FALSE, !.fail = TRUE, !.next = None] }

\* configure(interval): updateRefreshDeadline: min(updated + interval,
\* expiresAt) when there is no failure, which may already have passed.
\* Telenet ignores it.
ConfigureReplies(c) ==
    {c} \cup (IF c.fail \/ ~c.conn THEN {}
              ELSE { [c EXCEPT !.next = Min(n, c.exp)] : n \in 1..Cap(now + desired) })

\* begin(activity): generation += 1, cancel operation and scheduledRefresh.
Begin(act, step) ==
    /\ activity' = act
    /\ pc' = step
    /\ scheduled' = None

CanRefresh == activity = "idle" /\ (live.conn \/ bridgeFail)

\* finish(): idle, redraw, configureIfIdle when the interval changed (it
\* returns if that started an operation), else arm the refresh timer.
\* l and e are liveState and allowanceExpired at that point.
Finish(l, e) ==
    /\ bar' = Draw(l, e)
    /\ IF FaithfulFinishConfigures /\ applied # desired /\ client
       THEN Begin("configuring", "configure")
       ELSE /\ activity' = "idle"
            /\ pc' = "none"
            /\ scheduled' = IF FaithfulFinishSchedules /\ l.conn /\ l.next # None
                            THEN l.next ELSE None

\* failWorker, first half: bridgeFailure = .unavailable, redraw, then
\* await failed?.shutdown().
\* e is allowanceExpired when the redraw runs.
FailWorkerWith(l, e) ==
    /\ bridgeFail' = TRUE
    /\ bar' = Draw(l, e)
    /\ pc' = "failShutdown"

FailWorker(l) == FailWorkerWith(l, expired)

-----------------------------------------------------------------------------
Init ==
    /\ now = 1
    /\ awake = TRUE
    /\ sleeps = 0
    /\ wakePending = FALSE
    /\ selected = "a"
    /\ live = Empty
    /\ saved = [k \in A |-> Empty]
    /\ savedFail = [k \in A |-> FALSE]
    \* What the worker finds on disk at launch: a cached, connected state
    \* whose deadline is now or later and whose bundle may expire.
    /\ cache \in [A -> { [conn |-> TRUE, has |-> TRUE, exp |-> e, next |-> n, fail |-> FALSE]
                         : e \in {2, Far}, n \in {1, 2} }]
    /\ client = FALSE
    /\ bridgeFail = FALSE
    \* start(): begin(.restoring); restoreAndPerform(.refresh).
    /\ activity = "restoring"
    /\ pc = "restore"
    /\ manual = FALSE
    /\ prev = "a"
    /\ desired = 2                \* a saved setting other than the default; UserInterval covers 1
    /\ applied = DefaultInterval
    /\ scheduled = None
    /\ expTimer = None
    /\ expired = FALSE
    /\ bar = [allow |-> FALSE, exp |-> Far]
    /\ autoStreak = 0
    /\ actions = 0

-----------------------------------------------------------------------------
(* Time and the system.                                                    *)

Tick ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ autoStreak' = 0
    /\ UNCHANGED <<awake, sleeps, wakePending, selected, live, saved, savedFail, cache, client,
                   bridgeFail, activity, pc, manual, prev, desired, applied, scheduled, expTimer,
                   expired, bar>>

Sleep ==
    /\ awake /\ sleeps < MaxSleeps
    /\ awake' = FALSE
    /\ sleeps' = sleeps + 1
    /\ UNCHANGED <<now, wakePending, selected, live, saved, savedFail, cache, client, bridgeFail,
                   activity, pc, manual, prev, desired, applied, scheduled, expTimer, expired,
                   bar, autoStreak>>

\* NSWorkspace.didWakeNotification: Task { @MainActor in session.didWake() }.
Wake ==
    /\ ~awake
    /\ awake' = TRUE
    /\ wakePending' = TRUE
    /\ UNCHANGED <<now, sleeps, selected, live, saved, savedFail, cache, client, bridgeFail,
                   activity, pc, manual, prev, desired, applied, scheduled, expTimer, expired,
                   bar, autoStreak>>

\* refresh(manual:): guard canRefresh; begin(.refreshing); a missing worker
\* or an automatic Telenet refresh goes through restoreAndPerform.
StartRefresh(isManual) ==
    /\ Begin("refreshing", IF ~client \/ (~isManual /\ Telenet(selected)) THEN "restore" ELSE "perform")
    /\ manual' = isManual

\* didWake: idle, connected, nextRefreshAt <= now -> refresh(manual: false).
DidWake ==
    /\ wakePending
    /\ wakePending' = FALSE
    /\ IF activity = "idle" /\ live.conn /\ live.next # None /\ live.next <= now /\ CanRefresh
       THEN StartRefresh(FALSE)
       ELSE UNCHANGED <<activity, pc, manual, scheduled>>
    /\ UNCHANGED <<now, awake, sleeps, selected, live, saved, savedFail, cache, client, bridgeFail,
                   prev, desired, applied, expTimer, expired, bar, autoStreak>>

\* scheduledRefresh: sleepUntil(deadline); guard isCurrent; refresh(manual: false).
RefreshTimer ==
    /\ awake /\ scheduled # None /\ scheduled <= now
    /\ IF CanRefresh
       THEN StartRefresh(FALSE) /\ autoStreak' = Min(autoStreak + 1, 2)
       ELSE scheduled' = None /\ UNCHANGED <<activity, pc, manual, autoStreak>>
    /\ UNCHANGED <<now, awake, sleeps, wakePending, selected, live, saved, savedFail, cache,
                   client, bridgeFail, prev, desired, applied, expTimer, expired, bar>>

\* scheduledExpiry: sleepUntil(expiry); guard revision, not stopped;
\* allowanceExpired = true; onPresentationChange.
ExpiryTimer ==
    /\ awake /\ expTimer # None /\ expTimer <= now
    /\ expTimer' = None
    /\ IF activity # "stopped"
       THEN expired' = TRUE /\ bar' = Draw(live, TRUE)
       ELSE UNCHANGED <<expired, bar>>
    /\ UNCHANGED <<now, awake, sleeps, wakePending, selected, live, saved, savedFail, cache,
                   client, bridgeFail, activity, pc, manual, prev, desired, applied, scheduled,
                   autoStreak>>

-----------------------------------------------------------------------------
(* User actions.                                                           *)

UserRefresh ==
    /\ actions < MaxActions /\ actions' = actions + 1
    /\ CanRefresh
    /\ StartRefresh(TRUE)
    /\ autoStreak' = 0
    /\ UNCHANGED <<now, awake, sleeps, wakePending, selected, live, saved, savedFail, cache,
                   client, bridgeFail, prev, desired, applied, expTimer, expired, bar>>

\* refreshInterval didSet: save it, configureIfIdle().
UserInterval(i) ==
    /\ actions < MaxActions /\ actions' = actions + 1
    /\ i # desired /\ activity # "stopped"
    /\ desired' = i
    /\ autoStreak' = 0
    /\ IF activity = "idle" /\ client /\ applied # i
       THEN Begin("configuring", "configure")
       ELSE UNCHANGED <<activity, pc, scheduled>>
    /\ UNCHANGED <<now, awake, sleeps, wakePending, selected, live, saved, savedFail, cache,
                   client, bridgeFail, manual, prev, applied, expTimer, expired, bar>>

\* selectAccount(key): save the shown state and failure, begin(.switching),
\* drop the worker, show the saved state of key, scheduleExpiry, redraw.
UserSelect(k) ==
    /\ actions < MaxActions /\ actions' = actions + 1
    /\ k # selected
    /\ activity \notin {"connecting", "switching", "stopped"}
    /\ saved' = [saved EXCEPT ![selected] = live]
    /\ savedFail' = [savedFail EXCEPT ![selected] = bridgeFail]
    /\ Begin("switching", "persist")
    /\ prev' = selected
    /\ selected' = k
    /\ client' = FALSE
    /\ live' = saved[k]
    /\ bridgeFail' = savedFail[k]
    /\ expTimer' = Arm(saved[k])
    /\ expired' = FALSE
    /\ bar' = Draw(saved[k], FALSE)
    /\ autoStreak' = 0
    /\ UNCHANGED <<now, awake, sleeps, wakePending, cache, manual, desired, applied>>

\* connect(adding: false): begin(.connecting), drop the worker, empty
\* liveState, bridgeFailure = nil, scheduleExpiry, redraw.
UserReconnect ==
    /\ actions < MaxActions /\ actions' = actions + 1
    /\ activity \notin {"connecting", "switching", "stopped"}
    /\ Begin("connecting", "connect")
    /\ client' = FALSE
    /\ live' = Empty
    /\ bridgeFail' = FALSE
    /\ expTimer' = None
    /\ expired' = FALSE
    /\ bar' = Draw(Empty, FALSE)
    /\ autoStreak' = 0
    /\ UNCHANGED <<now, awake, sleeps, wakePending, selected, saved, savedFail, cache, manual,
                   prev, desired, applied>>

\* stop(): begin(.stopped), cancelExpiry, drop the worker (applicationShouldTerminate).
UserStop ==
    /\ activity # "stopped"
    /\ Begin("stopped", "none")
    /\ client' = FALSE
    /\ expTimer' = None
    /\ UNCHANGED <<now, awake, sleeps, wakePending, selected, live, saved, savedFail, cache,
                   bridgeFail, manual, prev, desired, applied, expired, bar, autoStreak>>

\* pumpOptional's catch: an optional read's bridge call threw; client = nil,
\* shut it down. No bridgeFailure, the refresh timer stays.
OptionalFails ==
    /\ actions < MaxActions /\ actions' = actions + 1
    /\ activity = "idle" /\ live.conn /\ client
    /\ client' = FALSE
    /\ bar' = Draw(live, expired)
    /\ UNCHANGED <<now, awake, sleeps, wakePending, selected, live, saved, savedFail, cache,
                   bridgeFail, activity, pc, manual, prev, desired, applied, scheduled, expTimer,
                   expired, autoStreak>>

-----------------------------------------------------------------------------
(* Operation steps (current operation only).                              *)

Rest == <<now, awake, sleeps, wakePending, autoStreak>>

\* selectAccount task: await accountDirectory.select(key). The catch
\* (AppSession.swift:785-789) puts the previous account and its saved state
\* back, calls scheduleExpiry (re-arms the timer and clears allowanceExpired
\* for the restored state, #57 fixed in #59), then failWorker redraws.
\* Mutants formal/mutants/RefreshSchedule/SelectFailure*.cfg drop it.
Persist ==
    /\ pc = "persist"
    /\ \/ /\ pc' = "restore"
          /\ manual' = FALSE
          /\ UNCHANGED <<selected, live, bridgeFail, bar, expTimer, expired>>
       \/ /\ PersistCanFail
          /\ selected' = prev
          /\ live' = saved[prev]
          /\ expTimer' = IF FaithfulSelectFailureArmsExpiry THEN Arm(saved[prev]) ELSE expTimer
          /\ expired' = IF FaithfulSelectFailureArmsExpiry THEN FALSE ELSE expired
          /\ FailWorkerWith(saved[prev], expired')
          /\ UNCHANGED manual
    /\ UNCHANGED <<saved, savedFail, cache, client, activity, prev, desired, applied, scheduled>>
    /\ UNCHANGED Rest

\* failWorker after `await failed?.shutdown()`: client = nil, idle. No
\* finish(), so no refresh timer: the bridge failure is shown instead.
FailShutdown ==
    /\ pc = "failShutdown"
    /\ client' = FALSE
    /\ activity' = "idle"
    /\ pc' = "none"
    /\ UNCHANGED <<selected, live, saved, savedFail, cache, bridgeFail, manual, prev, desired,
                   applied, scheduled, expTimer, expired, bar>>
    /\ UNCHANGED Rest

\* restoreAndPerform: restorationClient (a new worker starts at five
\* minutes), then applyInterval, then .restore.
RestoreStart ==
    /\ pc = "restore"
    /\ client' = TRUE
    /\ applied' = IF client THEN applied ELSE DefaultInterval
    /\ pc' = "restoreCfg"
    /\ UNCHANGED <<selected, live, saved, savedFail, cache, bridgeFail, activity, manual, prev,
                   desired, scheduled, expTimer, expired, bar>>
    /\ UNCHANGED Rest

\* applyInterval: while appliedInterval != refreshInterval, await
\* request(.configure(desired)); appliedInterval = desired; publish the reply
\* if it is for the shown connection (a fresh worker before .restore has no
\* connection yet: no publish). A throw goes to failWorker.
ConfigureStep(step, after, publishes) ==
    /\ pc = step
    /\ IF applied = desired
       THEN /\ pc' = after
            /\ UNCHANGED <<live, saved, cache, bridgeFail, applied, expTimer, expired, bar>>
       ELSE \/ /\ \E r \in ConfigureReplies(cache[selected]) :
                    /\ cache' = [cache EXCEPT ![selected] = r]
                    /\ IF publishes THEN Publish(r)
                       ELSE UNCHANGED <<live, saved, bridgeFail, expTimer, expired, bar>>
               /\ applied' = desired
               /\ pc' = step
            \/ /\ FailWorker(live)
               /\ UNCHANGED <<live, saved, cache, applied, expTimer, expired>>
    /\ UNCHANGED <<selected, savedFail, client, activity, manual, prev, desired, scheduled>>
    /\ UNCHANGED Rest

\* restoreAndPerform after `await client.request(.restore)`: publish; not
\* connected -> finish; a refresh waits for a future deadline (Telenet when
\* automatic, Vikings after a failure) -> finish; else perform.
RestoreReply ==
    /\ pc = "restoreReq"
    /\ \/ \E r \in RestoreReplies(cache[selected]) :
            /\ cache' = [cache EXCEPT ![selected] = r]
            /\ live' = r
            /\ saved' = [saved EXCEPT ![selected] = r]
            /\ bridgeFail' = FALSE
            /\ expTimer' = IF FaithfulPublishArmsExpiry THEN Arm(r) ELSE expTimer
            /\ expired' = IF FaithfulExpiryReset THEN FALSE ELSE expired
            /\ LET wait == IF Telenet(selected) THEN ~manual ELSE r.fail
               IN IF ~r.conn \/ (wait /\ r.next # None /\ now < r.next)
                  THEN /\ UNCHANGED applied
                       /\ Finish(r, IF FaithfulExpiryReset THEN FALSE ELSE expired)
                  ELSE /\ activity' = "refreshing"
                       /\ pc' = "perform"
                       /\ bar' = Draw(r, expired')
                       /\ UNCHANGED <<applied, scheduled>>
       \/ /\ FailWorker(live)
          /\ UNCHANGED <<cache, live, saved, expTimer, expired, activity, applied, scheduled>>
    /\ UNCHANGED <<selected, savedFail, client, manual, prev, desired>>
    /\ UNCHANGED Rest

\* perform(.refresh): await client.request; publish; then applyInterval.
Perform ==
    /\ pc = "perform"
    /\ \/ \E r \in RefreshReplies(cache[selected]) :
            /\ cache' = [cache EXCEPT ![selected] = r]
            /\ Publish(r)
            /\ pc' = "performCfg"
       \/ /\ FailWorker(live)
          /\ UNCHANGED <<cache, live, saved, expTimer, expired>>
    /\ UNCHANGED <<selected, savedFail, client, activity, manual, prev, desired, applied, scheduled>>
    /\ UNCHANGED Rest

\* After applyInterval in perform / configureIfIdle: finish().
Done ==
    /\ pc = "done"
    /\ Finish(live, expired)
    /\ UNCHANGED <<selected, live, saved, savedFail, cache, client, bridgeFail, manual, prev,
                   desired, applied, expTimer, expired>>
    /\ UNCHANGED Rest

\* performConnection (reconnect): await connector.connect. Success: empty
\* liveState (no scheduleExpiry), restoreAndPerform with the new connection.
\* failConnection: empty liveState, bridgeFailure = the failure, finish().
Connect ==
    /\ pc = "connect"
    /\ \/ /\ cache' = [cache EXCEPT ![selected] = [Empty EXCEPT !.conn = TRUE]]
          /\ pc' = "restore"
          /\ manual' = FALSE
          /\ UNCHANGED <<bridgeFail, activity, scheduled, bar>>
       \/ /\ bridgeFail' = TRUE
          /\ Finish(live, expired)
          /\ UNCHANGED <<cache, manual>>
    /\ UNCHANGED <<selected, live, saved, savedFail, client, prev, desired, applied, expTimer, expired>>
    /\ UNCHANGED Rest

OpStep ==
    \/ Persist \/ FailShutdown \/ RestoreStart \/ RestoreReply \/ Perform \/ Done \/ Connect
    \/ ConfigureStep("restoreCfg", "restoreReq", FALSE)
    \/ ConfigureStep("performCfg", "done", TRUE)
    \/ ConfigureStep("configure", "done", TRUE)

\* Bounds exhausted or the app quit: nothing else happens (keeps TLC's
\* deadlock check quiet).
Halted == UNCHANGED vars

UserStep ==
    \/ UserRefresh \/ \E i \in Intervals : UserInterval(i)
    \/ \E k \in A : UserSelect(k)
    \/ UserReconnect \/ OptionalFails

Next ==
    \/ Halted \/ UserStep
    \/ /\ \/ Tick \/ Sleep \/ Wake \/ DidWake \/ RefreshTimer \/ ExpiryTimer \/ UserStop \/ OpStep
       /\ UNCHANGED actions

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules.                                                                  *)

TypeOK ==
    /\ now \in Times /\ live \in Data /\ cache \in [A -> Data] /\ saved \in [A -> Data]
    /\ scheduled \in {None} \cup Times \cup {Far} /\ expTimer \in {None} \cup Times

\* No silent stall: an idle, connected app without a bridge failure has a
\* refresh timer for the shown nextRefreshAt. Harm: the menu keeps showing
\* old usage as current and never refreshes.
NoSilentStall ==
    (activity = "idle" /\ live.conn /\ ~bridgeFail)
        => (live.next # None /\ scheduled = live.next)

\* No refresh storm: between two ticks (and with no user action) the timer
\* starts at most one automatic refresh. Harm: a tight request loop against
\* the provider and a busy worker.
NoRefreshStorm == autoStreak <= 1

\* An interval change is applied: an idle app with a worker has told it the
\* current setting. Harm: the chosen refresh interval is silently ignored.
IntervalApplied == (activity = "idle" /\ client) => applied = desired

\* The menu bar never keeps an expired allowance on screen: once the drawn
\* data's expiresAt passed, a due expiry timer will redraw it. Harm: the
\* menu bar shows remaining GB of a bundle that has ended.
ExpiredNotShown ==
    (activity # "stopped" /\ bar.allow /\ bar.exp <= now)
        => (expTimer # None /\ expTimer <= now)

\* allowanceExpired only describes the shown data. Harm: a valid allowance
\* is shown as Unavailable.
ExpiredFlagMatchesShown == (expired /\ live.has) => live.exp <= now

=============================================================================
