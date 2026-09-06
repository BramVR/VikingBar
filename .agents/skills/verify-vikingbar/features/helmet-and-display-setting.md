# Helmet and display setting

## Sub-features

Fixed native helmet geometry, remaining-fraction inset, exceptional states, decimal GB label, Settings toggle, isolated persistence, light/dark rendering, and 1x/2x scales.

## How to get to it

Click the helmet and open **Settings**. The default-off toggle is **Show remaining GB in menu bar**. Its help text is **Display the data left in GB beside the helmet.** Turning it on adds a compact decimal GB amount; turning it off removes all adjacent text. The inset remains in both modes.

## Automatic native proof

Run `make smoke-app-fixture` under the [launch and isolation contract](../SKILL.md). The command supplies a new task-local settings file and checks:

- Empty default status title and fixed icon-only width through allowance changes.
- Exact Settings copy, fixture marker, toggle value, and immediate status change.
- Finite `36 GB`, exhausted `0 GB`, and honest `Unlimited`/`Unavailable` titles; GB remains decimal when the card uses GiB.
- All five fixture states plus Not connected in both modes, with visible status crops and exact card states.
- Preference on survives the first real Quit/relaunch; off survives the second. All three task-owned processes exit through Quit with code 0.

Inspect status crops, Settings captures, `result.json` persistence fields, and `cleanup.json`. Compare finite, exhausted, infinity, and question-mark images; screenshots and semantic AX assertions both matter. The smoke retains crops for visual inspection rather than claiming a pixel comparison.

For targeted actions, press `Settings`, read the tree, and press `vikingbar.showRemainingGB`. Re-read the toggle's `AXValue` and status `AXTitle`, `AXDescription`, and `AXHelp`. Fixture provenance and exact allowance/freshness remain meaningful even when `AXTitle` is empty. Press `Data` to return to the card.

## Deterministic rendering and model proof

Run `make check`. Generate inspectable PNGs from the actual renderer without launching a status item:

```sh
VIKINGBAR_RENDER_PROOF_DIR="$PWD/.build/proof/icon-renders" Scripts/test.sh --filter HelmetRendererTests
```

Inspect `helmet-contact-sheet.png` and individual light/dark 1x/2x images. Require a recognizable short-horn helmet with fixed bounds, left-anchored cutout, full/half/near-empty/empty fills, and distinct infinity/question treatments. Pixel tests verify bounds and fill direction. Model tests cover clamping, overfull values, zero/unknown totals, stale retained fill, decimal formatting including tiny nonzero values, selected-snapshot consistency, and view-independent status updates. Persistence tests use contained synthetic stores and exercise default/on/off/recreation and error visibility.

## Isolation

Explicit fixture launches use memory unless the app-only `--settings-file ABSOLUTE_PATH` is supplied with `--fixture`. Use a new task-owned path for proof, reuse only that file for relaunch, and never discover or migrate real preferences. The CLI report and its fixture status-title semantics remain unchanged. No carrier API proof is needed for this feature.
