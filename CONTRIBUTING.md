# Contribute to VikingBar

Use macOS 14 or later on Apple Silicon with Swift 6.2 or later. Read [development commands](docs/development.md) for local setup.

1. Run `Scripts/bootstrap-ci-tools.sh` to install the pinned check tools into this checkout.
2. Run `Scripts/ci-build.sh` for the same checks and development archives as GitHub Actions.
3. Run `swift test` with full Xcode, or `make test` with Command Line Tools.
4. For UI changes, run the [native fixture verification](.agents/skills/verify-vikingbar/SKILL.md) on an authorized desktop.
5. For API changes, supply the issue's required local live proof. Synthetic CI does not replace live API proof.

Keep account responses, credentials, Keychain access, and private screenshots out of hosted CI and commits. Tests and CI use explicit synthetic fixtures. Do not run live probes to debug a hosted check.

Include the relevant changelog entry and proof in your pull request. Maintainers add changelog credit when merging contributor changes. A passing `VikingBar checks` job is required by the maintainer merge gate. See [CI behavior](docs/ci.md) for enforcement status and artifact contents.

Use `make check` for format, lint, compilation, tests, docs, and CLI fixture smoke. Use `make smoke-package` for archive checks. The package gate executes the embedded fixture CLI without opening the app. Native menu verification is a separate local gate.
