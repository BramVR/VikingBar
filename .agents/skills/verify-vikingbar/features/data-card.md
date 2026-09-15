# Data card

## Sub-features

Selected SIM and bundle, remaining beside total allowance, thin remaining progress, usage, exact expiry, expandable details, extra charges, Refresh and freshness, My Viking, Bills, Points, and footer Settings. Plain actions use native menu selection colors while the pointer is inside their padded control frame. Disabled actions retain disabled text and no selection fill.

## How to get to it

Launch the fixture app and click the helmet. The balance opens directly without tabs. Use **Back** from Settings or Points. Settings contains GB/GiB, the menu bar preference, fixture selection, and Quit.

## Native proof

Run `make smoke-app-fixture` with the exclusive Mac UI slot. Require a fresh bundle, visible helmet, correctly ordered unclipped controls, one Settings entry, and no fixture/unit picker in the primary balance. Inspect `card.png`, named state captures, Settings, bundle-details, Points, refresh, selection, and action-hover captures. Require `result.json` and four real Quit exits in `cleanup.json`.

1. Inspect normal, hover, and exit captures for Refresh, Open My Viking, Bills, Points, Settings, and Back in explicit light appearance. Require native paired selection colors, one selected row, and unchanged AX and popover frames.
2. Require adjacent Bills-to-Points and Points-to-Settings transfers. Require the prior row to clear. Use the retained pointer receipts to confirm center and near-edge destinations inside each AX frame.
3. Click Settings at normalized point `0.05,0.5`. Require Settings to open. This proves that the padded edge belongs to the control's hit area.
4. Open Bills in each appearance. Require `vikingbar.invoices.load` to declare `AXEnabled == false`. Inspect its normal, hover, and exit captures and require no selected fill.
5. Open `vikingbar.settings`. Choose `GiB` through `vikingbar.units`. Require the binary-units explanation in Settings.
6. Press `vikingbar.back`. Require `33.53 GiB` remaining and `13.04 GiB used`. Enabled menu amount remains `36 GB`.
7. Return to Settings, choose `GB`, then Back. Require `36.00 GB` and `14.00 GB used`.
8. Drive `vikingbar.subscriptionPicker` and `vikingbar.bundlePicker`. Check the [distinct synthetic amounts](fixture-selection.md). Settings and Back preserve selection.
9. Expand `vikingbar.bundleDetails`. Require `vikingbar.bundleDescription` and `vikingbar.bundleApplicability` to match the selected bundle and remain inside the popover. The always-visible extra-charge label does not prove expansion. Collapse and require both fields to disappear before Refresh.
10. Press `vikingbar.refresh`. Require visible refreshing and disabled selectors, followed by a changed freshness timestamp with unchanged synthetic amounts.
11. Open `vikingbar.points`, inspect customer scope, and return with Back.
12. Open Settings and press `vikingbar.quit`. Require the original process exit 0.

Require finite positive AX and CoreGraphics popover bounds fully inside one finite positive active display. Matching an offscreen window is not proof. Capture each settled popover through its exact window ID. The smoke matches window and AXPopover bounds to avoid capturing a closing popup menu. Inspect explicit light, dark, high-contrast light, and high-contrast dark appearances. The final high-contrast dark launch also enables reduced transparency. App-only fixture flags change no system preferences.

## Proof status

The redesigned fixture gate passed on 2026-09-14 at product commit `f148176cf871f001cf83bd31a0634527e2e984de`. The uninterrupted four-launch run covered states, units, selection, refresh, details, Points, display-setting persistence, and four native Quit exits. Separate current-build captures completed light, dark, increased-contrast, and reduced-transparency inspection. Fresh parent and head captures showed the compact card at 386 by 560 logical points, compared with the former card at 386 by 596.

The issue 31 fixture gate passed on 2026-09-16 under `.build/proof/20260916-000000-411367`. Its 13 normal/hover/exit sequences cover all six named actions, adjacent-action transfers, unchanged control/window geometry, and disabled Load bills in all four appearances. A near-edge Settings click opened Settings. Inspection of the native PNGs confirmed readable selected text/icons, visible fills, and cleared selection after exit. `result.json` reports success, and `cleanup.json` records four verified Quit exits of 0. This is manual visual inspection of automated captures, not an automated raster comparison.

Separate keyboard proof on the same executable passed under `.build/proof/20260915-235941-451980`. Real Command-comma, Command-left, and Command-R events opened Settings, returned to the balance, and completed Refresh. The helper verified the task-owned app was frontmost before dispatch. The process exited through Quit with status 0. This check does not establish Tab traversal.

Real keyboard events opened Settings, returned with Back, refreshed the balance, and selected the distinct Travel SIM and Extra data bundle. The selector check established focus through Accessibility before sending Down and Return. It does not prove Tab traversal. Global Keyboard Navigation remained unchanged. Earlier failed probes remain separate from passing receipts.

A private synthetic derivative with identical production views passed long-detail expansion across the fitted/scrollable boundary, native scrollbar navigation to the footer and back, collapse, and Quit. An app-local URL interceptor confirmed native My Viking dispatch and its exact destination; it did not load a browser or account page. Raw receipts and before/after dark captures remain private. These focused results supplement the automatic gate.

Normal launches inherit macOS appearance and native popover material. Fixture-only appearance overrides and the reduce-transparency fallback do not change system preferences.

## Gotchas

The native helper prefers an actual popup menu item over its current value. Re-read the tree after opening a picker. Quit can disconnect Accessibility before AXPress returns; the helper waits for its captured app to terminate. Failure cleanup is not Quit-button proof.

No-argument startup can access the stored live account. Explicit fixture launch, including its Not connected selection, stays isolated.
