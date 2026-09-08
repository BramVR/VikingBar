# Installed app and login preferences

Coverage is pending. Source and synthetic checks do not establish native registration or installed live balance.

## Sub-features

Local installation and explicit update, production bundle identity, local ad-hoc sealing, data-card used/remaining preference, refresh interval, connection-bound SIM restoration, wake refresh, actual launch-at-login state, and deterministic proof cleanup.

## How to get to it (user POV)

Follow [local installation](../../../../docs/local-install.md). Open the installed app and click its helmet. Choose **Settings** for the data-card preference, refresh interval, and **Launch at login**. The existing remaining-GB toggle stays independent. Choose the SIM in **Data**.

## Driving it with native AX

Obtain the coordinator's explicit runtime slots and approval of the exact unused `INSTALL_TARGET` before running either gate. Use the production identity `be.bram.vikingbar`. An alternate proof identifier does not prove production registration. Neither gate may replace the user's bundle or terminate a pre-existing process.

After the coordinator grants both slots, set `VIKINGBAR_UI_SLOT=held` and `VIKINGBAR_CREDENTIAL_SLOT=held` as execution acknowledgments. These variables do not grant permission. Run `make smoke-installed-app INSTALL_TARGET=/absolute/approved/fresh/VikingBar.app` with the configured `PEEKABOO_BIN`. The target and its receipt must be absent and below the user's `Applications` directory. The gate builds and installs a fresh bundle, records hashes and process identity, and uses an isolated settings file. Only this fresh, exclusive task-owned flow accepts initial `notRegistered` or distinct `notFound` status. It records the actual candidate and installed states and rechecks the exact published path immediately before registration. `unavailable`, unknown, enabled, and approval-required states fail. A staged URL's missing record does not prove global absence of another copy's same-ID registration; changing such a registration needs a separate reviewed plan.

Open **Settings** and observe `vikingbar.dataDisplayMode`, `vikingbar.refreshInterval`, `vikingbar.launchAtLogin`, and `vikingbar.loginItemStatus`. Change the card to **Used** and the interval to **Every 30 minutes** through the native pickers. Enable launch at login through the native toggle. Require actual system status `enabled` and visible **On**. `requiresApproval`, unavailable service, and registration errors fail the enabled-registration gate.

Both gates require the artifact's `sourceDirty` flag to be exactly `false` and its commit to equal the current reviewed `HEAD`. The smoke checks the staged candidate before executing its status command or publishing it. The live gate checks the retained artifact before native inspection, and each app launch rechecks identity. Ordinary local installs may still use dirty development builds; they cannot pass installed proof.

Quit and relaunch the same installed executable. Verify the settings and used amount survived. Return the login item to `notRegistered` before the proof can pass. Failure cleanup uses the same installed app's credential-free `--login-item disable` and `--login-item status` commands when native controls are unavailable. Only unregister a service this run attempted to register after observing its absent baseline.

Run `make proof-live CHECK=installed-balance INSTALL_TARGET=/absolute/approved/fresh/VikingBar.app` against the retained, verified installed bundle. Reuse the stored Keychain session. No password fallback. Require independent API comparison, matching private snapshot and visible card, native Refresh with a newer timestamp, and successful Quit/relaunch with the same connection and selected SIM. Restore any display preferences changed by the proof. Never restore an old refresh token after rotation.

The doctor must verify the exact installed executable and CLI hashes, PID, parent, start time, current command, visible status frame, and active screen before driving. Inspect actual PNGs as well as AX results. Record app and worker ownership before waits. A cleanup error fails the proof even when the feature assertions passed. Keep receipts and captures private and present after teardown.

## Gotchas

- Ordinary fixture launches do not access ServiceManagement. Installed smoke explicitly opts in with `--allow-login-item`, which requires `--fixture` and an isolated `--settings-file`.
- Registration can cause a later OS login to launch the production app without fixture arguments. Hold both UI and account slots. The gate itself does not log out or reboot the Mac.
- Actual `enabled` status proves registration eligibility. Manual relaunch proves persistence. Neither proves execution at OS login.
- Ad-hoc sealing provides local bundle integrity, not Developer ID trust or notarization. A relinked CLI can require renewed Keychain authorization. Report that prerequisite; do not weaken the ACL.
- An existing registration or install target requires a separately reviewed plan. Never restore a user's registration by guessing its earlier bundle path.
- macOS returned `notFound` for a fresh staged app with no Background Task Management record. Keep this state distinct from generic `unavailable`; never normalize it globally to `notRegistered`. Cleanup after a registration attempt still requires actual `notRegistered`.
- Synthetic tests cover additional SIMs, failure backoff, interval changes during a request, wake coalescing, and denied/unavailable registration. Record any real-account case the available account cannot exercise.
