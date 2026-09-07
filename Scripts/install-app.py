#!/usr/bin/env python3
"""Build and install a local ad-hoc sealed VikingBar, retaining explicit updates."""
import argparse
import ctypes
import datetime
import errno
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
PROC_PIDPATHINFO_MAXSIZE = 4096
PROC_PIDT_SHORTBSDINFO = 13
PROC_FLAG_SYSTEM = 1
SZOMB = 5


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


class ProcessInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in ("pid", "ppid", "pgid", "status")] + [
        ("comm", ctypes.c_char * 16),
    ] + [(name, ctypes.c_uint32) for name in ("flags", "uid", "gid", "ruid", "rgid", "svuid", "svgid", "reserved")]


def process_executable(pid, library):
    # libproc.h uses a uint32_t buffer size; PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN.
    buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    ctypes.set_errno(0)
    length = library.proc_pidpath(pid, buffer, ctypes.sizeof(buffer))
    if length > 0:
        raw = buffer.value
        if length >= len(buffer) or not raw.startswith(b"/") or len(raw) > length:
            raise InstallFailure("process-inspection-failed")
        return Path(os.fsdecode(raw))
    if ctypes.get_errno() == errno.ESRCH:
        return None
    info = ProcessInfo()
    ctypes.set_errno(0)
    size = library.proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, ctypes.byref(info), ctypes.sizeof(info))
    if size == 0 and ctypes.get_errno() == errno.ESRCH:
        return None
    if size == ctypes.sizeof(info) and info.pid == pid and (info.status == SZOMB or info.flags & PROC_FLAG_SYSTEM):
        return None
    raise InstallFailure("process-inspection-failed")


def process_paths():
    try:
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        library.proc_pidpath.restype = ctypes.c_int
        library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        library.proc_pidinfo.restype = ctypes.c_int
        result = subprocess.run(["ps", "-axo", "pid="], capture_output=True, text=True, timeout=10, check=False)
        rows = result.stdout.split()
        if result.returncode or not rows or any(not row.isascii() or not row.isdecimal() for row in rows):
            raise InstallFailure("process-inspection-failed")
        for pid in sorted(set(map(int, rows))):
            if pid > 0:
                path = process_executable(pid, library)
                if path is not None:
                    yield path
    except (OSError, AttributeError, subprocess.SubprocessError):
        raise InstallFailure("process-inspection-failed") from None


def refuse_running(target):
    try:
        for part in (target, *target.parents):
            if part.is_symlink():
                raise InstallFailure("symlink-target-refused")
        try:
            target.stat()
        except FileNotFoundError:
            # Fresh publication must use an exclusive rename; no existing bundle is replaced.
            return
        resolved = target.resolve()
        for executable in process_paths():
            path = executable.resolve()
            if resolved == path or resolved in path.parents:
                raise InstallFailure("running-target-refused-quit-it-first")
    except InstallFailure as error:
        if str(error) == "process-inspection-failed":
            raise InstallFailure("existing-target-process-origin-unresolved") from None
        raise
    except OSError:
        raise InstallFailure("existing-target-process-origin-unresolved") from None


def rename_exclusive(source, destination):
    library = ctypes.CDLL(None, use_errno=True)
    rename = library.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004):  # RENAME_EXCL
        failure = ctypes.get_errno()
        if failure == errno.EEXIST:
            raise InstallFailure("target-created-during-build")
        raise OSError(failure, os.strerror(failure))


def receipt_path(target):
    return target.parent / ("." + target.name + ".install.json")


def receipt_identity(path):
    metadata = path.lstat()
    if path.is_symlink() or not path.is_file():
        raise InstallFailure("symlink-or-invalid-receipt-refused")
    return (metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns, digest(path))


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
        original = target.stat() if target.exists() else None
        if target.exists():
            if not replace:
                raise InstallFailure("existing-target-requires-explicit-replace")
            bundle_metadata(target)
        previous_receipt = receipt_path(target)
        original_receipt = None
        if previous_receipt.exists() or previous_receipt.is_symlink():
            if previous_receipt.is_symlink() or not target.exists():
                raise InstallFailure("existing-install-receipt-refused")
            original_receipt = receipt_identity(previous_receipt)
            validate_install(target, verify)
            if receipt_identity(previous_receipt) != original_receipt:
                raise InstallFailure("install-receipt-changed-during-validation")
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
        if target.exists() and original is None:
            raise InstallFailure("target-created-during-build")
        if original is not None:
            current = target.stat()
            if (current.st_dev, current.st_ino) != (original.st_dev, original.st_ino):
                raise InstallFailure("target-changed-during-build")
        installed = False
        if (previous_receipt.exists() or previous_receipt.is_symlink()) and not target.exists():
            raise InstallFailure("install-receipt-created-during-build")
        try:
            if original is not None:
                bundle_metadata(target)
                target.rename(backup)
                record["backup"] = str(backup)
                if original_receipt is not None:
                    if receipt_identity(previous_receipt) != original_receipt:
                        raise InstallFailure("install-receipt-changed-during-build")
                    rename_exclusive(previous_receipt, stage / "previous-install.json")
                    if receipt_identity(stage / "previous-install.json") != original_receipt:
                        raise InstallFailure("install-receipt-changed-during-backup")
            rename_exclusive(candidate, target)
            installed = True
            if artifact(target, verify) != record["artifact"]:
                raise InstallFailure("installed-artifact-changed")
            record["passed"] = True
            private_write(stage / "result.json", record)
            private_write(stage / "install.json", record)
            # Publish last: failures before this point never own the public receipt path.
            rename_exclusive(stage / "install.json", previous_receipt)
            return record
        except BaseException:
            if installed:
                check_running(target)
                target.rename(stage / "failed.app")
            if backup.exists():
                rename_exclusive(backup, target)
            if (stage / "previous-install.json").exists() or (stage / "previous-install.json").is_symlink():
                if not previous_receipt.exists() and not previous_receipt.is_symlink():
                    rename_exclusive(stage / "previous-install.json", previous_receipt)
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
