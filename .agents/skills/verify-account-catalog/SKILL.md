---
name: verify-account-catalog
description: "Model-check accounts-v1.json catalog reserve, select, and replace changes across app and CLI."
---

# Verify the account catalog

Use this skill before handing off any change to `AccountCatalog` in `Sources/VikingBarCore/Accounts.swift`: how accounts are reserved or selected, how `accounts-v1.json` is written, or how `catalog.lock` is taken. A TLA+ model, `formal/AccountCatalog.tla`, checks two concurrent writers (app and CLI), crashes at any step, and readers that read without the lock.

## Rules the model checks

- `NoLostReservation`: a slot whose `reserve` returned success stays listed. Harm: an added account disappears, and its Keychain session and cache become unreachable.
- `SelectedIsListed`: the stored selection is a listed account. Harm: `readExisting` rejects the catalog, and every app and CLI start fails with a storage error.
- `NoTornFile`: no reader can see a half-written file. Harm: the same failure, after a crash or a concurrent read.

All three hold at the sync commit.

## Coverage and sync

Sync commit: `91b1b01`. At that commit the model describes `Sources/VikingBarCore/Accounts.swift`: `AccountCatalog.transaction`, `snapshot`, `reserve`, `select(_:replacing:)`, `readExisting`, `selectedAtInvocation`; and `FileSessionLease` in `Sources/VikingBarCore/SessionPersistence.swift`.

```sh
git diff --stat 91b1b01 -- Sources/VikingBarCore/Accounts.swift Sources/VikingBarCore/SessionPersistence.swift
```

A new catalog operation (rename, remove, relabel) is covered code: add it as a goal in `Start`.

## Run

```sh
./Scripts/check-formal.sh AccountCatalog   # `make check-formal` runs every model
```

It takes about 6 seconds (1.3 million states). Expect `PASS AccountCatalog` and three `PASS ... mutant` lines. Read every result with the pstack `/statechart` skill on `formal/AccountCatalog.tla` and the config that produced it.

## Model-to-code mapping

- `Start`: a `reserve` (append a new slot) or a `select(key, replacing:)` begins.
- `Lock`: `FileSessionLease(url: catalog.lock).acquire()`. A held lock throws `busy` (`LOCK_NB`), which needs no step.
- `Read`: `readExisting()`, then the edit. A select of an unlisted key throws `invalidSelection`; `replacing:` only changes a selection that still equals `expected`. An unchanged snapshot skips the write.
- `Write`: write `.catalog-UUID.tmp` and `synchronize()`.
- `Rename`: `rename(temporary, accounts-v1.json)`, atomic.
- `Release`: `defer { lease.release() }`; `reserve` returns its entry.
- `Crash`: the process ends after any step; the kernel releases the flock.

Mutants in `formal/mutants/AccountCatalog/`, each with an `\* expect:` line:

- `FaithfulLockAroundEdit` → `LockSkipped` breaks `NoLostReservation`.
- `FaithfulAtomicReplace` → `WrittenInPlace` breaks `NoTornFile`.
- `FaithfulSelectChecksListed` → `UnlistedSelection` breaks `SelectedIsListed`.

## When a check fails

Map each trace step to the code. A possible trace is a real bug. Report it in the code's words. If asked, file an issue with the `/statechart` chart and the bug path, and record it as `formal/findings/AccountCatalog/<Name>.cfg` with `\* expect:` and `\* issue:` lines. Do not weaken a rule, and do not change product code unless asked. If a step is impossible in the code, fix the model and cite the code. A mutant that passes means the model lost its power; fix the model.

## When the change is intended

Edit the actions to match, one per observable file or lock effect. Keep a mutant per rule. Run the check. Move the sync commit forward only after you confirm the model describes the code at the new commit.

## Assumptions and limits

- Two writers, two new slots plus the legacy slot. Labels, revision numbers, providers, and the absent-catalog bootstrap (which writes the same default under the lock) are abstracted.
- A busy lock fails the operation instead of waiting. The app surfaces that as a failed selection or addition. The model does not count it as a rule break.
- `prepareDirectory`'s symlink checks and file permissions are not modeled.
