---
summary: "ADR 001: native menu app and CLI sharing a Swift core."
read_when:
  - Creating the Swift package or app shell
  - Adding API access, snapshots, or presentation logic
  - Changing credential storage or verification boundaries
---

# ADR 001: Native menu app with a shared Swift core

Status: native live sessions, account persistence, fixture display, and menu bar preferences are implemented. See [recorded native proof and limits](live-proof.md#recorded-coverage). The CLI also retains the separate local auth/balance proof.

## Decision

Follow CodexBar's SwiftPM structure, with three responsibilities:

- `VikingBarCore`: typed API responses, HTTP/auth services, credential-store interfaces, bundle mapping, history calculations, and immutable snapshots.
- `VikingBar`: SwiftUI/AppKit menu app, settings, rendering, and macOS lifecycle. It consumes the same snapshots as the CLI.
- `VikingBarCLI`: small diagnostic and proof interface with stable JSON output and explicit fixture mode.

Use Swift 6.2 and target macOS 14+ initially. Begin with Apple Silicon. Availability-guard newer APIs and verify the declared minimum; do not claim support for untested architectures.

Keep HTTP, credential storage, time, and persistence injectable. A serial auth owner coordinates refresh and token rotation. Optional points, history, or invoice failures must not discard a successful data balance.

Use 1Password to bootstrap authentication and Keychain for refresh tokens. Never embed the 1Password service-account token in the app. Fixture mode must never read real credentials or masquerade as live data.

## Why

CodexBar already demonstrates the desired menu-bar workflow. Sharing the core gives the UI and CLI identical allowance semantics and makes most behavior testable without launching AppKit. A single telecom provider does not need CodexBar's multi-provider macro registry, browser-cookie imports, or AI-specific data models.

## Verification and delivery

Local gates prove parsing, state, and calculations using synthetic data. Automatic app smoke tests prove the packaged UI. The configured local live runner proves real API behavior with redacted output. Missing required live proof cannot pass through a skip.

Hosted GitHub Actions runs checks and delivers development artifacts using the same scripts as local builds. Manual release dispatch stages a draft from a selected tag with checksums and changelog. Signing, notarization, and automatic updates need separate setup.

## Reuse provenance

Contributor guidance starts from [CodexBar AGENTS.md](https://github.com/steipete/CodexBar/blob/98b86f39db63d230e2a7f78cdb013a845af33213/AGENTS.md), inspected on 6 September 2026. Preserve applicable wording; adapt project names, unavailable tools, runtime safety, and telecom-specific boundaries. Do not copy another project's signing configuration or secrets. Preserve upstream MIT notices with any copied code.

## Fixture presentation

The app owns an AppKit status item and hosts its card in a SwiftUI popover. This gives native accessibility tooling an explicit status button to inspect and press. A SwiftUI MenuBarExtra would reduce lifecycle code, but leaves more status-item behavior to the framework.

The core owns immutable allowance snapshots and their menu presentation. The CLI serializes both, while the app renders the same presentation. A separate status presentation derives the helmet state and optional decimal GB label from the selected snapshot. The CLI report keeps its existing status-title semantics.

The app draws one fixed native template helmet. Its inset bar drains from right to left as the remaining fraction decreases. Unlimited and unavailable balances use distinct internal marks. A zero total has no fraction, and stale data keeps its known fill. The tooltip and accessibility label expose allowance, subscription, freshness, and fixture provenance. The card retains its visible fixture marker. No-argument launch restores a live session and refreshes it when connected. Without a stored connection, it shows account setup.

The session owns status updates, so changing a fixture or the display preference updates AppKit independently of the mounted SwiftUI view. The Settings destination binds to the default-off **Show remaining GB in menu bar** preference. The app stores that preference in a new settings file with no migration from other applications. Fixture launches use memory unless an explicit isolated settings file is supplied for relaunch proof. Tests inject their persistence inputs and never discover real user state.

## Live session ownership

The existing preference file also stores typed data-card display and refresh interval values. Missing keys use the original remaining display and five-minute cadence. `DataCardPresentation` applies the selected card mode without changing the raw allowance or the helmet's remaining-fraction meaning.

`AppSession` sends the latest interval to the worker between account operations. `VikingSession` uses one interval calculation for restored, published, and selected bundle deadlines. Failure retry deadlines remain authoritative. Startup still refreshes a successful restored connection. Wake uses the existing scheduler and does not interrupt token rotation.

The app's injectable login-item manager owns ServiceManagement calls. Preferences never contain a launch-enabled Boolean. The control displays actual registration status and separate operation errors. Ordinary fixtures use a disabled manager; the installed smoke opts into production registration explicitly and restores its absent baseline.

`AppSession` restores live state, schedules refresh, and publishes presentation changes. `SessionProcessClient` sends JSON-lines commands to the bundled `vikingbar session` process over private pipes. The CLI owns `VikingSession`, the token store, and the account cache. The app never reads the token directly.

`AccountConnector` starts the packaged `connect-account.py` helper. The helper creates one private named tmux session, sources the approved profile there, and reads one approved 1Password item. It passes the three credential fields to the same bundled CLI's `connect` command through stdin. Only the 1Password child receives the service-account token. Passwords are released before balance retrieval.

Each successful connection receives a new connection ID. Cached subscription state belongs to that connection, and each SIM retains its own bundles. The selected active data bundle supplies the helmet and allowance card. Applicability, expiry, and extra charges remain separate display values. Missing amounts stay unavailable.

A process lease serializes token rotation across CLI processes. The owner records a pending rotation before the refresh request and replaces the whole Keychain record afterward. An interrupted rotation requires reconnect. The server exchange and local write cannot be atomic. Relaunch refresh uses the stored token without another 1Password read. Unsigned rebuilds can require renewed Keychain authorization; the release rebuild proof must verify that boundary.

Fixture isolation is fixed at launch. Selecting **Not connected** in a fixture picker does not create a live worker or read Keychain. Fixture settings remain in memory unless `--settings-file` supplies an isolated path. Live startup uses the app's settings file and exposes no fixture picker.

## Customer points

`LiveSessionState.points` belongs to the current connection, outside the selected subscription. `CustomerPoints` stores balance and history independently, each with freshness and a fixed failure code. Amounts use `Decimal`. Transaction states preserve the provider's raw value, including unknown future states.

A separate `VikingSession.refreshPoints()` operation reuses the serialized auth owner and connection checks. The app publishes usage and schedules its next refresh before processing optional points and invoice requests. Optional results update their own fields. Required refresh interrupts optional data reads and retains pending metadata requests, while an active token rotation settles before the worker continues. Reconnection discards the previous customer's points and queued requests. Changing SIMs preserves customer scope.

The two loyalty GETs are explicit allowlist cases. Transaction pagination constructs numbered requests locally, with a maximum of three pages of 20 records. It never follows provider-supplied URLs. The shared `PointsPresentation` formats the app and CLI output. An independent CLI proof decoder compares source API values with production models before native proof compares the visible UI.
