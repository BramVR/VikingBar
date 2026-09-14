# Viking Points

## Sub-features

- Customer-wide available, pending, and blocked points, with no per-SIM attribution.
- Expandable recent transactions with signed amounts and preserved provider states.
- Separate balance and history freshness, retained values, and failure messages.
- Bounded history of three pages of 20 transactions, with explicit truncation.

## How to get to it (user POV)

Open the helmet and choose **Points**. Expand **Recent transactions**. Use **Back**, then **Refresh** on the balance to update usage and points. Fixture launches label their points as synthetic.

## Driving it with native AX and the CLI

Read the parent [verification skill](../SKILL.md). Hold fresh coordinator slots for the Mac UI and account access. Run `make proof-live CHECK=points` with `PEEKABOO_BIN` pointing to the configured executable. This stored-session gate requires an already connected account. It never bootstraps credentials.

The gate builds and identifies its own bundle and worker, compares raw loyalty responses through `vikingbar proof points-api`, and opens the native Points destination. It compares available, pending, blocked, freshness, and history summary with the shared CLI presentation. It expands the transaction list and proves the first complete visible row's amount, state, date, and description when a row exists. The receipt's `visible_transaction_count` is 0 or 1: it records whether the first complete row was proved, not the total number of visible rows. The API comparison covers all fetched rows; it does not establish that every row was visible onscreen.

After native Refresh, require newer points balance and history timestamps, a usable usage card, and unchanged connection identity. The run must exit through native Quit and retain its successful cleanup receipt. Inspect the settled popover PNGs in the private `.build/proof/<run>/` directory.

The status item and the matched popover must each fit within a real display. The balance and points gates share finite rectangle validation and AX-to-CoreGraphics window matching. Card text must lie inside that popover; expanded transaction text must also lie inside its scroll area. Offscreen or clipped popovers fail even when the status item remains visible. Capture the matched window, not the first window in the process list.

For targeted inspection, use `vikingbar.points`, `vikingbar.points.available`, `vikingbar.points.pending`, `vikingbar.points.blocked`, and `vikingbar.points.transactionsToggle`. Row identifiers use `vikingbar.points.transaction.<zero-based-index>.amount`, `.state`, `.updated`, and `.description`. Press `vikingbar.back` for Refresh. Open footer Settings for Quit.

Run `make check` and `Scripts/test.sh` for synthetic coverage. `vikingbar --fixture finite` exposes synthetic points through the shared CLI presentation without account access. The fixture states exercise pending, blocked, expired, rejected, and unknown transaction states. Core tests also cover empty history and pagination boundaries.

## Gotchas

Points belong to the customer. Switching SIMs must not relabel the same customer balance or repeat it for each SIM. Pending and blocked amounts never contribute to available points. A truncated transaction list cannot calculate the account balance.

A successful balance fetch does not imply successful history retrieval. A points failure must leave usage visible and preserve last-success values with stale labels. Unknown values stay unavailable.

The stored-session live gate passed on product commit `9481b3af40ba2c1cc992d9432effb8b327e0423e`. It verified the independent API comparison and token refresh, newer balance and history timestamps after native Refresh, unchanged connection identity, expansion and collapse, one complete visible transaction row, and native Quit with successful owned-process cleanup. Actual collapsed, refreshed, and expanded screenshots were inspected; balances, freshness labels, tabs, and the first row remained inside the settled popover. The history viewport is bounded to keep the summary visible.

Combined invoice and points coverage passed on `a2b87f3b22170b5c90ac4a6528d8d61d2ae3f55d`. Bills loading preserved points. The independent points API comparison passed, and native Refresh produced newer usage, points balance, and history timestamps on the same connection. Native summaries and the first expanded row matched the CLI; collapse and Quit with owned-process cleanup passed. Captures and receipts remain private.

Fresh all-nine post-merge maintenance passed on main `e0f353dcfe2042932bf6e03e647782dc37b6aa99`. The current-build run covered combined Bills and Points, the independent Points API comparison, native Refresh, first-row expansion and collapse, and owned-process Quit cleanup; the separate auth CLI gate also passed. This closes the earlier inactive-display maintenance gap. Current compact-navigation proof on 2026-09-14 passed Points, Back, newer usage and Points timestamps after Refresh, first-row expansion and collapse, independent API comparison, and native Quit. A Keychain prompt interrupted the release stage. A separate continuation of the exact release binaries then passed stored-session restoration, a newer balance on the same connection and selection, native Quit, and cleanup. The interrupted receipt remains failed; the composed live evidence completes the gate.

This proves the fetched live history and the first visible row, not every row's onscreen rendering. Empty history, truncation, stale/error recovery, and provider states absent from the account remain covered by synthetic tests. Re-run the live gate after material product or proof changes; keep its private receipts bound to the tested source and executable hashes.

Account values, transaction descriptions, native captures, and cached CLI output remain private. Publish only redacted receipts and build identity. Reconnection needs the approved setup and a coordinator credential slot.
