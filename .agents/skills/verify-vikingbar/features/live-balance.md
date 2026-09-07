# Live balance

Coverage: PENDING. Source describes the implementation. No native live success is claimed until the complete gate has private receipts.

## Behavior

Default native startup restores the live account and refreshes it when connected. A disconnected account shows **Connect with 1Password**. The approved reference file selects one item and its `client_id`, `username`, and `password` fields. The packaged helper sources the authorized profile inside one private named tmux session and performs one `op item get`. It sends credentials over stdin to the bundled CLI, which owns Keychain. The native app receives session state over private pipes, never tokens.

The card selects one SIM and one active data bundle. The selected bundle controls the helmet, remaining amount, used percentage, and expiry. Bundles retain separate applicability and amounts. Extra charges show the selected SIM's euro amount, or unavailable when missing. Another SIM cannot supply the selected SIM's allowance. **Refresh now** requests fresh data. Failed reads retain known data as stale, while expired or unknown amounts stay unavailable.

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

Require one native connection, raw-API comparisons through `proof balance-api`, a native Refresh with a newer timestamp, Quit and stored-token relaunch, then a release rebuild and another stored-token relaunch. Both relaunches must preserve the connection identity. No second 1Password read is allowed. Record bundle paths, hashes, and task-owned process identities for each launch.

When the live account has several SIMs or active bundles, select each and compare its own amount, expiry, applicability, and charges with the corresponding report. If the account lacks that data, record the unavailable case and retain synthetic selection coverage. Do not claim live multi-SIM proof from a single-SIM account.

Require visible status and card captures, current native AX values, successful API comparisons, unchanged bootstrap receipt, and verified Quit exits. Preserve evidence through cleanup. Missing native access, Keychain authorization, API data, or a release-relaunch receipt leaves coverage pending or failed.

## Evidence and cleanup

Keep account JSON, identifiers, screenshots, and process receipts private. Publish only redacted results and build identity. Fixture screenshots and an auth-balance receipt do not prove this feature. Stop only verified task-owned processes and confirm that proof artifacts survive cleanup.
