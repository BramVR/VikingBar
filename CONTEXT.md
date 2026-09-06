# Project context

## Current state

The Swift package contains a fixture menu app, shared allowance models, and a JSON CLI. Live API integration remains pending. The HTML exploration predates the confirmed public-client setup; this document records the newer findings.

## Authentication

Mobile Vikings support confirmed a public OAuth application with no client secret, using the resource owner password grant. They stated the client has read-only scope. Login and token refresh succeeded in a local probe on 6 September 2026.

- API base: `https://uwa.mobilevikings.be/mv`.
- Token endpoint: `POST /oauth2/token/`, form-encoded password or refresh grant.
- Public client ID and login fields are held in the configured 1Password item. The client ID is not a secret; keep account-specific setup out of source defaults.
- Initial connection retrieves the approved username/password through 1Password. Discard the password after the exchange; do not repeatedly read it during background refresh.
- Planned refresh-token persistence: macOS Keychain, with rotation handled atomically. The probe did not persist its tokens.
- The observed access-token lifetime was 599 seconds. Always honor `expires_in`.
- MFA behavior remains unverified. Never disable MFA to make the integration work.

### Scope discrepancy

Both initial and refreshed token responses reported `read write`, even when the initial request included `scope=read`. This conflicts with support's statement. Effective write permissions were not tested. Do not claim server-enforced read-only access until clarified.

The client must enforce its own request allowlist: required authentication POSTs and approved data GETs. No test writes to discover permissions.

The password grant is a legacy flow: the app briefly handles the account password. Browser authorization with PKCE is not currently offered according to support. This is an accepted constraint for the personal integration, not a modern OAuth recommendation.

## Data verified

`GET /subscriptions` and `GET /subscriptions/{id}/balance` succeeded using a refreshed token. Balance data included a finite data bundle with total, used, remaining, validity dates, and out-of-bundle cost. Personal values and identifiers are intentionally omitted.

## Data documented, not yet verified

- `/subscriptions/{id}/usage-summary`: summaries by time range, traffic type, regionality, and in/out-of-bundle usage.
- `/subscriptions/{id}/usage`: detailed records. Prefer summaries when sufficient; details can contain phone numbers.
- `/loyalty-points/balance` and `/loyalty-points/transactions`: available/pending/blocked points and transaction states.
- `/invoices`, invoice details, and PDF endpoints: payment state, amount due, discounts, and grouped bills.

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

The ad-hoc probe is evidence of feasibility, not a completed automatic gate. Issue #2 establishes repeatable live proof; subsequent API features extend it. Fixture tests alone do not close issues requiring real API behavior.

## References

- [Official API documentation](https://docs.uwa.mobilevikings.be/).
- [OAuth security guidance](https://www.rfc-editor.org/rfc/rfc9700.html#section-2.4).
- [Build issues](https://github.com/BramVR/VikingBar/issues).
- [Architecture decision](docs/architecture.md).
