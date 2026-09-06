# Build artifacts and private drafts

## Sub-features

Development app and standalone CLI archives, version/commit manifests, checksums, hosted PR/main artifacts, and private draft releases from exact tags.

## Prerequisites

Read [Download builds and stage a draft release](../../../../docs/RELEASING.md). Use a trusted, reviewed checkout for inspection and trust the artifact's source commit and build workflow before executing downloaded binaries. Checksums establish integrity against the supplied list, not authenticity. Use the project's macOS arm64 toolchain and authenticated GitHub access for private downloads. No carrier credentials or UI slot are needed.

## Driving it with terminal

For a local development package, run `make smoke-package`. It builds the release binaries, packages `.build/artifacts`, extracts both archives, and runs their fixture CLIs. Local builds may report dirty source; delivered CI/draft proof requires `sourceDirty: false`.

For hosted artifacts, select a successful `VikingBar checks` PR or main run and record its run ID and full built commit SHA. A PR run may build the merge commit; verify its parents against the expected base and PR head. Download with `gh run download RUN_ID --repo BramVR/VikingBar --dir FRESH_DIRECTORY`. Select the directory containing `manifest.json`, not the separate logs artifact.

Before executing binaries, check the manifest commit/version against that exact trusted source. Run `shasum -a 256 -c SHA256SUMS` inside the artifact directory. From the trusted checkout, run `python3 Scripts/smoke-package.py /absolute/path/to/artifact-directory`. Require complete checksum coverage, clean delivered source, arm64 executables, minimum macOS 14 load commands, matching app metadata, executable permissions, and the manifest's resource layout. Require the bundled and standalone fixture CLI smoke to pass all states, units/timezone, and argument errors.

## Private draft coverage

Ordinary maintenance can inspect and download an existing trusted, task-owned private draft. Read `gh release view TAG --repo BramVR/VikingBar --json isDraft,tagName,targetCommitish,body,assets`. Require `isDraft: true`, the exact tag commit, matching VERSION, and notes containing the exact changelog section and full commit SHA. Download into a fresh directory with `gh release download TAG --repo BramVR/VikingBar --dir FRESH_DIRECTORY`, then apply the same manifest, checksum, and extracted CLI checks. Compare downloaded asset sizes and hashes with GitHub's asset metadata.

Creating a tag or dispatching the draft workflow requires explicit release-proof authorization. Follow the canonical release procedure, keep proof versions isolated from main, and never publish the draft. For the issue #3 repeat-dispatch acceptance check, record the draft ID and each asset's ID/digest before dispatching the same tag again. Require either success with identical assets retained or an explicit conflicting-asset refusal with the original release and assets intact. Never overwrite assets to make the proof pass.

## Evidence and limits

Keep run IDs, source SHA, manifest, checksum results, extracted CLI output, draft identity, and before/after asset receipts in private proof outside commits. Evidence survives temporary extraction cleanup. These are development builds without Developer ID signing or notarization. Compiler ad hoc signatures do not establish distribution trust. Package inspection does not prove native graphical behavior or runtime compatibility on every supported macOS version; use the UI feature recipes for native proof.
