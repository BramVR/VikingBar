---
name: verify-vikingbar
description: "Verify VikingBar fixture UI, JSON CLI, and authorized API proof."
---

# Verify VikingBar

Use the logged-in Mac desktop. Read [the feature map](features/README.md) before choosing coverage. The app and explicit fixture CLI use synthetic data. The separate [auth/balance proof](features/auth-balance-proof.md) intentionally accesses the network and requires authorized credentials.

## Launch

Run `make smoke-app-fixture` from the repo root. It builds `.build/app/VikingBar.app`, starts its executable with `--fixture finite`, waits for its visible status item, drives the card, and stops its own process. Require exit 0 and `.build/proof/<run>/result.json` with `passed: true`.

For interactive coverage, run `make package-app` and `swiftc Scripts/inspect-ui.swift -o .build/inspect-ui`, then `.build/app/VikingBar.app/Contents/MacOS/VikingBarApp --fixture finite` in a task-owned terminal session. Record PID, parent, start time, full executable path, and SHA256 before driving. Quit from the card after the check. Do not drive a pre-existing app. Native menu bar proof needs the exclusive Mac UI slot if other workers share the host.

## Doctor

Run `.build/inspect-ui <recorded-pid>` after compiling the helper. Require the `vikingbar.status` element and its full frame within a `peekaboo screen list --json` display. Confirm `ps -p <recorded-pid> -o pid,ppid,lstart,command` still matches the recorded executable. Never accept an offscreen item as click proof.

## Drive

The executable helper `Scripts/smoke-app-fixture.py`, invoked by `make smoke-app-fixture`, records a screen with Peekaboo 4, then presses the actual status button through `Scripts/inspect-ui.swift`. The native helper targets the recorded VikingBar PID and reads its accessibility tree. Peekaboo captures the resulting card by exact window ID. macOS 26 hosts status items in Control Center, which prevents Peekaboo 4.2.0 from resolving this item reliably. The native probe follows the app's `AXExtrasMenuBar` instead. Peekaboo must have Screen Recording and Accessibility permission. This controlled fixture test authorizes its foreground menu click.

For more coverage, use `.build/inspect-ui <pid> press vikingbar.fixturePicker`, read the tree again, then `.build/inspect-ui <pid> press Unlimited`. Re-observe after each action. See the feature files for expected states. The data-card map also covers the GB/GiB picker and real Quit action. The fixture-selection map covers **Not connected**. These routes require the interactive recipe; the smoke command only covers the five fixtures and task-process cleanup. The CLI command is `swift run vikingbar --fixture finite`; replace the state as needed.

## Evidence

Keep `.build/proof/<run>/` private and outside commits. It contains process identity, executable hash, build log, before screenshot, click receipt, card tree, card screenshot, result, and cleanup receipt. For fixture states, confirm the screenshot shows the fixture marker and amounts. For Not connected, require the unavailable card without a fixture marker; AX text alone cannot prove visibility. Full desktop captures may contain unrelated personal content.

Proof uses the real status button and card. Do not substitute internal setters, launch survival, or model tests. Capture action plus resulting state. Verify fixture isolation by tracing app and CLI entry points through their selected execution paths. The shared core includes URLSession transport, so imports alone cannot prove isolation. The CLI without arguments must exit 2 with fixture-required guidance. Only the explicit `proof auth-balance` route runs live authentication and balance requests; use its feature recipe and credential prerequisite.

## Cleanup

The helper terminates only its recorded child process and waits for exit, including failed attempts. It never removes proof. Confirm `cleanup.json` reports `exited: true` and `card.png` survives successful cleanup. For interactive runs use `.build/inspect-ui <pid> press vikingbar.quit`. Require helper exit 0, its JSON receipt, and the original app process's exit 0. The helper verifies termination of the captured application, including when Quit disconnects its AX reply. This is separate from the smoke runner's cleanup termination. Never kill by app name or clean another application's state.

## Helpers

- `make check` checks formatting, lint, build, tests, and documentation links.
- `make check-proof` runs synthetic API and credential-wrapper tests without 1Password or account access.
- `make proof-live CHECK=auth-balance` runs authorized live proof; follow [its prerequisites](features/auth-balance-proof.md) first.
- `make smoke-app-fixture` runs executable `Scripts/smoke-app-fixture.py` end to end.
- `.build/inspect-ui <pid>` reads the native tree; append `press <selector>` to perform a targeted AXPress. Selectors match identifiers, titles, or exact popup values. The smoke command compiles this helper with `swiftc`.
- `make package-app` runs executable `Scripts/package-app.sh` to build the bundle for interactive checks.

Use `$maintain-verification-skill` when available to update the map after product changes.
