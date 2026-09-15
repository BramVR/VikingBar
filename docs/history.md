---
summary: "Daily SIM summaries, cycle estimates, and history proof boundaries."
read_when:
  - Changing daily usage or forecast calculations
  - Extending history API or native chart proof
---

# Daily SIM usage and cycle estimates

The selected SIM's Data card includes a compact daily usage summary and chart. Hover over a bar to show its date, amount, and status in the main usage section. Click the bar or activate the summary with the keyboard or an accessibility tool to open a separate detail panel beside the main popover. The panel keeps the selected day and stays open until closed, dismissed with Escape, or its parent or account context changes.

The usage section places today's usage and the observed cycle total above an inline chart. The adjacent panel groups the selected day, current-cycle totals and estimate, and data scope into distinct sections. The existing balance layout, selectors, and menu actions remain unchanged.

The chart shows the last 30 Brussels calendar days, including today and days before the current bundle began. Bars show reported daily bytes in GB or GiB. Hover over a day for its full Brussels date, amount, and observation status. Missing summaries remain gaps; an explicit numeric zero is confirmed zero. Today is partial. Stale samples retain their amounts with a stale label.

An orange dashed line marks **Cycle started** at the selected bundle's known start time when it falls in the visible month. The panel shows that date, including the time for a midday start. The app does not infer earlier renewal dates. **Cycle so far** and the estimate use only the current cycle, even though the chart includes older usage.

History covers all data traffic for that SIM, across regions and bundles. The provider's selected-bundle balance has a different scope. The card keeps both figures separate and explains that provider updates may lag. The history sum never replaces or corrects the balance.

## Request and availability limits

The only history endpoint is `GET /subscriptions/{id}/usage-summary`. Each request sets `traffic_type=data`, `direction=outgoing`, `from_date`, and `until_date`. It reads aggregates, not call-detail records. The decoder retains byte totals and fetch metadata; it does not retain phone numbers or raw responses.

The live API groups totals by direction and traffic type. VikingBar reads only `outgoing.data.total_quantity`; incoming, voice, SMS, and unknown traffic do not contribute. It also accepts the provider's documented array of regional data summaries. A grouped numeric zero is confirmed zero. An empty documented array remains missing; a missing or malformed selected aggregate fails the load.

The [provider schema](https://docs.uwa.mobilevikings.be/swagger.json) defines an inclusive start and exclusive end. Unqualified dates use Europe/Brussels. VikingBar constructs Gregorian calendar days in that timezone, clips them to the exact bundle period and current time, and sends whole-second UTC datetimes with a numeric `+0000` offset, escaping the plus in the query. The server rejects fractional seconds and `Z` in these parameters. Calendar arithmetic handles 23-hour and 25-hour DST days. The observation clock uses whole seconds so request and display intervals agree. A fractional bundle boundary fails the history request locally instead of silently changing its scope; balance remains available and the forecast stays unavailable.

One history load makes at most 62 unique summary requests, with a 45-second operation budget and at most 10 seconds per request. Exact intervals shared by the cycle and rolling month are fetched once. A midday cycle start needs separate full-day chart and partial-day cycle summaries; bytes are never prorated. At exact midnight, today's empty chart slot needs no request. Cycles longer than the bound show the rolling month while withholding incomplete cycle totals and estimates. A failure or rate limit stops the remaining requests. Unfetched intervals remain missing. Missing or failed older chart data does not invalidate a complete current-cycle estimate. API retention and delayed updates can leave gaps; the app does not promise earlier history.

Recent observations expire after five minutes. Older completed days expire after 24 hours. Missing observations remain eligible for retry after the history retry delay. A new Brussels day or bundle period invalidates the corresponding interval assumptions. Cache entries remain tied to the connection, SIM, bundle identity, and cycle dates.

## Estimate rules

An estimate requires at least three complete Brussels days and fresh, confirmed evidence for the entire elapsed cycle through the start of today. A clipped opening day contributes bytes and elapsed time but does not count as a complete day. Today's partial traffic does not enter the forecast.

The calculation divides observed bytes by actual elapsed seconds, then multiplies by the cycle's actual duration in seconds. Complete zero observations can produce a zero estimate. New cycles, missing or stale evidence, failed loads, truncated periods, and expired cycles suppress the estimate.

The card labels the result **Estimated SIM data this cycle**. It makes no renewal promise. The summary endpoint has no bundle identifier, so the app does not divide SIM totals by a selected allowance. It shows no forecast percentage, including for unlimited and unknown limits.

## Session ownership

Balance refresh returns before history starts. The app queues `refreshHistory` alongside Points and Bills on the existing CLI worker. Only one optional command runs at a time; pending metadata survives a foreground refresh. Foreground refresh or selection cancels and drains that optional command through the ordered worker protocol. History publication checks connection, SIM, cycle, and revision. The app merges only history from the reply, never an older balance.

History uses the access token obtained by balance refresh. It does not bootstrap credentials or rotate the token independently. Expiry and optional failures leave the main balance available. The next balance refresh can obtain a usable token and retry history.

`vikingbar live --history` refreshes balance and then loads history. `vikingbar live --cached` reads saved state and includes the shared history presentation. Both access the connected account's local store; the first also reads the API. Output contains private account amounts and identity. Fixture commands remain isolated.

## Verification status

`make proof-live CHECK=history` uses a stored connection. It requires fresh coordinator grants for account access and Mac UI driving. It builds the native bundle, runs the independent `proof history-api` comparison, opens the chart, verifies displayed values, presses Refresh, and retains chart captures and process cleanup receipts.

The chart and balance checks use two visible windows of the same report. The runner verifies main-chart hover details without opening the panel, a real click preserving the selected day, pointer travel into the companion, and day selection. All chart labels and required history text must fit inside the detail panel. Classic capture includes both attached windows; the runner validates each exact-window target receipt and the resulting two-window group geometry. The main balance and freshness text remain visible and are checked before Refresh.

The API comparison requires real summaries with sufficient evidence for a calculable forecast. Missing evidence fails the gate; a synthetic result or unavailable estimate cannot substitute for the required live proof. No 1Password read is part of this history gate. A missing stored connection must be established separately through the approved connection workflow.

On 15 September 2026, code head `8645afe` passed the complete stored-session gate with 30 real summary requests and 18 observed cycle days. API mapping, forecast arithmetic, main-bar hover, click-open details, exact chart values and captures, native Refresh, and cleanup all passed. The gate requires a balance newer than its pre-launch snapshot before interactions, preventing the launch-refresh race found on `d473579`. Earlier chart accessibility and native-focus failures are covered by the hardened production comparator and fresh synthetic keyboard scenarios. Real account reports and screenshots remain private. See the [history feature map](../.agents/skills/verify-vikingbar/features/history.md) for commands and coverage boundaries.
