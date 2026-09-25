---
summary: "Read-only Telenet feasibility gate, private setup, and coverage limits."
read_when:
  - Running Telenet account proof
  - Adding Telenet provider support
  - Changing Telenet authentication or usage parsing
---

# Telenet proof

Issue [#40](https://github.com/BramVR/VikingBar/issues/40) adds a proof-local Python gate. The separate [Telenet home integration](telenet-home.md) implements the Swift app and CLI provider. The feasibility gate uses one password lookup, an in-memory cookie session, service discovery, and two reads of every discovered service. It reports only fixed stages and coverage states. A local synthetic pass cannot complete the issue; the authorized real gate must pass.

## Private setup

Use a private reference outside the checkout. The Telenet credential item must already be authorized in the `Codex Automation` vault. The item selector may be its exact ID or title; do not put a password in the reference. The file contains:

```json
{"vault":"Codex Automation","item_id":"APPROVED_TELENET_ITEM","fields":["username","password"]}
```

Set `VIKINGBAR_TELENET_CREDENTIAL_REFERENCE` to that file. Hold the exclusive credential slot. State the exact item and two fields before execution. Run in one named tmux session with tracing disabled and the approved profile loaded:

```sh
set +x
. "$HOME/.profile"
export VIKINGBAR_TELENET_CREDENTIAL_REFERENCE=/absolute/private/telenet-reference.json
make proof-live CHECK=telenet-auth-usage
```

The wrapper performs exactly one targeted `op item get`. Only the `op` child gets `OP_SERVICE_ACCOUNT_TOKEN`; the proof child gets only `PATH`, `TMPDIR`, `LANG`, and `LC_ALL`, with username and password supplied over stdin. No cookies or responses are saved. Do not invoke `op` directly outside the named tmux session, enumerate items, or run this gate in hosted CI. A failed run does not retry the credential read.

## Scope and evidence

The request policy permits the observed Telenet authorization route, the exact secure IDX password sequence, the bounded callback, and GET-only usage discovery. Every URL, method, query, and authentication body is checked before sending. Redirects are handled explicitly; the final website destination is never fetched. Proxies and automatic redirects are disabled. Responses, time, requests, service count, and redirect hops are bounded; 429 stops immediately.

The current v2 schema discovers home products and mobile lines separately. A discovered service must yield a valid usage response on both passes. A home bill cycle supplies the period; mobile usage supplies its next billing date and provider update timestamp. The decoder retains the upstream v2 `CAP`, `FUP`, `TURBO`, or `UNLIMITED` category, reported amount, and GB interpretation; mobile bars retain categories, units, finite/unlimited semantics, amounts, period end, and freshness. The raw-response oracle compares those fields independently of the normalized decoder. Unknown schemas fail instead of inventing zero values. The unofficial upstream integration is a protocol clue, not proof that live behavior still matches it.

A successful receipt has `home` and `mobile` as `verified` or `absent`, at least one verified service, `session_reused`, `renewed_reads`, and `usage_matches` true. An absent home or mobile service leaves that downstream feature's real account coverage blocked. Failure receipts carry only fixed stage and diagnostic codes. MFA or other interactive remediation fails closed. Recreating the HTTP opener with copied in-memory cookies proves session reuse and a second read. It does not prove natural expiry or renewal; both receipt fields remain `unobserved`. Native app display, account setup, background refresh, and service-specific UI remain downstream gates.

Run `make check-proof` for the synthetic gate and `make check` for the full repository gate. The required real command is `make proof-live CHECK=telenet-auth-usage` under the approved credential slot. Record the source revision, command, UTC time, exit status, and redacted receipt privately. Do not capture personal traffic, publish raw provider responses, or treat fixture success as live evidence.

## Observed coverage

The authorized gate passed on 2026-09-23 against the residential product-v2 backend: home usage verified, mobile absent, session reuse and both usage reads verified. The home response reported `UNLIMITED`; its reported usage and allocation remain separate from that allowance category. Mobile parsing has synthetic coverage only, including rejection of another line's identity. Issue #43 still needs an account with mobile lines. Expiry, token renewal, and MFA remain unobserved; unattended long-running refresh and native presentation require downstream proof.
