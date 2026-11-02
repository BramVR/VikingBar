-------------------------- MODULE AccountSwitching --------------------------
(***************************************************************************)
(* The app's account switching: what the menu shows while the user         *)
(* switches accounts, adds or reconnects one, cancels, and while late      *)
(* replies from old workers and optional reads arrive.                     *)
(*                                                                         *)
(* Code (Sources/VikingBar):                                               *)
(*   AppSession.swift          begin, isCurrent, perform, publish,         *)
(*                             failWorker, connect, performConnection,     *)
(*                             failConnection, restorePreviousWorker,      *)
(*                             cancelConnection, restoreAndPerform,        *)
(*                             reconcileSelection, selectAccount           *)
(*   AppSessionOptional.swift  interruptOptional, pumpOptional             *)
(* Code (Sources/VikingBarCore):                                           *)
(*   LiveModels.swift          mergePoints (same account and connection)   *)
(*                                                                         *)
(* AppSession is @MainActor: code between two awaits runs as one step. An  *)
(* operation Task keeps running after begin() cancels it, so every old     *)
(* task stays in the model and can resume at any later time. A worker      *)
(* reply is computed in one step (the worker answers for its own account   *)
(* and current connection) and consumed in a later one (the task resumes). *)
(* Account a starts selected and connected; b is the account being added   *)
(* or switched to. The CLI can reconnect any account or change the stored  *)
(* selection at any time.                                                  *)
(*                                                                         *)
(* Faithful* constants are TRUE for the code as written; each mutant in    *)
(* formal/mutants/AccountSwitching turns one off.                          *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxOps,           \* begin() calls explored
    MaxReconnects,    \* new connection incarnations explored
    \* perform/restoreAndPerform/... : guard self.isCurrent(intent) after each await.
    FaithfulCurrentIntentGuard,
    \* perform/publish: guard state.account?.key == self.selectedAccount.
    FaithfulAccountKeyGuard,
    \* pumpOptional: guard revision == optionalRevision, same account and
    \* connection, idle; and mergePoints' own account/connection check.
    FaithfulOptionalGuard,
    \* performConnection/cancelConnection: restoreAddedSelection after a
    \* cancelled addition.
    FaithfulRestoreAddedSelection

A == {"a", "b"}
None == "none"
Empty == [acct |-> None, conn |-> 0, pts |-> 0]   \* LiveSessionState()

VARIABLES
    selected,    \* selectedAccount
    catalog,     \* selection stored in accounts-v1.json (shared with the CLI)
    live,        \* liveState: whose data, which connection, which connection's points
    saved,       \* savedAccounts
    client,      \* account of the current worker, or None
    activity,
    gen,         \* generation (intent of the current operation)
    rev,         \* optionalRevision
    conn,        \* current connection incarnation at each account
    reconnects,
    op,          \* op[i]: operation with intent i (old ones keep running)
    opt,         \* the one optional read in flight, or a "none" record
    cliSelected  \* history: the CLI changed the stored selection

vars == <<selected, catalog, live, saved, client, activity, gen, rev, conn, reconnects, op, opt, cliSelected>>

\* Connection ids are UUIDs, unique across accounts: b's start at 11.
Conn(k) == IF k = "a" THEN conn[k] ELSE 10 + conn[k]
SameConn(x, y) == x.acct = y.acct /\ x.conn = y.conn

NoOp == [pc |-> "done", kind |-> "none", worker |-> None, reply |-> Empty,
         prev |-> None, prior |-> Empty, target |-> None]
NoOpt == [pc |-> "none", rev |-> 0, worker |-> None, conn |-> Empty, reply |-> Empty]

Init ==
    /\ selected = "a"
    /\ catalog = "a"
    /\ live = [acct |-> "a", conn |-> 1, pts |-> 1]
    /\ saved = [k \in A |-> Empty]
    /\ client = "a"
    /\ activity = "idle"
    /\ gen = 0
    /\ rev = 0
    /\ conn = [k \in A |-> 1]
    /\ reconnects = 0
    /\ op = [i \in 1..MaxOps |-> NoOp]
    /\ opt = NoOpt
    /\ cliSelected = FALSE

Connected == live.acct # None
Current(i) == ~FaithfulCurrentIntentGuard \/ gen = i

\* begin(activity): interruptOptional (revision += 1, cancel the optional
\* read), generation += 1, cancel the old operation.
Begin(act, o) ==
    /\ gen < MaxOps
    /\ gen' = gen + 1
    /\ rev' = rev + 1
    /\ activity' = act
    /\ op' = [op EXCEPT ![gen + 1] = o]

Set(i, field, value) == op' = [op EXCEPT ![i][field] = value]
Go(i, pc) == op' = [op EXCEPT ![i].pc = pc]

\* What a worker for account k returns now: its account, its current
\* connection, and points of that connection or none yet.
Reply(k) == {[acct |-> k, conn |-> Conn(k), pts |-> p] : p \in {0, Conn(k)}}

\* publish(state): drop a reply for another account; keep the shown points
\* when the connection is the same (mergePoints), else take the reply's.
Publish(r) ==
    IF FaithfulAccountKeyGuard /\ r.acct # selected
    THEN UNCHANGED <<live, saved>>
    ELSE LET shown == IF SameConn(r, live) THEN [r EXCEPT !.pts = live.pts] ELSE r
         IN /\ live' = shown
            /\ saved' = [saved EXCEPT ![selected] = shown]

Finish(i) == activity' = "idle" /\ Go(i, "done")

-----------------------------------------------------------------------------
(* User actions (main actor, synchronous parts).                           *)

\* refresh(): begin(.refreshing); the task first reconciles the selection.
UserRefresh ==
    /\ activity = "idle"
    /\ Begin("refreshing", [NoOp EXCEPT !.pc = "reconcile", !.kind = "refresh"])
    /\ UNCHANGED <<selected, catalog, live, saved, client, conn, reconnects, opt>>

\* selectAccount(key): save the shown state, begin(.switching), drop the
\* worker, show the saved state of the new account; the task persists it.
\* The menu calls selectAccount(key) with persist: true; persist: false
\* only comes from reconcileSelection (see Reconcile).
UserSelect(k) ==
    /\ k # selected
    /\ activity \notin {"connecting", "switching"}
    /\ saved' = [saved EXCEPT ![selected] = live]
    /\ Begin("switching", [NoOp EXCEPT !.pc = "persistSelect",
                                       !.kind = "select", !.prev = selected])
    /\ client' = None
    /\ selected' = k
    /\ live' = saved'[k]
    /\ UNCHANGED <<catalog, conn, reconnects, opt>>

\* connect(input:adding:): begin(.connecting), drop the worker; reconnect
\* clears the shown state, adding keeps it while the new account connects.
UserConnect(adding) ==
    /\ activity \notin {"connecting", "switching"}
    /\ adding => selected = "a"
    /\ Begin("connecting", [NoOp EXCEPT !.pc = "connector", !.kind = IF adding THEN "add" ELSE "reconnect",
                                        !.prev = selected, !.prior = live,
                                        !.target = IF adding THEN "b" ELSE selected])
    /\ client' = None
    /\ live' = IF adding THEN live ELSE Empty
    /\ UNCHANGED <<selected, catalog, saved, conn, reconnects, opt>>

\* cancelConnection: begin(.connecting) again, then restore the previous
\* account if this was an addition.
UserCancel ==
    /\ activity = "connecting"
    /\ gen > 0 /\ op[gen].kind \in {"add", "reconnect"} /\ op[gen].pc # "done"
    /\ LET old == op[gen] IN
       Begin("connecting", [NoOp EXCEPT !.pc = IF old.kind = "add" THEN "cancelRestore" ELSE "cancelDone",
                                        !.kind = "cancel", !.prev = old.prev, !.prior = old.prior,
                                        !.target = old.target])
    /\ client' = None
    /\ UNCHANGED <<selected, catalog, live, saved, conn, reconnects, opt>>

-----------------------------------------------------------------------------
(* Operation task steps. Each resumes after one await.                     *)

\* reconcileSelection: await the catalog snapshot; a different stored
\* selection switches to it (selectAccount(persist: false)) and stops here.
Reconcile(i) ==
    /\ op[i].pc = "reconcile"
    /\ IF ~Current(i) THEN Go(i, "done") /\ UNCHANGED <<selected, live, saved, client, activity, gen, rev>>
       ELSE IF catalog # selected
            THEN /\ selected' = catalog
                 /\ saved' = [saved EXCEPT ![selected] = live]
                 /\ live' = saved'[catalog]
                 /\ client' = None
                 /\ gen < MaxOps
                 /\ gen' = gen + 1
                 /\ rev' = rev + 1
                 /\ activity' = "switching"
                 /\ op' = [op EXCEPT ![i].pc = "done",
                                     ![gen + 1] = [NoOp EXCEPT !.pc = "restore", !.kind = "select",
                                                               !.prev = selected]]
            ELSE /\ Go(i, IF client = None THEN "restore" ELSE "refreshRequest")
                 /\ UNCHANGED <<selected, live, saved, client, activity, gen, rev>>
    /\ UNCHANGED <<catalog, conn, reconnects, opt>>

\* selectAccount task: await accountDirectory.select(key). Failure goes back
\* to the previous account and fails the worker.
PersistSelect(i) ==
    /\ op[i].pc = "persistSelect"
    /\ IF ~Current(i) THEN Go(i, "done") /\ UNCHANGED <<catalog, selected, live, activity>>
       ELSE \/ /\ catalog' = selected
               /\ Go(i, "restore")
               /\ UNCHANGED <<selected, live, activity>>
            \/ /\ selected' = op[i].prev
               /\ live' = saved[op[i].prev]
               /\ activity' = "idle"
               /\ Go(i, "done")
               /\ UNCHANGED catalog
    /\ UNCHANGED <<saved, client, gen, rev, conn, reconnects, opt>>

\* restoreAndPerform: client = clientFactory(selectedAccount); await
\* .restore. The worker answers for the account it was made for.
RestoreRequest(i) ==
    /\ op[i].pc = "restore"
    /\ IF ~Current(i) THEN Go(i, "done") /\ UNCHANGED client
       ELSE /\ client' = IF client = None THEN selected ELSE client
            /\ \E r \in Reply(IF client = None THEN selected ELSE client) :
                  op' = [op EXCEPT ![i].pc = "restoreAnswer", ![i].worker = client',
                                   ![i].reply = r]
    /\ UNCHANGED <<selected, catalog, live, saved, activity, gen, rev, conn, reconnects, opt>>

