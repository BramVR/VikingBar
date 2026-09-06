# Repository Guidelines

Adapted from [steipete/CodexBar](https://github.com/steipete/CodexBar/blob/98b86f39db63d230e2a7f78cdb013a845af33213/AGENTS.md). Preserve applicable upstream wording; change project-specific instructions only where needed.

## Project Structure & Modules
- SwiftPM builds the app, shared core, CLI, and tests. Live API integration and release automation remain separate tickets.
- `Sources/VikingBar`: Swift 6 menu bar app (usage/allowance display, icon renderer, settings). Keep changes small and reuse existing helpers.
- `Sources/VikingBarCore`: shared API/auth, snapshots, bundle mapping, and injectable host services.
- `Sources/VikingBarCLI`: CLI diagnostics and fixture/live proof using the shared core.
- `Tests/VikingBarTests`: XCTest coverage for usage parsing, account state, icon patterns; mirror new logic with focused tests.
- `Scripts`: local checks, fixture proof, packaging, pinned CI tools, and draft-release helpers. See `docs/development.md` and `docs/RELEASING.md`. No signing setup exists.
- `docs`: architecture, release notes, and process. Build/release instructions arrive with their implementation. Root-level zips/appcast are generated artifacts—avoid editing except during releases.

## Build, Test, Run
- Use `swift build` (debug) or `swift build -c release`; `swift test` for the full suite.
- Local gates: `make check`, `swift test`, `make smoke-package`, and `make workflow-check`. `make smoke-app-fixture` supplies separate native UI proof. See `docs/development.md`. Live API proof remains separate.
- Dev loop and packaging scripts must build a fresh `VikingBar.app`, launch it, and confirm it stays running. Stop only verified task-owned instances; never use broad `pkill` commands as incidental cleanup.
- `Scripts/ci-build.sh` runs shared CI gates. `docs/RELEASING.md` covers manually dispatched draft releases from exact tags. Signing/notarization and automatic updates are separate follow-up work.

## Coding Style & Naming
- Enforce SwiftFormat/SwiftLint: run `swiftformat Sources Tests` and `swiftlint --strict`. 4-space indent, 120-char lines, explicit `self` is intentional—do not remove.
- Favor small, typed structs/enums; maintain existing `MARK` organization. Use descriptive symbols; match current commit tone.

## Testing Guidelines
- Add/extend XCTest cases under `Tests/VikingBarTests/*Tests.swift` (`FeatureNameTests` with `test_caseDescription` methods).
- Swift Testing: prefer backticked sentence names; no camelCase.
- Once the package exists, always run `swift test` before handoff; add focused `swift test --filter ...` runs for parser/provider fixes when possible. Docs-only changes require documentation checks, not nonexistent build commands.
- After any code change, run `make check` and fix all reported format/lint issues before handoff. Ticket #1/#3 must establish this gate before dependent code work.
- Prefer CLI/focused tests over app-bundle live tests when behavior can be verified without relaunching VikingBar.
- Never run tests/checks or ad-hoc validation that can display macOS Keychain prompts. Live provider probes, `vikingbar` against real accounts, and real SecItem reads require explicit authorization or the configured, authorized live proof workflow; otherwise use parser tests, stubs, and test stores.
- Persistence tests must inject isolated defaults, snapshot URLs, a synthetic home, and a contained recording FileManager. Ordinary settings tests must not discover or migrate real user state.
- macOS CI is brittle around headless AppKit status/menu tests. Prefer covering menu behavior through stable state/model seams instead of constructing live `NSStatusBar`/`NSMenu` flows unless the AppKit wiring itself is the thing under test.
- Required real proof is defined in each issue. Missing, skipped, or fixture-only proof does not complete an issue that requires a live dependency.

## Commit & PR Guidelines
- Commit messages: short imperative clauses (e.g., “Improve usage probe”, “Fix icon dimming”); keep commits scoped. Use Conventional Commits for VikingBar.
- PRs/patches should list summary, commands run, screenshots/GIFs for UI changes, and linked issue/reference when relevant.

## Agent Notes
- Use the provided scripts and package manager (SwiftPM); avoid adding dependencies or tooling without confirmation.
- Menu bar automation: capture the target screen first and verify the VikingBar icon is visibly onscreen. Reject `click-extra` success when coordinates fall outside display bounds; hidden menu extras are not click proof.
- Validate UI/runtime behavior against the freshly built bundle to avoid running stale binaries. Record the bundle path and verify the running instance.
- For CLI-testable provider/parser/settings behavior, use CLI/focused tests instead of packaging and relaunch scripts.
- Run a compile-and-run helper only when UI/runtime behavior needs bundle-level validation; it must build, package, relaunch, and verify the app stays running. Use only configured hosts for UI proof; no Parallels/macOS VM is assumed available.
- Release script: keep it in the foreground; do not background it—wait until it finishes.
- No Sparkle, Developer ID, or notarization keys are configured. Never reuse CodexBar's release keys or signing settings.
- Swift concurrency: treat sibling `async let` tasks as a review red flag when one child is required and another is optional/best-effort. Prefer sequential awaits or a drained `withThrowingTaskGroup` that surfaces required failures and explicitly contains optional failures; crash stacks mentioning `swift_task_dealloc` or `asyncLet_finish_after_task_completion` should trigger an audit of nearby `async let` usage.
- Prefer modern SwiftUI/Observation macros: use `@Observable` models with `@State` ownership and `@Bindable` in views; avoid `ObservableObject`, `@ObservedObject`, and `@StateObject`.
- Favor modern macOS APIs over legacy/deprecated counterparts when refactoring; preserve the declared macOS 14 minimum with availability checks or document an approved minimum-version change.
- Keep subscription data siloed: never display one SIM's allowance or identity as another's. Points are customer-level; grouped invoices must remain labeled as grouped.
- Read `CONTEXT.md` before API/auth work. The client is public, with no secret. Token responses report `read write` despite the read-only scope promised by support; enforce an explicit request allowlist and never probe write permissions by changing the account.
- Follow the 1Password skill for targeted credential access inside one persistent tmux session. Keep secrets, personal responses, and proof artifacts out of source, logs, and hosted CI. Store only needed fields; no SIM PIN/PUK exports.
- Preserve MIT attribution for copied CodexBar code. Browser-cookie fallback and AI-provider-specific integrations are outside the initial scope.

## Local skills

- For packaged fixture app or CLI verification, read `.agents/skills/verify-vikingbar/SKILL.md`.
