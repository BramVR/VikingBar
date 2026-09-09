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

The transport allows only `https://uwa.mobilevikings.be` and these routes:

- `POST /mv/oauth2/token/` for password and refresh grants.
- `GET /mv/subscriptions` and `GET /mv/subscriptions/{id}/balance`.
- `GET /mv/loyalty-points/balance` and `GET /mv/loyalty-points/transactions?page=N&per_page=20`, with N from 1 through 3.
- `GET /mv/invoices?page=N&per_page=20`, with N from 1 through 5, and explicit `GET /mv/invoices/{id}/pdf` requests.

Identifiers contain only ASCII letters, digits, hyphens, or underscores. The client rejects redirects and never follows provider pagination URLs. Requests use an ephemeral session without cookies or persistent caching. Authentication uses form-encoded grants and honors `expires_in`.

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

Add a named check and its explicit request policy in the Swift core. Add synthetic success, malformed-response, and forbidden-request tests before running it live. Extend the Python receipt validation if the new check needs different non-secret assertions. Reuse the authorized stored session when the feature supports it; use the approved bootstrap only when connection is required. Never turn arbitrary URLs or HTTP methods into user-configurable proof inputs. History, points, and bills need their own endpoint assertions and real proof.

## Native balance proof

For the invoice-specific gate, see [invoice proof](#invoice-proof). It uses the stored session and does not bootstrap credentials or launch the native app.

`make proof-live CHECK=balance-ui` routes to `Scripts/balance-ui-proof.py`. This path requires explicit live-account authorization, the exclusive credential slot, and the exclusive Mac UI slot. Set `VIKINGBAR_CREDENTIAL_REFERENCE` to the approved reference file. The packaged connection helper creates its own private named tmux session and sources the approved profile there. It derives `USER` from the OS account for that tmux environment so the profile can select its service-account credential. The `op` and CLI child environments are unchanged. Do not add a separate credential read before this command.

The private `connect-result-ownership.json` receipt records the helper, tmux server and pane PIDs, unique session name, artifact hashes, and cleanup attempt. App and runtime-worker identities are recorded separately in the same proof directory.

The native runner records each session worker in `workers.json` before waiting for UI or balance responses. Failure cleanup tries native Quit, then stops only its recorded app and workers. Worker signals require matching PID, start time, and command, with the original parent or PID 1 after reparenting. `cleanup.json` reports success only when all tracked app and worker processes exited and ownership checks passed. Missing worker ownership or failed process inspection cannot count as successful cleanup.

The runner handles SIGTERM as a fixed cancellation failure and runs owned-process cleanup before restoring its previous signal handler, umask, and core-dump limit. Repeated SIGTERM does not interrupt cleanup. SIGKILL cannot run this cleanup path.

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

Invoice coverage is separate from the recorded balance runs below. Its live gate remains pending.

The core `balance-ui` gate passed on the source committed as `6955b39`. The coordinator retained the private receipts. The run proved native connection, raw API comparison with forced token rotation, a newer update after native Refresh, and the same connection after relaunch. A release rebuild changed the CLI executable hash and still refreshed with the stored token. The successful sequence used one credential read. The coordinator verified that all task-owned apps, workers, helper processes, and tmux processes had exited.

Live selection coverage was limited to one SIM and one data bundle. The API comparison included the returned bundle array, but that does not establish live multi-SIM or multiple-data-bundle selection coverage.

The later blank-title fallback uses `LiveBalancePresentation.title(for:index:)` for the card and picker. It displays `Data bundle N` using the provider index plus one and preserves raw provider values. A subsequent proof passed on the source committed as `c3e1259`, using the stored session with no additional credential reads. It opened the native picker, selected the existing data bundle, and verified readable matching titles in the picker and card. The run also passed independent API comparison with forced token rotation and a newer update after native Refresh, while preserving the connection identity. The coordinator inspected the actual card capture and verified native Quit exited 0 with the app and worker gone.

The release-rebuild proof belongs to the earlier core gate. The later picker proof covers the updated debug build. Receipts and captures remain private; only redacted results and build identity may be published. Live multi-SIM and multiple-data-bundle selection remain unverified.

## Invoice proof

With an existing connected account and the coordinator's credential slot, run:

```sh
make proof-live CHECK=invoices
```

The wrapper invokes `.build/debug/vikingbar proof invoices` with a restricted environment. It performs no 1Password read. The CLI restores and refreshes the stored session, reads bounded invoice metadata, and compares it independently with the production invoice model and presentation. This command accesses Keychain and the account API. A new executable build can require Keychain authorization.

If the account has an invoice, the command explicitly downloads the latest document through `VikingSession.downloadInvoice`. The oracle compares the resulting private file with the authenticated PDF response. The command does not open a PDF viewer. A real empty account passes only after a successful, complete empty response; unavailable invoices and skipped requests fail. See [download limits and retention](invoices.md#pdf-handling).

The strict receipt contains only `schema_version`, `check`, `passed`, `invoice_count`, `empty`, `truncated`, `metadata_matches`, `presentation_matches`, and `pdf_downloaded`. Empty and PDF-download flags must agree with the invoice count. Truncated results require the full 100-document bound. Unknown fields, failed comparisons, and nonzero CLI exits fail the wrapper. No invoice IDs, amounts, document paths, bearer tokens, or provider diagnostics appear in its output.

Retain the receipt, source SHA, executable hash, UTC time, and exit status privately. Native Bills-tab and PDF-button coverage are separate and require the Mac UI slot. Opening a personal PDF requires an explicit request. Follow the [invoice feature map](../.agents/skills/verify-vikingbar/features/invoices.md).

## Viking Points proof

Hold fresh coordinator slots for account access and native UI driving. Use an existing connected session and the configured Peekaboo executable, then run:

```sh
make proof-live CHECK=points
```

`Scripts/points-proof.py` builds a fresh bundle, reads the real loyalty endpoints through `vikingbar proof points-api`, and compares API balances and transaction states with production models. It then compares the native points section and expanded recent transactions with the shared CLI presentation. Native Refresh must produce newer successful points timestamps while the usage card stays usable. The proof preserves connection identity and quits the task-owned app.

This check reuses the stored session. It does not retrieve the password or connect an account. A missing connection, Keychain access failure, failed loyalty request, mismatched value, hidden UI, or failed cleanup fails the gate. Reconnection requires the coordinator's credential slot and approved account setup.

Raw account output and captures stay private under `.build/proof/`. Retain the build hashes, API comparison, native action receipts, images, result, and cleanup receipt. Inspect the PNGs after the automated check. Synthetic tests cover states absent from the live account; do not claim that every state was observed live.

The [points feature map](../.agents/skills/verify-vikingbar/features/points.md) records live coverage and its limits.

## Direct sign-in proof

`make proof-live CHECK=direct-connect-ui` extends the native balance proof. This new entry method requires explicit approval of its concrete private proof configuration, plus the coordinator's credential and Mac UI slots. Existing retry authorization does not approve this new configuration. The direct native gate has not yet passed.

The private configuration identifies the reviewed source digest, the approved credential-reference digest, one named tmux session, slot owners, and a short expiry. `VIKINGBAR_DIRECT_CONNECT_CONFIG` names that file outside the checkout. `VIKINGBAR_DIRECT_CONNECT_CONFIG_SHA256` acknowledges its exact contents. The coordinator supplies fresh `VIKINGBAR_CREDENTIAL_SLOT`, `VIKINGBAR_MAC_UI_SLOT`, and `VIKINGBAR_SLOT_BINDINGS_EXPIRES_AT` bindings. They must match the configuration's slots and expiry; inactive placeholders fail. The expiry must be in the next hour. These are operator checks against supplied bindings. The runner cannot verify a coordinator grant independently, and setting variables does not grant authorization.

After approval, the external proof process runs inside the configured tmux session. It reads the exact approved 1Password item once and passes the three selected fields through a private pipe to `inspect-ui fill-direct`. That helper fills the actual native fields through Accessibility. It accepts no password argument or file, requires a secure password field, and emits a fixed receipt. This external credential source belongs to the proof process. The app's direct route has no 1Password or tmux dependency.

The helper identifies duplicate Accessibility references with `CFEqual` and rejects distinct controls sharing a field identifier. It focuses each field before setting its value and moves focus afterward. Its fill receipt proves only those Accessibility operations succeeded. Native submission must separately prove that SwiftUI received the edits; nonempty AX values alone do not satisfy the gate. The focus-based edit path still requires a successful fixture run.

During direct proof, a process-execution policy permits the app and bundled CLI only. The runner checks the restriction before reading credentials. The app receives neither the credential reference nor the service-account token. It submits the form to the existing CLI `connect` command through private stdin. The CLI continues to own the refresh session in Keychain.

Before writing credentials to that stdin, the app publishes a private connection-worker candidate and waits for the runner's acknowledgement. The runner verifies and records the child's PID, parent, start time, exact command, and executable hash first. Cleanup checks this candidate even if the app has already exited. Unverified ownership fails cleanup instead of permitting a signal to an unknown process. Direct sign-in with `--proof-directory` requires this runner handshake and fails after 15 seconds without acknowledgement. The normal direct sign-in flow does not require it.

The helper suppresses form text in accessibility output. The runner captures no screenshot while entering credentials, and all child errors remain fixed diagnostics. Credentials remain briefly in process memory; clearing references does not guarantee erasure of immutable runtime strings. No password belongs in arguments, environment, settings, files, logs, clipboard, or proof receipts.

The gate requires a real API comparison, native refresh, stored-session relaunch, release rebuild and another stored-session relaunch. It preserves the balance proof's identity and cleanup checks. The optional method still requires a separate `make proof-live CHECK=balance-ui` result under its existing authorization policy. Missing or skipped proof keeps issue 26 incomplete and blocks website availability claims.

### Continue a completed direct connection

`make proof-live CHECK=direct-connect-ui-resume` is an internal continuation for an interrupted direct proof whose connection already succeeded. It requires approval of its concrete private configuration and fresh credential and Mac UI slot bindings. It does not change the app's direct sign-in behavior. The full direct native gate remains pending; a successful connection receipt alone does not complete it.

Set `VIKINGBAR_DIRECT_RESUME_CONFIG` to an absolute private 0600 JSON file outside the checkout and bind its bytes with `VIKINGBAR_DIRECT_RESUME_CONFIG_SHA256`. Its exact fields are `schema_version: 1`, `check: "direct-connect-ui"`, `mode: "stored-session"`, `source_sha256`, `manifest_path`, `manifest_sha256`, `credential_slot`, `mac_ui_slot`, and `expires_at`. The slots and expiry must match the three coordinator environment bindings described above, with expiry in the next hour. Do not source the credential profile for this route. It never requires or reads the service-account token, credential reference, or `op`, and never submits another connection or password grant. It uses the saved Keychain session, with no second credential-item read and no reconnect fallback.

The private 0600 manifest has exact fields `schema_version: 1`, `prior_revision`, `prior_directory`, `prior_config_path`, `prior_config_sha256`, `artifacts`, `reviewed_debug_build`, and `build_policy: "reviewed-debug-same-product-release"`. `prior_revision` is the full Git commit SHA. `artifacts` maps these nine filenames to SHA256 values:

- `direct-configuration.json`, `initial-process.json`, and `direct-connect-launch.json`.
- `direct-connect-child.json`, `direct-connect-child-ready.json`, and `direct-connect-process.json`.
- `connect-result.json`, `direct-input.json`, and `cleanup.json`.

Admission requires exact receipt schemas, successful connection, one private-pipe credential read, process-execution restriction, established worker ownership, and successful cleanup. The prior directory is the original private `.build/proof/<run>` directory; it must be 0700 and have no `result.json`, and its selected files must be 0600. The configuration, manifest, selected files, and prior directory must belong to the current OS user. Historical session-worker turnover may leave multiple owned session records, but exactly one connect worker must match the recorded direct child. Missing or extra fields, changed hashes, duplicate JSON keys, symlinks, aliases, hard links, and permissive files fail admission before app launch or account access. The runner validates the original configuration without following its credential reference. It reconstructs the prior source digest from the recorded revision and binds the current source separately. `Package.swift`, `Package.resolved`, and `Sources` must remain unchanged. The prior executable hashes remain bound to the original receipts. The sandbox preflight still applies.

`reviewed_debug_build` explicitly approves the new debug build with exactly `revision`, `product_sha256`, `build_manifest_sha256`, `app_sha256`, and `cli_sha256`. Generate this object only after committing the reviewed changes and packaging from a clean checkout. The revision must match current `HEAD`, and the product digest must match the unchanged product sources. Before launch, the freshly packaged app, CLI, and `Contents/Resources/build-manifest.json` must match all three reviewed hashes. The build manifest must record that revision, debug configuration, and `sourceDirty: false`. This permits an explicitly reviewed build relationship when rebuilding unchanged product sources produces different binaries; it does not replace or waive the prior hashes. The later release rebuild uses the same product sources and must change the CLI hash from the reviewed debug build.

Before each launch and account-read stage, the runner writes a private `<stage>-readiness.json` receipt bound to both the resume configuration and manifest SHA256 values, then opens a window capped at 600 seconds and the coordinator slot expiry. Enter the Mac login password directly into any Keychain prompt and choose **Allow** for that request. Do not choose **Always Allow** or change the item's ACL. Later reads and the release build may require another one-time Allow. The runner suppresses screenshots while waiting for the stored-session report and skips every launch's full-screen capture. After the report succeeds, card captures may resume while the same slot deadline continues to bound identity checks, capture, and Quit. Timeout fails the run and cleans up only recorded task-owned processes.

Continuation must complete the native balance comparison, independent balance API comparison, native Refresh with a newer update, native Quit, debug relaunch, release rebuild, and another stored-session relaunch. It requires connection-ID continuity from the first readable resumed state through subsequent stages; the prior fixed connection receipt does not contain that ID. A changed prior connection receipt or a new connection receipt fails the run. The final receipt retains `check: "direct-connect-ui"` and adds `credential_reads_total: 1` and `resume_manifest_sha256`. Preserve both runs' private evidence and successful cleanup. Synthetic validation does not establish a live pass.
