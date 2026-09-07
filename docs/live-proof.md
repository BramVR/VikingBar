---
summary: "Run local authentication and subscription-balance proof with one targeted 1Password read."
read_when:
  - Changing authentication or API requests
  - Adding an endpoint-specific live proof check
  - Running local account proof
---

# Local API proof

`make proof-live CHECK=auth-balance` proves password login, an explicit token refresh, subscription discovery, and a balance response for every discovered subscription. The GET requests use the refreshed access token. A missing credential, failed request, empty subscription list, invalid response, or skipped stage fails the gate. Synthetic tests do not satisfy this live gate.

The proof runs in the shared Swift core through `vikingbar proof auth-balance`. Explicit fixture app and CLI runs remain synthetic. This auth-balance proof persists no refresh token. The default native app uses the separate [live account session](live-account.md).

## Setup

Use the project's Swift toolchain, Python 3, tmux, and the installed 1Password CLI. Obtain the exact approved item ID and field labels privately. Never enumerate vaults or items. Keep the reference outside the repository, with this structure and the real item ID substituted locally:

```json
{
  "vault": "Codex Automation",
  "item_id": "APPROVED_ITEM_ID",
  "fields": ["client_id", "username", "password"]
}
```

The three labels must each occur exactly once and contain a nonempty string. There is no client secret. `VIKINGBAR_CREDENTIAL_REFERENCE` names this private file. It contains selectors, never credential values.

Hold the coordinator's exclusive credential slot. Before execution, state the exact item, fields, and purpose. Start one persistent named tmux session and run the following inside it, from this checkout:

```sh
set +x
. "$HOME/.profile"
export VIKINGBAR_CREDENTIAL_REFERENCE=/absolute/private/credential-reference.json
make proof-live CHECK=auth-balance
```

The approved profile supplies `BRAM_OP_SERVICE_ACCOUNT_TOKEN`. Do not print it. Do not run `op --version`, sign-in probes, or additional item reads as setup. The runner performs one `op item get` with the explicit vault and item, captures the JSON in memory, selects the three fields, and passes them to the built CLI over stdin. Both child processes receive only `PATH`, `TMPDIR`, `LANG`, and `LC_ALL` from the caller. The 1Password child also receives the service-account token; the Swift CLI does not. Loader variables such as `DYLD_LIBRARY_PATH` and `DYLD_FRAMEWORK_PATH` are excluded. Passwords and OAuth tokens are never written to files or passed as command arguments. Preserve this session for a specifically authorized retry; do not create parallel sessions. End only this task-owned session after proof and evidence capture.

## Requests and auth limits

The transport allows only `https://uwa.mobilevikings.be` with `POST /mv/oauth2/token/`, `GET /mv/subscriptions`, and `GET /mv/subscriptions/{id}/balance`. Subscription IDs must contain only ASCII letters, digits, hyphens, or underscores. It rejects redirects. Requests use an ephemeral session without cookies or persistent caching. Authentication uses form-encoded password and refresh grants and honors `expires_in`.

The initial grant requests `scope=read`. Support described the public client as read-only, but the prior probe received `read write` on both token responses. The receipt records a boolean scope mismatch, without copying arbitrary provider text. The client request allowlist is the enforcement boundary. Never test server write permissions through an account mutation.

MFA behavior remains unverified. An MFA challenge or auth rejection fails the gate. Never disable MFA or use browser-cookie fallback. No personal credentials belong in hosted CI.

## Verification and evidence

Run the synthetic gate first:

```sh
make check-proof
```

This runs the Swift proof tests and Python credential-wrapper tests. It does not invoke 1Password or access real accounts. Tests cover request ordering, the refreshed token, allowlists, response validation, failure status, and redaction.

On success, the live runner returns JSON with `schema_version`, `check`, `passed`, `password_grant`, `refresh_grant`, `scope_mismatch`, `subscription_count`, `balance_count`, and `failure`. A successful receipt requires both grants and an equal, positive number of discovered subscriptions and validated balances. No identifiers, bundle amounts, phone numbers, credentials, or raw responses appear in output. On failure, the wrapper exits nonzero and returns a different JSON object, `{"passed": false, "error": "fixed-diagnostic-code"}`. It suppresses the CLI failure receipt and upstream error text. The direct CLI command emits the full receipt schema on both success and failure; its `failure` field contains a fixed code when the proof fails.

Keep receipts in a private directory outside version control, such as `proof-private/`. Record the commit SHA, executable SHA256, command, UTC time, exit status, and receipt. Evidence must survive cleanup. Publish only the minimum non-secret pass/fail summary; do not publish raw account responses or desktop captures. A receipt proves endpoint execution and response validation, not correctness of the native app's allowance display.

## Extend a check

Add a named check and its explicit request policy in the Swift core. Add synthetic success, malformed-response, and forbidden-request tests before running it live. Extend the Python receipt validation if the new check needs different non-secret assertions. Run through the same credential bootstrap; never turn arbitrary URLs or HTTP methods into user-configurable proof inputs. History, points, and bills need their own endpoint assertions and real proof.

