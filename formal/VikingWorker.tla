---------------------------- MODULE VikingWorker ----------------------------
(***************************************************************************)
(* The Mobile Vikings worker actor VikingSession: its operation flights,   *)
(* generation, cancel, optional reads against refreshes, and the on-disk   *)
(* balance cache, in two processes (app worker and CLI) that share one     *)
(* account's Keychain record, session.lock, and balance cache file.        *)
(*                                                                         *)
(* Code (Sources/VikingBarCore):                                           *)
(*   VikingSession.swift           bootstrapWithDiagnostics, restore,      *)
(*                                 refresh, selectSubscription,            *)
(*                                 selectBundle, cancel, connect, fetch,   *)
(*                                 fetchBalance, authorize (adopt and      *)
(*                                 token reuse only), withConnectionLease, *)
(*                                 recordFailure, adopt, checkGeneration   *)
(*   VikingSessionOperation.swift  runOptional, run, InFlight, OperationKind *)
(*   VikingSessionHistory.swift    refreshHistory, fetchHistory, checkHistory *)
(*   VikingSessionPoints.swift     fetchPoints, fetchPointsBalance/History *)
(*   VikingSessionInvoices.swift   fetchInvoices, fetchPaymentReview,      *)
(*                                 renderPayment                           *)
(*   VikingSessionState.swift      canRestore, publish, selectBundle       *)
(*   UsageHistory.swift            historyContext, reviseHistory           *)
(*   SessionPersistence.swift      FileBalanceCache.load/save, FileSessionLease *)
(*                                                                         *)
(* VikingSession is an actor: code between two awaits is one step. The     *)
(* operation closure passed to run() is a nonisolated @Sendable closure,   *)
(* so the task leaves the actor between its checkGeneration and the first  *)
(* line of the fetch function ("prev" -> "body"); any actor call, cancel() *)
(* included, can run there. Token rotation is formal/TokenRotation.tla:    *)
(* here a token is the connection it belongs to plus valid/expired, and an *)
(* exchange is one held-lease await that succeeds or fails.                *)
(*                                                                         *)
(* Data is abstracted to where it came from: a balance is <<connection,    *)
(* subscription>>, points and invoices are a connection, history is        *)
(* <<connection, subscription, revision>> (its context; the bundle index   *)
(* is folded into the revision). 0/None mean none. Revisions are UUIDs:    *)
(* a global counter keeps them unique across processes.                    *)
(*                                                                         *)
(* In production each process serializes its calls: SessionCommandQueue   *)
(* (VikingBarCLI/SessionCommands.swift) awaits the previous command, and   *)
(* only cancel/shutdown run at once (queue.cancel -> session.cancel). With *)
(* Concurrent = TRUE a process may also start calls while others run, the  *)
(* actor's own contract that runOptional/run implement.                    *)
(*                                                                         *)
(* Faithful* constants are TRUE for the code as written; each mutant in    *)
(* formal/mutants/VikingWorker turns one off.                              *)
(***************************************************************************)
EXTENDS Naturals, TLC

CONSTANTS
    Procs,            \* processes with their own VikingSession on one account
    Subs,             \* mobile subscriptions of the login
    MaxCalls,         \* calls explored, all processes together
    MaxConns,         \* connection incarnations (bootstraps) explored
    MaxRev,           \* history revisions explored
    MaxCancels,       \* external cancel() calls explored
    Concurrent,       \* a process may start a call while another one runs
    \* checkGeneration (generation == self.generation) before every write of
    \* data or the cache: fetchBalance, fetchPoints*, fetchInvoices,
    \* fetchPaymentReview, checkHistory.
    FaithfulCheckBeforeWrite,
    \* withConnectionLease / checkHistory: guard record.connectionID ==
    \* expected, else adopt and throw connectionChanged.
    FaithfulLeaseConnCheck,
    \* adopt: a new record connection resets token and current.
    FaithfulAdoptResets,
    \* fetchBalance: a changed subscription clears balance, bundle, history.
    FaithfulClearOnSubChange,
    \* checkHistory: guard current.historyContext == context.
    FaithfulHistoryContextCheck,
    \* FileBalanceCache.load: record.state.connectionID == connectionID, and
    \* restore's canRestore(connectionID:).
    FaithfulCacheKeyed,
    \* run's defer: if self.flight?.id == id.
    FaithfulDeferChecksId,
    \* run's defer clears isRefreshing on every exit, not only on success.
    FaithfulDeferClearsSpinner,
    \* runOptional: while let flight = self.flight { await it }.
    FaithfulOptionalWaits

None == "none"
NoBal == <<0, None>>
NoHist == <<0, None, 0>>
Optional == {"points", "history", "invoices", "review"}

\* LiveSessionState() with connectionID c; review is paymentReview,
\* refreshing is isRefreshing, subs is "subscriptions is not empty".
Emp(c) == [conn |-> c, subs |-> FALSE, sub |-> None, bal |-> NoBal, rev |-> 0,
           hist |-> NoHist, pts |-> 0, inv |-> 0, review |-> "none", refreshing |-> FALSE]

\* What FileBalanceCache.save keeps: no payment review, no spinner state.
Snap(s) == [conn |-> s.conn, subs |-> s.subs, sub |-> s.sub, bal |-> s.bal, rev |-> s.rev,
            hist |-> s.hist, pts |-> s.pts, inv |-> s.inv]

\* historyContext: connection, selected subscription, a bundle, a revision.
Ctx(s) == IF s.conn # 0 /\ s.sub # None /\ s.bal # NoBal /\ s.rev # 0
          THEN <<s.conn, s.sub, s.rev>> ELSE NoHist

NoCall == [proc |-> None, kind |-> None, sub |-> None, pc |-> "none", gen |-> 0, conn |-> 0,
           tok |-> 0, sel |-> None, ctx |-> NoHist, prev |-> 0, nonopt |-> FALSE, after |-> None]
\* A returned call keeps only what other steps read, so finished calls
\* that differ only in their history merge into one state.
Done(p, nonopt) == [NoCall EXCEPT !.proc = p, !.pc = "done", !.nonopt = nonopt]

VARIABLES
    rconn,         \* Keychain record's connectionID (shared)
    conns,         \* connections issued so far
    lease,         \* call holding session.lock across an await, or 0 (shared)
    cache,         \* balance cache file; conn = 0 means no file (shared)
    cur,           \* cur[p]: process p's VikingSession.current
    tok,           \* tok[p]: connection of self.token, 0 = nil
    tokValid,      \* tokValid[p]: now < token.expiresAt
    gen,           \* gen[p]: self.generation
    flight,        \* flight[p]: call id of self.flight, or 0
    revs,          \* history revisions issued
    cancels,       \* external cancel() calls so far
    nCalls,        \* calls started
    call,          \* call[i]: one public call and its run() task
    staleWrite,    \* history: a cancelled or superseded call wrote data or the cache
    strayCheck,    \* history: a cancelled or superseded call set paymentReview = .checking
    deadSave,      \* history: a cache save labeled a connection the record no longer has
    restoredOther, \* history: restore left a connection the record does not have
    optCancelled   \* history: an optional read cancelled a running refresh

vars == <<rconn, conns, lease, cache, cur, tok, tokValid, gen, flight, revs, cancels, nCalls, call,
          staleWrite, strayCheck, deadSave, restoredOther, optCancelled>>

Warm(c) == [Emp(c) EXCEPT !.subs = TRUE, !.sub = "x", !.bal = <<c, "x">>, !.rev = 1,
                          !.hist = <<c, "x", 1>>, !.pts = c, !.inv = c]

\* Each process starts fresh (LiveSessionState()) or as after a restore and
\* refresh of connection 1; the cache holds that refresh.
Init ==
    /\ rconn = 1
    /\ conns = 1
    /\ lease = 0
    /\ cache = Snap(Warm(1))
    /\ \E warm \in [Procs -> BOOLEAN] :
          /\ cur = [p \in Procs |-> IF warm[p] THEN Warm(1) ELSE Emp(0)]
          /\ tok = [p \in Procs |-> IF warm[p] THEN 1 ELSE 0]
    /\ tokValid = [p \in Procs |-> TRUE]
    /\ gen = [p \in Procs |-> 0]
    /\ flight = [p \in Procs |-> 0]
    /\ revs = 1
    /\ cancels = 0
    /\ nCalls = 0
    /\ call = [i \in 1..MaxCalls |-> NoCall]
    /\ staleWrite = FALSE
    /\ strayCheck = FALSE
    /\ deadSave = FALSE
    /\ restoredOther = FALSE
    /\ optCancelled = FALSE

-----------------------------------------------------------------------------
(* Helpers.                                                                *)

P(i) == call[i].proc
Fresh(i) == call[i].gen = gen[P(i)]
\* checkGeneration passes (Task.checkCancellation and generation match).
Check(i) == ~FaithfulCheckBeforeWrite \/ Fresh(i)
\* withConnectionLease(expected: e): guard record.connectionID == expected.
ConnOK(e) == ~FaithfulLeaseConnCheck \/ rconn = e

\* adopt(record).
Adopted(s) == IF s.conn = rconn THEN s
              ELSE IF FaithfulAdoptResets THEN Emp(rconn) ELSE [s EXCEPT !.conn = rconn]
AdoptedTok(s, t) == IF s.conn # rconn /\ FaithfulAdoptResets THEN 0 ELSE t

Running(p) == \E i \in 1..nCalls : P(i) = p /\ call[i].pc # "done"
CanStart(p) == nCalls < MaxCalls /\ (Concurrent \/ ~Running(p))

Flags == <<strayCheck, restoredOther, optCancelled>>

\* End of run()'s task. outcome: "ok" (operation returned), "fail" (threw),
\* "cancel" (CancellationError). cc: the failure is connectionChanged.
\* s, t, c, l, w, sv: current, token, cache, lease after the body, whether
\* the body wrote data, whether it saved the cache.
\* do: isRefreshing = false on success. catch: recordFailure if the
\* generation still matches and the kind is not optional. defer: clear
\* flight (and isRefreshing) if self.flight?.id == id.
Commit(i, outcome, cc, s, t, c, l, w, sv) ==
    LET p == P(i)
        k == call[i]
        rf == outcome = "fail" /\ ~cc /\ k.nonopt /\ gen[p] = k.gen
        rfAdopt == rf /\ l = 0 /\ rconn # s.conn
        rfSave == rf /\ l = 0 /\ rconn = s.conn
        s1 == IF rfAdopt THEN Adopted(s) ELSE s
        clear == flight[p] = i \/ ~FaithfulDeferChecksId
        off == k.nonopt /\ (outcome = "ok" \/ (clear /\ FaithfulDeferClearsSpinner))
    IN /\ cur' = [cur EXCEPT ![p] = IF off THEN [s1 EXCEPT !.refreshing = FALSE] ELSE s1]
       /\ tok' = [tok EXCEPT ![p] = IF rfAdopt THEN AdoptedTok(s, t) ELSE t]
       /\ cache' = IF rfSave THEN Snap(s1) ELSE c
       /\ lease' = l
       /\ flight' = [flight EXCEPT ![p] = IF clear THEN 0 ELSE @]
       /\ call' = [call EXCEPT ![i] = Done(p, k.nonopt)]
       /\ staleWrite' = (staleWrite \/ (w /\ ~Fresh(i)))
       /\ deadSave' = (deadSave \/ (sv /\ c.conn # rconn))

\* The task continues at pc after an await.
Continue(i, pc, k, s, t, c, l, w, sv) ==
    LET p == P(i) IN
    /\ cur' = [cur EXCEPT ![p] = s]
    /\ tok' = [tok EXCEPT ![p] = t]
    /\ cache' = c
    /\ lease' = l
    /\ call' = [call EXCEPT ![i] = [k EXCEPT !.pc = pc]]
    /\ UNCHANGED flight
    /\ staleWrite' = (staleWrite \/ (w /\ ~Fresh(i)))
    /\ deadSave' = (deadSave \/ (sv /\ c.conn # rconn))

Cancelled(i) == Commit(i, "cancel", FALSE, cur[P(i)], tok[P(i)], cache, lease, FALSE, FALSE)
Failed(i, cc, s, t) == Commit(i, "fail", cc, s, t, cache, lease, FALSE, FALSE)

\* run(kind:): cancel() a previous flight, capture the generation, set
\* isRefreshing and clear paymentReview for a non-optional kind, store the
\* flight, and start the task, which first awaits the previous task.
Run(i, base) ==
    LET p == base.proc
        prev == flight[p]
        g == IF prev # 0 THEN gen[p] + 1 ELSE gen[p]
        s0 == IF prev # 0 THEN [cur[p] EXCEPT !.review = "none"] ELSE cur[p]
        s1 == IF base.nonopt THEN [s0 EXCEPT !.refreshing = TRUE, !.review = "none"] ELSE s0
    IN /\ gen' = [gen EXCEPT ![p] = g]
       /\ cur' = [cur EXCEPT ![p] = s1]
       /\ flight' = [flight EXCEPT ![p] = i]
       /\ call' = [call EXCEPT ![i] = [base EXCEPT !.pc = "prev", !.gen = g, !.prev = prev]]
       /\ optCancelled' = (optCancelled \/ (prev # 0 /\ ~base.nonopt /\ call[prev].nonopt))

Base(p, kind, sub, ctx) ==
    [NoCall EXCEPT !.proc = p, !.kind = kind, !.sub = sub, !.gen = gen[p], !.conn = cur[p].conn,
                   !.ctx = ctx, !.nonopt = kind \notin Optional]

-----------------------------------------------------------------------------
(* Public calls: the synchronous part up to the first await.               *)

\* refresh(subscriptionID: nil): join (or refuse) a non-optional flight,
\* else run(.refresh).
RefreshStart(p) ==
    /\ CanStart(p)
    /\ nCalls' = nCalls + 1
    /\ IF flight[p] # 0 /\ call[flight[p]].nonopt
       THEN /\ call' = [call EXCEPT ![nCalls + 1] = Done(p, TRUE)]
            /\ UNCHANGED <<gen, cur, flight, optCancelled>>
       ELSE Run(nCalls + 1, Base(p, "refresh", None, NoHist))
    /\ UNCHANGED <<rconn, conns, lease, cache, tok, tokValid, revs, cancels, staleWrite, strayCheck,
                   deadSave, restoredOther>>

\* selectSubscription(id:) (and refresh(subscriptionID:)): guard the id is
\* listed, then run(.refresh(id)) directly.
SelectStart(p, x) ==
    /\ CanStart(p)
    /\ cur[p].subs
    /\ nCalls' = nCalls + 1
    /\ Run(nCalls + 1, Base(p, "select", x, NoHist))
    /\ UNCHANGED <<rconn, conns, lease, cache, tok, tokValid, revs, cancels, staleWrite, strayCheck,
                   deadSave, restoredOther>>

\* refreshPoints, refreshInvoices, reviewInvoicePayment, refreshHistory ->
\* runOptional: capture generation and connection; wait for any flight.
\* refreshHistory first needs a historyContext (else returns current).
OptStart(p, kind) ==
    /\ CanStart(p)
    /\ kind = "history" => Ctx(cur[p]) # NoHist
    /\ nCalls' = nCalls + 1
    /\ LET base == Base(p, kind, None, IF kind = "history" THEN Ctx(cur[p]) ELSE NoHist) IN
       IF FaithfulOptionalWaits /\ flight[p] # 0
       THEN /\ call' = [call EXCEPT ![nCalls + 1] = [base EXCEPT !.pc = "wait", !.prev = flight[p]]]
            /\ UNCHANGED <<gen, cur, flight, optCancelled>>
       ELSE Run(nCalls + 1, base)
    /\ UNCHANGED <<rconn, conns, lease, cache, tok, tokValid, revs, cancels, staleWrite, strayCheck,
                   deadSave, restoredOther>>

\* runOptional loop: the awaited flight ended. checkGeneration; same
\* connection; wait again or run.
OptWait(i) ==
    /\ call[i].pc = "wait"
    /\ call[call[i].prev].pc = "done"
    /\ LET p == P(i) IN
       IF ~Check(i) \/ cur[p].conn # call[i].conn
       THEN /\ call' = [call EXCEPT ![i] = Done(p, FALSE)]
            /\ UNCHANGED <<gen, cur, flight, optCancelled>>
       ELSE IF flight[p] # 0
            THEN /\ call' = [call EXCEPT ![i].prev = flight[p]]
                 /\ UNCHANGED <<gen, cur, flight, optCancelled>>
            ELSE Run(i, call[i])
    /\ UNCHANGED <<rconn, conns, lease, cache, tok, tokValid, revs, cancels, nCalls, staleWrite,
                   strayCheck, deadSave, restoredOther>>

\* restore(): guard flight == nil; under the lease load the record, adopt,
\* load the cache for record.connectionID and take it if canRestore; drop a
\* history whose context differs. A busy lease throws (markStale only).
Restore(p) ==
    /\ CanStart(p)
    /\ nCalls' = nCalls + 1
    /\ call' = [call EXCEPT ![nCalls + 1] = Done(p, TRUE)]
    /\ IF flight[p] # 0 \/ lease # 0
       THEN UNCHANGED <<cur, tok, restoredOther>>
       ELSE LET s1 == Adopted(cur[p])
                keyed == IF FaithfulCacheKeyed THEN cache.conn = s1.conn ELSE cache.conn # 0
                c == cache
                cached == [conn |-> c.conn, subs |-> c.subs, sub |-> c.sub, bal |-> c.bal, rev |-> c.rev,
                           hist |-> IF c.hist = Ctx(c) THEN c.hist ELSE NoHist,
                           pts |-> c.pts, inv |-> c.inv, review |-> "none", refreshing |-> FALSE]
                s2 == IF keyed THEN cached ELSE s1
            IN /\ cur' = [cur EXCEPT ![p] = s2]
               /\ tok' = [tok EXCEPT ![p] = AdoptedTok(cur[p], tok[p])]
               /\ restoredOther' = (restoredOther \/ s2.conn # rconn)
    /\ UNCHANGED <<rconn, conns, lease, cache, tokValid, gen, flight, revs, cancels, staleWrite,
                   strayCheck, deadSave, optCancelled>>

\* selectBundle(index:): guard flight == nil; withConnectionLease(current):
\* clear paymentReview, select an active bundle (reviseHistory: new
\* revision, history kept only for the same bundle cycle), save the cache.
Bundle(p) ==
    /\ CanStart(p)
    /\ nCalls' = nCalls + 1
    /\ call' = [call EXCEPT ![nCalls + 1] = Done(p, TRUE)]
    /\ LET s == cur[p] IN
       IF flight[p] # 0 \/ lease # 0 \/ (ConnOK(s.conn) /\ s.bal = NoBal)
       THEN UNCHANGED <<cur, tok, cache, revs, deadSave>>
       ELSE IF ~ConnOK(s.conn)
            THEN /\ cur' = [cur EXCEPT ![p] = Adopted(s)]
                 /\ tok' = [tok EXCEPT ![p] = AdoptedTok(s, tok[p])]
                 /\ UNCHANGED <<cache, revs, deadSave>>
            ELSE /\ revs < MaxRev
                 /\ revs' = revs + 1
                 /\ \E keep \in BOOLEAN :
                       LET s1 == [s EXCEPT !.review = "none", !.rev = revs + 1,
                                           !.hist = IF keep /\ @ # NoHist THEN <<@[1], @[2], revs + 1>>
                                                    ELSE NoHist]
                       IN /\ cur' = [cur EXCEPT ![p] = s1]
                          /\ cache' = Snap(s1)
                          /\ deadSave' = (deadSave \/ s1.conn # rconn)
                 /\ UNCHANGED tok
    /\ UNCHANGED <<rconn, conns, lease, tokValid, gen, flight, cancels, staleWrite, strayCheck,
                   restoredOther, optCancelled>>

\* bootstrapWithDiagnostics: guard flight == nil, generation += 1, token =
\* nil, current = LiveSessionState(), run(.bootstrap).
ConnectStart(p) ==
    /\ CanStart(p)
    /\ nCalls' = nCalls + 1
    /\ IF flight[p] # 0
       THEN /\ call' = [call EXCEPT ![nCalls + 1] = Done(p, TRUE)]
            /\ UNCHANGED <<gen, cur, tok, flight>>
       ELSE LET g == gen[p] + 1 IN
            /\ gen' = [gen EXCEPT ![p] = g]
            /\ tok' = [tok EXCEPT ![p] = 0]
            /\ cur' = [cur EXCEPT ![p] = [Emp(0) EXCEPT !.refreshing = TRUE]]
            /\ flight' = [flight EXCEPT ![p] = nCalls + 1]
            /\ call' = [call EXCEPT ![nCalls + 1] = [Base(p, "connect", None, NoHist) EXCEPT
                                                      !.pc = "prev", !.gen = g, !.conn = 0]]
    /\ UNCHANGED <<rconn, conns, lease, cache, tokValid, revs, cancels, staleWrite, strayCheck,
                   deadSave, restoredOther, optCancelled>>

