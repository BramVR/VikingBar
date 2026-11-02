---
name: verify-token-rotation
description: "Model-check Mobile Vikings refresh-token rotation, session.lock, and Keychain session record changes."
---

# Verify token rotation

Use this skill before handing off any change to how VikingBar refreshes, stores, or reconnects a Mobile Vikings session. A TLA+ model, `formal/TokenRotation.tla`, checks every interleaving of three concurrent workers (app and CLI calls), crashes at any step, lost requests and responses, failed Keychain writes, and reconnects. Tests cannot reach most of these orders.

## Rules the model checks

- `StoredTokenUsable`: if the Keychain record does not ask for reconnect, its refresh token still works at the server. Harm: the app retries a dead token on every refresh and shows transport failures instead of asking the user to reconnect.
- `NoRetiredTokenSent`: no worker sends a refresh token that the server already rotated away. Harm: the server can treat reuse as theft and revoke the session another worker just obtained.
- `ReconnectSticks`: the Keychain keeps the connection from the latest successful connect. Harm: a reconnect the user just finished is replaced by the older connection, possibly another login.

## Coverage and sync

Sync commit: `91b1b01`. At that commit the model describes this code:

- `Sources/VikingBarCore/VikingSession.swift`: `authorize`, `connect`, `restore` (pending check only), `loadRecord`, `saveRecord`.
- `Sources/VikingBarCore/SessionPersistence.swift`: `FileSessionLease`, `FileLeaseHandle`, `KeychainSessionStore`, `StoredSession`.
- `Sources/VikingBarCore/LiveAPI.swift`: `LiveAPI.token` (any failure after the server answers counts as a lost response).

Every other caller (`withConnectionLease`, `checkHistory`, `fetchPoints`) only reads the record under the lease and is safe as long as it does not write `StoredSession`. A new writer of `StoredSession` or a new path that sends `refresh_token` is covered code.

To see whether a change needs a recheck:

```sh
git diff --stat 91b1b01 -- Sources/VikingBarCore/VikingSession.swift Sources/VikingBarCore/SessionPersistence.swift Sources/VikingBarCore/LiveAPI.swift
git diff 91b1b01 -G 'saveRecord|store\.save|refresh_token|lease\.acquire|rotationPending' -- Sources
```

No output from both: the model still applies; run the check anyway if the change is about auth. Output: read the diff against the mapping below before trusting a pass.

## Run

```sh
./Scripts/check-formal.sh TokenRotation   # this model only; `make check-formal` runs every model
```

Needs Java 11+ on `PATH`. The first run downloads TLC 1.7.4 into `.build/formal-tools/` and verifies its SHA-256; later runs are offline. A run takes about 5 seconds. Full TLC output is in `.build/formal/TokenRotation*.log`.

Expect five `PASS` lines: the faithful model has no error, and each mutant in `formal/mutants/TokenRotation/` still breaks the rule on its `\* expect:` line. A mutant that stops failing means the model lost the power to catch that bug; fix the model before trusting any pass.

Read every result, pass or fail, with the pstack `/statechart` skill on `formal/TokenRotation.tla` and the config that produced it. On a failure it tells the shortest bad path in plain words; on a pass it draws how a session moves between states. Turn a trace into the code's words with the mapping below.

## Model-to-code mapping

Each action is one effect another worker or the server can observe.

- `AcquireForRefresh` / `AcquireForConnect`: `self.lease.acquire()`, which is `flock(LOCK_EX | LOCK_NB)`. A busy lease throws `LiveFailure.busy` and needs no step. Two calls in one process are two workers: each opens its own descriptor, so flock refuses the second.
- `LoadForRefresh`: `loadRecord()` in `authorize`, then `guard !record.rotationPending` (reconnect) or `canReuse` (return the cached access token).
- `MarkPending`: `record.rotationPending = true; try self.saveRecord(record)`; a failed save throws before any request.
- `ServerRotates` / `RequestLost`: the `refresh_token` grant in `api.token`, reaching or not reaching the server.
- `ReceiveRefresh`: success saves the whole record with the new token and `rotationPending = false`; any failure saves nothing and throws `reconnectRequired`.
- `ServerGrants` / `ReceiveConnect`: the password grant in `connect` and its `saveRecord` of a new `ConnectionID`.
- `Crash`: the process dies at any step; the kernel closes the descriptor and releases the flock.

The four `Faithful*` constants are `TRUE` for the code at the sync commit:

- `FaithfulMarkPendingFirst`: pending is saved before the exchange. Mutant `NoPendingMark` must fail `StoredTokenUsable`.
- `FaithfulHoldLeaseAcrossExchange`: `defer { handle.release() }` keeps the lease through the exchange and final save. Mutant `LeaseDroppedDuringExchange` must fail `ReconnectSticks`.
- `FaithfulHonorPending`: a pending record is never refreshed. Mutant `PendingIgnored` must fail `NoRetiredTokenSent`.
- `FaithfulKeepPendingOnFailure`: a failed exchange or save leaves the record pending. Mutant `PendingClearedOnFailure` must fail `StoredTokenUsable`.

## When a check fails

Map each step of the trace to code. If every step is something the code can do (check the guards and the order of awaits), it is a real bug: report the path in the code's words, as in "the CLI saves pending, the server rotates, the response is lost, the app...". Do not weaken a rule or remove a step to make it pass, and do not change product code unless asked. If asked for a ticket, include the `/statechart` Mermaid chart and the numbered bug path from its report.

If a step is impossible in the code, the model is wrong. Common modeling errors: a step that merges two Keychain writes, a guard the code has but the action lacks, or a bound so small that a needed step is disabled. Fix the action and cite the code that justifies it.

## When the change is intended

1. Edit the matching actions so the model again describes the code; keep one action per observable effect and cite the Swift statement in a comment.
2. If the change removes or replaces a protection that a `Faithful*` constant names, update that constant's meaning, its mutant config, and the mutant's `\* expect:` line. Every rule must keep at least one mutant that breaks it.
3. Run the check. A new failure is a finding about the change: report it, file an issue if asked, and record it as `formal/findings/TokenRotation/<Name>.cfg` with `\* expect:` and `\* issue:` lines so it reports `OPEN` instead of failing. When a fix lands, the finding config fails the run; delete it and add its rule to `formal/TokenRotation.cfg`.
4. Move the sync commit above forward only after you confirm, file by file, that the model describes the code at the new commit.

## Assumptions and limits

- The server retires a refresh token when it rotates it, and a password grant leaves old-family tokens as they were. Neither is confirmed by Mobile Vikings; the first is the cautious reading.
- Bounds: 3 workers, 5 issued tokens, 2 connections (about 60,000 states). A one-time run at 7 tokens and 3 connections (1.9 million states) also passed at the sync commit.
- Not modeled: access-token expiry and reuse across generations, the balance cache, `withConnectionLease` reads, history publication checks, account catalog slots, and Telenet cookie rotation in `TelenetHomeAccount`.
- A request that never reached the server still leaves the record pending, so the user reconnects although the old token works. The model allows this on purpose; it is the documented cost of a non-atomic exchange and Keychain write.
