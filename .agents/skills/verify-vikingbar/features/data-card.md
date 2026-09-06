# Data card

## Sub-features

Status meter, used percentage, used and remaining amounts, expiry, last update, GB/GiB selection, and Quit.

## How to get to it (user POV)

Start the fixture app. Click its **Fixture** status item. Use **Data units** to switch between GB and GiB. Use **Quit VikingBar** to exit.

## Driving it with native AX and Peekaboo

Run `make smoke-app-fixture`. Inspect `before.png`, `click.json`, and `card.png` in the printed proof directory. Require a visible fixture marker, finite percentage, decimal GB amounts, expiry, and last update. The bundle must have no Dock icon. This command covers the card and five fixtures; it stops its child process during cleanup and does not exercise the units picker or Quit button.

For those routes, use the interactive launch and doctor in [the verification skill](../SKILL.md), starting with `--fixture finite`. Open the card with `.build/inspect-ui <pid> press vikingbar.status` and read `.build/inspect-ui <pid>`.

1. Run `.build/inspect-ui <pid> press GB`. Read the tree again and confirm the units menu contains **GiB**.
2. Run `.build/inspect-ui <pid> press GiB`. Read the card again. Require `33.53 GiB` remaining, `13.04 GiB used`, and a binary-units explanation.
3. Run `.build/inspect-ui <pid> press GiB` to reopen the picker. Read the tree, then run `.build/inspect-ui <pid> press GB`. Require `36.00 GB` remaining and `14.00 GB used`.
4. Capture each resulting card with Peekaboo, using its exact `kCGWindowNumber` from the helper's `windows` output: `peekaboo see --window-id <window-id> --no-elements --no-remote --path <proof-dir>/units.png --json`. Use a different filename for each state.
5. After all UI checks, run `.build/inspect-ui <pid> press vikingbar.quit`. Require helper exit 0 with a JSON receipt naming `vikingbar.quit` and the launched app's exit 0. Confirm the recorded PID exited.

## Gotchas

The unit popup exposes its current selection through `AXValue`. The helper matches that value only on `AXPopUpButton`. Re-observe after each action.

Quit can disconnect Accessibility before AXPress returns. The helper waits for its captured application to terminate before reporting success. A cleanup termination is not Quit-button proof. Keep both the Quit receipt and the original process's exit result.

An AX item outside the display is not click proof. Missing card content fails the smoke command. A no-argument launch shows setup information instead of fixture balances.
