# CLI JSON

## Sub-features

Shared snapshot and menu model, fixture selection, GB/GiB, timezone, argument errors.

## How to get to it (user POV)

Run `swift run vikingbar --fixture finite` in the repo.

## Driving it with terminal

Build once with `swift build`. Run `.build/debug/vikingbar --fixture finite` and repeat for unlimited, exhausted, stale, and error. Require parseable JSON with `snapshot`, `menu`, and explicit fixture provenance.

Run `.build/debug/vikingbar --fixture finite --unit GiB --time-zone Europe/Brussels`. Require GiB labels and local date formatting. Run `.build/debug/vikingbar` without arguments and require a nonzero exit with fixture-required guidance. Save stdout, stderr, and exit codes alongside UI proof.

## Gotchas

Separate launches can use different fixture reference times. Compare deterministic model tests for exact timestamps, and compare stable amount/provenance labels across separate CLI and app launches. Fixture commands need no credentials. The separate [auth/balance proof](auth-balance-proof.md) is intentionally networked; it receives credentials through stdin via the approved wrapper. Running the CLI without arguments remains a fixture-required negative check.
