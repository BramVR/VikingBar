---------------------------- MODULE OptionalQueue ----------------------------
(***************************************************************************)
(* The app's optional-request queue (points, bills, invoice PDF, bank      *)
(* transfer QR) and the Bills view's QR review, against one account       *)
(* worker process per client.                                              *)
(*                                                                         *)
(* Code (Sources/VikingBar):                                               *)
(*   AppSessionOptional.swift  loadInvoices, reviewPayment,                *)
(*                             clearPaymentReview, clearPaymentExpiry,     *)
(*                             schedulePaymentExpiry, openInvoice,         *)
(*                             enqueueOptional, interruptOptional,         *)
(*                             pumpOptional, publishOptional               *)
(*   AppSession.swift          begin, finish, perform, publish,            *)
(*                             failWorker, configureIfIdle, applyInterval, *)
(*                             restoreAndPerform, selectAccount, refresh   *)
(*   InvoicesView.swift        paymentExpanded, select, collapsePayment,   *)
(*                             .task(id: canLoadInvoices), .onDisappear    *)
(*   SessionProcessClient.swift  replies carry the worker state even when  *)
(*                             the command failed; a dead process throws   *)
(* Code (Sources/VikingBarCore, Sources/VikingBarCLI):                     *)
(*   SessionCommands.swift     SessionCommandQueue: commands run one at a  *)
(*                             time; cancel acts on arrival and cancels    *)
(*                             queued commands, which then only report     *)
(*   VikingSession*.swift      run (non-optional clears paymentReview),    *)
(*                             cancel, configure (keeps paymentReview),    *)
(*                             fetchInvoices, fetchPaymentReview,          *)
(*                             renderPayment, fetchInvoicePDF              *)
(*   ProviderAccounts.swift    perform: clearInvoiceDocument every command *)
(*   LiveModels.swift          mergeInvoices (same account + connection)   *)
(*   InvoicePayment.swift      QR lifetime (300 s = Lifetime ticks)        *)
(*                                                                         *)
(* AppSession is @MainActor: code between two awaits is one step. The      *)
(* whole app is one record `s` so helpers (Interrupt, Pump, Begin, Finish) *)
(* compose like the Swift calls do. Optional Tasks cancelled by            *)
(* interruptOptional keep running in `s.opts` until they check. Only the   *)
(* current operation Task is kept: older ones exit at their next           *)
(* isCurrent check (AccountSwitching model), but their commands stay in    *)
(* the worker queue and still change worker state. Connection ids encode   *)
(* the account: a -> 1, b -> 2. Two invoices, both payable.                *)
(*                                                                         *)
(* Faithful* constants are TRUE for the code as written; each mutant in    *)
(* formal/mutants/OptionalQueue turns one off.                             *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    MaxOps,            \* begin() calls explored
    MaxOptStarts,      \* pumpOptional starts explored
    MaxWorkers,        \* worker processes started (incl. the first)
    MaxTime,           \* ticks explored
    Lifetime,          \* InvoicePaymentQRCode.lifetime in ticks
    MaxSwitches,       \* selectAccount calls
    MaxIntervalChanges,\* Settings refresh-interval changes
    MaxCrashes,        \* worker processes dying on their own
    \* Environment: the user can reach Bills and expand the QR while a
    \* configure command (local IPC, milliseconds) is in flight.
    UserBeatsConfigure,
    \* pumpOptional: guard !Task.isCancelled, revision == optionalRevision,
    \* same account and connection, activity == .idle; plus mergeInvoices'
    \* own account/connection check.
    FaithfulOptionalGuard,
    \* publishOptional(.payment): schedulePaymentExpiry(qrCode.expiresAt).
    FaithfulExpiryTimer,
    \* ProviderAccounts.perform clearInvoiceDocument + fetchInvoicePDF's
    \* invoiceDocument = nil, and publishOptional's document.invoiceID == id.
    FaithfulDocumentChecks,
    \* finish() and pumpOptional's defer call pumpOptional().
    FaithfulPumpOnSettle

Accts == {"a", "b"}
ConnOf(k) == IF k = "a" THEN 1 ELSE 2
AcctOf(c) == IF c = 1 THEN "a" ELSE "b"
Invs == {1, 2}

NoReview == [k |-> "none", inv |-> 0, conn |-> 0, exp |-> 0]
NoIntent == [k |-> "none", i |-> 0]
NoReply == [has |-> FALSE, ok |-> FALSE, conn |-> 0, review |-> NoReview, doc |-> 0]
NoOp == [pc |-> "none", gen |-> 0, sent |-> 0, old |-> 0, reply |-> NoReply]
NoOpt == [pc |-> "none", cur |-> FALSE, it |-> NoIntent, conn |-> 0, wk |-> 0, reply |-> NoReply]
NoTimer == [armed |-> FALSE, exp |-> 0]

VARIABLES
    s,       \* AppSession + InvoicesView state (one record, see Init)
    wq,      \* commands written to worker processes, in order
    wv,      \* worker process state: alive, account, paymentReview, invoiceDocument
    nw,      \* workers started
    now,
    crashes,
    badPdf   \* history: a PDF opened that is not the requested invoice of the shown connection

vars == <<s, wq, wv, nw, now, crashes, badPdf>>

Init ==
    /\ s = [activity |-> "idle", gen |-> 0, op |-> NoOp,
            selected |-> "a", liveConn |-> 1, saved |-> [k \in Accts |-> IF k = "a" THEN 1 ELSE 0],
            review |-> NoReview,            \* liveState.paymentReview
            timer |-> NoTimer,              \* paymentExpiry (paymentRevision folded in)
            client |-> 1, bridgeFail |-> FALSE,
            desired |-> 1, applied |-> 1, changes |-> 0, switches |-> 0,
            pending |-> << >>, active |-> NoIntent,
            curOpt |-> 0, nextOpt |-> 1,    \* optionalOperation, next Task slot
            opts |-> [n \in 1..MaxOptStarts |-> NoOpt],
            cancelQ |-> << >>, cancelInFlight |-> FALSE,   \* optionalCancellation chain
            bills |-> FALSE, expanded |-> FALSE, selInv |-> 0, lastCan |-> FALSE, taskDue |-> FALSE]
    /\ wq = << >>
    /\ wv = [w \in 1..MaxWorkers |-> [alive |-> w = 1, acct |-> "a", review |-> NoReview, doc |-> 0]]
    /\ nw = 1
    /\ now = 0
    /\ crashes = 0
    /\ badPdf = FALSE

-----------------------------------------------------------------------------
(* Derived app state.                                                      *)

Connected(x) == x.liveConn # 0
IsInvoice(it) == it.k \in {"inv", "pdf", "pay"}
InSeq(q, e) == \E j \in 1..Len(q) : q[j] = e
\* isLoadingInvoices
Loading(x) == IsInvoice(x.active) \/ \E j \in 1..Len(x.pending) : IsInvoice(x.pending[j])
\* canSelectAccountData && client != nil
CanLoad(x) == x.activity = "idle" /\ Connected(x) /\ ~x.bridgeFail /\ x.client # 0
CancelsDone(x) == x.cancelQ = << >> /\ ~x.cancelInFlight

-----------------------------------------------------------------------------
(* Main-actor helpers, composed like the Swift calls.                      *)

\* enqueueOptional: skip if active or already pending.
Enqueue(x, it) ==
    IF x.active = it \/ InSeq(x.pending, it) THEN x
    ELSE [x EXCEPT !.pending = Append(@, it)]

\* pumpOptional: idle, connected, no optionalOperation, pending, client.
\* The Task captures revision, client and liveState.connectionID.
\* Past MaxOptStarts the step is cut off (nextOpt overflows; see Fits).
Pump(x) ==
    IF x.activity = "idle" /\ Connected(x) /\ x.curOpt = 0 /\ x.pending # << >> /\ x.client # 0
    THEN IF x.nextOpt > MaxOptStarts THEN [x EXCEPT !.nextOpt = MaxOptStarts + 2] ELSE
         LET n == x.nextOpt IN
         [x EXCEPT !.pending = Tail(@), !.active = Head(x.pending), !.curOpt = n, !.nextOpt = n + 1,
                   !.opts = [@ EXCEPT ![n] = [pc |-> "wait", cur |-> TRUE, it |-> Head(x.pending),
                                               conn |-> x.liveConn, wk |-> x.client, reply |-> NoReply]]]
    ELSE x

\* interruptOptional(clear:): clearPaymentExpiry, paymentReview = nil;
\* requeue an active points/bills read; drop PDF and payment intents;
\* revision += 1 (all running optional Tasks become stale); a cancel is
\* chained to the client only if an optional operation exists.
Interrupt(x, clear) ==
    LET a == x.active
        p1 == IF a.k \in {"pts", "inv"} /\ ~InSeq(x.pending, a) THEN <<a>> \o x.pending ELSE x.pending
        p2 == SelectSeq(p1, LAMBDA e : e.k \notin {"pdf", "pay"})
    IN [x EXCEPT !.timer = NoTimer, !.review = NoReview,
                 !.pending = IF clear THEN << >> ELSE p2,
                 !.opts = [n \in 1..MaxOptStarts |-> [@[n] EXCEPT !.cur = FALSE]],
                 !.cancelQ = IF x.curOpt # 0 /\ x.client # 0 THEN Append(@, x.client) ELSE @,
                 !.curOpt = 0, !.active = NoIntent]

\* begin(activity)
Begin(x, act, pc) ==
    LET i == Interrupt(x, act \in {"connecting", "stopped"}) IN
    [i EXCEPT !.gen = @ + 1, !.activity = act,
              !.op = [NoOp EXCEPT !.pc = pc, !.gen = x.gen + 1, !.old = x.client]]

\* finish(): idle; configureIfIdle when the interval is not applied; else
\* schedule the refresh (not modeled; AutoRefresh) and pumpOptional.
Finish(x) ==
    LET y == [x EXCEPT !.activity = "idle", !.op = NoOp] IN
    IF y.applied # y.desired /\ y.client # 0 THEN Begin(y, "configuring", "cfgWait")
    ELSE IF FaithfulPumpOnSettle THEN Pump(y) ELSE y

\* publish(state): drop another account's state; same connection keeps the
\* shown invoices but takes the worker's paymentReview
\* (mergeInvoices(includePaymentReview: false) on the incoming state);
\* another connection replaces everything and clears pendingOptional.
Publish(x, r) ==
    IF r.conn # 0 /\ AcctOf(r.conn) # x.selected THEN x
    ELSE IF r.conn = x.liveConn
         THEN [x EXCEPT !.review = r.review, !.bridgeFail = FALSE,
                        !.saved = [@ EXCEPT ![x.selected] = r.conn]]
         ELSE [x EXCEPT !.review = r.review, !.liveConn = r.conn, !.pending = << >>, !.bridgeFail = FALSE,
                        !.saved = [@ EXCEPT ![x.selected] = r.conn]]

\* failWorker: bridgeFailure = .unavailable, await shutdown, client = nil,
\* idle. pendingOptional is kept.
FailWorker(x) == [x EXCEPT !.bridgeFail = TRUE, !.client = 0, !.activity = "idle", !.op = NoOp]

\* A dead process keeps no state (reset to cut the state space).
Kill(w) == IF w = 0 THEN wv ELSE [wv EXCEPT ![w] = [@ EXCEPT !.alive = FALSE, !.review = NoReview, !.doc = 0]]

Cmd(w, owner, tag, kind, inv) ==
    [wk |-> w, owner |-> owner, tag |-> tag, kind |-> kind, inv |-> inv, cancelled |-> FALSE]

\* clearPaymentReview (collapsePayment in the view).
ClearReview(x) ==
    LET y == [x EXCEPT !.timer = NoTimer, !.review = NoReview,
                       !.pending = SelectSeq(@, LAMBDA e : e.k # "pay")]
    IN IF y.active.k = "pay" THEN Interrupt(y, FALSE) ELSE y


InvIntent == [k |-> "inv", i |-> 0]
PtsIntent == [k |-> "pts", i |-> 0]

\* loadInvoices (non-fixture): guard, clearPaymentExpiry, paymentReview =
\* nil, enqueue bills, pump.
LoadInvoices(x) ==
    IF Connected(x) /\ x.client # 0 /\ x.activity \notin {"stopped", "connecting"} /\ ~Loading(x)
    THEN Pump(Enqueue([x EXCEPT !.timer = NoTimer, !.review = NoReview], InvIntent))
    ELSE x

\* reviewPayment(id) (no fixture renderer). Both invoices are payable
\* candidates. Returns early, changing nothing, while bills load.
ReviewPayment(x, i) ==
    IF Loading(x) THEN x
    ELSE LET y == [x EXCEPT !.timer = NoTimer,
                            !.review = [k |-> "checking", inv |-> i, conn |-> x.liveConn, exp |-> 0]]
         IN IF ~CanLoad(y)
            THEN [y EXCEPT !.review = [k |-> "unavail", inv |-> i, conn |-> x.liveConn, exp |-> 0]]
            ELSE Pump(Enqueue(y, [k |-> "pay", i |-> i]))

\* openInvoice(id): both invoices are listed.
OpenInvoice(x, i) == Pump(Enqueue(x, [k |-> "pdf", i |-> i]))

\* configureIfIdle
ConfigureIfIdle(x) ==
    IF x.activity = "idle" /\ x.client # 0 /\ x.applied # x.desired
    THEN Begin(x, "configuring", "cfgWait") ELSE x

\* perform(.refresh) tail: enqueue points when connected, finish().
AfterRefresh(x) == Finish(IF Connected(x) THEN Enqueue(x, PtsIntent) ELSE x)

SendOp(x, kind) == Append(wq, Cmd(x.client, "op", x.op.gen, kind, 0))

-----------------------------------------------------------------------------
(* Bills view and other user actions.                                      *)

\* destination = .bills: a new InvoicesView (@State paymentExpanded = false,
\* selectedInvoiceID = nil). Its .task starts in the same run-loop turn,
\* before the user can click (Bills controls wait for ~taskDue).
ShowBills ==
    /\ ~s.bills
    /\ UserBeatsConfigure \/ s.activity # "configuring"
    /\ s' = [s EXCEPT !.bills = TRUE, !.expanded = FALSE, !.selInv = 0, !.taskDue = TRUE]
    /\ UNCHANGED <<wq, wv, nw, now, crashes, badPdf>>

\* Leaving Bills (Back, or the popover closing): .onDisappear collapsePayment.
HideBills ==
    /\ s.bills
    /\ s' = [ClearReview(s) EXCEPT !.bills = FALSE, !.expanded = FALSE]
    /\ UNCHANGED <<wq, wv, nw, now, crashes, badPdf>>

\* .task(id: canLoadInvoices) { loadInvoices() } on appear and on id change.
BillsTask ==
    /\ s.bills
    /\ s.taskDue \/ CanLoad(s) # s.lastCan
    /\ s' = LoadInvoices([s EXCEPT !.taskDue = FALSE, !.lastCan = CanLoad(s)])
    /\ UNCHANGED <<wq, wv, nw, now, crashes, badPdf>>

\* Bank transfer QR toggle, collapsed: selectedInvoiceID = row, expand,
\* reviewPayment(row). The shown row is selectedInvoiceID or the first.
Expand(i) ==
    /\ s.bills /\ ~s.taskDue /\ ~s.expanded /\ s.selInv \in {0, i}
    /\ s' = ReviewPayment([s EXCEPT !.selInv = i, !.expanded = TRUE], i)
    /\ UNCHANGED <<wq, wv, nw, now, crashes, badPdf>>

\* Toggle, expanded: collapsePayment.
Collapse ==
    /\ s.bills /\ ~s.taskDue /\ s.expanded
    /\ s' = ClearReview([s EXCEPT !.expanded = FALSE])
    /\ UNCHANGED <<wq, wv, nw, now, crashes, badPdf>>

\* Picker, or rows changing: select(id) collapses.
Pick(i) ==
    /\ s.bills /\ ~s.taskDue /\ s.selInv # i
    /\ s' = ClearReview([s EXCEPT !.selInv = i, !.expanded = FALSE])
    /\ UNCHANGED <<wq, wv, nw, now, crashes, badPdf>>

\* Refresh bills button: enabled when canLoadInvoices && !isLoadingInvoices.
RefreshBills ==
    /\ s.bills /\ ~s.taskDue /\ CanLoad(s) /\ ~Loading(s)
    /\ s' = LoadInvoices(s)
    /\ UNCHANGED <<wq, wv, nw, now, crashes, badPdf>>

\* Open PDF: same enablement.
OpenPdf(i) ==
    /\ s.bills /\ ~s.taskDue /\ CanLoad(s) /\ ~Loading(s)
    /\ s' = OpenInvoice(s, i)
    /\ UNCHANGED <<wq, wv, nw, now, crashes, badPdf>>

\* Settings picker (another destination, so Bills is not shown):
\* refreshInterval didSet -> configureIfIdle.
ChangeInterval ==
    /\ ~s.bills /\ s.changes < MaxIntervalChanges
    /\ s' = ConfigureIfIdle([s EXCEPT !.desired = 3 - @, !.changes = @ + 1])
    /\ UNCHANGED <<wq, wv, nw, now, crashes, badPdf>>

\* refresh(): DataCard button, scheduledRefresh, or didWake. canRefresh.
\* (reconcileSelection is the AccountSwitching model.)
Refresh ==
    /\ s.activity = "idle" /\ (Connected(s) \/ s.bridgeFail)
    /\ s' = Begin(s, "refreshing", IF s.client # 0 THEN "refWait" ELSE "restore")
    /\ UNCHANGED <<wq, wv, nw, now, crashes, badPdf>>

\* selectAccount(other) from the Account destination: save the shown
\* state, begin(.switching), pendingOptional.removeAll(), client = nil,
\* show the other account's saved state with paymentReview = nil.
SelectAccount ==
    /\ ~s.bills /\ s.activity \notin {"connecting", "switching"} /\ s.switches < MaxSwitches
    /\ LET k == IF s.selected = "a" THEN "b" ELSE "a"
           y == Begin([s EXCEPT !.saved[s.selected] = s.liveConn], "switching", "swShutdown")
       IN s' = [y EXCEPT !.pending = << >>, !.client = 0, !.selected = k, !.liveConn = s.saved[k],
                         !.review = NoReview, !.bridgeFail = FALSE, !.switches = @ + 1]
    /\ UNCHANGED <<wq, wv, nw, now, crashes, badPdf>>

-----------------------------------------------------------------------------
(* Operation Task steps (the current intent only).                         *)

Waiting == {"cfgAns", "refAns", "refCfgAns", "rstAns"}
Got == s.op.pc \in Waiting /\ s.op.reply.has
R == s.op.reply
Dead(x) == [x EXCEPT !.op.reply = NoReply]

\* configureIfIdle task: await optionalCancellation; applyInterval sends
\* .configure(desired).
CfgWait ==
    /\ s.op.pc = "cfgWait" /\ CancelsDone(s)
    /\ s' = [s EXCEPT !.op.pc = "cfgAns", !.op.sent = s.desired]
    /\ wq' = SendOp(s, "configure")
    /\ UNCHANGED <<wv, nw, now, crashes, badPdf>>

\* applyInterval body after the reply: appliedInterval = desired; publish
\* only for the same connection; loop while the interval still differs.
\* `next` is the pc after the loop ends.
Configured(next) ==
    LET y == [Dead(s) EXCEPT !.applied = s.op.sent]
        z == IF R.conn = s.liveConn THEN Publish(y, R) ELSE y
    IN IF z.applied # z.desired
       THEN /\ s' = [z EXCEPT !.op.sent = z.desired]
            /\ wq' = SendOp(z, "configure")
       ELSE /\ s' = IF next = "finish" THEN Finish(z) ELSE AfterRefresh(z)
            /\ UNCHANGED wq

\* A thrown request (dead worker) ends in failWorker, which shuts it down.
Failed == s' = FailWorker(s) /\ wv' = Kill(s.client) /\ UNCHANGED wq

CfgAns ==
    /\ s.op.pc = "cfgAns" /\ Got
    /\ IF ~R.ok THEN Failed ELSE Configured("finish") /\ UNCHANGED wv
    /\ UNCHANGED <<nw, now, crashes, badPdf>>

\* perform(.refresh): await optionalCancellation, then client.request.
RefWait ==
    /\ s.op.pc = "refWait" /\ CancelsDone(s)
    /\ IF s.client = 0 THEN Failed
       ELSE /\ s' = [s EXCEPT !.op.pc = "refAns"]
            /\ wq' = SendOp(s, "refresh")
            /\ UNCHANGED wv
    /\ UNCHANGED <<nw, now, crashes, badPdf>>

\* Reply: invalidReply for another account; publish; applyInterval.
RefAns ==
    /\ s.op.pc = "refAns" /\ Got
    /\ IF ~R.ok \/ (R.conn # 0 /\ AcctOf(R.conn) # s.selected) THEN Failed
       ELSE LET y == Publish(Dead(s), R) IN
            /\ IF y.applied # y.desired
               THEN /\ s' = [y EXCEPT !.op.pc = "refCfgAns", !.op.sent = y.desired]
                    /\ wq' = SendOp(y, "configure")
               ELSE s' = AfterRefresh(y) /\ UNCHANGED wq
            /\ UNCHANGED wv
    /\ UNCHANGED <<nw, now, crashes, badPdf>>

RefCfgAns ==
    /\ s.op.pc = "refCfgAns" /\ Got
    /\ IF ~R.ok THEN Failed ELSE Configured("refresh") /\ UNCHANGED wv
    /\ UNCHANGED <<nw, now, crashes, badPdf>>

\* selectAccount task: await previous?.shutdown() (persisting the
\* selection is the AccountSwitching model).
SwShutdown ==
    /\ s.op.pc = "swShutdown"
    /\ s' = [s EXCEPT !.op.pc = "restore"]
    /\ wv' = Kill(s.op.old)
    /\ UNCHANGED <<wq, nw, now, crashes, badPdf>>

\* restoreAndPerform: restorationClient starts a worker for the selected
\* account (appliedInterval = .fiveMinutes; applyInterval's configure to a
\* fresh worker returns an empty state that publish drops, so it is folded
\* into appliedInterval = desired), then .restore.
Restore ==
    /\ s.op.pc = "restore" /\ nw < MaxWorkers
    /\ LET n == nw + 1 IN
       /\ nw' = n
       /\ wv' = [wv EXCEPT ![n] = [alive |-> TRUE, acct |-> s.selected, review |-> NoReview, doc |-> 0]]
       /\ s' = [s EXCEPT !.client = n, !.applied = s.desired, !.op.pc = "rstAns"]
       /\ wq' = Append(wq, Cmd(n, "op", s.op.gen, "restore", 0))
    /\ UNCHANGED <<now, crashes, badPdf>>

\* Restored: publish; not connected -> finish; else perform(.refresh).
RstAns ==
    /\ s.op.pc = "rstAns" /\ Got
    /\ IF ~R.ok THEN Failed
       ELSE LET y == Publish(Dead(s), R) IN
            /\ s' = IF ~Connected(y) THEN Finish(y)
                    ELSE [y EXCEPT !.activity = "refreshing", !.op.pc = "refWait"]
            /\ UNCHANGED <<wq, wv>>
    /\ UNCHANGED <<nw, now, crashes, badPdf>>

-----------------------------------------------------------------------------
(* Optional Tasks (pumpOptional's Task body).                              *)

\* await cancellation?.value; try Task.checkCancellation();
\* guard revision == optionalRevision; client.request(optional.request).
OptSend(n) ==
    /\ s.opts[n].pc = "wait" /\ CancelsDone(s)
    /\ IF ~s.opts[n].cur
       THEN s' = [s EXCEPT !.opts[n] = NoOpt] /\ UNCHANGED wq
       ELSE /\ s' = [s EXCEPT !.opts[n].pc = "sent"]
            /\ wq' = Append(wq, Cmd(s.opts[n].wk, "opt", n, s.opts[n].it.k, s.opts[n].it.i))
    /\ UNCHANGED <<wv, nw, now, crashes, badPdf>>

\* mergeInvoices(from:) guard: same account and connection.
Merge(x, r) == ~FaithfulOptionalGuard \/ r.conn = x.liveConn

\* publishOptional(state, intent:)
PublishOptional(x, it, r) ==
    CASE it.k = "inv" -> IF Merge(x, r) THEN [x EXCEPT !.review = r.review] ELSE x
      [] it.k = "pay" ->
           LET y == IF Merge(x, r) THEN [x EXCEPT !.review = r.review] ELSE x IN
           IF r.review.k = "ready"
           THEN [y EXCEPT !.timer = IF FaithfulExpiryTimer THEN [armed |-> TRUE, exp |-> r.review.exp]
                                    ELSE NoTimer]
           ELSE y
      [] OTHER -> x

\* openDocument(document.fileURL) runs for .pdf(id) when the reply has a
\* document (and, faithfully, its invoiceID == id).
Opens(it, r) == it.k = "pdf" /\ r.doc # 0 /\ (FaithfulDocumentChecks => r.doc = it.i)

OptResume(n) ==
    /\ s.opts[n].pc = "sent" /\ s.opts[n].reply.has
    /\ LET o == s.opts[n]
           r == o.reply
           x == [s EXCEPT !.opts[n] = NoOpt]   \* the Task ends; its slot is not reused
           ok == ~FaithfulOptionalGuard
                 \/ (o.cur /\ r.conn # 0 /\ AcctOf(r.conn) = AcctOf(s.liveConn) /\ o.conn = r.conn
                     /\ o.conn = s.liveConn /\ s.activity = "idle")
           \* defer: if revision == optionalRevision { nil; nil; pumpOptional() }
           Defer(y) == IF o.cur
                       THEN IF FaithfulPumpOnSettle
                            THEN Pump([y EXCEPT !.curOpt = 0, !.active = NoIntent])
                            ELSE [y EXCEPT !.curOpt = 0, !.active = NoIntent]
                       ELSE y
       IN IF r.ok
          THEN /\ s' = Defer(IF ok THEN PublishOptional(x, o.it, r) ELSE x)
               /\ badPdf' = (badPdf \/ (ok /\ Opens(o.it, r)
                                        /\ (r.doc # o.it.i \/ r.conn # s.liveConn)))
               /\ UNCHANGED wv
          \* catch: guard revision current; payment -> unavailable; client =
          \* nil; await client.shutdown(); then the defer.
          ELSE IF o.cur
               THEN /\ s' = Defer([x EXCEPT !.client = 0,
                                    !.review = IF o.it.k = "pay"
                                               THEN [k |-> "unavail", inv |-> o.it.i, conn |-> s.liveConn, exp |-> 0]
                                               ELSE @])
                    /\ wv' = Kill(o.wk)
                    /\ UNCHANGED badPdf
               ELSE s' = x /\ UNCHANGED <<wv, badPdf>>
    /\ UNCHANGED <<wq, nw, now, crashes>>

\* optionalCancellation Task: await previous; client.request(.cancel).
\* The worker acts on arrival: VikingSession.cancel() (paymentReview =
\* nil) and every queued command is cancelled and only reports.
CancelSend ==
    /\ s.cancelQ # << >> /\ ~s.cancelInFlight
    /\ LET w == Head(s.cancelQ) IN
       /\ s' = [s EXCEPT !.cancelQ = Tail(@), !.cancelInFlight = TRUE]
       /\ wq' = Append([j \in 1..Len(wq) |-> IF wq[j].wk = w THEN [wq[j] EXCEPT !.cancelled = TRUE] ELSE wq[j]],
                       Cmd(w, "cancel", 0, "cancel", 0))
       /\ wv' = IF wv[w].alive THEN [wv EXCEPT ![w].review = NoReview] ELSE wv
    /\ UNCHANGED <<nw, now, crashes, badPdf>>

-----------------------------------------------------------------------------
(* Worker processes: one command at a time per process.                   *)

\* Deliver a reply to the Task waiting for it, if it still waits.
Deliver(x, e, r) ==
    CASE e.owner = "op" ->
           IF x.op.gen = e.tag /\ x.op.pc \in Waiting /\ ~x.op.reply.has
           THEN [x EXCEPT !.op.reply = r] ELSE x
      [] e.owner = "opt" -> [x EXCEPT !.opts[e.tag].reply = r]
      [] OTHER -> [x EXCEPT !.cancelInFlight = FALSE]

WState(w, review, doc) ==
    [has |-> TRUE, ok |-> TRUE, conn |-> ConnOf(wv[w].acct), review |-> review, doc |-> doc]

WorkerStep(j) ==
    /\ j \in 1..Len(wq)
    /\ \A j2 \in 1..(j - 1) : wq[j2].wk # wq[j].wk
    /\ LET e == wq[j]
           w == wv[e.wk]
           rest == [m \in 1..(Len(wq) - 1) |-> IF m < j THEN wq[m] ELSE wq[m + 1]]
           \* ProviderAccounts.perform: clearInvoiceDocument (also fetchInvoicePDF).
           doc0 == IF FaithfulDocumentChecks THEN 0 ELSE w.doc
       IN /\ wq' = rest
          /\ IF ~w.alive
             \* SessionProcessClient: a stopped process throws.
             THEN s' = Deliver(s, e, [NoReply EXCEPT !.has = TRUE]) /\ UNCHANGED wv
             ELSE IF e.kind = "cancel" \/ e.cancelled
             \* Cancelled queued commands skip execute and report state().
             THEN s' = Deliver(s, e, WState(e.wk, w.review, w.doc)) /\ UNCHANGED wv
             ELSE \E good \in BOOLEAN :
                  LET review ==
                        CASE e.kind \in {"refresh", "inv"} -> NoReview   \* run(): non-optional; fetchInvoices
                          [] e.kind = "pay" ->
                               IF good THEN [k |-> "ready", inv |-> e.inv, conn |-> ConnOf(w.acct), exp |-> now + Lifetime]
                               ELSE [k |-> "unavail", inv |-> e.inv, conn |-> ConnOf(w.acct), exp |-> 0]
                          [] OTHER -> w.review                         \* configure, restore, points
                      doc == IF e.kind = "pdf" /\ good THEN e.inv ELSE doc0
                  IN /\ (e.kind \notin {"pay", "pdf"} => good)
                     /\ wv' = [wv EXCEPT ![e.wk].review = review, ![e.wk].doc = doc]
                     /\ s' = Deliver(s, e, WState(e.wk, review, doc))
    /\ UNCHANGED <<nw, now, crashes, badPdf>>

\* A worker process dies (crash, invalid reply, broken pipe).
WorkerCrash(w) ==
    /\ crashes < MaxCrashes /\ wv[w].alive
    /\ crashes' = crashes + 1
    /\ wv' = Kill(w)
    /\ UNCHANGED <<s, wq, nw, now, badPdf>>

-----------------------------------------------------------------------------
(* Time and the QR expiry timer.                                           *)

\* schedulePaymentExpiry's Task: sleepUntil(expiry), revision current, not
\* stopped -> .unavailable(.reviewExpired).
TimerFire ==
    /\ s.timer.armed /\ now >= s.timer.exp
    /\ s' = [s EXCEPT !.timer = NoTimer, !.review = [NoReview EXCEPT !.k = "expired"]]
    /\ UNCHANGED <<wq, wv, nw, now, crashes, badPdf>>

\* A due timer fires before time moves on.
Tick ==
    /\ now < MaxTime
    /\ ~(s.timer.armed /\ now >= s.timer.exp)
    /\ now' = now + 1
    /\ UNCHANGED <<s, wq, wv, nw, crashes, badPdf>>

Next ==
    \/ ShowBills \/ HideBills \/ BillsTask \/ Collapse \/ RefreshBills
    \/ \E i \in Invs : Expand(i) \/ Pick(i) \/ OpenPdf(i)
    \/ ChangeInterval \/ Refresh \/ SelectAccount
    \/ CfgWait \/ CfgAns \/ RefWait \/ RefAns \/ RefCfgAns \/ SwShutdown \/ Restore \/ RstAns
    \/ \E n \in 1..MaxOptStarts : OptSend(n) \/ OptResume(n)
    \/ CancelSend
    \/ \E j \in 1..Len(wq) : WorkerStep(j)
    \/ \E w \in 1..MaxWorkers : WorkerCrash(w)
    \/ TimerFire \/ Tick

\* Bounds (CONSTRAINT): states past them are not explored, and the rules
\* hold vacuously there, so a cut-off pump is never read as a lost one.
InBounds == s.gen <= MaxOps /\ s.nextOpt <= MaxOptStarts + 1

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules.                                                                  *)

Visible == s.bills /\ s.expanded /\ s.review.k = "ready"

\* A QR the user can see is for the invoice they expanded and the shown
\* account/connection. Harm: the user scans a transfer for another bill,
\* or another customer's bill.
QRMatchesView == InBounds => (Visible => s.review.inv = s.selInv /\ s.review.conn = s.liveConn)

\* A QR the user can see is not past its expiresAt, unless its expiry
\* timer is armed and about to replace it. Harm: the user pays an amount
\* verified more than five minutes ago (already paid, or changed).
QRNotExpired == InBounds => (Visible => (now < s.review.exp \/ (s.timer.armed /\ s.timer.exp = s.review.exp)))

\* A PDF opened is the requested invoice of the shown connection. Harm:
\* another bill, or another customer's bill, opens.
PdfMatchesRequest == InBounds => (~badPdf)

Settled == s.activity = "idle" /\ s.op.pc = "none" /\ s.curOpt = 0

\* Idle, connected, with a client and no optional operation: nothing waits
\* in the queue. Harm: points/bills/history never load and "Refreshing
\* bills" stays on with the controls disabled.
PumpNotForgotten == InBounds => ((Settled /\ Connected(s) /\ s.client # 0) => s.pending = << >>)

\* Queued work that cannot run (no client) is reported: the worker-stopped
\* message asks for a refresh. Harm: "Refreshing bills"/history loading
\* stays on and Bills, PDF and QR stay disabled with no error, until the
\* next scheduled refresh.
StuckQueueReported == InBounds => ((Settled /\ s.pending # << >>) => ((Connected(s) /\ s.client # 0) \/ s.bridgeFail))

=============================================================================
