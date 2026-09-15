# Daily SIM data and estimate

## Sub-features

- Thirty daily aggregate bars for the selected SIM, including days before the current bundle started, with GB/GiB, missing days, confirmed zero, partial today, and stale observations.
- A marker at the known current bundle start; prior usage remains outside current-cycle totals and estimates. Midday starts use separate full-day chart and partial-day cycle summaries.
- An observed SIM total alongside the separately reported bundle balance.
- A labeled cycle estimate after three complete days with continuous fresh evidence. No percentage without known allowance scope.
- Balance remains available while history loads or fails. Foreground selection and Refresh cancel and drain pending history.

## How to get to it (user POV)

Open the helmet, select a SIM and data bundle, then hover over the daily usage summary. A separate detail panel opens beside the main popover. Move into the panel and hover over a day to inspect its date, amount, and status. Click or activate the summary with the keyboard to open the same details. Arrow keys select a day; Escape dismisses the panel. **Refresh** refreshes balance first and schedules optional history. **Data units** in Settings changes both the card and chart units.

CLI equivalents are `vikingbar live --history` and `vikingbar live --cached`. Both use the stored session. Do not run either as a credential-free diagnostic.

## Driving it with the native proof runner

Read [history semantics](../../../../docs/history.md) and [live setup](../../../../docs/live-proof.md). Require fresh coordinator grants for account access and Mac UI driving, an existing authorized stored session, and an active display. Read the configured `PEEKABOO_BIN` wrapper before use. Do not alter shared capture state.

Run `make proof-live CHECK=history` with `PEEKABOO_BIN` set to the approved executable. The gate uses `Scripts/history-proof.py`, reuses recorded-process cleanup from the balance proof, and performs no 1Password bootstrap.

Require exit 0 and the redacted history receipt with `api_matches`, `forecast_matches`, `native_chart_matches`, and `native_refresh` all true. Require `cleanup.json` to show `exited: true`. Missing or insufficient live evidence fails the gate.

The gate first runs bundled `vikingbar proof history-api`. This forces real daily reads and compares their mapping and forecast arithmetic independently. It then launches the fresh native bundle and hovers over `vikingbar.historyDisclosure`. The main AXPopover and the separate `vikingbar.historyPanel` must each match a visible CG window on a real display. The chart, total, forecast, status, and scope must fit fully inside the companion window and match the same production presentation. Negative-origin displays are supported. Native Refresh must produce a newer successful balance; eligible historical samples may come from the scoped cache.

Classic capture returns these attached windows as one group. The history gate targets each member by exact PID and window ID, validates its receipt against that member's bounds, and requires each PNG to match the geometric union of exactly the two known content windows at a uniform scale. It rejects extra content windows and rechecks both identities, frames, and selected-day details after each capture. These are explicitly labeled group images, not individual crops. No area capture or retry substitutes for a failed receipt.

Keep the generated `.build/proof/<run>/` directory private. It contains API receipts, typed private reports, native trees, initial and refreshed chart PNGs, exact process and executable identities, and cleanup receipts. Inspect both PNGs for visible bars, date labels, units, gap markers, estimate wording, and readable layout. Evidence must survive cleanup. Publish only redacted results and build identity.

The runner checks source-to-panel pointer traversal and selected-day details through `vikingbar.historyPlot`, whose bounds exclude chart axes. It compares the main balance and freshness text against the same report used for the detail panel. Moving away dismisses the panel; the next chart check opens it again.

For source-only checks, run `make check SWIFTFORMAT=/tmp/vikingbar-tools-issue1/swiftformat`, `Scripts/test.sh --filter History`, and `python3 -m unittest discover -s Scripts/tests -p test_history_proof.py`. These tests inject synthetic HTTP and stores. They do not drive the native app, use Keychain, invoke 1Password, or contact the account API.

## Gotchas

- The summary endpoint groups traffic over the requested interval, not by day. The client requests bounded Brussels days with inclusive start and exclusive end. Empty arrays do not establish zero.
- Live responses group totals under direction and traffic keys. Select only `outgoing.data`; the documented regional row array remains supported. Do not sum incoming data or other traffic types. Missing selected groups are malformed, while an explicit zero total is confirmed zero.
- Date queries require whole seconds and an escaped numeric UTC offset. Fractional seconds and `Z` produced HTTP 400 in the bounded live diagnostic.
- Summary traffic spans the SIM's regions and bundles. The selected balance and history need not match. No call-detail endpoint or personal raw-response fixture is allowed.
- Forecast proof needs three complete days plus continuous fresh elapsed-cycle evidence. Unavailable or truncated history is not a passing skip.
- CLI and native session replies contain account data. Keep output and captures out of public PRs and CI.
- On 15 September 2026, `7300211` passed live API/forecast proof after the earlier Keychain wait was resolved. Native validation failed because the complete daily series was absent from the chart accessibility tree. Cleanup passed. Earlier synthetic checks missed that assertion; the hardened harness now runs the unchanged production comparator. Verify the compact revision's chart label and complete live gate before issue completion. No password or 1Password read is part of this workflow.
