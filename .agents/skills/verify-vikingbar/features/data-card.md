# Data card

## Sub-features

Selected SIM and bundle, remaining beside total allowance, thin remaining progress, usage, exact expiry, expandable details, extra charges, Refresh and freshness, My Viking, Points, and footer Settings.

## How to get to it

Launch the fixture app and click the helmet. The balance opens directly without tabs. Use **Back** from Settings or Points. Settings contains GB/GiB, the menu bar preference, fixture selection, and Quit.

## Native proof

Run `make smoke-app-fixture` with the exclusive Mac UI slot. Require a fresh bundle, visible helmet, correctly ordered unclipped controls, one Settings entry, and no fixture/unit picker in the primary balance. Inspect `card.png`, named state captures, Settings, bundle-details, Points, refresh, and selection captures. Require `result.json` and four real Quit exits in `cleanup.json`.

1. Open `vikingbar.settings`. Choose `GiB` through `vikingbar.units`. Require the binary-units explanation in Settings.
2. Press `vikingbar.back`. Require `33.53 GiB` remaining and `13.04 GiB used`. Enabled menu amount remains `36 GB`.
3. Return to Settings, choose `GB`, then Back. Require `36.00 GB` and `14.00 GB used`.
4. Drive `vikingbar.subscriptionPicker` and `vikingbar.bundlePicker`. Check the [distinct synthetic amounts](fixture-selection.md). Settings and Back preserve selection.
5. Expand `vikingbar.bundleDetails`. Inspect description, applicability, and charges. Collapse it before Refresh.
6. Press `vikingbar.refresh`. Require visible refreshing and disabled selectors, followed by a changed freshness timestamp with unchanged synthetic amounts.
7. Open `vikingbar.points`, inspect customer scope, and return with Back.
8. Open Settings and press `vikingbar.quit`. Require the original process exit 0.

Capture each settled popover through its exact window ID. The smoke matches window and AXPopover bounds to avoid capturing a closing popup menu. Inspect light, dark, both increased-contrast appearances, and reduced transparency. App-only fixture flags change no system preferences.

## Proof status

The redesigned native workflow is pending. Previous tab-layout captures are historical evidence only. Before closing issue22, retain old/new primary, Settings, and exceptional captures and compare the new result with the approved owner mockup. Source and packaged CLI gates do not prove native wiring or visual quality.

## Gotchas

The native helper prefers an actual popup menu item over its current value. Re-read the tree after opening a picker. Quit can disconnect Accessibility before AXPress returns; the helper waits for its captured app to terminate. Failure cleanup is not Quit-button proof.

No-argument startup can access the stored live account. Explicit fixture launch, including its Not connected selection, stays isolated.