RestoreResume(i) ==
    /\ op[i].pc = "restoreAnswer"
    /\ IF ~Current(i) THEN Go(i, "done") /\ UNCHANGED <<live, saved, activity>>
       ELSE /\ Publish(op[i].reply)
            /\ IF op[i].kind = "restorePrevious" THEN Finish(i)
               ELSE Go(i, "refreshRequest") /\ UNCHANGED activity
    /\ UNCHANGED <<selected, catalog, client, gen, rev, conn, reconnects, opt>>

\* perform(.refresh): await client.request.
RefreshRequest(i) ==
    /\ op[i].pc = "refreshRequest"
    /\ IF ~Current(i) \/ client = None THEN Go(i, "done")
       ELSE \E r \in Reply(client) :
               op' = [op EXCEPT ![i].pc = "refreshAnswer", ![i].worker = client, ![i].reply = r]
    /\ UNCHANGED <<selected, catalog, live, saved, client, activity, gen, rev, conn, reconnects, opt>>

RefreshResume(i) ==
    /\ op[i].pc = "refreshAnswer"
    /\ IF ~Current(i) THEN Go(i, "done") /\ UNCHANGED <<live, saved, activity>>
       ELSE Publish(op[i].reply) /\ Finish(i)
    /\ UNCHANGED <<selected, catalog, client, gen, rev, conn, reconnects, opt>>

