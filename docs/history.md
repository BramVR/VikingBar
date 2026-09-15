---
summary: "Daily SIM summaries, cycle estimates, and history proof boundaries."
read_when:
  - Changing daily usage or forecast calculations
  - Extending history API or native chart proof
---

# Daily SIM usage and cycle estimates

The selected SIM's Data card includes **Daily SIM data and estimate**. Its chart uses the selected data bundle's validity period. Bars show reported daily bytes in GB or GiB. Missing summaries remain gaps; an explicit numeric zero is confirmed zero. Today is partial. Stale samples retain their amounts with a stale label.

History covers all data traffic for that SIM, across regions and bundles. The provider's selected-bundle balance has a different scope. The card keeps both figures separate and explains that provider updates may lag. The history sum never replaces or corrects the balance.

## Request and availability limits

The only history endpoint is `GET /subscriptions/{id}/usage-summary`. Each request sets `traffic_type=data`, `direction=outgoing`, `from_date`, and `until_date`. It reads aggregates, not call-detail records. The decoder retains byte totals and fetch metadata; it does not retain phone numbers or raw responses.

The [provider schema](https://docs.uwa.mobilevikings.be/swagger.json) defines an inclusive start and exclusive end. Unqualified dates use Europe/Brussels. VikingBar constructs Gregorian calendar days in that timezone, clips them to the exact bundle period and current time, and sends whole-second UTC datetimes with a numeric `+0000` offset, escaping the plus in the query. The server rejects fractional seconds and `Z` in these parameters. Calendar arithmetic handles 23-hour and 25-hour DST days. The observation clock uses whole seconds so request and display intervals agree. A fractional bundle boundary fails the history request locally instead of silently changing its scope; balance remains available and the forecast stays unavailable.

One history load covers at most 62 daily intervals, with a 45-second operation budget and at most 10 seconds per request. Longer elapsed periods are marked truncated. A failure or rate limit stops the remaining requests. Unfetched intervals remain missing. API retention and delayed updates can leave gaps even inside the requested period; the app does not promise earlier history.

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

The API comparison requires real summaries with sufficient evidence for a calculable forecast. Missing evidence fails the gate; a synthetic result or unavailable estimate cannot substitute for the required live proof. No 1Password read is part of this history gate. A missing stored connection must be established separately through the approved connection workflow.

The source and synthetic gate pass. Required live history proof has not passed. On 15 September 2026, the integrated build at `47c5a4d` timed out during the API proof before native launch. SecurityAgent appeared while the CLI waited, which suggests a Keychain authorization wait. No API receipt or chart capture was produced. Cleanup passed. See the [history feature map](../.agents/skills/verify-vikingbar/features/history.md) for commands, evidence, and coverage boundaries.
