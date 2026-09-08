# Daily SIM data and estimate

## Sub-features

- Daily aggregate bars for the selected SIM and selected bundle period, with GB/GiB, missing days, confirmed zero, partial today, and stale observations.
- An observed SIM total alongside the separately reported bundle balance.
- A labeled cycle estimate after three complete days with continuous fresh evidence. No percentage without known allowance scope.
- Balance remains available while history loads or fails. Foreground selection and Refresh cancel and drain pending history.

## How to get to it (user POV)

Open the helmet, choose **Data**, select a SIM and data bundle, then expand **Daily SIM data and estimate**. **Refresh now** refreshes balance first and schedules optional history. **Data units** changes both the card and chart units.

CLI equivalents are `vikingbar live --history` and `vikingbar live --cached`. Both use the stored session. Do not run either as a credential-free diagnostic.

## Driving it with the native proof runner

Read [history semantics](../../../../docs/history.md) and [live setup](../../../../docs/live-proof.md). Require fresh coordinator grants for account access and Mac UI driving, an existing authorized stored session, and an active display. Read the configured `PEEKABOO_BIN` wrapper before use. Do not alter shared capture state.

Run `make proof-live CHECK=history` with `PEEKABOO_BIN` set to the approved executable. The gate uses `Scripts/history-proof.py`, reuses recorded-process cleanup from the balance proof, and performs no 1Password bootstrap.

Require exit 0 and the redacted history receipt with `api_matches`, `forecast_matches`, `native_chart_matches`, and `native_refresh` all true. Require `cleanup.json` to show `exited: true`. Missing or insufficient live evidence fails the gate.

The gate first runs bundled `vikingbar proof history-api`. This forces real daily reads and compares their mapping and forecast arithmetic independently. It then launches the fresh native bundle, opens `vikingbar.historyDisclosure`, and compares `vikingbar.historyChart`, `vikingbar.historyForecast`, `vikingbar.historyStatus`, and `vikingbar.historyScope` with the same production presentation. The chart and each required history text must fit fully inside one AXPopover whose bounds match one CG window on a real display. Capture receipts must match that window, its bounds, and the requested image path; the card is rechecked after capture. Negative-origin displays are supported. It requires a newer successful balance after native Refresh; eligible historical samples may come from the scoped cache.

Keep the generated `.build/proof/<run>/` directory private. It contains API receipts, typed private reports, native trees, initial and refreshed chart PNGs, exact process and executable identities, and cleanup receipts. Inspect both PNGs for visible bars, date labels, units, gap markers, estimate wording, and readable layout. Evidence must survive cleanup. Publish only redacted results and build identity.

For source-only checks, run `make check SWIFTFORMAT=/tmp/vikingbar-tools-issue1/swiftformat`, `Scripts/test.sh --filter History`, and `python3 -m unittest discover -s Scripts/tests -p test_history_proof.py`. These tests inject synthetic HTTP and stores. They do not drive the native app, use Keychain, invoke 1Password, or contact the account API.

## Gotchas

- The summary endpoint groups traffic over the requested interval, not by day. The client requests bounded Brussels days with inclusive start and exclusive end. Empty arrays do not establish zero.
- Date queries require whole seconds and an escaped numeric UTC offset. Fractional seconds and `Z` produced HTTP 400 in the bounded live diagnostic; corrected aggregate and native proof still require a fresh slot.
- Summary traffic spans the SIM's regions and bundles. The selected balance and history need not match. No call-detail endpoint or personal raw-response fixture is allowed.
- Forecast proof needs three complete days plus continuous fresh elapsed-cycle evidence. Unavailable or truncated history is not a passing skip.
- CLI and native session replies contain account data. Keep output and captures out of public PRs and CI.
- Native history proof remains blocked before chart capture by the date-query failure. Source and synthetic results cannot establish visual or live API coverage. Record the exact verified head and private evidence after the coordinator grants the live slots.
