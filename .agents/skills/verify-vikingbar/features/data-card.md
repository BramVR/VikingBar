# Data card

## Sub-features

Used percentage, used and remaining amounts, expiry, freshness, GB/GiB selection, and Quit. See [Helmet and display setting](helmet-and-display-setting.md) for the status image and Settings preference.

## How to get to it

Launch the fixture app and click the helmet. Select **Data** if Settings is open. Use **Data units** to switch GB/GiB and **Quit VikingBar** to exit.

## Native proof

Run `make smoke-app-fixture`. Inspect `before.png`, `click.json`, `card.png`, and the named fixture captures. Require a visible fixture marker, finite percentage, decimal GB amounts, expiry, and last update. The app must have no Dock icon. The command also covers Settings, both display modes, all fixtures, Not connected, units, and three real Quit exits across two relaunches.

For targeted checks, use the interactive launch and doctor in [the verification skill](../SKILL.md). Open the card with `.build/inspect-ui <pid> press vikingbar.status`. Read the tree before the next action.

1. Press `GB`. Wait until the popup exposes the **GiB** menu item, then press `GiB`.
2. Require `33.53 GiB` remaining, `13.04 GiB used`, and the binary-units explanation. If amount mode is enabled, the status title remains `36 GB`.
3. Press `GiB`, wait for the **GB** menu item, then press `GB`. Require `36.00 GB` remaining and `14.00 GB used`.
4. Capture each settled popover by its exact window ID. The smoke's `capture_card` helper matches window and AXPopover bounds to avoid capturing a closing popup menu.
5. Press `vikingbar.quit`. Require the helper's receipt and the original app process's exit 0.

## Gotchas

SwiftUI tab-content accessibility identifiers can overwrite descendant control identifiers. Target native tabs by their observed `AXRadioButton` descriptions, `Data` and `Settings`; retain the individual card identifiers. The helper matches popup current values only on `AXPopUpButton` and prefers an actual menu item when open.

Quit can disconnect Accessibility before AXPress returns. The helper waits for its captured application to terminate. A failure-cleanup termination is not Quit proof. No-argument launch shows setup information without synthetic balances.
