---
summary: "Build, inspect, and verify the native app and isolated fixtures."
read_when:
  - Building VikingBar
  - Changing fixture UI or CLI behavior
  - Running packaged app proof
---

# Build and verify VikingBar

Use macOS 14 or later, Swift 6.2 or later, SwiftFormat, SwiftLint, and Python 3. The initial build targets Apple Silicon. SwiftFormat 0.63.0 and SwiftLint 0.65.0 are the verified formatter versions. No Swift package dependencies are required.

Run the contributor gate:

```sh
make check
```

This checks formatting, lint, compilation, tests, documentation links, and CLI fixtures. `Scripts/test.sh` runs `swift test`; on Command Line Tools installations it supplies the bundled Swift Testing framework and runtime search paths. Full Xcode uses plain `swift test`. The lint command also locates the selected toolchain's SourceKit framework. `make format` applies formatting. Override `SWIFTFORMAT` or `SWIFTLINT` with an installed tool path when needed.

For the pinned tools and full CI build, run `Scripts/bootstrap-ci-tools.sh`, then `Scripts/ci-build.sh`. Tools remain under `.build/ci-tools/bin`. See [contribution checks](../CONTRIBUTING.md), [CI behavior](ci.md), and [artifact downloads](RELEASING.md).

Run `make smoke-package` to build and inspect development app and CLI archives without opening the app. Run `make workflow-check` with actionlint 1.7.12 for GitHub Actions syntax, expressions, and embedded shell checks.

Inspect a synthetic allowance through the shared core:

```sh
swift run vikingbar --fixture finite
swift run vikingbar --fixture unlimited --unit GiB --time-zone Europe/Brussels
```

The fixture names are `finite`, `unlimited`, `exhausted`, `stale`, and `error`. JSON contains both the snapshot and the menu model. GB means 1,000,000,000 bytes; GiB means 1,073,741,824 bytes. Dates default to the current user's timezone. The CLI rejects a missing fixture selection. The app without `--fixture` restores a live account session and shows account setup when disconnected. That path can access Keychain.

Build an unsigned development bundle:

```sh
make package-app
open .build/app/VikingBar.app --args --fixture finite
```

The app has no Dock icon. Click its helmet menu bar item to inspect the data card. Choose another fixture in the card or use **Quit VikingBar** to exit. Open **Settings** to turn on **Show remaining GB in menu bar**. The label uses decimal GB independently of the card's units. Turning it off leaves only the helmet. Fixture provenance remains visible in the card and available in the tooltip, accessibility label, and CLI. Keep `--fixture` on every credential-free app launch. Selecting **Not connected** in its picker stays in fixture mode and cannot access the live account. For live startup, follow [account setup](live-account.md).

Explicit fixture launches keep the display preference in memory. To verify persistence, pass the app-only `--settings-file` option with an absolute path inside a task-owned temporary directory. It requires an explicit `--fixture`. Reuse that file for the task-owned relaunch; never pass a real settings file. The automatic smoke command supplies its own isolated file.

Generate deterministic native icon renders without launching the app:

```sh
VIKINGBAR_RENDER_PROOF_DIR="$PWD/.build/proof/icon-renders" Scripts/test.sh --filter HelmetRendererTests
```

Inspect `helmet-contact-sheet.png` and the individual PNGs in that directory. They cover full, half, near-empty, empty, unlimited, and unavailable treatments in light and dark at 1x and 2x. Pixel tests check fixed bounds, fill direction, and distinct exceptional states.

## Capture packaged UI proof

Use the logged-in Mac desktop with Peekaboo 4 and its Screen Recording and Accessibility permissions. Hold the coordinator's exclusive Mac UI slot when other agents are active.

```sh
make smoke-app-fixture
```

The command builds a fresh bundle, starts a task-owned process, checks its identity, captures the visible helmet, opens the real data card, and checks its accessibility text with a targeted native probe. It selects fixtures, switches the Settings toggle, and verifies both menu bar modes. Task-owned relaunches verify that on and off choices persist in the isolated settings file. Cropped status images, card and Settings captures, process receipts, `result.json`, and cleanup receipts remain under `.build/proof/`. Cleanup stops only recorded task processes. Missing permissions, a hidden status item, or missing required behavior fail the command.

Read the [verification skill](../.agents/skills/verify-vikingbar/SKILL.md) for feature coverage and targeted follow-up proof. These commands require no credentials and never use real accounts.

## Verify live account behavior

The packaged app contains `vikingbar` and `Resources/connect-account.py`. Native connection requires `/usr/bin/python3`, tmux, the 1Password CLI, and the approved service-account setup in `~/.profile`. The helper sources that profile inside its own named tmux session.

The app-only `--credential-reference` and `--proof-directory` flags each accept one absolute path and reject fixture launches. The reference selects an approved item without storing its credentials. The proof directory receives `connect-result.json` and must not already contain that receipt. Neither flag connects automatically; press **Connect with 1Password**.

With explicit account authorization and the credential and Mac UI slots, run `make proof-live CHECK=balance-ui`. The required gate covers one native connection, API comparison, native refresh, stored-token relaunch, and a release rebuild followed by stored-token relaunch. No second 1Password read is allowed in that sequence. See [live proof requirements](live-proof.md#native-balance-proof). Coverage remains pending until those stages have actual receipts.
