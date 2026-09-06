---
summary: "ADR 001: native menu app and CLI sharing a Swift core."
read_when:
  - Creating the Swift package or app shell
  - Adding API access, snapshots, or presentation logic
  - Changing credential storage or verification boundaries
---

# ADR 001: Native menu app with a shared Swift core

Status: implemented for fixture allowance display. API, auth, and persistence remain pending.

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

The core owns immutable allowance snapshots and their menu presentation. The CLI serializes both, while the app renders the same presentation. Formatting amounts independently in each executable would let labels and unlimited semantics drift. Fixture provenance remains visible in the status title and card; no-argument launch has no synthetic balance.
