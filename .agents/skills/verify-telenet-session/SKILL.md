---
name: verify-telenet-session
description: "Model-check Telenet cookie session, reconnect, cooldown, and Retry-After changes."
---

# Verify the Telenet session

Use this skill before handing off any change to how VikingBar signs in to Telenet, refreshes home usage, or stores the Telenet session record. A TLA+ model, `formal/TelenetSession.tla`, checks every interleaving of two concurrent workers (app and CLI calls). It covers crashes at any step, Telenet ending or replacing cookie sessions, 401 and 429 answers, lost responses, failed Keychain writes, and time passing in whole minutes.

## Rules the model checks

- `RequestsSpaced`: no call starts within a minute of the previous call's start, or before a saved `Retry-After`. Harm: VikingBar hammers Telenet after it asked to wait.
- `NoRejectedSessionReuse`: no request reuses a cookie session that Telenet already answered 401 for, once that 401's record save landed. Harm: a background loop of failing requests instead of one reconnect prompt.
- `ReconnectSticks`: the Keychain keeps the connection from the latest saved login. Harm: a reconnect the user just finished is replaced by the old session.
- `ReconnectOnlyWhenNeeded`: with no call running, the record asks for reconnect only if Telenet no longer accepts its session. Harm: quitting the app or pressing Ctrl-C mid-refresh forces a password sign-in for a working session. Was open finding [#55](https://github.com/BramVR/VikingBar/issues/55), fixed in #61: `reserveAttempt` and connect's new `Record` no longer set `rotationPending`.

## Coverage and sync

Sync commit: `d4f3a59`. At that commit the model describes this code:

- `Sources/VikingBarCore/TelenetHomeAccount.swift`: `connect`, `restore` (pending check only), `refresh`, `read`, `reserveAttempt`, `finishFailure`, `loadRecord`, `saveRecord`, `Record`.
- `Sources/VikingBarCore/TelenetAPI.swift`: `send` and `json` (cookie receive, 401/403/3xx/429 mapping).
- `Sources/VikingBarCore/SessionPersistence.swift`: `FileSessionLease`, `KeychainSessionStore`.

To see whether a change needs a recheck:

```sh
git diff --stat d4f3a59 -- Sources/VikingBarCore/TelenetHomeAccount.swift Sources/VikingBarCore/TelenetAPI.swift Sources/VikingBarCore/SessionPersistence.swift
```

Output means: read the diff against the mapping below before trusting a pass.

## Run

```sh
./Scripts/check-formal.sh TelenetSession   # `make check-formal` runs every model
```

Needs Java 11+; the first run downloads pinned TLC. It takes about 20 seconds (12 million states). Logs are in `.build/formal/TelenetSession*.log`.

Expect one `PASS TelenetSession` and six `PASS ... mutant` lines. No findings are open. Any `FAIL` is a problem:

- The main model failing: a rule that held now breaks. That is a finding about the change.
- A mutant passing: the model lost the power to catch that bug. Fix the model.
- A finding no longer breaking: the code changed. If it was fixed on purpose, move its rule into `formal/TelenetSession.cfg`, turn the finding into a mutant with a new `Faithful*` flag (as `InterruptForcesReconnect` was for #55), and say so on the issue. Otherwise find out what changed.

Read every result with the pstack `/statechart` skill on `formal/TelenetSession.tla` and the config that produced it: on a failure, its shortest bad path in plain words; on a pass, a chart of how a session moves. With 12 million states, give `/statechart` a smaller config (one worker, `MaxTime = 2`) for the chart.

## Model-to-code mapping

- `Acquire`: `self.lease.acquire()` then `loadRecord()`. `busy` and a held flock both throw before any step. `prior` is `record.rotationPending` as loaded, which connect hands to `finishFailure(.replacementLogin)`.
- `Reserve`: refresh's `guard !record.rotationPending`, then `reserveAttempt`. It checks the deadline (connect passes `reconnecting: true`, which ignores `nextAllowedAt`), sets `nextAttemptAt = now + 60`, and saves; `rotationPending` keeps its loaded value. Both throw outside the `do`/`catch`.
- `ReadRequest`: `api.discover()` plus `api.read` as one request: ok (Telenet may replace the cookie), 429, 401 for a dead session, or a lost response. Only a received 401 marks the session rejected.
- `ReadFinish`: `read`'s save on success, or `finishFailure` on failure. If the success save throws, the catch runs `finishFailure` as a storage failure. If the last save throws, the reserved record stays. A 401 marks the session rejected only here, when `finishFailure`'s save lands.
- `LoginRequest` / `LoginSaved`: `api.login`, then the new `Record(connectionID: ConnectionID(), established: true)` (`rotationPending` defaults to false). If that save throws, `finishFailure(.currentSession)` saves the same new connection without the flag.
- `LoginFinishFailed`: `finishFailure(.replacementLogin)`: prior cookies, prior `needsReconnect`, saved deadlines.
- `SessionEnds`: Telenet expiry or revocation. `Crash`: the process ends; the kernel releases the flock.

The `Faithful*` constants are `TRUE` for the code at the sync commit. Each has a mutant in `formal/mutants/TelenetSession/` whose `\* expect:` line names the rule it must break:

- `FaithfulReserveChecksDeadline` → `DeadlineIgnored` breaks `RequestsSpaced`.
- `FaithfulHoldLeaseThroughRead` → `LeaseDroppedDuringRead` breaks `ReconnectSticks`.
- `FaithfulAuthFailureMarksReconnect` → `AuthFailureForgotten` breaks `NoRejectedSessionReuse`.
- `FaithfulSaveRetryAfter` → `RetryAfterDropped` breaks `RequestsSpaced`.
- `FaithfulRefreshHonorsPending` → `PendingIgnored` breaks `NoRejectedSessionReuse`.
- `FaithfulInterruptKeepsSession` → `InterruptForcesReconnect` breaks `ReconnectOnlyWhenNeeded` (the pre-#61 `rotationPending = true` on reserve and new login).

## When a check fails

Map each trace step to the code above. If every step is possible in the code, it is a real bug: tell it in the code's words, as in "the CLI reserves, Telenet answers 429, the save fails, the app connects inside the Retry-After". Do not weaken a rule or delete a step to make it pass, and do not change product code unless asked. If asked for a ticket, include the `/statechart` Mermaid chart (from a small config) and the numbered bug path from its report, as in #55. Record a reported finding as `formal/findings/TelenetSession/<Name>.cfg` with `\* expect:` and `\* issue:` lines.

If a step is impossible in the code, the model is wrong. Common modeling errors: a guard the code has but the action lacks; a deadline compared at request time instead of at reservation; a history variable that counts something VikingBar could never have known, such as a 401 or 429 whose response was lost.

## When the change is intended

1. Edit the matching actions, one action per observable effect, with a comment that quotes the Swift.
2. Keep every rule backed by at least one mutant; update `Faithful*` comments and `\* expect:` lines.
3. Run the check. Report any new failure as a finding.
4. Move the sync commit forward only after you confirm, file by file, that the model describes the code at the new commit.

## Assumptions and limits

- Telenet may replace a cookie on any response and may end a session at any time; whether it does is unverified, so the model allows both.
- The 401 path stands for every `authenticationFailed` failure (401, 403, 3xx).
- A 429 counts toward `RequestsSpaced`, and a 401 toward `NoRejectedSessionReuse`, only once a record save follows it. A crash or failed write before that loses it; the only guard, flagging every reservation as pending, is the #55 bug. Cost: one repeat request with the dead cookie, whose 401 then saves.
- Bounds: 2 workers, 3 minutes, 4 cookie sessions, 2 saved logins, backoff and `Retry-After` of 2 minutes (the code's backoff is 30 minutes or more; only its order relative to the floor matters).
- Not modeled: hourly automatic polling (an app scheduler deadline, not a record field), the jitter, `failures` counting, daily-usage failures, service selection, the balance cache, and in-actor `busy` and generation checks.
