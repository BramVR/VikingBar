# Viking Points

## Sub-features

- Customer-wide available, pending, and blocked points, with no per-SIM attribution.
- Expandable recent transactions with signed amounts and preserved provider states.
- Separate balance and history freshness, retained values, and failure messages.
- Bounded history of three pages of 20 transactions, with explicit truncation.

## How to get to it (user POV)

Open the helmet and choose **Points**. Expand **Recent transactions**. Use **Refresh now** on the Data tab to update usage and points. Fixture launches label their points as synthetic.

## Driving it with native AX and the CLI

Read the parent [verification skill](../SKILL.md). Hold fresh coordinator slots for the Mac UI and account access. Run `make proof-live CHECK=points` with `PEEKABOO_BIN` pointing to the configured executable. This stored-session gate requires an already connected account. It never bootstraps credentials.

The gate builds and identifies its own bundle and worker, compares raw loyalty responses through `vikingbar proof points-api`, and opens the native Points tab. It compares available, pending, blocked, freshness, and history summary with the shared CLI presentation. It expands the transaction list and proves the first complete visible row's amount, state, date, and description when a row exists. The receipt reports the actual visible row count. The API comparison covers all fetched rows; it does not establish that every row was visible onscreen.

After native Refresh, require newer points balance and history timestamps, a usable usage card, and unchanged connection identity. The run must exit through native Quit and retain its successful cleanup receipt. Inspect the settled popover PNGs in the private `.build/proof/<run>/` directory.

For targeted inspection, use `Points`, `vikingbar.points.available`, `vikingbar.points.pending`, `vikingbar.points.blocked`, and `vikingbar.points.transactionsToggle`. Row identifiers use `vikingbar.points.transaction.<zero-based-index>.amount`, `.state`, `.updated`, and `.description`. Switch to **Data** for Refresh and Quit.

Run `make check` and `Scripts/test.sh` for synthetic coverage. `vikingbar --fixture finite` exposes synthetic points through the shared CLI presentation without account access. The fixture states exercise pending, blocked, expired, failed, and unknown transaction states. Core tests also cover empty history and pagination boundaries.

## Gotchas

Points belong to the customer. Switching SIMs must not relabel the same customer balance or repeat it for each SIM. Pending and blocked amounts never contribute to available points. A truncated transaction list cannot calculate the account balance.

A successful balance fetch does not imply successful history retrieval. A points failure must leave usage visible and preserve last-success values with stale labels. Unknown values stay unavailable.

The live gate has not yet executed on this implementation. Missing live proof is an incomplete feature. Empty live history can prove an honest empty state but cannot prove a visible transaction row. Synthetic tests cover provider states absent from the real account.

Account values, transaction descriptions, native captures, and cached CLI output remain private. Publish only redacted receipts and build identity. Reconnection needs the approved setup and a coordinator credential slot.
