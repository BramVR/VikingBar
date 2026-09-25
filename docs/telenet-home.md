---
summary: "Connect Telenet home internet and read policy counters separately from downloaded traffic."
read_when:
  - Connecting a Telenet account
  - Changing Telenet home usage or polling
  - Running native Telenet proof
---

# Telenet home internet

Source builds support Telenet residential home internet beside Mobile Vikings. The published 0.1.0 preview predates this integration. Telenet mobile, business accounts, invoices, and modem or Wi-Fi controls are outside this integration.

## Connect an account

Open the helmet, then **Settings**, **Account**, and **Add account**. Choose **Telenet** and enter your username and password. Telenet does not need a Mobile Vikings public client ID. You can also use **Connect with 1Password** with an approved two-field reference. The helper reads that item once in its own named tmux session.

The password is discarded after login. VikingBar saves the cookie session in a separate Keychain item for that account. Background refresh never reads 1Password or retries the password. If Telenet requires another sign-in or interactive authentication, reconnect explicitly. MFA, natural expiry, and automatic renewal are not claimed as verified.

Choose **Telenet** in the provider picker and select a home service. Switch back to **Mobile Vikings** to read your mobile balance. Each account caches its selected service with that service's identity. A Telenet error does not replace Mobile Vikings data.

## Read the home card

The card preserves Telenet's billing dates and category. A billing-period end is not labeled as an allowance expiry.

Finite plans show a large remaining allowance and cyan quota bar, matching the mobile card. Downloaded traffic has its own amount and a peak/off-peak composition bar. That bar divides downloaded traffic; it does not measure remaining allowance. Expand **Usage details** for the provider and fetch timestamps.

- The policy counter comes from Telenet's usage endpoint. It is separate from total downloaded traffic.
- Peak and off-peak traffic come from the daily-usage endpoint. Their sum is downloaded traffic.
- `CAP` is a finite quota. `FUP` and `TURBO` retain their policy-threshold meaning and category. Passing a threshold does not mean data is exhausted.
- `UNLIMITED` retains the provider's category. A separately reported allocation is shown as an allocation, without inventing a remaining percentage or asserting a speed limit.
- The current decoder reports speed state as unknown. No speed-status field has been verified for this endpoint. Crossing a counter threshold alone does not prove that speed was reduced.
- Provider update time is separate from the time VikingBar successfully fetched the response. Missing values are unavailable, not zero.

Traffic uses decimal GB from the provider. The selected display unit controls presentation, with 1 GB equal to 1,000,000,000 bytes.

## Read daily usage

The home card uses the same 30-day chart and adjacent detail panel as Mobile Vikings. Hover over a bar to read its date, amount, and status. Click the bar to open the detail panel on that day. Close dismisses the panel. The data-unit setting applies to both charts.

Daily bars show Telenet's reported downloaded traffic for the selected home service. The current billing period is the available source range. Earlier dates remain unavailable, missing rows remain gaps, and a reported zero stays distinct from a missing reading. Future dates in Telenet's response never become observations. Today's reading remains partial if it survives in the cache into the next day.

The panel keeps the observed daily sum separate from the provider's period download total. Neither replaces the policy counter on the home card. A labeled estimate uses fresh, continuous evidence from at least three complete elapsed days. It excludes today's partial traffic and uses actual elapsed Brussels time across daylight-saving changes. Missing days, stale readings, or an expired period suppress the estimate. Provider reports can lag.

The chart uses daily observations returned with the home usage reading. Daily evidence is cached with its account, home service, connection, and billing period. Switching that context closes the previous detail panel.

## Refresh and recovery

Automatic Telenet polling runs no more often than hourly. Manual requests have a one-minute minimum interval. Both limits survive relaunch and apply across the app and CLI for the same account.

A failed request keeps the previous reading marked stale. Transient failures back off without immediate retry. A server `Retry-After` deadline remains authoritative even when longer than the normal backoff. Cached reads and service selection do not bypass that deadline. Authentication failures require reconnect; they do not trigger background password use.

## Use the CLI

Reserve a separate account slot:

```sh
vikingbar accounts add --provider telenet
```

Use the returned `telenet/UUID` selector for connection and reads:

```sh
vikingbar connect --account telenet/UUID
vikingbar live --account telenet/UUID
vikingbar live --account telenet/UUID --cached
vikingbar live --account telenet/UUID --service SERVICE_ID
vikingbar accounts select telenet/UUID
```

`connect` reads a JSON object with `username` and `password` from private stdin. Use the approved connection helper instead of putting secrets in shell history. Explicit account selectors do not change the shared default; `accounts select` does.

The live report includes `state.homeUsage` and the shared `home` presentation. It contains no cookies or credentials. It can contain personal service and usage information, so keep it private.

A concurrent account update can make a CLI live read return `session-busy`. Wait for the update before retrying the read. The native proof retries that specific response within its bounded wait.

The live `dailyusage` response contains dated `dailyUsages` entries with `total`, `peak`, and `offPeak` values. The cache retains validated decimal GB values through the fetch day. The shared `historyPresentation` report supplies the home chart, including gaps, partial readings, and the estimate. Display conversion rounds fractional bytes to the nearest byte.

## Verify the integration

Run the local checks without credentials:

```sh
make check
make smoke-app-fixture
```

The required real gate is:

```sh
make proof-live CHECK=telenet-home-ui
```

Set `VIKINGBAR_TELENET_CREDENTIAL_REFERENCE` to the private two-field reference described in [Telenet proof](telenet-proof.md). Set `PEEKABOO_BIN` to the configured Peekaboo executable. Hold exclusive account-access and Mac UI ownership. State the exact approved item and fields before running; the native helper performs the one targeted lookup. Do not run a separate credential read first.

The gate builds a fresh bundle, connects through the native 1Password action, independently checks usage responses, compares native card and status text, refreshes, switches to Mobile Vikings and back, and relaunches with the stored session. It requires an existing usable Mobile Vikings account and a real Telenet home service. It restores the prior selected account and stops only its recorded processes. Private screenshots, process identities, comparisons, and cleanup receipts stay under `.build/proof/`.

A missing account service, native automation failure, skipped comparison, or fixture-only pass leaves issue #42 incomplete. The standalone [feasibility gate](telenet-proof.md) proves a different boundary and does not replace native proof.