## Native balance proof

`make proof-live CHECK=balance-ui` routes to `Scripts/balance-ui-proof.py`. This path requires explicit live-account authorization, the exclusive credential slot, and the exclusive Mac UI slot. Set `VIKINGBAR_CREDENTIAL_REFERENCE` to the approved reference file. The packaged connection helper creates its own private named tmux session and sources the approved profile there. It derives `USER` from the OS account for that tmux environment so the profile can select its service-account credential. The `op` and CLI child environments are unchanged. Do not add a separate credential read before this command.

The private `connect-result-ownership.json` receipt records the helper, tmux server and pane PIDs, unique session name, artifact hashes, and cleanup attempt. App and runtime-worker identities are recorded separately in the same proof directory.

The native runner records each session worker in `workers.json` before waiting for UI or balance responses. Failure cleanup tries native Quit, then stops only its recorded app and workers. Worker signals require matching PID, start time, and command, with the original parent or PID 1 after reparenting. `cleanup.json` reports success only when all tracked app and worker processes exited and ownership checks passed. Missing worker ownership or failed process inspection cannot count as successful cleanup.

Connection failures preserve a fixed stage through the CLI and helper. Credential context, item-read failures or timeouts, and invalid fields have separate codes. The CLI reports `credential-input`, `local-filesystem`, `session-busy`, `token-network`, `token-rejected`, `token-response`, `token-rate-limited`, `token-server`, `keychain-write`, `connect-cancelled`, or the unknown fallback `connect-failed`. Native proof prefixes a validated stage with `native-connect-`. Only exact allowlisted failure receipts are accepted; raw stderr, provider text, extra fields, and unknown error strings are never forwarded.

A connection-command timeout does not identify the operation that was waiting. Earlier generic `connect-failed` receipts establish only an unsuccessful inner result; they cannot establish whether credentials were read, a token was issued, or storage was attempted. Preserve those receipts and do not infer a cause or repeat the password read. A separate stored-session inspection requires explicit authorization; `live --cached` can read Keychain and private cached account data even though it makes no API request.

Required issue #4 sequence:

1. Build and launch a fresh native bundle. Record its path, PID, parent, start time, and executable hashes.
2. Press **Connect with 1Password** once. Require the packaged helper's redacted connection receipt from exactly one approved item read.
3. Compare raw API fields with production models through the bundled `vikingbar proof balance-api`. Compare the native card and visible status item with the same account's production CLI report.
4. Press **Refresh now**. Require a newer successful update and matching native values.
5. Quit and relaunch. Require the same connection ID and a successful refresh using the stored token.
6. Quit, rebuild the bundle in release configuration, and relaunch. Require another successful stored-token refresh with the same connection ID and no second 1Password read.
7. Preserve API comparison, native captures, build identities, connection, relaunch, and cleanup receipts. Missing stages fail the gate.

`vikingbar proof balance-api` forces token refresh and independently checks subscription IDs, bundle fields, expiry, regionality, extra charges, and the selected allowance presentation against API responses. Its receipt is redacted. It requires an existing connection and accesses Keychain and the account API.

`vikingbar live` refreshes and prints private state, snapshots, and presentation values. `live --cached` reads saved state. The app's private `vikingbar session` JSON-lines interface accepts restore, refresh, subscription selection, bundle selection, cancel, and shutdown commands. Treat these as explicit account-access paths, not fixture diagnostics. Never place their output in hosted CI or public proof.

The auth-balance gate and its receipt schema remain unchanged. It proves the credential exchange and endpoint validation separately. A successful auth-balance receipt cannot replace native balance proof.

## Recorded coverage

The core `balance-ui` gate passed on the source committed as `6955b39`. The coordinator retained the private receipts. The run proved native connection, raw API comparison with forced token rotation, a newer update after native Refresh, and the same connection after relaunch. A release rebuild changed the CLI executable hash and still refreshed with the stored token. The successful sequence used one credential read. The coordinator verified that all task-owned apps, workers, helper processes, and tmux processes had exited.

Live selection coverage was limited to one SIM and one data bundle. The API comparison included the returned bundle array, but that does not establish live multi-SIM or multiple-data-bundle selection coverage.

The later blank-title fallback uses `LiveBalancePresentation.title(for:index:)` for the card and picker. It displays `Data bundle N` using the provider index plus one and preserves raw provider values. A subsequent proof passed on the source committed as `c3e1259`, using the stored session with no additional credential reads. It opened the native picker, selected the existing data bundle, and verified readable matching titles in the picker and card. The run also passed independent API comparison with forced token rotation and a newer update after native Refresh, while preserving the connection identity. The coordinator inspected the actual card capture and verified native Quit exited 0 with the app and worker gone.

The release-rebuild proof belongs to the earlier core gate. The later picker proof covers the updated debug build. Receipts and captures remain private; only redacted results and build identity may be published. Live multi-SIM and multiple-data-bundle selection remain unverified.
