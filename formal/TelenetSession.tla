--------------------------- MODULE TelenetSession ---------------------------
(***************************************************************************)
(* Telenet home cookie session across VikingBar app and CLI workers that   *)
(* share one account's Keychain record and session.lock.                   *)
(*                                                                         *)
(* Code (Sources/VikingBarCore):                                           *)
(*   TelenetHomeAccount.swift  connect, refresh, read, reserveAttempt,     *)
(*                             finishFailure, Record                       *)
(*   TelenetAPI.swift          send (cookie jar receive, 401/429 mapping)  *)
(*   SessionPersistence.swift  FileSessionLease, KeychainSessionStore      *)
(*                                                                         *)
(* One Worker is one connect/refresh call. Each TLC step is one effect     *)
(* another worker or Telenet can observe: a flock plus loadRecord, a       *)
(* Keychain write, one request at Telenet, one response. The discover and  *)
(* usage reads of one call are merged into one request: the record is      *)
(* written only before and after them, and the lease is held throughout.   *)
(* Crash releases the flock. Time is in whole minutes; the manual floor    *)
(* (nextAttemptAt = now + 60 s) is one minute.                             *)
(*                                                                         *)
(* Faithful* constants are TRUE for the code as written; each mutant in    *)
(* formal/mutants/TelenetSession turns one off.                            *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    Workers,
    MaxTime,          \* minutes explored
    MaxCookies,       \* bound on cookie sessions Telenet issues
    MaxConnections,   \* bound on saved logins
    Backoff,          \* failureDeadline, scaled down (code: 30+ minutes)
    RetryAfter,       \* a 429 Retry-After, in minutes from now
    \* reserveAttempt: guard self.now() >= deadline else rateLimited.
    FaithfulReserveChecksDeadline,
    \* connect/refresh: `defer { handle.release() }` holds session.lock
    \*                  until the final saveRecord.
    FaithfulHoldLeaseThroughRead,
    \* finishFailure: rotationPending = authenticationFailed on 401/403/3xx.
    FaithfulAuthFailureMarksReconnect,
    \* finishFailure: serverRetryAfter = max(serverRetryAfter, retryAfter).
    FaithfulSaveRetryAfter,
    \* refresh: guard !record.rotationPending else reconnectRequired.
    FaithfulRefreshHonorsPending,
    \* reserveAttempt and connect's new Record leave rotationPending alone
    \* (#55, fixed in #61); FALSE restores the old `rotationPending: true`.
    FaithfulInterruptKeepsSession

None == "none"
Never == 0           \* deadlines hold minute + 1, so 0 means "none"
At(m) == m + 1
Max(a, b) == IF a > b THEN a ELSE b

VARIABLES
    now,
    lease,       \* worker holding session.lock, or None
    store,       \* Keychain Record: conn, cookie, pending, attemptAt, retryAt, allowedAt
    live,        \* cookie sessions Telenet still accepts
    rejected,    \* cookie sessions answered 401 with a record save after
    cookies,     \* cookie sessions issued so far (newest id)
    conns,       \* connection incarnations saved so far
    pc,
    copy,        \* worker's local `var record`
    prior,       \* worker's record.rotationPending as loaded, before reserve
    jar,         \* worker's api.cookies after its last response
    outcome,     \* worker's last response
    latestConn,  \* history: connection of the last saved login
    lastStart,   \* history: At(minute) of the last saved reservation
    announced,   \* history: latest Retry-After deadline received with a record save
    burst,       \* history: a call started inside the floor or a Retry-After
    deadReuse    \* history: a request with a session already answered 401

vars == <<now, lease, store, live, rejected, cookies, conns, pc, copy, prior, jar, outcome,
          latestConn, lastStart, announced, burst, deadReuse>>
worker == <<pc, copy, prior, jar, outcome>>
server == <<live, rejected, cookies>>
history == <<latestConn, lastStart, announced, burst, deadReuse>>

Init ==
    /\ now = 0
    /\ lease = None
    /\ store = [conn |-> 1, cookie |-> 1, pending |-> FALSE,
                attemptAt |-> Never, retryAt |-> Never, allowedAt |-> Never]
    /\ live = {1}
    /\ rejected = {}
    /\ cookies = 1
    /\ conns = 1
    /\ pc = [w \in Workers |-> "idle"]
    /\ copy = [w \in Workers |-> store]
    /\ prior = [w \in Workers |-> FALSE]
    /\ jar = [w \in Workers |-> 0]
    /\ outcome = [w \in Workers |-> "none"]
    /\ latestConn = 1
    /\ lastStart = Never
    /\ announced = Never
    /\ burst = FALSE
    /\ deadReuse = FALSE

Goto(w, p) == pc' = [pc EXCEPT ![w] = p]

\* End of a call; the lease handle's defer releases the flock.
Finish(w) ==
    /\ Goto(w, "idle")
    /\ lease' = IF lease = w THEN None ELSE lease

Tick ==
    /\ now < MaxTime
    /\ now' = now + 1
    /\ UNCHANGED <<lease, store, conns, worker, server, history>>

\* Telenet ends a session on its own: natural expiry or revocation.
SessionEnds ==
    /\ \E c \in live : live' = live \ {c}
    /\ UNCHANGED <<now, lease, store, conns, worker, rejected, cookies, history>>

\* lease.acquire() then loadRecord(). A busy lease throws busy: no step.
Acquire(w, kind) ==
    /\ pc[w] = "idle"
    /\ lease = None
    /\ lease' = w
    /\ copy' = [copy EXCEPT ![w] = store]
    /\ prior' = [prior EXCEPT ![w] = store.pending]
    /\ Goto(w, kind)
    /\ UNCHANGED <<now, store, conns, jar, outcome, server, history>>

\* refresh: guard !rotationPending. reserveAttempt: deadline check (connect
\* ignores the failure backoff), then nextAttemptAt = now + 60 s, saved
\* before any request; rotationPending keeps its loaded value. Both throw
\* outside the do/catch, so a refusal or failed save writes nothing more.
Reserve(w) ==
    /\ pc[w] \in {"refresh", "connect"}
    /\ LET r == copy[w]
           deadline == IF pc[w] = "connect" THEN Max(r.attemptAt, r.retryAt)
                       ELSE Max(r.attemptAt, Max(r.retryAt, r.allowedAt))
           due == At(now) >= deadline
           reserved == [r EXCEPT !.attemptAt = At(now + 1),
                                 !.pending = (r.pending \/ ~FaithfulInterruptKeepsSession)]
       IN IF (pc[w] = "refresh" /\ r.pending /\ FaithfulRefreshHonorsPending)
             \/ (~due /\ FaithfulReserveChecksDeadline)
          THEN Finish(w) /\ UNCHANGED <<store, copy, lastStart, burst>>
          ELSE \/ /\ store' = reserved
                  /\ copy' = [copy EXCEPT ![w] = reserved]
                  /\ Goto(w, IF pc[w] = "refresh" THEN "reading" ELSE "loggingIn")
                  /\ lease' = IF FaithfulHoldLeaseThroughRead THEN lease ELSE None
                  /\ lastStart' = At(now)
                  /\ burst' = (burst \/ lastStart = At(now) \/ At(now) < announced)
               \/ Finish(w) /\ UNCHANGED <<store, copy, lastStart, burst>>
    /\ UNCHANGED <<now, conns, prior, jar, outcome, server, latestConn, announced, deadReuse>>

Answer(w, o, c) ==
    /\ outcome' = [outcome EXCEPT ![w] = o]
    /\ jar' = [jar EXCEPT ![w] = c]

\* discover + read with the record's cookie jar. Telenet answers ok (it may
\* replace the cookie), 429 with Retry-After, 401 for a dead session, or the
\* response is lost after Telenet acted (transport).
ReadRequest(w) ==
    /\ pc[w] = "reading"
    /\ LET c == copy[w].cookie IN
       /\ deadReuse' = (deadReuse \/ c \in rejected)
       /\ IF c \in live
          THEN \/ Answer(w, "ok", c) /\ UNCHANGED <<live, cookies>>
               \/ /\ cookies < MaxCookies
                  /\ cookies' = cookies + 1
                  /\ live' = (live \ {c}) \cup {cookies + 1}
                  /\ \/ Answer(w, "ok", cookies + 1)
                     \/ Answer(w, "transport", c)
               \/ /\ \E o \in {"rateLimited", "transport"} : Answer(w, o, c)
                  /\ UNCHANGED <<live, cookies>>
          ELSE /\ \E o \in {"unauthorized", "transport"} : Answer(w, o, c)
               /\ UNCHANGED <<live, cookies>>
    /\ Goto(w, "readAnswered")
    /\ UNCHANGED <<now, lease, store, conns, copy, prior, rejected, latestConn, lastStart, announced, burst>>

\* finishFailure: cookies = api.cookies, rotationPending = authenticationFailed,
\* serverRetryAfter = max(..), nextAllowedAt = failureDeadline.
Failed(r, o, c) ==
    [r EXCEPT !.cookie = c,
              !.pending = (o = "unauthorized" /\ FaithfulAuthFailureMarksReconnect),
              !.retryAt = IF o = "rateLimited" /\ FaithfulSaveRetryAfter
                          THEN Max(r.retryAt, At(now + RetryAfter)) ELSE r.retryAt,
              !.allowedAt = Max(r.allowedAt, At(now + Backoff))]

\* A 429 counts once a record save follows it. A crash or a failed save
\* before that loses the deadline in any design.
Announce(w) ==
    announced' = IF outcome[w] = "rateLimited" /\ store' # store
                 THEN Max(announced, At(now + RetryAfter)) ELSE announced

\* read: success saves cookies, rotationPending = false. If that save throws,
\* the catch runs finishFailure (storage, not auth) and saves again. Any
\* failure runs finishFailure. If the last save throws, the reserved record
\* stays. Like a 429, a 401 counts once finishFailure's save lands: a crash
\* or failed save before that loses it in any design that does not flag
\* every reservation as pending (the #55 bug).
ReadFinish(w) ==
    /\ pc[w] = "readAnswered"
    /\ LET r == copy[w]
           o == outcome[w]
       IN \/ /\ o = "ok"
             /\ store' = [r EXCEPT !.cookie = jar[w], !.pending = FALSE, !.allowedAt = Never]
             /\ UNCHANGED rejected
          \/ /\ o = "ok"
             /\ store' = Failed(r, "storage", jar[w])
             /\ UNCHANGED rejected
          \/ /\ o # "ok"
             /\ store' = Failed(r, o, jar[w])
             /\ rejected' = IF o = "unauthorized" THEN rejected \cup {jar[w]} ELSE rejected
          \/ UNCHANGED <<store, rejected>>
    /\ Finish(w)
    /\ Announce(w)
    /\ UNCHANGED <<now, conns, copy, prior, jar, outcome, live, cookies, latestConn, lastStart, burst, deadReuse>>

\* connect: api.login with the password starts a new cookie session.
LoginRequest(w) ==
    /\ pc[w] = "loggingIn"
    /\ \/ /\ cookies < MaxCookies
          /\ cookies' = cookies + 1
          /\ live' = live \cup {cookies + 1}
          /\ \/ Answer(w, "ok", cookies + 1) /\ Goto(w, "loggedIn")
             \/ Answer(w, "transport", cookies + 1) /\ Goto(w, "loginFailed")
       \/ /\ \E o \in {"unauthorized", "rateLimited", "transport"} : Answer(w, o, 0)
          /\ Goto(w, "loginFailed")
          /\ UNCHANGED <<live, cookies>>
    /\ UNCHANGED <<now, lease, store, conns, copy, prior, rejected, history>>

\* connect: record = Record(connectionID: ConnectionID(), established: true)
\* with rotationPending defaulting to false; saveRecord; then discover +
\* read. A failed save throws inside the do: the catch sees a new
\* connection (.currentSession) and finishFailure saves the same new record
\* with pending = false.
LoginSaved(w) ==
    /\ pc[w] = "loggedIn"
    /\ conns < MaxConnections
    /\ conns' = conns + 1
    /\ LET r == [copy[w] EXCEPT !.conn = conns + 1, !.cookie = jar[w],
                                !.pending = ~FaithfulInterruptKeepsSession]
       IN \/ /\ store' = r
             /\ copy' = [copy EXCEPT ![w] = r]
             /\ latestConn' = conns + 1
             /\ Goto(w, "reading")
             /\ UNCHANGED lease
          \/ /\ store' = Failed(r, "storage", jar[w])
             /\ latestConn' = conns + 1
             /\ Finish(w)
             /\ UNCHANGED copy
          \/ /\ Finish(w)
             /\ UNCHANGED <<store, copy, latestConn>>
    /\ UNCHANGED <<now, prior, jar, outcome, server, lastStart, announced, burst, deadReuse>>

\* finishFailure(.replacementLogin): the prior record keeps its cookies,
\* gets back its prior needsReconnect, and saves retry/backoff deadlines.
LoginFinishFailed(w) ==
    /\ pc[w] = "loginFailed"
    /\ LET r == copy[w]
           o == outcome[w]
       IN \/ store' = [Failed(r, o, r.cookie) EXCEPT !.pending = prior[w]]
          \/ UNCHANGED store
    /\ Finish(w)
    /\ Announce(w)
    /\ UNCHANGED <<now, conns, copy, prior, jar, outcome, server, latestConn, lastStart, burst, deadReuse>>

\* Process exit, kill, Ctrl-C, or reboot: the kernel releases the flock.
Crash(w) ==
    /\ pc[w] # "idle"
    /\ Finish(w)
    /\ UNCHANGED <<now, store, conns, copy, prior, jar, outcome, server, history>>

Next ==
    \/ Tick \/ SessionEnds
    \/ \E w \in Workers :
        \/ Acquire(w, "refresh") \/ Acquire(w, "connect") \/ Reserve(w)
        \/ ReadRequest(w) \/ ReadFinish(w)
        \/ LoginRequest(w) \/ LoginSaved(w) \/ LoginFinishFailed(w)
        \/ Crash(w)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules.                                                                  *)

\* No call starts its requests within a minute of the previous call's start
\* or before a saved Retry-After. Harm: VikingBar hammers Telenet after it
\* asked to wait, which risks blocking the account.
RequestsSpaced == ~burst

\* No request reuses a cookie session that Telenet already answered 401 for
\* and whose 401 VikingBar saved.
\* Harm: a background loop of failing requests instead of one reconnect prompt.
NoRejectedSessionReuse == ~deadReuse

\* The Keychain keeps the connection from the latest saved login. Harm: a
\* reconnect the user just finished is replaced by the old session.
ReconnectSticks == store.conn = latestConn

\* When no call is running, the record asks for reconnect only if Telenet no
\* longer accepts its session. Harm: quitting the app or pressing Ctrl-C in
\* the CLI mid-refresh forces a password sign-in for a working session.
ReconnectOnlyWhenNeeded == (lease = None /\ store.pending) => store.cookie \notin live

=============================================================================
