#!/usr/bin/env python3
"""Build and install a local ad-hoc sealed VikingBar, retaining explicit updates."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
IDENTIFIER = "be.bram.vikingbar"
EXECUTABLES = ("VikingBarApp", "vikingbar")


class InstallFailure(Exception):
    pass


def private_write(path, value):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600), "w") as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def target_path(value):
    path = Path(value)
    if not path.is_absolute() or path.name != "VikingBar.app" or ".." in path.parts:
        raise InstallFailure("absolute-VikingBar.app-target-required")
    for part in (path, *path.parents):
        if part.is_symlink():
            raise InstallFailure("symlink-target-refused")
    return path


def bundle_metadata(bundle):
    try:
        if not bundle.is_dir() or any(path.is_symlink() for path in bundle.rglob("*")):
            raise ValueError()
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != IDENTIFIER or info.get("CFBundleExecutable") != "VikingBarApp":
            raise ValueError()
        return info
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise InstallFailure("unrelated-or-invalid-bundle") from None


def signature(bundle):
    for target in (bundle, bundle / "Contents/MacOS/vikingbar"):
        result = subprocess.run(["codesign", "--verify", "--strict", "--deep", str(target)],
                                capture_output=True, timeout=30, check=False)
        if result.returncode:
            raise InstallFailure("local-signature-verification-failed")
    result = subprocess.run(["codesign", "--display", "--verbose=4", str(bundle)],
                            capture_output=True, timeout=30, check=False)
    if result.returncode or b"Signature=adhoc" not in result.stderr.splitlines():
        raise InstallFailure("local-adhoc-signature-required")
    return {"kind": "local-adhoc", "verified": True, "distributionTrust": False}


def artifact(bundle, verify=signature):
    info = bundle_metadata(bundle)
    try:
        manifest = json.loads((bundle / "Contents/Resources/build-manifest.json").read_text())
        if (manifest.get("schemaVersion") != 1 or not re.fullmatch(r"[0-9a-f]{40}", manifest["commit"])
                or not re.fullmatch(r"\d+\.\d+\.\d+", info["CFBundleVersion"])
                or info["CFBundleVersion"] != manifest["version"].split("-")[0]
                or info["CFBundleShortVersionString"] != manifest["version"].split("-")[0]
                or manifest.get("localAdHocSealed") is not True
                or manifest.get("developerIDSigned") is not False or manifest.get("notarized") is not False):
            raise ValueError()
        hashes = {}
        for name in EXECUTABLES:
            executable = bundle / "Contents/MacOS" / name
            if not executable.is_file() or not os.access(executable, os.X_OK):
                raise ValueError()
            hashes[name] = digest(executable)
        return {"bundleIdentifier": IDENTIFIER, "version": manifest["version"], "commit": manifest["commit"],
                "sourceDirty": manifest["sourceDirty"], "manifestSHA256": digest(bundle / "Contents/Resources/build-manifest.json"),
                "executables": hashes, "signature": verify(bundle)}
    except (OSError, ValueError, KeyError, TypeError):
        raise InstallFailure("invalid-build-manifest") from None


def refuse_running(target):
    result = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True, timeout=10, check=False)
    if result.returncode:
        raise InstallFailure("process-inspection-failed")
    if any(str(target) + "/" in row for row in result.stdout.splitlines()):
        raise InstallFailure("running-target-refused-quit-it-first")


def receipt_path(target):
    return target.parent / ("." + target.name + ".install.json")


def validate_install(target, verify=signature):
    target = target_path(str(target))
    try:
        path = receipt_path(target)
        if path.is_symlink() or path.stat().st_mode & 0o077:
            raise ValueError()
        receipt = json.loads(path.read_text())
        if (type(receipt.get("schema_version")) is not int or receipt.get("schema_version") != 1 or receipt.get("passed") is not True
                or receipt.get("target") != str(target) or receipt.get("ownerUID") != os.getuid()
                or not isinstance(receipt.get("installedAt"), str)
                or receipt.get("artifact") != artifact(target, verify)):
            raise ValueError()
        return receipt
    except (OSError, ValueError, TypeError, KeyError):
        raise InstallFailure("invalid-install-receipt") from None


def build(bundle):
    subprocess.run([sys.executable, str(ROOT / "Scripts/package-artifacts.py"), "--app-only", "--local-adhoc",
                    "--configuration", "release", "--output", str(bundle)], cwd=ROOT, check=True)


def install(value, replace=False, builder=build, verify=signature, check_running=refuse_running, before_publish=None):
    target = target_path(value)
    target.parent.mkdir(parents=True, exist_ok=True)
    lock = target.parent / ("." + target.name + ".install.lock")
    with os.fdopen(os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "r+") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        target_path(value)
        if target.exists():
            if not replace:
                raise InstallFailure("existing-target-requires-explicit-replace")
            bundle_metadata(target)
        previous_receipt = receipt_path(target)
        if previous_receipt.exists() or previous_receipt.is_symlink():
            if previous_receipt.is_symlink() or not target.exists():
                raise InstallFailure("existing-install-receipt-refused")
            validate_install(target, verify)
        check_running(target)
        stage = Path(tempfile.mkdtemp(prefix=".vikingbar-install-", dir=target.parent))
        candidate, backup = stage / "VikingBar.app", stage / "previous.app"
        record = {"schema_version": 1, "passed": False, "ownerUID": os.getuid(), "target": str(target),
                  "installedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(), "backup": None}
        private_write(stage / "intent.json", record)
        builder(candidate)
        record["artifact"] = artifact(candidate, verify)
        if before_publish is not None:
            before_publish(candidate)
        target_path(value)
        check_running(target)
        if target.exists() and not replace:
            raise InstallFailure("target-created-during-build")
        installed = False
        if (previous_receipt.exists() or previous_receipt.is_symlink()) and not target.exists():
            raise InstallFailure("install-receipt-created-during-build")
        try:
            if target.exists():
                bundle_metadata(target)
                target.rename(backup)
                record["backup"] = str(backup)
                if previous_receipt.exists() or previous_receipt.is_symlink():
                    if previous_receipt.is_symlink():
                        raise InstallFailure("symlink-receipt-refused")
                    previous_receipt.rename(stage / "previous-install.json")
            candidate.rename(target)
            installed = True
            if artifact(target, verify) != record["artifact"]:
                raise InstallFailure("installed-artifact-changed")
            record["passed"] = True
            private_write(stage / "result.json", record)
            private_write(previous_receipt, record)
            return record
        except BaseException:
            if installed:
                check_running(target)
                target.rename(stage / "failed.app")
            if backup.exists():
                backup.rename(target)
            if previous_receipt.exists() and installed:
                previous_receipt.rename(stage / "failed-install.json")
            if (stage / "previous-install.json").exists():
                (stage / "previous-install.json").rename(previous_receipt)
            record["passed"] = False
            private_write(stage / "rollback.json", record)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", default=str(Path.home() / "Applications/VikingBar.app"))
    parser.add_argument("--replace", action="store_true")
    args = parser.parse_args()
    try:
        receipt = install(args.target, args.replace)
        print(json.dumps(receipt, sort_keys=True))
        return 0
    except Exception as error:
        print(json.dumps({"passed": False, "error": str(error) if isinstance(error, InstallFailure) else "install-failed"}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
