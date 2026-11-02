---------------------------- MODULE TokenRotation ----------------------------
(***************************************************************************)
(* Mobile Vikings refresh-token rotation across VikingBar app and CLI      *)
(* workers that share one account's Keychain record and session.lock.     *)
(*                                                                         *)
(* Code (Sources/VikingBarCore):                                           *)
(*   VikingSession.swift      VikingSession.authorize, VikingSession.connect *)
(*   SessionPersistence.swift FileSessionLease.acquire, FileLeaseHandle,   *)
(*                            KeychainSessionStore, StoredSession          *)
(*                                                                         *)
(* One Worker is one in-flight authorize/connect call. Two calls in one    *)
(* process are separate Workers: each opens its own descriptor, and flock  *)
(* refuses the second one with EWOULDBLOCK, exactly as across processes.   *)
(* One TLC step is one effect another worker or the server can observe:    *)
(* one flock, one Keychain read or write, one token request at the server, *)
(* one response arrival. Crash releases the flock because the kernel       *)
(* closes the descriptor.                                                  *)
(*                                                                         *)
(* The four Faithful* constants are TRUE for the code as written. Each     *)
(* mutant config in formal/mutants turns one off to prove a rule can fail. *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Workers,                      \* concurrent authorize/connect calls
    MaxTokens,                    \* bound on refresh tokens the server issues
    MaxConnections,               \* bound on reconnects
    \* authorize: record.rotationPending = true; try self.saveRecord(record)
    \*            happens before api.token.
    FaithfulMarkPendingFirst,
    \* authorize: `defer { handle.release() }` keeps session.lock held
    \*            across the awaited exchange and the final saveRecord.
    FaithfulHoldLeaseAcrossExchange,
    \* authorize/restore: `guard !record.rotationPending` -> reconnectRequired.
    FaithfulHonorPending,
    \* authorize: a failed exchange or failed final save writes nothing, so
    \*            the Keychain record keeps rotationPending = true.
    FaithfulKeepPendingOnFailure

None == "none"

VARIABLES
    lease,      \* worker holding session.lock, or None
    store,      \* Keychain StoredSession: [conn, token, pending]
    valid,      \* refresh tokens the server still accepts
    issued,     \* refresh tokens issued so far (also the newest token id)
    conns,      \* connection incarnations created so far
    pc,         \* worker program counter
    copy,       \* worker's local `var record` loaded from Keychain
    reply,      \* refresh token in the worker's response, 0 = none
    latestConn, \* history: connection of the last successful connect save
    sentRetired \* history: some worker sent a token the server had rotated

vars == <<lease, store, valid, issued, conns, pc, copy, reply, latestConn, sentRetired>>

Records == [conn : 1..MaxConnections, token : 0..MaxTokens, pending : BOOLEAN]

PCs == {"idle",
        "rLocked", "rLoaded", "rMarked", "rWaiting",   \* authorize
        "cLocked", "cWaiting"}                         \* connect

TypeOK ==
    /\ lease \in Workers \cup {None}
    /\ store \in Records
    /\ valid \subseteq 1..MaxTokens
    /\ issued \in 0..MaxTokens
    /\ conns \in 1..MaxConnections
    /\ pc \in [Workers -> PCs]
    /\ copy \in [Workers -> Records]
    /\ reply \in [Workers -> 0..MaxTokens]
    /\ latestConn \in 1..MaxConnections
    /\ sentRetired \in BOOLEAN

\* Start connected: one connection, one valid refresh token in Keychain.
Init ==
    /\ lease = None
    /\ store = [conn |-> 1, token |-> 1, pending |-> FALSE]
    /\ valid = {1}
    /\ issued = 1
    /\ conns = 1
    /\ pc = [w \in Workers |-> "idle"]
    /\ copy = [w \in Workers |-> store]
    /\ reply = [w \in Workers |-> 0]
    /\ latestConn = 1
    /\ sentRetired = FALSE

Holds(w) == lease = w

\* Ends a call. The lease handle's defer/deinit releases the flock.
Finish(w) ==
    /\ pc' = [pc EXCEPT ![w] = "idle"]
    /\ reply' = [reply EXCEPT ![w] = 0]
    /\ lease' = IF Holds(w) THEN None ELSE lease

\* FileSessionLease.acquire: flock(LOCK_EX | LOCK_NB). Busy callers throw
\* LiveFailure.busy and stay idle, which needs no step.
AcquireForRefresh(w) ==
    /\ pc[w] = "idle"
    /\ lease = None
    /\ lease' = w
    /\ pc' = [pc EXCEPT ![w] = "rLocked"]
    /\ UNCHANGED <<store, valid, issued, conns, copy, reply, latestConn, sentRetired>>

\* authorize: loadRecord(). A pending record throws reconnectRequired. A
\* reusable in-memory access token (canReuse) returns without rotating.
LoadForRefresh(w) ==
    /\ pc[w] = "rLocked"
    /\ copy' = [copy EXCEPT ![w] = store]
    /\ \/ /\ store.pending /\ FaithfulHonorPending
          /\ Finish(w)
       \/ /\ Finish(w)                                   \* canReuse
       \/ /\ ~(store.pending /\ FaithfulHonorPending)
          /\ pc' = [pc EXCEPT ![w] = "rLoaded"]
          /\ UNCHANGED <<lease, reply>>
    /\ UNCHANGED <<store, valid, issued, conns, latestConn, sentRetired>>

\* authorize: record.rotationPending = true; try self.saveRecord(record).
\* A failed save throws LiveFailure.storage before any request.
MarkPending(w) ==
    /\ pc[w] = "rLoaded"
    /\ IF FaithfulMarkPendingFirst
       THEN \/ /\ store' = [copy[w] EXCEPT !.pending = TRUE]
               /\ pc' = [pc EXCEPT ![w] = "rMarked"]
               /\ UNCHANGED <<lease, reply>>
            \/ /\ Finish(w)
               /\ UNCHANGED store
       ELSE /\ pc' = [pc EXCEPT ![w] = "rMarked"]
            /\ UNCHANGED <<store, lease, reply>>
    /\ UNCHANGED <<valid, issued, conns, copy, latestConn, sentRetired>>

\* The refresh_token grant reaching the server. The server rotates: the old
\* token stops working and a new one is issued. A request that never reaches
\* the server is the failure branch of ReceiveRefresh with reply = 0.
ServerRotates(w) ==
    /\ pc[w] = "rMarked"
    /\ issued < MaxTokens
    /\ LET t == copy[w].token IN
       IF t \in valid
       THEN /\ issued' = issued + 1
            /\ valid' = (valid \ {t}) \cup {issued + 1}
            /\ reply' = [reply EXCEPT ![w] = issued + 1]
            /\ UNCHANGED sentRetired
       ELSE /\ sentRetired' = TRUE
            /\ UNCHANGED <<issued, valid, reply>>
    /\ pc' = [pc EXCEPT ![w] = "rWaiting"]
    \* Mutant: drop the lock while awaiting the exchange.
    /\ lease' = IF FaithfulHoldLeaseAcrossExchange THEN lease ELSE None
    /\ UNCHANGED <<store, conns, copy, latestConn>>

RequestLost(w) ==
    /\ pc[w] = "rMarked"
    /\ pc' = [pc EXCEPT ![w] = "rWaiting"]
    /\ lease' = IF FaithfulHoldLeaseAcrossExchange THEN lease ELSE None
    /\ UNCHANGED <<store, valid, issued, conns, copy, reply, latestConn, sentRetired>>

\* Response handling. Success saves the whole replacement record:
\* refreshToken = received, rotationPending = false, generation += 1.
\* Failure (lost response, malformed body, invalid_grant, failed final
\* save) writes nothing and throws reconnectRequired.
ReceiveRefresh(w) ==
    /\ pc[w] = "rWaiting"
    /\ \/ /\ reply[w] # 0
          /\ store' = [copy[w] EXCEPT !.token = reply[w], !.pending = FALSE]
       \/ /\ FaithfulKeepPendingOnFailure
          /\ UNCHANGED store
       \/ /\ ~FaithfulKeepPendingOnFailure                \* mutant: roll back
          /\ store' = [copy[w] EXCEPT !.pending = FALSE]
    /\ Finish(w)
    /\ UNCHANGED <<valid, issued, conns, copy, latestConn, sentRetired>>

\* VikingSession.connect: lease, password grant, save a new connection.
AcquireForConnect(w) ==
    /\ pc[w] = "idle"
    /\ lease = None
    /\ conns < MaxConnections
    /\ lease' = w
    /\ pc' = [pc EXCEPT ![w] = "cLocked"]
    /\ UNCHANGED <<store, valid, issued, conns, copy, reply, latestConn, sentRetired>>

\* The password grant issues a token in a new family. Old-family tokens are
\* left as they were: whether the server revokes them is unknown.
ServerGrants(w) ==
    /\ pc[w] = "cLocked"
    /\ issued < MaxTokens
    /\ issued' = issued + 1
    /\ valid' = valid \cup {issued + 1}
    /\ reply' = [reply EXCEPT ![w] = issued + 1]
    /\ pc' = [pc EXCEPT ![w] = "cWaiting"]
    /\ UNCHANGED <<lease, store, conns, copy, latestConn, sentRetired>>

\* Success saves StoredSession(connectionID: ConnectionID(), generation: 0,
\* rotationPending: false). Failure (lost response, keychainWrite) saves
\* nothing; the previous connection stays as it was.
ReceiveConnect(w) ==
    /\ pc[w] = "cWaiting"
    /\ \/ /\ conns' = conns + 1
          /\ store' = [conn |-> conns + 1, token |-> reply[w], pending |-> FALSE]
          /\ latestConn' = conns + 1
       \/ UNCHANGED <<conns, store, latestConn>>
    /\ Finish(w)
    /\ UNCHANGED <<valid, issued, copy, sentRetired>>

\* Process exit, kill, or reboot at any point: the kernel releases the flock.
Crash(w) ==
    /\ pc[w] # "idle"
    /\ Finish(w)
    /\ UNCHANGED <<store, valid, issued, conns, copy, latestConn, sentRetired>>

Next ==
    \/ \E w \in Workers :
        \/ AcquireForRefresh(w) \/ LoadForRefresh(w) \/ MarkPending(w)
        \/ ServerRotates(w) \/ RequestLost(w) \/ ReceiveRefresh(w)
        \/ AcquireForConnect(w) \/ ServerGrants(w) \/ ReceiveConnect(w)
        \/ Crash(w)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Rules. Each guards a user-visible harm.                                 *)

\* A record that does not ask for reconnect holds a refresh token the server
\* still accepts. Harm: the app keeps retrying a dead token on every refresh
\* and reports transport failures instead of asking the user to reconnect.
StoredTokenUsable == ~store.pending => store.token \in valid

\* No worker sends a refresh token the server already rotated away. Harm:
\* the server can treat reuse as theft and revoke the session another
\* worker just obtained; at best the user is told to reconnect for nothing.
NoRetiredTokenSent == ~sentRetired

\* The Keychain holds the connection from the most recent successful
\* connect. Harm: a reconnect the user just completed is silently replaced
\* by the previous connection, possibly another login.
ReconnectSticks == store.conn = latestConn

=============================================================================
