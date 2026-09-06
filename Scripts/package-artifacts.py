#!/usr/bin/env python3
"""Build development bundles and immutable, checksummed distribution archives."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
NOTICE = "Development build. No Developer ID signing or Apple notarization.\n"


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def metadata(configuration):
    version = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", version):
        raise ValueError("VERSION must contain X.Y.Z or X.Y.Z-prerelease")
    commit = command("git", "rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected full Git commit SHA")
    developer_dir = os.environ.get("DEVELOPER_DIR") or command("xcode-select", "-p")
    if developer_dir.endswith("/CommandLineTools"):
        receipt = plistlib.loads(subprocess.check_output(
            ["pkgutil", "--pkg-info-plist", "com.apple.pkg.CLTools_Executables"]))
        xcode = "Command Line Tools " + receipt["pkg-version"]
    else:
        xcode = command("xcodebuild", "-version")
    return dict(schemaVersion=1, version=version, commit=commit, architecture="arm64",
                sourceDirty=bool(command("git", "status", "--porcelain", "--untracked-files=normal")),
                minimumMacOS="14.0", configuration=configuration, developmentBuild=True,
                developerIDSigned=False, notarized=False,
                toolchain=dict(xcode=xcode, swift=command("swift", "--version")))


def build_bundle(bundle, info):
    configuration = info["configuration"]
    for product in ("VikingBarApp", "vikingbar"):
        subprocess.run(["swift", "build", "-c", configuration, "--arch", "arm64", "--product", product],
                       cwd=ROOT, check=True)
    binary_dir = Path(command("swift", "build", "-c", configuration, "--arch", "arm64", "--show-bin-path"))
    executables = bundle / "Contents/MacOS"
    resources = bundle / "Contents/Resources"
    executables.mkdir(parents=True)
    resources.mkdir()
    for name in ("VikingBarApp", "vikingbar"):
        source = binary_dir / name
        if command("lipo", "-archs", str(source)) != "arm64":
            raise ValueError(f"Expected arm64 executable: {source}")
        shutil.copy2(source, executables / name)
    info["resources"] = [path.name for path in sorted(binary_dir.glob("*.bundle"))]
    for resource in sorted(binary_dir.glob("*.bundle")):
        # SwiftPM resolves resources relative to Bundle.main.bundleURL.
        shutil.copytree(resource, bundle / resource.name)
        shutil.copytree(resource, executables / resource.name)
    write_json(resources / "build-manifest.json", info)
    (resources / "DEVELOPMENT.txt").write_text(NOTICE)
    plist = dict(CFBundleExecutable="VikingBarApp", CFBundleIdentifier="be.bram.vikingbar",
                 CFBundleName="VikingBar", CFBundlePackageType="APPL",
                 CFBundleShortVersionString=info["version"].split("-")[0], CFBundleVersion="1",
                 LSMinimumSystemVersion=info["minimumMacOS"], LSUIElement=True, NSHighResolutionCapable=True)
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))


def archive(source, destination, epoch):
    timestamp = time.gmtime(max(epoch, 315532800))[:6]
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
        for path in sorted(source.rglob("*")):
            if path.is_symlink():
                raise ValueError(f"Symlink unsupported in package: {path}")
            name = path.relative_to(source).as_posix() + ("/" if path.is_dir() else "")
            entry = zipfile.ZipInfo(name, timestamp)
            entry.create_system = 3
            mode = 0o40755 if path.is_dir() else (0o100755 if os.access(path, os.X_OK) else 0o100644)
            entry.external_attr = mode << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            output.writestr(entry, b"" if path.is_dir() else path.read_bytes())


def checksums(output):
    paths = sorted(path for path in output.iterdir() if path.name != "SHA256SUMS")
    if any(not path.is_file() or path.is_symlink() for path in paths):
        raise ValueError("Artifact directory must contain regular files only")
    (output / "SHA256SUMS").write_text("".join(f"{digest(path)}  {path.name}\n" for path in paths))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--app-only", action="store_true")
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    args = parser.parse_args()
    output = (args.output or ROOT / ".build/artifacts").resolve()
    if not args.app_only and output.exists() and any(output.iterdir()):
        if not (output / "manifest.json").is_file():
            parser.error("Unexpected artifact residue; choose a fresh --output directory")
        expected_names = {"manifest.json", "SHA256SUMS"}
        previous = json.loads((output / "manifest.json").read_text())
        for item in previous["files"]:
            if not re.fullmatch(r"(?:VikingBar|vikingbar-cli)-[0-9A-Za-z.-]+-arm64-[0-9a-f]{40}\.zip", item["path"]):
                raise ValueError("Unrecognized prior archive")
            expected_names.add(item["path"])
        if {path.name for path in output.iterdir()} != expected_names:
            raise ValueError("Unexpected artifact residue; choose a fresh --output directory")
        if any(not path.is_file() or path.is_symlink() for path in output.iterdir()):
            raise ValueError("Prior artifacts must be regular files")
    output.parent.mkdir(parents=True, exist_ok=True)
    info = metadata(args.configuration)
    with tempfile.TemporaryDirectory(prefix="vikingbar-package-", dir=output.parent) as temporary:
        stage = Path(temporary)
        app_root = stage / "app"
        bundle = app_root / "VikingBar.app"
        build_bundle(bundle, info)
        if args.app_only:
            if output.exists():
                existing = plistlib.loads((output / "Contents/Info.plist").read_bytes())
                if existing.get("CFBundleIdentifier") != "be.bram.vikingbar":
                    raise ValueError("Refusing to replace an unrelated bundle")
                old = stage / "previous.app"
                output.rename(old)
            bundle.rename(output)
        else:
            artifacts = stage / "artifacts"
            artifacts.mkdir()
            stem = f'{info["version"]}-arm64-{info["commit"]}'
            epoch = int(command("git", "show", "-s", "--format=%ct", "HEAD"))
            archive(app_root, artifacts / f"VikingBar-{stem}.zip", epoch)
            cli_root = stage / "cli"
            cli_root.mkdir()
            shutil.copy2(bundle / "Contents/MacOS/vikingbar", cli_root / "vikingbar")
            for resource in bundle.glob("*.bundle"):
                shutil.copytree(resource, cli_root / resource.name)
            write_json(cli_root / "build-manifest.json", info)
            (cli_root / "DEVELOPMENT.txt").write_text(NOTICE)
            archive(cli_root, artifacts / f"vikingbar-cli-{stem}.zip", epoch)
            info["files"] = [dict(path=p.name, sha256=digest(p), bytes=p.stat().st_size)
                             for p in sorted(artifacts.iterdir())]
            write_json(artifacts / "manifest.json", info)
            checksums(artifacts)
            if output.exists():
                output.rename(stage / "previous-artifacts")
            artifacts.rename(output)
    print(output)


if __name__ == "__main__":
    main()
