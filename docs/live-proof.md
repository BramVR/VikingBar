---
summary: "Run local authentication and subscription-balance proof with one targeted 1Password read."
read_when:
  - Changing authentication or API requests
  - Adding an endpoint-specific live proof check
  - Running local account proof
---

# Local API proof

`make proof-live CHECK=auth-balance` proves password login, an explicit token refresh, subscription discovery, and a balance response for every discovered subscription. The GET requests use the refreshed access token. A missing credential, failed request, empty subscription list, invalid response, or skipped stage fails the gate. Synthetic tests do not satisfy this live gate.

The proof runs in the shared Swift core through `vikingbar proof auth-balance`. The ordinary app and fixture CLI remain synthetic. No refresh token is persisted by this proof runner. App login and Keychain storage are separate work.

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

Keep receipts in a private directory outside version control, such as `proof-private/`. Record the commit SHA, executable SHA256, command, UTC time, exit status, and receipt. Evidence must survive cleanup. Publish only the minimum non-secret pass/fail summary; do not publish raw account responses or desktop captures. A receipt proves endpoint execution and response validation, not correctness of a future app's allowance display.

## Extend a check

Add a named check and its explicit request policy in the Swift core. Add synthetic success, malformed-response, and forbidden-request tests before running it live. Extend the Python receipt validation if the new check needs different non-secret assertions. Run through the same credential bootstrap; never turn arbitrary URLs or HTTP methods into user-configurable proof inputs. History, points, and bills need their own endpoint assertions and real proof.
