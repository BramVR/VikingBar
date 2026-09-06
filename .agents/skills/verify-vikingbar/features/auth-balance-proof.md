# Auth/balance proof

## Sub-features

Password grant, explicit refresh grant, discovery with the refreshed token, and validated balances for every discovered subscription. The request allowlist enforces the read-only account operations despite the reported OAuth scope mismatch. No account writes, token persistence, or app login setup.

## Prerequisites

Read [Local API proof](../../../../docs/live-proof.md) for the maintained credential and receipt contract. Require the project Swift toolchain, Python 3, tmux, installed 1Password CLI, an approved exact credential reference, and the coordinator's exclusive credential slot. Keep the selector JSON outside git; it names the approved vault/item and `client_id`, `username`, `password` labels, never values. No client secret. Do not enumerate items or run sign-in/version probes.

## Driving it with terminal

Run `make check-proof` first. These synthetic tests need no credential slot and do not satisfy live proof.

State the exact approved item, fields, and auth/balance purpose privately. In one task-owned named tmux session, from this checkout:

```sh
set +x
. "$HOME/.profile"
export VIKINGBAR_CREDENTIAL_REFERENCE=/absolute/private/credential-reference.json
make proof-live CHECK=auth-balance
```

The wrapper performs one targeted `op item get` inside that session, holds credentials in memory, and feeds the freshly built CLI through stdin. Do not invoke the direct CLI with credentials in arguments or files. Hold the session only for this proof and a specifically authorized retry.

## Evidence and cleanup

Record commit SHA, executable SHA256, command, UTC time, exit status, and receipt privately outside version control. Require exit 0 and the strict success schema: `schema_version`, `check`, `passed`, `password_grant`, `refresh_grant`, `scope_mismatch`, `subscription_count`, `balance_count`, `failure`. Require `schema_version: 1`, `check: "auth-balance"`, `passed: true`, both grants true, equal positive subscription/balance counts, and `failure: null`. The wrapper validates field types and redacts provider data. Preserve the scope-mismatch boolean; never probe write permissions to investigate it.

Wrapper failure exits nonzero with only `passed: false` and a fixed `error` code. The direct CLI has a different full failure receipt. Missing credentials, empty subscriptions, invalid responses, or skipped stages fail the gate. Never count fixture output as live proof.

Confirm receipts contain no credentials, tokens, subscription identifiers, phone numbers, bundle amounts, or raw account responses. Publish only a minimal non-secret pass/fail summary. End only the task-owned tmux session after evidence capture; confirm its processes exited and private evidence survives. No UI instance is needed.

## Gotchas

The app and ordinary fixture CLI remain synthetic. This route proves endpoint execution and response validation, not allowance display correctness. MFA behavior remains unverified; a challenge fails the gate without disabling MFA or using browser cookies. Hosted CI must not run this credentialed recipe.
