# Project context

## Current state

The Swift package contains the native menu app, a shared core, and a JSON CLI. Mobile Vikings and Telenet home internet run as live providers; fixtures remain synthetic. The HTML exploration predates the confirmed public-client setup; this document records the newer findings.

## Authentication

Mobile Vikings support confirmed a public OAuth application with no client secret, using the resource owner password grant. They stated the client has read-only scope. Login and token refresh succeeded in a local probe on 6 September 2026.

- API base: `https://uwa.mobilevikings.be/mv`.
- Token endpoint: `POST /oauth2/token/`, form-encoded password or refresh grant.
- Public client ID and login fields are held in the configured 1Password item. The client ID is not a secret; keep account-specific setup out of source defaults.
- Initial connection accepts direct native credential entry or retrieves the approved username/password through optional 1Password. Discard the password after the exchange; do not repeatedly read it during background refresh.
- Refresh tokens persist in macOS Keychain under a rotation lease. The token exchange and Keychain write cannot be atomic; an interrupted rotation requires reconnect. The auth/balance probe persists no tokens.
- The observed access-token lifetime was 599 seconds. Always honor `expires_in`.
- MFA behavior remains unverified. Never disable MFA to make the integration work.

### Scope discrepancy

Both initial and refreshed token responses reported `read write`, even when the initial request included `scope=read`. This conflicts with support's statement. Effective write permissions were not tested. Do not claim server-enforced read-only access until clarified.

The client must enforce its own request allowlist: required authentication POSTs and approved data GETs. No test writes to discover permissions.

The password grant is a legacy flow: the app briefly handles the account password. Browser authorization with PKCE is not currently offered according to support. This is an accepted constraint for the personal integration, not a modern OAuth recommendation.

## Data verified

`GET /subscriptions` and `GET /subscriptions/{id}/balance` succeeded using a refreshed token. Balance data included a finite data bundle with total, used, remaining, validity dates, and out-of-bundle cost. Personal values and identifiers are intentionally omitted.

Later stored-session gates verified these reads:

- `/subscriptions/{id}/usage-summary`: daily outgoing data summaries. See [history](docs/history.md).
- `/loyalty-points/balance` and `/loyalty-points/transactions`: available/pending/blocked points and transaction states. See [live proof](docs/live-proof.md#viking-points-proof).
- `/invoices` and invoice PDFs: payment state, amount due, and grouped bills. See [invoices](docs/invoices.md).

## Data documented, not yet verified

- `/subscriptions/{id}/usage`: detailed records. Prefer summaries when sufficient; details can contain phone numbers. Not in the request allowlist.
- Invoice detail endpoints. Not in the request allowlist.

Other API responses can include SIM PIN/PUK and customer information. Decode and export only needed fields. Do not save raw responses as fixtures.

## Domain vocabulary

- Customer: account owner; owns points and may have several subscriptions.
- Subscription: selected mobile service/SIM; prepaid or postpaid.
- Bundle: allowance with its own validity and applicability. Different bundles are not automatically additive.
- Data amount: API bytes. Label binary conversion as GiB; GB uses decimal conversion.
- Unlimited: bundle total `-1`; show usage without a fabricated percentage.
- Expiry: bundle `valid_until`, not necessarily an invoice date or a guaranteed future renewal.
- Regionality: provider classification of domestic/roaming context, not a precise location.
- Forecast: locally calculated estimate, separate from reported balance.
- Freshness: last successful fetch time; failures do not turn unknown amounts into zero.

## Proof and credentials

Follow the 1Password skill for targeted reads through a persistent tmux session. No credential enumeration, secret output, or service-account token in hosted CI. Exact account/item references belong in private local setup.

The repeatable [local auth/balance gate](docs/live-proof.md) completed password login, token refresh, subscription discovery, and balance retrieval on 6 September 2026. It still observes the scope mismatch. Subsequent API features extend the named checks. Fixture tests alone do not close issues requiring real API behavior.

## References

- [Official API documentation](https://docs.uwa.mobilevikings.be/).
- [OAuth security guidance](https://www.rfc-editor.org/rfc/rfc9700.html#section-2.4).
- [Build issues](https://github.com/BramVR/VikingBar/issues).
- [Architecture decision](docs/architecture.md).

## Provider account identity

A provider identifies an integration; an account slot is a stable local connection address. An account slot is neither a username nor a SIM. Reconnect replaces its connection incarnation while preserving the slot. A service key includes account, provider service ID, and mobile/home kind. Points belong to the customer/account; invoices keep their reported grouped, customer, or subscription scope. The selected account is a shared app/CLI default. Explicit CLI account selectors do not change it. The original Mobile Vikings slot aliases the old credential, lease, and cache addresses without credential discovery or data migration. Production registers Mobile Vikings and Telenet home internet. Synthetic home-provider fixtures remain isolated from both live providers.

## Telenet home domain

The production Telenet adapter is separate from Mobile Vikings OAuth. Its home reading belongs to an account, connection, and home service. The v2 usage endpoint reports a policy counter and allocation. The daily-usage endpoint supplies peak/off-peak traffic; their sum is downloaded traffic. These quantities are not interchangeable. Preserve `CAP`, `FUP`, `TURBO`, and `UNLIMITED`, with non-CAP allocation separate from a finite quota. An allocation on `UNLIMITED` alone does not establish a speed threshold. Speed changes require reported evidence; otherwise the state is unknown. Billing civil dates are not mobile bundle expiry. Provider update time and successful local fetch time are separate. See [home setup and proof](docs/telenet-home.md).
