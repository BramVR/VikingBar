# Live balance

Coverage: core live gate and subsequent current-build stored-session picker proof PASSED. Live selection coverage is limited to one SIM and one data bundle. See the evidence below for build boundaries.

## Behavior

Default native startup restores the live account and refreshes it when connected. A disconnected account shows **Connect with 1Password**. The approved reference file selects one item and its `client_id`, `username`, and `password` fields. The packaged helper sources the authorized profile inside one private named tmux session and performs one `op item get`. The helper derives `USER` from the OS account only for tmux so the approved profile can select its credential. The `op` and CLI child environments remain unchanged. It sends credentials over stdin to the bundled CLI, which owns Keychain. The native app receives session state over private pipes, never tokens.

The card selects one SIM and one active data bundle. The selected bundle controls the helmet, remaining amount, used percentage, and expiry. Bundles retain separate applicability and amounts. The picker and card share `LiveBalancePresentation.title(for:index:)`. Blank or whitespace-only titles display as `Data bundle N`, using the provider-array index plus one. Raw provider values remain unchanged. Extra charges show the selected SIM's euro amount, or unavailable when missing. Another SIM cannot supply the selected SIM's allowance. **Refresh now** requests fresh data. Failed reads retain known data as stale, while expired or unknown amounts stay unavailable.

Each connection has a new identity. Refresh uses the stored token. A pending token rotation survives interruption and forces reconnect if no replacement was saved. CLI processes share a lease around rotation. Unsigned rebuilds may need renewed Keychain authorization.

An explicit fixture launch never creates a live worker. Choosing **Not connected** in its fixture picker keeps that isolation. Live launches have no fixture picker. The app-only `--credential-reference` and `--proof-directory` flags accept absolute paths and reject fixture mode. The latter writes a new `connect-result.json`; neither flag connects without the native button.

## Source

- `Sources/VikingBar/AppSession.swift` owns startup, refresh scheduling, account selection, and fixture isolation.
- `Sources/VikingBar/SessionProcessClient.swift` owns the CLI process and private command pipes.
- `Sources/VikingBar/AccountConnector.swift` invokes the packaged `Scripts/connect-account.py` helper.
- `Sources/VikingBar/DataCard.swift` renders account actions, SIMs, active bundles, and charges.
- `Sources/VikingBar/AppLaunchOptions.swift` validates app-only paths.
- `Sources/VikingBarCLI/LiveCommands.swift` provides live reports and stored-token proof.
- `Sources/VikingBarCLI/BalanceOracle.swift` compares independent API decoding with production state and presentation.

## Prerequisites

Explicit account authorization, the credential slot, and the Mac UI slot are required. Use the logged-in Mac desktop with Peekaboo permissions and a visible helmet. Native bootstrap requires `/usr/bin/python3`, tmux, `op`, an approved reference file, and the authorized service-account setup in `~/.profile`. Never probe those credentials as part of ordinary checks.

## Drive

Run `make proof-live CHECK=balance-ui` from the repository with `VIKINGBAR_CREDENTIAL_REFERENCE` set to the private selector file. Follow [the full required sequence](../../../../docs/live-proof.md#native-balance-proof).

Require one native connection, raw-API comparisons through `proof balance-api`, a native Refresh with a newer timestamp, Quit and stored-token relaunch, then a release rebuild and another stored-token relaunch. Both relaunches must preserve the connection identity. No second 1Password read is allowed in a successful sequence. Credential-read retries require explicit authorization. Record bundle paths, hashes, and task-owned process identities for each launch.

The completed run covered one SIM and one data bundle. Its API comparison covered the returned bundle array, but live multi-SIM and multiple-data-bundle selection remain unverified.

For stored-session title verification, launch the fresh bundle with the stored session. Verify that the native picker and card show the shared fallback, press Refresh, and preserve current-build identity and cleanup receipts. Do not bootstrap again to repeat this proof.

When the live account has several SIMs or active bundles, select each and compare its own amount, expiry, applicability, and charges with the corresponding report. If the account lacks that data, record the unavailable case and retain synthetic selection coverage. Do not claim live multi-SIM proof from a single-SIM account.

Require visible status and card captures, current native AX values, successful API comparisons, unchanged bootstrap receipt, and verified Quit exits. Preserve evidence through cleanup. Missing native access, Keychain authorization, API data, or a release-relaunch receipt leaves coverage pending or failed.

## Evidence and cleanup

The core gate passed on the source committed as `6955b39`. Private receipts prove native connection, forced rotation and API comparison, Refresh, relaunch, and a release rebuild with a changed CLI hash that reused the stored token. The successful sequence used one credential read. All task-owned apps, workers, helper processes, and tmux processes exited.

A subsequent updated debug build passed stored-session native picker proof with no additional credential reads. The run opened the picker, selected its existing data bundle, and matched the readable fallback in the picker and card. Independent API comparison, forced rotation, native Refresh with a newer timestamp, and the same connection identity also passed. The coordinator inspected the actual card PNG. Native Quit exited 0, and both app and worker exited. The earlier release-rebuild gate and this later debug-build proof are separate evidence.

Keep account JSON, identifiers, screenshots, and process receipts private. Publish only redacted results and build identity. Fixture screenshots and an auth-balance receipt do not prove this feature. Stop only verified task-owned processes and confirm that proof artifacts survive cleanup.

Check `workers.json` for session-worker identities recorded before native UI waits. On failure, require `cleanup.json` to cover every recorded app and worker, including a worker reparented to PID 1. A stopped app alone is not cleanup proof. Unknown ownership or failed identity inspection must leave cleanup failed; never stop an unrecorded lookalike.
