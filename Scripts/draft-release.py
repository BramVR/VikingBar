#!/usr/bin/env python3
"""Validate tagged development builds and append missing draft assets safely."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile


TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")


def validate_tag(tag):
    match = TAG.fullmatch(tag)
    if not match or (match[4] and any(p.isdigit() and len(p) > 1 and p[0] == "0" for p in match[4].split("."))):
        raise ValueError("Expected vMAJOR.MINOR.PATCH with optional SemVer prerelease")
    return tag[1:]


def release_metadata(tag, commit, source):
    version = validate_tag(tag)
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected full commit SHA")
    if (source / "VERSION").read_text().strip() != version:
        raise ValueError("Tag and VERSION disagree")
    sections = re.split(r"^## ", (source / "CHANGELOG.md").read_text(), flags=re.M)[1:]
    matches = [part.split("\n", 1)[1].strip() for part in sections
               if part.split("\n", 1)[0].strip() == version and "\n" in part]
    if len(matches) != 1 or not matches[0]:
        raise ValueError("Expected one nonempty exact version changelog section")
    body = (f"## {version}\n\n{matches[0]}\n\n"
            "Development build. No Developer ID signing or notarization.\n\n"
            f"Source commit: {commit}\n")
    return {"tag": tag, "commit": commit, "version": version, "body": body}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_assets(directory, metadata):
    checksums = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line)
        if not match or match[2] in checksums or match[2] in {"SHA256SUMS", ".", ".."}:
            raise ValueError("Invalid checksum entry")
        checksums[match[2]] = match[1]
    actual = {p.name for p in directory.iterdir()}
    if actual != set(checksums) | {"SHA256SUMS"}:
        raise ValueError("Artifact files and checksum list disagree")
    for name, digest in checksums.items():
        path = directory / name
        if path.is_symlink() or not path.is_file() or sha256(path) != digest:
            raise ValueError(f"Checksum mismatch: {name}")
    manifest = json.loads((directory / "manifest.json").read_text())
    expected = {"schemaVersion": 1, "version": metadata["version"], "commit": metadata["commit"],
                "architecture": "arm64", "minimumMacOS": "14.0", "configuration": "release", "developmentBuild": True,
                "developerIDSigned": False, "notarized": False, "sourceDirty": False}
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise ValueError("Manifest identity or development-build flags disagree")
    stem = f"{metadata['version']}-arm64-{metadata['commit']}"
    archive_names = {f"VikingBar-{stem}.zip", f"vikingbar-cli-{stem}.zip"}
    if set(checksums) != archive_names | {"manifest.json"}:
        raise ValueError("Archive names disagree with release identity")
    files = manifest["files"]
    if len(files) != 2 or {f["path"] for f in files} != set(checksums) - {"manifest.json"}:
        raise ValueError("Expected exactly app and CLI archives")
    for item in files:
        if not item["path"].endswith(".zip") or item["sha256"] != checksums[item["path"]] or item["bytes"] != (directory / item["path"]).stat().st_size:
            raise ValueError("Manifest file entry disagrees")
    return {**checksums, "SHA256SUMS": sha256(directory / "SHA256SUMS")}


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True)


def remote_commit(repo, tag):
    ref = json.loads(gh("api", f"repos/{repo}/git/ref/tags/{tag}"))["object"]
    for _ in range(10):
        if ref["type"] == "commit":
            return ref["sha"]
        if ref["type"] != "tag":
            break
        ref = json.loads(gh("api", f"repos/{repo}/git/tags/{ref['sha']}"))["object"]
    raise ValueError("Tag does not resolve to a commit")


def missing_assets(release, metadata, hashes, download):
    if not release["draft"] or release["tag_name"] != metadata["tag"] or release["target_commitish"] != metadata["commit"] or release["body"].strip() != metadata["body"].strip():
        raise ValueError("Existing release is published or has conflicting identity/notes")
    existing = {}
    for asset in release["assets"]:
        name = asset["name"]
        if name in existing or name not in hashes:
            raise ValueError("Unexpected or duplicate existing release asset")
        digest = asset.get("digest")
        if not digest:
            digest = "sha256:" + download(asset)
        if digest != "sha256:" + hashes[name]:
            raise ValueError(f"Existing asset differs: {name}")
        existing[name] = digest
    return sorted(set(hashes) - set(existing))


def publish(repo, tag, commit, directory, metadata_dir):
    metadata = json.loads((metadata_dir / "release.json").read_text())
    validate_tag(tag)
    if metadata["tag"] != tag or metadata["commit"] != commit or metadata["version"] != tag[1:]:
        raise ValueError("Release metadata identity disagrees")
    hashes = verify_assets(directory, metadata)
    if remote_commit(repo, tag) != commit:
        raise ValueError("Remote tag moved since the build")
    releases = json.loads(gh("api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100"))
    matches = [release for page in releases for release in page if release["tag_name"] == tag]
    if len(matches) > 1:
        raise ValueError("Multiple releases for tag")
    with tempfile.TemporaryDirectory() as temporary:
        def download(asset):
            payload = subprocess.check_output(["gh", "api", "-H", "Accept: application/octet-stream",
                                               f"repos/{repo}/releases/assets/{asset['id']}"])
            return hashlib.sha256(payload).hexdigest()
        pending = missing_assets(matches[0], metadata, hashes, download) if matches else sorted(hashes)
        if remote_commit(repo, tag) != commit:
            raise ValueError("Remote tag moved before release write")
        if not matches:
            notes = Path(temporary) / "notes.txt"
            notes.write_text(metadata["body"])
            gh("release", "create", tag, "--repo", repo, "--draft", "--verify-tag", "--target", commit,
               "--title", tag, "--notes-file", str(notes))
        for name in pending:
            gh("release", "upload", tag, str(directory / name), "--repo", repo)
    print(f"Draft {tag}: verified {len(hashes)} assets; uploaded {len(pending)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "publish"])
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--source", type=Path, default=Path("."))
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--assets", type=Path, default=Path(".build/artifacts"))
    parser.add_argument("--repo")
    args = parser.parse_args()
    if args.command == "prepare":
        metadata = release_metadata(args.tag, args.commit, args.source)
        args.metadata.mkdir(parents=True, exist_ok=True)
        (args.metadata / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
    else:
        if not args.repo or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
            parser.error("publish requires --repo OWNER/REPO")
        publish(args.repo, args.tag, args.commit, args.assets, args.metadata)


if __name__ == "__main__":
    main()
