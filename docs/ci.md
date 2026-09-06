---
summary: "CI toolchain, required checks, artifacts, and proof boundaries."
read_when:
  - Changing CI or packaging
  - Reviewing a merge or downloading a development build
---

# CI checks and development artifacts

The `VikingBar checks` job runs for pull requests and pushes to `main`. It invokes the repository's `Scripts/ci-build.sh`. A failing format, lint, build, test, documentation, fixture CLI, workflow, or package check fails the job.

The runner is GitHub's Apple Silicon `macos-15` image with Xcode 26.2 selected explicitly. The workflow checks the selected toolchain and architecture. The app retains its macOS 14 deployment minimum. CI does not establish Intel support or graphical behavior on macOS 14.

Pinned downloads install SwiftFormat 0.63.0, SwiftLint 0.65.0, and actionlint 1.7.12. Each download is verified against a checked-in SHA-256 before execution. Tool installation stays under `.build`. Workflow actions use full reviewed commit SHAs. SwiftPM caches separate OS, architecture, toolchain, and package manifest/lockfile inputs. There is no `Package.resolved` until the first SwiftPM dependency exists.

Normal jobs have read-only repository access. Draft release creation uses a separate write-permission job. Checks never receive Mobile Vikings credentials or 1Password tokens, and never run real Keychain reads. The CLI smoke uses explicit fixture arguments. UI proof stays local through `make smoke-app-fixture`; issue-specific API proof stays local too.

## Artifacts

Successful PR and main runs deliver equivalent development app and CLI archives, a manifest, and checksums. Filenames and the manifest identify the version, arm64 architecture, and full source commit SHA. Build logs are separate diagnostic artifacts. Artifact retention is finite and configured in each workflow.

The app contains `VikingBarApp`, the `vikingbar` CLI, build metadata, and a development-build notice. These builds have no Developer ID notarization. Compiler-generated ad hoc signatures do not constitute distribution signing. The package check extracts the archives, validates bundle metadata and resources, checks arm64 executables, and runs the bundled fixture CLI.

## Merge enforcement

Required-check configuration is a post-merge setup step for issue #3. The workflow must exist on `main` and its exact main run must pass before the coordinator enables enforcement. Until that setup is verified, maintainers must inspect the exact PR head and require a successful `VikingBar checks` result. Do not treat a skipped check or local-only run as a pass.

Issue #3 remains open after the initial workflow merge until real main artifacts and a task-owned private draft release have been downloaded and verified. If the repository plan rejects required checks, record GitHub's exact response here and retain the maintainer gate. No enforcement is claimed yet.

## References

- [GitHub macOS 15 arm64 runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md).
- [SwiftFormat 0.63.0](https://github.com/nicklockwood/SwiftFormat/releases/tag/0.63.0).
- [SwiftLint 0.65.0](https://github.com/realm/SwiftLint/releases/tag/0.65.0).
- [actionlint 1.7.12](https://github.com/rhysd/actionlint/releases/tag/v1.7.12).
