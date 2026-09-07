# VikingBar

Native macOS menu bar app for Mobile Vikings usage, allowances, Viking Points, and bills. Inspired by [CodexBar](https://github.com/steipete/CodexBar).

## Status

The native app opens a live account session by default. Connect through the approved 1Password helper to show a selected SIM's data bundle, expiry, and extra charges. See [account setup](docs/live-account.md). Explicit fixture launches remain isolated from account access.

Native live proof covers API comparisons, refresh, stored-token recovery after relaunch and a release rebuild, and readable bundle selection. See [recorded coverage and limits](docs/live-proof.md#recorded-coverage).

The menu bar helmet shows the remaining allowance through its inset bar. Open **Settings** in the data card to enable **Show remaining GB in menu bar**. The saved choice defaults to off. The optional label uses decimal GB even when the card uses GiB.

Expand **Daily SIM data and estimate** for daily aggregate usage and a labeled cycle estimate. Missing and stale days remain distinct from zero. See [history rules and pending live proof](docs/history.md).

## Planned behavior

- Viking Points and latest bill details.
- Launch at login.

## Build plan

1. [Fixture menu app and shared core](https://github.com/BramVR/VikingBar/issues/1).
2. [Automatic live API proof with 1Password](https://github.com/BramVR/VikingBar/issues/2).
3. [CI checks, build artifacts, and draft releases](https://github.com/BramVR/VikingBar/issues/3).
4. [Live bundle display](https://github.com/BramVR/VikingBar/issues/4).
5. [Daily history and forecast](https://github.com/BramVR/VikingBar/issues/5).
6. [Viking Points](https://github.com/BramVR/VikingBar/issues/6).
7. [Latest bill](https://github.com/BramVR/VikingBar/issues/7).
8. [Local installation and launch at login](https://github.com/BramVR/VikingBar/issues/8).

Issues contain dependencies and required proof. CI follows the first runnable fixture app; live API proof can be established independently.

## Development

Swift 6.2, SwiftPM, SwiftUI/AppKit, a shared core, and a small CLI. Initial target is macOS 14+, Apple Silicon. Run `make check`, `make package-app`, and `make smoke-app-fixture`. See [development commands](docs/development.md).

See [contribution checks](CONTRIBUTING.md) for CI parity and [build downloads and draft releases](docs/RELEASING.md) for development artifacts.

Start with [VISION.md](VISION.md), [CONTEXT.md](CONTEXT.md), [AGENTS.md](AGENTS.md), and the [docs index](docs/README.md).

## Credentials

1Password holds the login credentials. The public OAuth client needs no client secret. The bundled CLI owns refresh tokens in macOS Keychain. The native app communicates with that CLI over private pipes. Never commit passwords, tokens, account responses, or private proof artifacts. See [authentication findings](CONTEXT.md#authentication).

## Attribution

CodexBar is the reference for app structure and contributor guidance. Preserve its MIT notices when copying code. VikingBar's own code license has not yet been selected.

## Local API proof

See [local proof setup](docs/live-proof.md) for `make check-proof` and the credential-gated `make proof-live CHECK=auth-balance`. Ordinary fixture runs require no account access.
