---
name: verify-vikingbar
description: "Verify VikingBar UI, CLI, build artifacts, and authorized API proof."
---

# Verify VikingBar

Use the logged-in Mac desktop. Read [the feature map](features/README.md) before choosing coverage. The app and explicit fixture CLI use synthetic data. The separate [auth/balance proof](features/auth-balance-proof.md) intentionally accesses the network and requires authorized credentials.

For development archives and existing private drafts, use [Build artifacts and private drafts](features/packaged-artifacts.md). Package checks execute fixture CLIs and do not require native UI driving.

## Launch

Run `make smoke-app-fixture` from the repo root with the exclusive Mac UI slot. It builds `.build/app/VikingBar.app`, launches three task-owned fixture processes in sequence, and uses one new `.build/proof/<run>/settings.json` file for persistence proof. Require exit 0, `result.json` with `passed: true`, and `cleanup.json` with `exited: true` and three verified Quit exits of 0.

For interactive coverage, run `make package-app` and `swiftc Scripts/inspect-ui.swift -o .build/inspect-ui`, then launch `.build/app/VikingBar.app/Contents/MacOS/VikingBarApp --fixture finite` in a task-owned terminal session. Record PID, parent, start time, full executable path, and SHA256 before driving. Explicit fixture launches use memory for the display preference. For relaunch proof, add `--settings-file` with an absolute path inside a new task-owned directory and reuse that file. This app-only option requires `--fixture`. Never read or migrate real settings for fixture proof.

## Doctor

Run `.build/inspect-ui <recorded-pid>`. Require `vikingbar.status` and its full frame within a `peekaboo screen list --json` display. Confirm `ps -p <recorded-pid> -o pid,ppid,lstart,command` still matches the recorded executable. Capture the visible helmet before pressing it. A hidden or offscreen status item is not click proof.

The native helper waits briefly for Launch Services registration after a process starts. macOS 26 hosts status items in Control Center; the helper follows the app's `AXExtrasMenuBar` to find its real button. Peekaboo requires Screen Recording and Accessibility permission.

## Drive

The automatic smoke presses the real helmet, switches Data and Settings tabs, checks both display modes across all five fixtures and Not connected, verifies GB/GiB, and proves on/off persistence through real Quit and relaunch. Read [Helmet and display setting](features/helmet-and-display-setting.md) for the state and rendering matrix. [Data card](features/data-card.md) and [Fixture selection](features/fixture-selection.md) cover exact card expectations.

For targeted actions, use `.build/inspect-ui <pid> press <selector>` and re-observe after each action. Selectors match identifiers, titles, current popup values, and native tab radio-button descriptions. Press `Settings` or `Data` for the tabs. Wait for popup menu items before choosing a value; the helper prefers actual menu items over a popup's current value.

## Evidence

Keep raw `.build/proof/<run>/` receipts and captures private and outside commits. The run preserves per-launch process/hash receipts, native trees, click and Quit receipts, tightly cropped status images, card and Settings captures, the isolated settings file, `result.json`, and cleanup. The initial `before.png`, `click.json`, `card.png`, and `process.json` names remain available.

Default status title is empty; amount mode adds only the remaining decimal GB amount or an honest exceptional state. Fixture provenance stays visible in the card and Settings and explicit in tooltip, accessibility label, and CLI. Inspect the actual PNGs; AX text alone does not prove visibility or helmet appearance. Card captures must target the settled popover window, not a transient fixture menu. The smoke matches CoreGraphics window bounds to the AXPopover frame before capture.

Verify fixture isolation by tracing app and CLI entry points through their selected paths. Shared core imports include network transport, so imports alone cannot prove isolation. The CLI without arguments must exit 2 with fixture-required guidance. Only explicit `proof auth-balance` runs live authentication and balance requests; follow its credential prerequisite.

## Cleanup

The smoke's three launches must each exit through `vikingbar.quit` with code 0. Failure cleanup terminates only its recorded child process and waits for exit; that fallback is not Quit-button proof. Require `cleanup.json` to report all task processes exited and confirm screenshots survive cleanup. Interactive runs use `.build/inspect-ui <pid> press vikingbar.quit` and retain the receipt plus original process exit status. Never drive or stop a pre-existing app.

## Helpers

- `make check` checks formatting, lint, build, tests, documentation, CLI fixtures, and Python gates.
- `make smoke-package` builds and inspects development archives; follow [artifact trust and download checks](features/packaged-artifacts.md).
- `make check-proof` runs synthetic API and credential-wrapper tests without 1Password or account access.
- `make proof-live CHECK=auth-balance` requires the authorized [auth/balance proof](features/auth-balance-proof.md) recipe.
- `make smoke-app-fixture` runs `Scripts/smoke-app-fixture.py` end to end.
- `.build/inspect-ui <pid>` reads native AX; append `press <selector>` for a targeted action.
- `make package-app` builds the bundle for interactive checks.

Use `$maintain-verification-skill` when available to update the map after product changes.