\* performConnection: await previous.shutdown, connectionTarget, and
\* connector.connect. Success creates a new connection for the target.
Connector(i) ==
    /\ op[i].pc = "connector"
    /\ IF ~Current(i) THEN Go(i, "done") /\ UNCHANGED <<conn, reconnects>>
       ELSE \/ /\ reconnects < MaxReconnects
               /\ reconnects' = reconnects + 1
               /\ conn' = [conn EXCEPT ![op[i].target] = @ + 1]
               /\ Go(i, IF op[i].kind = "add" THEN "addSelect" ELSE "connected")
            \/ Go(i, "connectFailed") /\ UNCHANGED <<conn, reconnects>>
    /\ UNCHANGED <<selected, catalog, live, saved, client, activity, gen, rev, opt>>

\* adding: await accountDirectory.select(target). If the intent is stale,
\* restoreAddedSelection puts the previous selection back.
AddSelect(i) ==
    /\ op[i].pc = "addSelect"
    /\ catalog' = op[i].target
    /\ IF ~Current(i)
       THEN op' = [op EXCEPT ![i].pc = "restoreAdded"]
       ELSE Go(i, "connected")
    /\ UNCHANGED <<selected, live, saved, client, activity, gen, rev, conn, reconnects, opt>>

\* restoreAddedSelection: select(account, replacing: target) only replaces
\* the stored selection while it is still the target.
RestoreAdded(i) ==
    /\ op[i].pc = "restoreAdded"
    /\ catalog' = IF catalog = op[i].target /\ FaithfulRestoreAddedSelection THEN op[i].prev ELSE catalog
    /\ Go(i, "done")
    /\ UNCHANGED <<selected, live, saved, client, activity, gen, rev, conn, reconnects, opt>>

