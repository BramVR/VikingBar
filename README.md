# VikingBar

Native macOS menu bar app for Mobile Vikings usage, allowances, Viking Points, and bills. Inspired by [CodexBar](https://github.com/steipete/CodexBar).

## Status

Planning and repository setup. No runnable app, Swift package, build scripts, or CI workflows yet. Account login, token refresh, and balance retrieval were verified in a separate local probe on 6 September 2026; the reusable proof runner is still to be built.

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

Planned stack: Swift 6.2, SwiftPM, SwiftUI/AppKit, a shared core, and a small CLI. Initial target: macOS 14+, Apple Silicon. Build and verification commands will be documented when implemented.

Start with [VISION.md](VISION.md), [CONTEXT.md](CONTEXT.md), [AGENTS.md](AGENTS.md), and the [docs index](docs/README.md).

## Credentials

1Password holds the login credentials. The public OAuth client needs no client secret. The planned app stores refresh tokens in macOS Keychain. Never commit passwords, tokens, account responses, or private proof artifacts. See [authentication findings](CONTEXT.md#authentication).

## Attribution

CodexBar is the reference for app structure and contributor guidance. Preserve its MIT notices when copying code. VikingBar's own code license has not yet been selected.
