---
name: verify-vikingbar
description: "Verify VikingBar app, website, CLI, artifacts, and authorized API proof."
---

# Verify VikingBar

Use the logged-in Mac desktop. Read [the feature map](features/README.md) before choosing coverage. Explicit fixture app and CLI launches use synthetic data. Default native startup restores a live session and can access Keychain and the account API. Read [Live balance](features/live-balance.md) for that authorized path. The separate [auth/balance proof](features/auth-balance-proof.md) also requires authorized credentials.

For development archives and existing private drafts, use [Build artifacts and private drafts](features/packaged-artifacts.md). Package checks execute fixture CLIs and do not require native UI driving.

For local installation, persisted card and refresh settings, and production login registration, read [Installed app and login preferences](features/installed-app.md). Its gates require an approved exact installation target and runtime slots. Registration proof cannot overwrite an existing user registration.

The [website](features/website.md) has a separate synthetic browser preview. Verify it from its own `website/` source; the demo does not prove native app behavior.

## Launch

Run `make smoke-app-fixture` from the repo root with the exclusive Mac UI slot. It builds `.build/app/VikingBar.app`, launches four task-owned fixture processes in sequence, and uses one new `.build/proof/<run>/settings.json` file for persistence proof. Require exit 0, `result.json` with `passed: true`, and `cleanup.json` with `exited: true` and four verified Quit exits of 0.

For interactive coverage, run `make package-app` and `swiftc Scripts/inspect-ui.swift -o .build/inspect-ui`, then launch `.build/app/VikingBar.app/Contents/MacOS/VikingBarApp --fixture finite` in a task-owned terminal session. Record PID, parent, start time, full executable path, and SHA256 before driving. Explicit fixture launches use memory for the display preference. For relaunch proof, add `--settings-file` with an absolute path inside a new task-owned directory and reuse that file. This app-only option requires `--fixture`. Never read or migrate real settings for fixture proof. Selecting **Not connected** inside that fixture launch must remain isolated and must not start a live worker.

For authorized native live coverage, use `make proof-live CHECK=balance-ui` with the credential and Mac UI slots. Follow [Live balance](features/live-balance.md). Require one native bootstrap, API comparisons, native Refresh, relaunch, and release rebuild with stored-token relaunch. No second 1Password read in a successful sequence. Credential-read retries need explicit authorization. The core sequence and subsequent stored-session picker proof passed. Read the feature evidence for build boundaries and selection limits.

For website coverage, follow [Website](features/website.md): build and test first, then start one task-owned Vite server and drive one browser tab. The local preview needs no account credentials.

## Doctor

Run `.build/inspect-ui <recorded-pid>`. Require `vikingbar.status` and its full frame within a `peekaboo screen list --json` display. Confirm `ps -p <recorded-pid> -o pid,ppid,lstart,command` still matches the recorded executable. Capture the visible helmet before pressing it. A hidden or offscreen status item is not click proof.

The native helper waits briefly for Launch Services registration after a process starts. macOS 26 hosts status items in Control Center; the helper follows the app's `AXExtrasMenuBar` to find its real button. Peekaboo requires Screen Recording and Accessibility permission.

If a live proof's Peekaboo screen capture refuses an old Bridge ScreenCaptureKit owner, first verify a classic screen capture with the configured Peekaboo CLI. Then set `PEEKABOO_BIN="$PWD/.agents/skills/verify-vikingbar/peekaboo-classic.sh"` for that proof. The skill-owned helper adds `--capture-engine classic` only to `peekaboo see`; it leaves permission, app, and screen inspection unchanged. Re-drive the affected proof and retain both failure and passing receipts.

For the website, verify the recorded Vite listener PID, parent, start time, and command; require a successful localhost HTTP response and the expected hero in the browser before driving. Recheck after a failed action. If the UI is wedged while the server is healthy, reload to the known home state.

## Drive

The automatic smoke presses the real helmet, opens footer Settings and Back, checks both display modes across all five fixtures and Not connected, verifies GB/GiB, and proves on/off persistence through real Quit and relaunch. It also drives synthetic SIM/bundle selection, refresh, details, Points, and app-local light/dark/accessibility appearances. The redesigned fixture gate passed on 2026-09-14 with four native Quit exits. Read [Helmet and display setting](features/helmet-and-display-setting.md) for the state and rendering matrix. [Data card](features/data-card.md) records the build, separate keyboard proof, and its focus boundary. [Fixture selection](features/fixture-selection.md) covers exact card expectations.

For targeted actions, use `.build/inspect-ui <pid> press <selector>` and re-observe after each action. Selectors match identifiers, titles, current popup values, and native tab radio-button descriptions. Press `vikingbar.settings` for Settings and `vikingbar.back` to return to the balance. For pickers, use `.build/inspect-ui <pid> choose <picker-identifier> <exact-menu-title>`. This invocation presses the picker once, waits boundedly for one visible matching menu item, and presses it once. Do not split picker readiness and selection across invocations. Never retry a successful or uncertain action; retain the failure receipt and stop. Resolution waits do not make synchronous Accessibility calls interruptible.