\* cancel(): generation += 1, flight?.task.cancel(), paymentReview = nil.
\* The app sends it when it interrupts an optional read or begins another
\* operation; SessionCommandQueue runs it at once.
Cancel(p) ==
    /\ cancels < MaxCancels
    /\ cancels' = cancels + 1
    /\ gen' = [gen EXCEPT ![p] = @ + 1]
    /\ cur' = [cur EXCEPT ![p].review = "none"]
    /\ UNCHANGED <<rconn, conns, lease, cache, tok, tokValid, flight, revs, nCalls, call,
                   staleWrite, strayCheck, deadSave, restoredOther, optCancelled>>

\* The access token reaches expiresAt.
Expire(p) ==
    /\ tokValid[p]
    /\ tokValid' = [tokValid EXCEPT ![p] = FALSE]
    /\ UNCHANGED <<rconn, conns, lease, cache, cur, tok, gen, flight, revs, cancels, nCalls, call,
                   staleWrite, strayCheck, deadSave, restoredOther, optCancelled>>

-----------------------------------------------------------------------------
(* run()'s task.                                                           *)

\* _ = try? await previous?.task.value; try self.checkGeneration(generation).
\* Then the task calls the nonisolated operation closure and leaves the actor.
Prev(i) ==
    /\ call[i].pc = "prev"
    /\ IF call[i].prev = 0 THEN TRUE ELSE call[call[i].prev].pc = "done"
    /\ IF ~Check(i)
       THEN Cancelled(i)
       ELSE /\ call' = [call EXCEPT ![i].pc = "body"]
            /\ UNCHANGED <<cur, tok, cache, lease, flight, staleWrite, deadSave>>
    /\ UNCHANGED <<rconn, conns, tokValid, gen, revs, cancels, nCalls, Flags>>

TaskVars == <<rconn, conns, gen, revs, cancels, nCalls, Flags>>

\* fetch -> authorize(force: false): under the lease load the record and
\* adopt it; reuse a valid token of the same connection, else
\* checkGeneration, mark pending, and exchange with the lease held.
\* connectionID = current.connectionID after authorize.
RefreshAuth(i) ==
    /\ call[i].pc = "body" /\ call[i].kind \in {"refresh", "select"}
    /\ LET p == P(i)
           s1 == Adopted(cur[p])
           t1 == AdoptedTok(cur[p], tok[p])
       IN IF lease # 0 THEN Failed(i, FALSE, cur[p], tok[p])
          ELSE IF t1 = rconn /\ tokValid[p]
          THEN Continue(i, "subs", [call[i] EXCEPT !.conn = s1.conn, !.tok = rconn], s1, t1, cache, 0, FALSE, FALSE)
          ELSE IF ~Check(i) THEN Commit(i, "cancel", FALSE, s1, t1, cache, 0, FALSE, FALSE)
          ELSE Continue(i, "exchange", [call[i] EXCEPT !.after = "subs"], s1, t1, cache, i, FALSE, FALSE)
    /\ UNCHANGED <<tokValid, TaskVars>>

\* fetchPoints: connectionID = current.connectionID; authorize(expected:
\* connectionID, preserveUsage: true). Any authorize error goes to the
\* catch: checkGeneration, then withConnectionLease marks points
\* unavailable and saves the cache.
PointsCatch(i, e, s, t) ==
    IF ~Check(i) THEN Commit(i, "cancel", FALSE, s, t, cache, lease, FALSE, FALSE)
    ELSE IF lease # 0 THEN Failed(i, FALSE, s, t)
    ELSE IF ~ConnOK(e)
         THEN Commit(i, "fail", TRUE, Adopted(s), AdoptedTok(s, t), cache, 0, FALSE, FALSE)
         ELSE Commit(i, "ok", FALSE, s, t, Snap(s), 0, TRUE, TRUE)

PointsAuth(i) ==
    /\ call[i].pc = "body" /\ call[i].kind = "points"
    /\ LET p == P(i)
           e == cur[p].conn
           k == [call[i] EXCEPT !.conn = e]
           s1 == Adopted(cur[p])
           t1 == AdoptedTok(cur[p], tok[p])
       IN IF lease # 0 THEN PointsCatch(i, e, cur[p], tok[p])
          ELSE IF rconn # e
          THEN \* authorize: record.connectionID != expected: adopt, throw.
               IF ~Check(i) THEN Commit(i, "cancel", FALSE, s1, t1, cache, 0, FALSE, FALSE)
               ELSE Commit(i, "fail", TRUE, s1, t1, cache, 0, FALSE, FALSE)
          ELSE IF t1 = rconn /\ tokValid[p]
          THEN Continue(i, "pts", [k EXCEPT !.tok = rconn], s1, t1, cache, 0, FALSE, FALSE)
          ELSE IF ~Check(i) THEN Commit(i, "cancel", FALSE, s1, t1, cache, 0, FALSE, FALSE)
          ELSE Continue(i, "exchange", [k EXCEPT !.after = "pts"], s1, t1, cache, i, FALSE, FALSE)
    /\ UNCHANGED <<tokValid, TaskVars>>

\* authorize: `received = try await exchange.value` with the lease held.
\* The exchange is an unstructured Task, so cancellation does not stop it.
\* Success saves the record, sets the token, releases the lease, then
\* checkGeneration. Failure clears the token; fetch rethrows (run's catch
\* records it), fetchPoints' catch marks points unavailable.
Exchange(i) ==
    /\ call[i].pc = "exchange"
    /\ LET p == P(i) IN
       \/ /\ tokValid' = [tokValid EXCEPT ![p] = TRUE]
          /\ IF ~Check(i) THEN Commit(i, "cancel", FALSE, cur[p], rconn, cache, 0, FALSE, FALSE)
             ELSE Continue(i, call[i].after,
                           [call[i] EXCEPT !.conn = IF call[i].kind = "points" THEN @ ELSE cur[p].conn,
                                           !.tok = rconn],
                           cur[p], rconn, cache, 0, FALSE, FALSE)
       \/ /\ UNCHANGED tokValid
          /\ IF call[i].kind = "points"
             THEN LET s == cur[p] IN
                  IF ~Check(i) THEN Commit(i, "cancel", FALSE, s, 0, cache, 0, FALSE, FALSE)
                  ELSE Commit(i, "ok", FALSE, s, 0, Snap(s), 0, TRUE, TRUE)
             ELSE Commit(i, "fail", FALSE, cur[p], 0, cache, 0, FALSE, FALSE)
    /\ UNCHANGED TaskVars

\* fetchBalance: await api.subscriptions; checkGeneration; pick the
\* requested, the selected, or the first subscription; withConnectionLease:
\* checkGeneration, store subscriptions and selection; a changed selection
\* clears balance, bundle, history, and historyRevision.
Subs_(i) ==
    /\ call[i].pc = "subs"
    /\ LET p == P(i)
           k == call[i]
           s == cur[p]
           sel == IF k.sub # None THEN k.sub ELSE IF s.sub # None THEN s.sub ELSE "x"
           changed == s.sub # sel /\ FaithfulClearOnSubChange
           s1 == [s EXCEPT !.subs = TRUE, !.sub = sel,
                           !.bal = IF changed THEN NoBal ELSE @,
                           !.hist = IF changed THEN NoHist ELSE @,
                           !.rev = IF changed THEN 0 ELSE @]
       IN \/ Failed(i, FALSE, s, tok[p])
          \/ IF ~Check(i) THEN Cancelled(i)
             ELSE IF lease # 0 THEN Failed(i, FALSE, s, tok[p])
             ELSE IF ~ConnOK(k.conn)
                  THEN Commit(i, "fail", TRUE, Adopted(s), AdoptedTok(s, tok[p]), cache, 0, FALSE, FALSE)
             ELSE IF ~Check(i) THEN Cancelled(i)
             ELSE Continue(i, "balance", [k EXCEPT !.sel = sel], s1, tok[p], cache, 0, TRUE, FALSE)
    /\ UNCHANGED <<tokValid, TaskVars>>

\* fetchBalance: await api.balance(selected); withConnectionLease:
\* checkGeneration, publish (balance, bundle, reviseHistory), save cache.
Balance(i) ==
    /\ call[i].pc = "balance"
    /\ LET p == P(i)
           k == call[i]
           s == cur[p]
       IN \/ Failed(i, FALSE, s, tok[p]) /\ UNCHANGED revs
          \/ IF lease # 0 THEN Failed(i, FALSE, s, tok[p]) /\ UNCHANGED revs
             ELSE IF ~ConnOK(k.conn)
                  THEN Commit(i, "fail", TRUE, Adopted(s), AdoptedTok(s, tok[p]), cache, 0, FALSE, FALSE)
                       /\ UNCHANGED revs
             ELSE IF ~Check(i) THEN Cancelled(i) /\ UNCHANGED revs
             ELSE /\ revs < MaxRev
                  /\ revs' = revs + 1
                  /\ \E keep \in BOOLEAN :
                        LET same == s.hist # NoHist /\ s.hist[1] = s.conn /\ s.hist[2] = s.sub
                            s1 == [s EXCEPT !.bal = <<k.tok, k.sel>>, !.rev = revs + 1,
                                            !.hist = IF keep /\ same THEN <<@[1], @[2], revs + 1>>
                                                     ELSE NoHist]
                        IN Commit(i, "ok", FALSE, s1, tok[p], Snap(s1), 0, TRUE, TRUE)
    /\ UNCHANGED <<tokValid, rconn, conns, gen, cancels, nCalls, Flags>>

\* fetchPointsBalance + fetchPointsHistory (two awaits with the same
\* handling, merged): success or failure, withConnectionLease(connectionID):
\* checkGeneration, store points (failure: mark stale), save cache. A busy
\* lease or changed connection in the success path goes to the catch, which
\* checks generation and takes the lease again.
Points(i) ==
    /\ call[i].pc = "pts"
    /\ LET p == P(i)
           k == call[i]
           s == cur[p]
       IN \E ok \in BOOLEAN :
          IF ~Check(i) THEN Cancelled(i)
          ELSE IF lease # 0 THEN Failed(i, FALSE, s, tok[p])
          ELSE IF ~ConnOK(k.conn)
               THEN Commit(i, "fail", TRUE, Adopted(s), AdoptedTok(s, tok[p]), cache, 0, FALSE, FALSE)
          ELSE LET s1 == IF ok THEN [s EXCEPT !.pts = k.tok] ELSE s
               IN Commit(i, "ok", FALSE, s1, tok[p], Snap(s1), 0, TRUE, TRUE)
    /\ UNCHANGED <<tokValid, TaskVars>>

\* checkHistory(context, publish:): checkGeneration, historyContext ==
\* context, then under the lease the record must still be context's
\* connection (else connectionChanged); publish stores history and saves.
HistGuard(i) == Check(i) /\ (~FaithfulHistoryContextCheck \/ Ctx(cur[P(i)]) = call[i].ctx)
HistRecordOK(i) == lease = 0 /\ (~FaithfulLeaseConnCheck \/ rconn = call[i].ctx[1])

\* A failed checkHistory(publish:) goes to the catch: checkGeneration,
\* historyContext == context, then current.history = the stale version (no
\* cache save). h is the history to store.
HistPublish(i, h) ==
    LET s == cur[P(i)] IN
    IF ~HistGuard(i) THEN Cancelled(i)
    ELSE IF HistRecordOK(i)
         THEN Commit(i, "ok", FALSE, [s EXCEPT !.hist = h], tok[P(i)], Snap([s EXCEPT !.hist = h]), 0, TRUE, TRUE)
         ELSE Commit(i, "ok", FALSE, [s EXCEPT !.hist = h], tok[P(i)], cache, lease, TRUE, FALSE)

\* fetchHistory: checkHistory(context); token must be valid; then read. A
\* non-cancellation error builds a failure history from current.history
\* (labeled context) and publishes it.
HistBody(i) ==
    /\ call[i].pc = "body" /\ call[i].kind = "history"
    /\ LET p == P(i) IN
       IF ~HistGuard(i) THEN Cancelled(i)
       ELSE IF ~HistRecordOK(i) \/ tok[p] = 0 \/ ~tokValid[p]
            THEN HistPublish(i, call[i].ctx)
            ELSE Continue(i, "hist", [call[i] EXCEPT !.tok = tok[p]], cur[p], tok[p], cache, lease, FALSE, FALSE)
    /\ UNCHANGED <<tokValid, TaskVars>>

\* HistoryReader.read(validate: checkHistory) and checkHistory(publish:).
\* Data is what the token's login returns for the context's subscription.
HistRead(i) ==
    /\ call[i].pc = "hist"
    /\ LET k == call[i] IN
       \E ok \in BOOLEAN : HistPublish(i, IF ok THEN <<k.tok, k.ctx[2], k.ctx[3]>> ELSE k.ctx)
    /\ UNCHANGED <<tokValid, TaskVars>>

\* fetchInvoices: paymentReview = nil; connectionID = current.connectionID;
\* the token must be valid (else the catch); await api.invoices.
\* fetchPaymentReview: paymentReview = .checking first, then the same.
\* Their catch: checkGeneration, withConnectionLease: invoices unavailable
\* (fetchInvoices) or paymentReview = .unavailable (fetchPaymentReview).
InvCatch(i, e, s, t) ==
    IF ~Check(i) THEN Commit(i, "cancel", FALSE, s, t, cache, lease, FALSE, FALSE)
    ELSE IF lease # 0 THEN Failed(i, FALSE, s, t)
    ELSE IF ~ConnOK(e)
         THEN Commit(i, "fail", TRUE, Adopted(s), AdoptedTok(s, t), cache, 0, FALSE, FALSE)
    ELSE IF call[i].kind = "invoices"
         THEN Commit(i, "ok", FALSE, [s EXCEPT !.inv = 0], t, cache, 0, TRUE, FALSE)
         ELSE Commit(i, "ok", FALSE, [s EXCEPT !.review = "done"], t, cache, 0, TRUE, FALSE)

InvBody(i) ==
    /\ call[i].pc = "body" /\ call[i].kind \in {"invoices", "review"}
    /\ LET p == P(i)
           s == [cur[p] EXCEPT !.review = IF call[i].kind = "invoices" THEN "none" ELSE "checking"]
           k == [call[i] EXCEPT !.conn = cur[p].conn, !.tok = tok[p]]
       IN /\ strayCheck' = (strayCheck \/ (call[i].kind = "review" /\ ~Fresh(i)))
          /\ IF tok[p] = 0 \/ ~tokValid[p]
             THEN InvCatch(i, cur[p].conn, s, tok[p])
             ELSE Continue(i, "inv", k, s, tok[p], cache, lease, FALSE, FALSE)
    /\ UNCHANGED <<tokValid, rconn, conns, gen, revs, cancels, nCalls, restoredOther, optCancelled>>

\* After await api.invoices. fetchInvoices: withConnectionLease {
\* checkGeneration; store; save }. fetchPaymentReview: checkGeneration;
\* withConnectionLease { store; save }; select the invoice; render the QR
\* (merged) and set .ready or .unavailable under the lease.
Invoices(i) ==
    /\ call[i].pc = "inv"
    /\ LET p == P(i)
           k == call[i]
           s == cur[p]
           s1 == [s EXCEPT !.inv = k.tok, !.review = IF k.kind = "review" THEN "done" ELSE @]
       IN \/ InvCatch(i, k.conn, s, tok[p])
          \/ IF ~Check(i) THEN Cancelled(i)
             ELSE IF lease # 0 THEN Failed(i, FALSE, s, tok[p])
             ELSE IF ~ConnOK(k.conn) THEN InvCatch(i, k.conn, Adopted(s), AdoptedTok(s, tok[p]))
             ELSE Commit(i, "ok", FALSE, s1, tok[p], Snap(s1), 0, TRUE, TRUE)
    /\ UNCHANGED <<tokValid, TaskVars>>

\* connect: validate, lease.acquire() (busy -> sessionBusy), held across
\* the token request; Task.checkCancellation.
ConnBody(i) ==
    /\ call[i].pc = "body" /\ call[i].kind = "connect"
    /\ LET p == P(i) IN
       IF lease # 0 THEN Failed(i, FALSE, cur[p], tok[p])
       ELSE IF ~Check(i) THEN Cancelled(i)
       ELSE Continue(i, "token", call[i], cur[p], tok[p], cache, i, FALSE, FALSE)
    /\ UNCHANGED <<tokValid, TaskVars>>

\* connect: await api.token(password); saveRecord(new ConnectionID());
\* checkGeneration; current.connectionID = new; token = received; the
\* lease handle's defer releases.
ConnToken(i) ==
    /\ call[i].pc = "token"
    /\ LET p == P(i) IN
       \/ Commit(i, "fail", FALSE, cur[p], tok[p], cache, 0, FALSE, FALSE)
          /\ UNCHANGED <<rconn, conns, tokValid>>
       \/ /\ conns < MaxConns
          /\ conns' = conns + 1
          /\ rconn' = conns + 1
          /\ IF ~Check(i)
             THEN Commit(i, "cancel", FALSE, cur[p], tok[p], cache, 0, FALSE, FALSE) /\ UNCHANGED tokValid
             ELSE /\ tokValid' = [tokValid EXCEPT ![p] = TRUE]
                  /\ Commit(i, "ok", FALSE, [cur[p] EXCEPT !.conn = conns + 1], conns + 1, cache, 0, FALSE, FALSE)
    /\ UNCHANGED <<gen, revs, cancels, nCalls, Flags>>

-----------------------------------------------------------------------------

\* Every call has returned and the call budget is spent: stop, not deadlock.
Finished == nCalls = MaxCalls /\ (\A i \in 1..MaxCalls : call[i].pc = "done") /\ UNCHANGED vars

Next ==
    \/ \E p \in Procs :
        \/ RefreshStart(p) \/ Restore(p) \/ Bundle(p) \/ ConnectStart(p)
        \/ \E x \in Subs : SelectStart(p, x)
        \/ \E kind \in Optional : OptStart(p, kind)
        \/ Cancel(p) \/ Expire(p)
    \/ \E i \in 1..MaxCalls :
        \/ OptWait(i) \/ Prev(i)
        \/ RefreshAuth(i) \/ PointsAuth(i) \/ Exchange(i) \/ Subs_(i) \/ Balance(i) \/ Points(i)
        \/ HistBody(i) \/ HistRead(i) \/ InvBody(i) \/ Invoices(i) \/ ConnBody(i) \/ ConnToken(i)
    \/ Finished

Spec == Init /\ [][Next]_vars

\* The two processes run the same code.
ProcSymmetry == Permutations(Procs)

-----------------------------------------------------------------------------
(* Rules.                                                                  *)

\* Data in a state comes from that state's connection, and balance and
\* history from its selected subscription.
Siloed(x) ==
    /\ x.bal \in {NoBal, <<x.conn, x.sub>>}
    /\ x.pts \in {0, x.conn}
    /\ x.inv \in {0, x.conn}
    /\ x.hist = NoHist \/ (x.hist[1] = x.conn /\ x.hist[2] = x.sub)

\* The cache file never holds one connection's or subscription's data
\* under another's label. Harm: the next launch (app or CLI restore) shows
\* the previous login's balance, points, or bills, or one SIM's usage
\* under another SIM's name.
CacheSiloed == cache.conn = 0 \/ Siloed(cache)

\* What each worker reports is siloed the same way. Harm: the menu or CLI
\* shows another login's or another SIM's data.
ShownSiloed == \A p \in Procs : Siloed(cur[p])

\* Shown history is for the selected subscription, bundle, and revision.
\* Harm: the history chart shows another SIM's or bundle's usage.
HistoryMatchesContext == \A p \in Procs : cur[p].hist \in {NoHist, Ctx(cur[p])}

\* No cache save labels a connection the Keychain no longer holds. Harm: a
\* worker still on the old login overwrites the cache of the login the user
\* just connected, so the next launch opens empty.
CacheSavesCurrentConnection == ~deadSave

\* restore() ends on the Keychain record's connection. Harm: after a
\* reconnect (maybe another login) the app or CLI shows the old login.
RestoreShowsCurrentConnection == ~restoredOther

\* A cancelled or superseded call writes no data and no cache. Harm: an
\* older refresh or read overwrites the newer one's result.
NoStaleDataWrite == ~staleWrite

\* A cancelled or superseded payment review does not set .checking. Harm:
\* after the user closes the payment review, the worker still reports
\* "Checking"; the app's next configure or restore reply shows it again.
NoStaleReviewCheck == ~strayCheck

\* isRefreshing only while a non-optional flight runs. Harm: a stuck
\* refresh spinner.
NoStuckSpinner == \A p \in Procs : cur[p].refreshing => (flight[p] # 0 /\ call[flight[p]].nonopt)

\* While a task runs its operation, self.flight is set. Harm: restore,
\* selectBundle, or bootstrap run alongside it and mix states.
FlightTracksRunning ==
    \A i \in 1..MaxCalls : call[i].pc \notin {"none", "wait", "prev", "done"} => flight[P(i)] # 0

\* An optional read never cancels a running refresh. Harm: background
\* points or history reads abort the user's refresh.
OptionalNeverCancelsRefresh == ~optCancelled

=============================================================================