\* Success: savedAccounts[account] = prior state; select target; empty state;
\* restoreAndPerform(.refresh).
Connected_(i) ==
    /\ op[i].pc = "connected"
    /\ IF ~Current(i) THEN Go(i, "done") /\ UNCHANGED <<saved, selected, live>>
       ELSE /\ saved' = [saved EXCEPT ![op[i].prev] = op[i].prior]
            /\ selected' = op[i].target
            /\ live' = Empty
            /\ Go(i, "restore")
    /\ UNCHANGED <<catalog, client, activity, gen, rev, conn, reconnects, opt>>

\* failConnection: adding shows the prior state again and restores the
\* previous worker; a reconnect shows the empty state.
ConnectFailed(i) ==
    /\ op[i].pc = "connectFailed"
    /\ IF ~Current(i) THEN Go(i, "done") /\ UNCHANGED <<selected, live, activity>>
       ELSE /\ selected' = op[i].prev
            /\ live' = IF op[i].kind = "add" THEN op[i].prior ELSE Empty
            /\ IF op[i].kind = "add"
               THEN op' = [op EXCEPT ![i].pc = "restore", ![i].kind = "restorePrevious"]
                    /\ UNCHANGED activity
               ELSE Finish(i)
    /\ UNCHANGED <<catalog, saved, client, gen, rev, conn, reconnects, opt>>

\* cancelConnection after awaiting the old operation: restoreAddedSelection,
\* then selectedAccount = previous, liveState = prior, restorePreviousWorker.
CancelRestore(i) ==
    /\ op[i].pc = "cancelRestore"
    /\ \A j \in 1..MaxOps : j < i => op[j].pc = "done"      \* await operation?.value
    /\ catalog' = IF catalog = op[i].target /\ FaithfulRestoreAddedSelection THEN op[i].prev ELSE catalog
    /\ IF ~Current(i) THEN Go(i, "done") /\ UNCHANGED <<selected, live>>
       ELSE /\ selected' = op[i].prev
            /\ live' = op[i].prior
            /\ op' = [op EXCEPT ![i].pc = "restore", ![i].kind = "restorePrevious"]
    /\ UNCHANGED <<saved, client, activity, gen, rev, conn, reconnects, opt>>

