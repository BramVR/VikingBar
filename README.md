# VikingBar

Native macOS menu bar app for Mobile Vikings usage, allowances, Viking Points, and bills. Inspired by [CodexBar](https://github.com/steipete/CodexBar).

## Status

The fixture app and CLI show synthetic mobile data balances without account access. Account login and live data integration remain separate build tickets.

The menu bar helmet shows the remaining allowance through its inset bar. Open **Settings** in the data card to enable **Show remaining GB in menu bar**. The saved choice defaults to off. The optional label uses decimal GB even when the card uses GiB.

## Planned behavior

- Data usage meter, remaining allowance, bundle expiry, and extra charges.
- Daily usage chart and an explicitly labeled cycle forecast.
- Viking Points and latest bill details.
- SIM selection, automatic refresh, clear freshness/error states, and launch at login.

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

1Password holds the login credentials. The public OAuth client needs no client secret. The planned app stores refresh tokens in macOS Keychain. Never commit passwords, tokens, account responses, or private proof artifacts. See [authentication findings](CONTEXT.md#authentication).

## Attribution

CodexBar is the reference for app structure and contributor guidance. Preserve its MIT notices when copying code. VikingBar's own code license has not yet been selected.

## Local API proof

See [local proof setup](docs/live-proof.md) for `make check-proof` and the credential-gated `make proof-live CHECK=auth-balance`. Ordinary fixture runs require no account access.
