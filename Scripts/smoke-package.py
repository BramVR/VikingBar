#!/usr/bin/env python3
"""Inspect downloaded development archives and run only their synthetic CLIs."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import tempfile
import zipfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_checksums(directory):
    expected = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/\\]+)", line)
        assert match, f"Invalid checksum line: {line}"
        checksum, name = match.groups()
        assert name not in expected and name not in (".", "..", "SHA256SUMS")
        expected[name] = checksum
    actual = {path.name for path in directory.iterdir() if path.name != "SHA256SUMS"}
    assert expected and set(expected) == actual, "Checksum coverage differs from delivered files"
    for name, checksum in expected.items():
        path = directory / name
        assert path.is_file() and not path.is_symlink() and digest(path) == checksum, name


def extract(archive, destination):
    with zipfile.ZipFile(archive) as source:
        names = set()
        for entry in source.infolist():
            path = PurePosixPath(entry.filename)
            assert not path.is_absolute() and ".." not in path.parts and "\\" not in entry.filename
            assert entry.filename not in names, "Duplicate archive entry"
            names.add(entry.filename)
            mode = entry.external_attr >> 16
            assert stat.S_ISREG(mode) or stat.S_ISDIR(mode), "Unsupported archive entry"
            target = destination.joinpath(*path.parts)
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.read(entry))
                target.chmod(mode & 0o777)


def verify(directory):
    verify_checksums(directory)
    manifest = json.loads((directory / "manifest.json").read_text())
    assert manifest["schemaVersion"] == 1
    assert isinstance(manifest["sourceDirty"], bool)
    assert re.fullmatch(r"[0-9a-f]{40}", manifest["commit"])
    assert re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", manifest["version"])
    assert manifest["architecture"] == "arm64" and manifest["minimumMacOS"] == "14.0"
    assert manifest["configuration"] == "release"
    assert manifest["developmentBuild"] is True
    assert manifest["developerIDSigned"] is False and manifest["notarized"] is False
    assert manifest["toolchain"]["swift"] and manifest["toolchain"]["xcode"]
    stem = f'{manifest["version"]}-arm64-{manifest["commit"]}'
    archive_names = {f"VikingBar-{stem}.zip", f"vikingbar-cli-{stem}.zip"}
    assert {item["path"] for item in manifest["files"]} == archive_names
    assert len(manifest["files"]) == 2
    assert {p.name for p in directory.iterdir()} == archive_names | {"manifest.json", "SHA256SUMS"}
    for item in manifest["files"]:
        path = directory / item["path"]
        assert digest(path) == item["sha256"] and path.stat().st_size == item["bytes"]
    embedded = {key: value for key, value in manifest.items() if key != "files"}
    spec = importlib.util.spec_from_file_location("smoke_cli", Path(__file__).with_name("smoke-cli.py"))
    smoke_cli = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(smoke_cli)
    with tempfile.TemporaryDirectory(prefix="vikingbar-inspect-") as temporary:
        root = Path(temporary)
        app_root, cli_root = root / "app", root / "cli"
        extract(directory / f"VikingBar-{stem}.zip", app_root)
        extract(directory / f"vikingbar-cli-{stem}.zip", cli_root)
        assert {p.name for p in app_root.iterdir()} == {"VikingBar.app"}
        bundle = app_root / "VikingBar.app/Contents"
        plist = plistlib.loads((bundle / "Info.plist").read_bytes())
        expected = dict(CFBundleExecutable="VikingBarApp", CFBundleIdentifier="be.bram.vikingbar",
                        CFBundleName="VikingBar", CFBundlePackageType="APPL",
                        CFBundleShortVersionString=manifest["version"].split("-")[0],
                        CFBundleVersion="1", LSMinimumSystemVersion="14.0", LSUIElement=True)
        for key, value in expected.items():
            assert plist[key] == value, key
        resources = bundle / "Resources"
        for path in (resources, cli_root):
            assert json.loads((path / "build-manifest.json").read_text()) == embedded
            notice = (path / "DEVELOPMENT.txt").read_text()
            assert "Development build" in notice and "No Developer ID" in notice and "notarization" in notice
        for path in (bundle.parent, bundle / "MacOS", cli_root):
            assert {p.name for p in path.glob("*.bundle")} == set(manifest["resources"])
        for executable in (bundle / "MacOS/VikingBarApp", bundle / "MacOS/vikingbar", cli_root / "vikingbar"):
            assert os.access(executable, os.X_OK), executable
            architecture = subprocess.check_output(["lipo", "-archs", executable], text=True).strip()
            assert architecture == "arm64", architecture
            build = subprocess.check_output(["xcrun", "vtool", "-show-build", executable], text=True)
            assert re.search(r"platform MACOS\s+minos 14\.0(?:\.0)?\s", build), build
        assert digest(bundle / "MacOS/vikingbar") == digest(cli_root / "vikingbar")
        smoke_cli.verify(bundle / "MacOS/vikingbar")
        smoke_cli.verify(cli_root / "vikingbar")
    print(f"Package smoke passed: {directory}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact_directory", nargs="?", type=Path, default=Path(".build/artifacts"))
    verify(parser.parse_args().artifact_directory.resolve())