CancelDone(i) ==
    /\ op[i].pc = "cancelDone"
    /\ \A j \in 1..MaxOps : j < i => op[j].pc = "done"
    /\ IF ~Current(i) THEN Go(i, "done") /\ UNCHANGED activity ELSE Finish(i)
    /\ UNCHANGED <<selected, catalog, live, saved, client, gen, rev, conn, reconnects, opt>>

-----------------------------------------------------------------------------
(* Optional reads (points; history and invoices behave the same).          *)

\* pumpOptional: only when idle and connected; captures revision, worker,
\* and the shown connection, then awaits client.request.
OptionalStart ==
    /\ opt.pc = "none"
    /\ activity = "idle" /\ Connected /\ client # None
    /\ \E r \in Reply(client) :
          opt' = [pc |-> "answered", rev |-> rev, worker |-> client, conn |-> live, reply |-> r]
    /\ UNCHANGED <<selected, catalog, live, saved, client, activity, gen, rev, conn, reconnects, op>>

\* Resume: publish only for the same revision, account and connection while
\* idle; mergePoints then copies the reply's points.
OptionalResume ==
    /\ opt.pc = "answered"
    /\ LET r == opt.reply
           ok == IF FaithfulOptionalGuard
                 THEN opt.rev = rev /\ r.acct = live.acct /\ r.conn = opt.conn.conn
                      /\ SameConn(opt.conn, live) /\ activity = "idle"
                 ELSE TRUE
       IN live' = IF ok /\ (~FaithfulOptionalGuard \/ SameConn(r, live))
                  THEN [live EXCEPT !.pts = r.conn] ELSE live
    /\ opt' = NoOpt
    /\ UNCHANGED <<selected, catalog, saved, client, activity, gen, rev, conn, reconnects, op>>

-----------------------------------------------------------------------------
(* The CLI, sharing Keychain and the catalog.                              *)

CliReconnect(k) ==
    /\ reconnects < MaxReconnects
    /\ reconnects' = reconnects + 1
    /\ conn' = [conn EXCEPT ![k] = @ + 1]
    /\ UNCHANGED <<selected, catalog, live, saved, client, activity, gen, rev, op, opt>>

CliSelect(k) ==
    /\ catalog' = k
    /\ cliSelected' = TRUE
    /\ UNCHANGED <<selected, live, saved, client, activity, gen, rev, conn, reconnects, op, opt>>

AppStep ==
    \/ UserRefresh \/ UserCancel
    \/ \E k \in A : UserSelect(k)
    \/ \E adding \in BOOLEAN : UserConnect(adding)
    \/ \E i \in 1..MaxOps :
        \/ Reconcile(i) \/ PersistSelect(i) \/ RestoreRequest(i) \/ RestoreResume(i)
        \/ RefreshRequest(i) \/ RefreshResume(i) \/ Connector(i) \/ AddSelect(i)
        \/ RestoreAdded(i) \/ Connected_(i) \/ ConnectFailed(i) \/ CancelRestore(i) \/ CancelDone(i)
    \/ OptionalStart \/ OptionalResume
    \/ \E k \in A : CliReconnect(k)

Next ==
    \/ AppStep /\ UNCHANGED cliSelected
    \/ \E k \in A : CliSelect(k)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules.                                                                  *)

\* The menu shows only the selected account's data. Harm: one customer's
\* usage, SIM names, or bills appear under another account.
ShowsSelectedAccount == live.acct \in {None, selected}

\* A remembered state belongs to the account it is remembered for. Harm: a
\* later switch shows another account's data.
SavedStatesSiloed == \A k \in A : saved[k].acct \in {None, k}

\* Points shown come from the shown connection. Harm: after a reconnect
\* (possibly another login) the previous customer's points stay visible.
PointsMatchConnection == live.pts \in {0, live.conn}

\* Once the app settles, the stored selection is the account it shows,
\* unless the CLI changed it. Harm: the next launch or CLI call opens
\* another account than the one the user picked, or a cancelled addition.
SelectionPersisted ==
    ((activity = "idle" /\ \A i \in 1..MaxOps : op[i].pc = "done") /\ ~cliSelected)
        => catalog = selected

=============================================================================