For the website, use the single local browser tab to exercise the helmet scene, motion controls, separate synthetic SIMs and bundles, demo Settings, Source and Get dialogs, setup, and FAQ. See the [website recipe](features/website.md) for expected values and cleanup.

## Evidence

Keep raw `.build/proof/<run>/` receipts and captures private and outside commits. The run preserves per-launch process/hash receipts, native trees, click and Quit receipts, tightly cropped status images, card and Settings captures, the isolated settings file, `result.json`, and cleanup. The initial `before.png`, `click.json`, `card.png`, and `process.json` names remain available.

For website coverage, retain named browser observations and any screenshots under task-local `.build/proof/<run>/`, then confirm the files still exist after server and tab cleanup.

Default status title is empty; amount mode adds only the remaining decimal GB amount or an honest exceptional state. Fixture provenance stays visible in the card and Settings and explicit in tooltip, accessibility label, and CLI. Inspect the actual PNGs; AX text alone does not prove visibility or helmet appearance. Card capture waits for the same unique, opaque, display-contained AXPopover/CoreGraphics window pair in two consecutive native inspections, then makes one classic exact-window capture bound to the recorded PID and window ID. A failed or mismatched capture receipt is terminal; do not retry or substitute an area capture.

Verify fixture isolation by tracing app and CLI entry points through their selected paths. Shared core imports include network transport, so imports alone cannot prove isolation. The CLI without arguments must exit 2 with fixture-required guidance. Explicit `connect`, `live`, `proof balance-api`, and private `session` commands access the connected account or its store. `proof auth-balance` performs a separate credential exchange without persistence. Follow their credential prerequisites; never use them as credential-free diagnostics.

## Cleanup

The smoke's four launches must each exit through `vikingbar.quit` with code 0. Failure cleanup terminates only its recorded child process and waits for exit; that fallback is not Quit-button proof. Require `cleanup.json` to report all task processes exited and confirm screenshots survive cleanup. Interactive runs use `.build/inspect-ui <pid> press vikingbar.quit` and retain the receipt plus original process exit status. Never drive or stop a pre-existing app.

Close only the website tab created for the run and stop only its recorded Vite process/session. Verify its PID and port are gone while task-local evidence remains.

## Helpers

- `make check` checks formatting, lint, build, tests, documentation, CLI fixtures, and Python gates.
- `make smoke-package` builds and inspects development archives; follow [artifact trust and download checks](features/packaged-artifacts.md).
- `make check-proof` runs synthetic API and credential-wrapper tests without 1Password or account access.
- `make proof-live CHECK=balance-ui` requires the authorized [live balance](features/live-balance.md) recipe and private evidence.
- `make proof-live CHECK=history` requires a stored connection and fresh account/UI slots. Follow [daily SIM history](features/history.md) for the verified main-hover, click-open chart, and Refresh recipe.
- `make proof-live CHECK=auth-balance` requires the authorized [auth/balance proof](features/auth-balance-proof.md) recipe.
- `make proof-live CHECK=invoices` requires the authorized [invoice proof](features/invoices.md) recipe. It accesses the stored account and downloads a PDF only when an invoice exists; it never opens a PDF viewer.
- `make proof-live CHECK=points` requires the authorized [Viking Points](features/points.md) recipe, stored session, and private native evidence.
- `make smoke-app-fixture` runs `Scripts/smoke-app-fixture.py` end to end.
- `.build/inspect-ui <pid>` reads native AX; append `press <selector>` for a targeted action or `choose <picker-identifier> <exact-menu-title>` for picker selection in one invocation. Action errors are terminal; never retry successful or uncertain dispatch.
- `make package-app` builds the bundle for interactive checks.
- `make smoke-installed-app INSTALL_TARGET=ABSOLUTE_APP_PATH` requires an unused approved target and proves native preferences and production login registration with restoration.
- `make proof-live CHECK=installed-balance INSTALL_TARGET=ABSOLUTE_APP_PATH` verifies the retained installed artifact with authorized stored-session access.
- `PEEKABOO_BIN="$PWD/.agents/skills/verify-vikingbar/peekaboo-classic.sh" make proof-live CHECK=points` uses classic capture when the Bridge owner prevents the stored-session native gate. The helper is executable and otherwise passes Peekaboo commands through.
- From `website/`, `npm ci`, `npm run build`, and `npm test` prepare the local page; `npm run dev -- --host 127.0.0.1 --port 4173 --strictPort` serves it for browser proof. Check that the port is free before launch.

Use `$maintain-verification-skill` when available to update the map after product changes.
