---
summary: "Build, inspect, and verify the fixture app."
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

This checks formatting, lint, compilation, tests, and documentation links. `Scripts/test.sh` runs `swift test`; on Command Line Tools installations it supplies the bundled Swift Testing framework and runtime search paths. Full Xcode uses plain `swift test`. The lint command also locates the selected toolchain's SourceKit framework. `make format` applies formatting. Override `SWIFTFORMAT` or `SWIFTLINT` with an installed tool path when needed.

Inspect a synthetic allowance through the shared core:

```sh
swift run vikingbar --fixture finite
swift run vikingbar --fixture unlimited --unit GiB --time-zone Europe/Brussels
```

The fixture names are `finite`, `unlimited`, `exhausted`, `stale`, and `error`. JSON contains both the snapshot and the menu model. GB means 1,000,000,000 bytes; GiB means 1,073,741,824 bytes. Dates default to the current user's timezone. The CLI rejects a missing fixture selection. The app opens an unavailable setup card when no fixture is selected.

Build an unsigned development bundle:

```sh
make package-app
open .build/app/VikingBar.app --args --fixture finite
```

The app has no Dock icon. Click its **Fixture** menu bar item to inspect the data card. Choose another fixture in the card or use **Quit VikingBar** to exit. This build contains no account login, network client, or Keychain store.

## Capture packaged UI proof

Use the logged-in Mac desktop with Peekaboo 4 and its Screen Recording and Accessibility permissions. Hold the coordinator's exclusive Mac UI slot when other agents are active.

```sh
make smoke-app-fixture
```

The command builds a fresh bundle, starts a task-owned process, checks its identity, captures the visible menu bar, opens the real data card, and checks its accessibility text with a targeted native probe. It then selects all five fixtures and captures each card. It preserves JSON receipts and PNG evidence under `.build/proof/`. Cleanup stops only the process it started. Missing permissions, a hidden status item, or missing card content fail the command.

Read the [verification skill](../.agents/skills/verify-vikingbar/SKILL.md) for feature coverage and targeted follow-up proof. These commands require no credentials and never use real accounts.
