---
summary: "Install the unsigned preview, download development builds, and prepare releases from exact tags."
read_when:
  - Downloading CI artifacts
  - Preparing or verifying a draft release
---

# Download builds and stage a draft release

## Install the unsigned preview

Download the [VikingBar 0.1.0 preview](https://github.com/BramVR/VikingBar/releases/tag/v0.1.0) for Apple Silicon Macs running macOS 14 or later. You do not need a GitHub account or paid Apple Developer membership to download or use it. Intel Macs are not supported by this archive.

The preview has no Developer ID signature or Apple notarization. Its ad-hoc bundle seal requires no Apple account and does not identify a trusted developer to macOS.

1. Under **Assets**, download the ZIP whose name starts with `VikingBar-0.1.0-arm64-`. The separate `vikingbar-cli` archive is for terminal use.
2. Extract the ZIP and move **VikingBar.app** into **Applications**.
3. Open **VikingBar.app**. If macOS blocks it because the developer cannot be verified, open **System Settings → Privacy & Security**.
4. If you trust the downloaded app, choose **Open Anyway**, authenticate when prompted, then choose **Open**.
5. Click the helmet in the menu bar and follow [account setup](live-account.md). Mobile Vikings API approval and a compatible public client ID are required before connecting.

macOS saves the approval for that installed copy. A downloaded update or replacement may need approval again. This exception is for the unidentified-developer or unnotarized-app warning; do not override a warning that the app contains malware or is damaged. See [Apple's opening instructions](https://support.apple.com/en-us/102445).

To update, quit VikingBar, download the new preview, and replace the app in Applications. Automatic updates are not configured. A new bundled executable may also need renewed approval for its existing Keychain session.

## Download a development build

Use a trusted, reviewed checkout for inspection, such as an approved `main` revision. `Scripts/smoke-package.py` executes the downloaded CLI binaries. Run it only when you also trust the artifact's source commit and build workflow. Checksums verify integrity against the supplied checksum list. They do not establish authenticity or execution safety.

1. Sign in to GitHub and open a successful `VikingBar checks` run on the repository's **Actions** page. Source and documentation are public, but Actions artifact downloads require a GitHub account.
2. Download the development artifact for the desired full commit SHA.
3. Extract the Actions artifact into a new directory.
4. Run `shasum -a 256 -c SHA256SUMS` inside that directory.
5. Check `manifest.json` for the expected commit and version before executing either binary.
6. From the trusted, reviewed checkout, run `python3 Scripts/smoke-package.py /absolute/path/to/artifact-directory`.

For a terminal download, use `gh run download RUN_ID --repo BramVR/VikingBar --dir DESTINATION`. Choose the directory containing `manifest.json` when inspecting an artifact. Downloaded archives include the app and a standalone CLI. Logs are separate diagnostic artifacts.

These are development builds without Developer ID signing or notarization. Public previews use GitHub Releases. Developer ID signing, notarization, Homebrew distribution, and automatic updates are not configured.

## Prepare a version tag

1. Set `VERSION` to the intended SemVer version, such as `0.1.0-issue3.1` for isolated prerelease proof.
2. Add one nonempty `## VERSION` section to `CHANGELOG.md` with the exact version string. Keep `Unreleased` separate.
3. Run `Scripts/ci-build.sh` and review the result.
4. Commit the version and changelog together.
5. Create and push the corresponding existing tag, such as `v0.1.0-issue3.1`, with authorization for that release task.

The tag must resolve to the commit containing matching version and changelog files. The manifest preserves the full prerelease version. The macOS bundle short version uses its numeric core. Ordinary merges do not automatically bump the version or create tags.

## Stage the draft

The workflow must already exist on the default branch. Dispatch it with the existing tag:

```sh
gh workflow run draft-release.yml --repo BramVR/VikingBar -f tag=v0.1.0-issue3.1
```

The build job resolves the tag to an exact commit, checks out that commit, validates version and changelog agreement, and runs the same local gates as PR checks. A separate job verifies the build artifacts and stages a draft release with the version's changelog and development-build notice.

The workflow never publishes the draft. An existing published release, changed tag identity, or conflicting same-name asset fails the operation. Identical assets remain intact; missing assets may be uploaded. A rebuild that changes archive bytes fails safely instead of replacing earlier assets.

## Verify the draft

1. Require every build and draft job to pass.
2. Read the draft through `gh release view TAG --repo BramVR/VikingBar --json isDraft,tagName,targetCommitish,body,assets`.
3. Confirm `isDraft` is true and the notes contain the exact version's changelog and commit SHA.
4. Download assets into a fresh directory with `gh release download TAG --repo BramVR/VikingBar --dir DESTINATION`.
5. Verify `SHA256SUMS` and compare the manifest commit with `git rev-parse 'refs/tags/TAG^{commit}'` in the fetched source checkout.
6. Apply the source and workflow trust checks above, then run `Scripts/smoke-package.py` from a trusted, reviewed checkout.
7. Repeat the dispatch to test asset collision handling. Preserve the first artifact set if the rebuild differs.

Keep task-owned proof releases as private drafts. Record their tag, commit, workflow run, artifact checksums, and draft identity in private proof. Never place account data or desktop captures in release assets.

## Publish an unsigned preview

After release authorization, use the version tag and draft workflow above. Verify the downloaded draft assets before publication. Add the installation and account-setup links to the release notes, retain the complete version changelog and source commit, and state the supported Mac architecture and unsigned status. Mark the release as a prerelease, then publish it. An unsigned preview does not require an Apple Developer Program membership.

Point website downloads at the published release page. After verification, start the next patch's `Unreleased` changelog section and commit the closeout.
