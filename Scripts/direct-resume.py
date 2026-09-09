#!/usr/bin/env python3
"""Strict, read-only admission for a previously connected native proof."""
import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tarfile

ARTIFACTS = frozenset({"direct-configuration.json", "initial-process.json", "direct-connect-launch.json",
                       "direct-connect-child.json", "direct-connect-child-ready.json", "direct-connect-process.json",
                       "connect-result.json", "direct-input.json", "cleanup.json"})


class ResumeFailure(Exception):
    pass


def require(condition):
    if not condition:
        raise ResumeFailure("direct-resume-evidence-invalid")


def shape(value, keys):
    require(type(value) is dict and set(value) == set(keys))


def exact(value, expected):
    require(type(value) is type(expected))
    if type(expected) is dict:
        shape(value, expected)
        for key in expected:
            exact(value[key], expected[key])
    elif type(expected) is list:
        require(len(value) == len(expected))
        for item, reference in zip(value, expected):
            exact(item, reference)
    else:
        require(value == expected)


def sha(value):
    return type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def positive(value):
    return type(value) is int and value > 0


def pairs(values):
    result = {}
    for key, value in values:
        require(key not in result)
        result[key] = value
    return result


def canonical(path):
    require(type(path) is str and str(Path(path)) == path and Path(path).is_absolute())
    value = Path(path)
    require(value.resolve(strict=True) == value)
    return value


def outside_root(path, root):
    root = canonical(str(root))
    return not any(os.path.samefile(ancestor, root) for ancestor in (path, *path.parents))


def private_json(path, expected_hash):
    require(sha(expected_hash))
    path = canonical(str(path))
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600
                and info.st_uid == os.getuid() and info.st_nlink == 1)
        require(info.st_size <= 1024 * 1024)
        raw = stream.read(1024 * 1024 + 1)
    require(hashlib.sha256(raw).hexdigest() == expected_hash)
    return json.loads(raw, object_pairs_hook=pairs)


def digests(files):
    full, product = hashlib.sha256(), hashlib.sha256()
    for name, content in sorted(files.items()):
        is_product = name in {"Package.swift", "Package.resolved"} or name.startswith("Sources/")
        if is_product or (name.startswith("Scripts/") and Path(name).suffix in {".py", ".sh", ".swift"}):
            item = name.encode() + b"\0" + content + b"\0"
            full.update(item)
            if is_product:
                product.update(item)
    return full.hexdigest(), product.hexdigest()


def source_binding(root, revision):
    require(type(revision) is str and re.fullmatch(r"[0-9a-f]{40}", revision) is not None)
    archived = subprocess.run(["git", "archive", "--format=tar", revision], cwd=root,
                              env={"PATH": "/usr/bin:/bin"}, capture_output=True, timeout=30, check=False)
    require(archived.returncode == 0)
    with tarfile.open(fileobj=io.BytesIO(archived.stdout)) as archive:
        previous = {entry.name: archive.extractfile(entry).read() for entry in archive if entry.isfile()}
    paths = [root / "Package.swift"]
    if (root / "Package.resolved").is_file():
        paths.append(root / "Package.resolved")
    for directory in ("Sources", "Scripts"):
        paths.extend(path for path in (root / directory).rglob("*")
                     if path.is_file() and (directory == "Sources" or path.suffix in {".py", ".sh", ".swift"}))
    require(all(path.resolve(strict=True) == path for path in paths))
    current = {str(path.relative_to(root)): path.read_bytes() for path in paths}
    old_full, old_product = digests(previous)
    new_full, new_product = digests(current)
    require(old_product == new_product)
    return old_full, new_full, new_product


def current_revision(root):
    result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, env={"PATH": "/usr/bin:/bin"},
                            capture_output=True, timeout=10, check=False)
    require(result.returncode == 0)
    return result.stdout.decode().strip()


def validate(environment, root, now=None):
    try:
        config_path = canonical(environment["VIKINGBAR_DIRECT_RESUME_CONFIG"])
        require(outside_root(config_path, root))
        config = private_json(config_path, environment["VIKINGBAR_DIRECT_RESUME_CONFIG_SHA256"])
        shape(config, {"schema_version", "check", "mode", "source_sha256", "manifest_path", "manifest_sha256",
                       "credential_slot", "mac_ui_slot", "expires_at"})
        require(type(config["schema_version"]) is int and config["schema_version"] == 1)
        require(config["check"] == "direct-connect-ui" and config["mode"] == "stored-session")
        for key, variable in (("credential_slot", "VIKINGBAR_CREDENTIAL_SLOT"),
                              ("mac_ui_slot", "VIKINGBAR_MAC_UI_SLOT")):
            require(type(config[key]) is str and bool(config[key].strip()))
            require(config[key].strip().upper() not in {"INACTIVE", "DISABLED", "PENDING", "NONE"})
            require(config[key] == environment.get(variable))
        require(config["expires_at"] == environment.get("VIKINGBAR_SLOT_BINDINGS_EXPIRES_AT"))
        expires = datetime.datetime.fromisoformat(config["expires_at"].replace("Z", "+00:00"))
        require(0 < (expires - (now or datetime.datetime.now(datetime.timezone.utc))).total_seconds() <= 3600)
        manifest_path = canonical(config["manifest_path"])
        require(outside_root(manifest_path, root) and manifest_path != config_path)
        manifest = private_json(manifest_path, config["manifest_sha256"])
        shape(manifest, {"schema_version", "prior_revision", "prior_directory", "prior_config_path",
                         "prior_config_sha256", "artifacts", "build_policy", "reviewed_debug_build"})
        require(type(manifest["schema_version"]) is int and manifest["schema_version"] == 1)
        require(manifest["build_policy"] == "reviewed-debug-same-product-release")
        shape(manifest["artifacts"], ARTIFACTS)
        directory = canonical(manifest["prior_directory"])
        proof_root = canonical(str(root / ".build/proof"))
        require(directory.is_dir() and stat.S_IMODE(directory.stat().st_mode) == 0o700
                and directory.stat().st_uid == os.getuid() and os.path.samefile(directory.parent, proof_root))
        require(not os.path.lexists(directory / "result.json"))
        old_path = canonical(manifest["prior_config_path"])
        require(outside_root(old_path, root) and old_path not in {config_path, manifest_path})
        prior = private_json(old_path, manifest["prior_config_sha256"])
        shape(prior, {"schema_version", "check", "source_sha256", "credential_reference_sha256",
                      "expires_at", "tmux_session", "credential_slot", "mac_ui_slot"})
        require(type(prior["schema_version"]) is int and prior["schema_version"] == 1)
        require(prior["check"] == "direct-connect-ui" and sha(prior["credential_reference_sha256"]))
        require(all(type(prior[key]) is str and bool(prior[key].strip())
                    for key in ("expires_at", "tmux_session", "credential_slot", "mac_ui_slot")))
        require(datetime.datetime.fromisoformat(prior["expires_at"].replace("Z", "+00:00")).tzinfo is not None)
        old_source, new_source, product = source_binding(root, manifest["prior_revision"])
        reviewed = manifest["reviewed_debug_build"]
        shape(reviewed, {"revision", "product_sha256", "build_manifest_sha256", "app_sha256", "cli_sha256"})
        require(type(reviewed["revision"]) is str and re.fullmatch(r"[0-9a-f]{40}", reviewed["revision"]) is not None)
        require(all(sha(reviewed[key]) for key in reviewed if key != "revision"))
        require(reviewed["product_sha256"] == product and reviewed["revision"] == current_revision(root))
        require(prior["source_sha256"] == old_source and config["source_sha256"] == new_source)
        evidence = {name: private_json(directory / name, manifest["artifacts"][name]) for name in ARTIFACTS}
        validate_evidence(evidence, prior, manifest, directory, root)
        return {"config": config, "manifest": manifest, "evidence": evidence, "directory": directory}
    except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.SubprocessError, tarfile.TarError):
        raise ResumeFailure("direct-resume-evidence-invalid") from None


def identity_matches(identity, pid, parent, command, started=None):
    require(type(identity) is str)
    parts = identity.split(None, 7)
    require(len(parts) == 8 and parts[0] == str(pid) and parts[1] == str(parent) and parts[7] == command)
    if started is not None:
        require(" ".join(parts[2:7]) == started)


def validate_evidence(evidence, prior, manifest, directory, root):
    initial = evidence["initial-process.json"]
    app_keys = {"pid", "parentPID", "arguments", "startedAt", "executableSHA256", "workerOwnershipEstablished",
                "identity", "cli", "cliSHA256"}
    shape(initial, app_keys)
    executable = str(root / ".build/app/VikingBar.app/Contents/MacOS/VikingBarApp")
    cli = str(root / ".build/app/VikingBar.app/Contents/MacOS/vikingbar")
    policy = ('(version 1)(allow default)(deny process-exec)(allow process-exec (literal '
              + json.dumps(executable) + ') (literal ' + json.dumps(cli) + '))')
    require(positive(initial["pid"]) and positive(initial["parentPID"]))
    require(initial["workerOwnershipEstablished"] is True and initial["cli"] == cli)
    require(sha(initial["executableSHA256"]) and sha(initial["cliSHA256"]))
    identity_matches(initial["identity"], initial["pid"], initial["parentPID"],
                     executable + " --proof-directory " + str(directory))
    require(datetime.datetime.fromisoformat(initial["startedAt"]).tzinfo is not None)
    require(initial["arguments"] == ["/usr/bin/sandbox-exec", "-p", policy, executable,
                                      "--proof-directory", str(directory)])
    exact(evidence["direct-configuration.json"], {
        "sourceSHA256": prior["source_sha256"], "configurationSHA256": manifest["prior_config_sha256"],
        "sandboxSHA256": hashlib.sha256(policy.encode()).hexdigest(), "processExecRestricted": True})
    launch = dict(initial, connectOwnershipRequired=True, connectOwnershipEstablished=False)
    exact(evidence["direct-connect-launch.json"], launch)
    child = evidence["direct-connect-child.json"]
    shape(child, {"schema_version", "pid", "parentPID"})
    require(type(child["schema_version"]) is int and child["schema_version"] == 1)
    require(positive(child["pid"]) and type(child["parentPID"]) is int and child["parentPID"] == initial["pid"])
    exact(evidence["direct-connect-child-ready.json"], {"schema_version": 1, "pid": child["pid"]})
    exact(evidence["connect-result.json"], {"schema_version": 1, "check": "connect", "passed": True,
                                               "connected": True})
    exact(evidence["direct-input.json"], {"credentialReads": 1, "privatePipe": True,
        "formCaptureSkipped": True, "appCredentialReference": False, "processExecRestricted": True})
    require(type(evidence["direct-input.json"]["credentialReads"]) is int)
    cleanup = evidence["cleanup.json"]
    shape(cleanup, {"exited", "workers", "apps"})
    launch["connectOwnershipEstablished"] = True
    require(cleanup["exited"] is True)
    exact(cleanup["apps"], [launch])
    require(type(cleanup["workers"]) is list and len(cleanup["workers"]) >= 2)
    identities = set()
    for worker in cleanup["workers"]:
        shape(worker, {"pid", "parentPID", "startTime", "command", "identity", "cliSHA256"})
        require(positive(worker["pid"]) and type(worker["parentPID"]) is int
                and worker["parentPID"] == initial["pid"] and worker["cliSHA256"] == initial["cliSHA256"])
        require(worker["command"] in {cli + " session", cli + " connect"})
        require(type(worker["startTime"]) is str and bool(worker["startTime"]))
        identity_matches(worker["identity"], worker["pid"], worker["parentPID"],
                         worker["command"], worker["startTime"])
        require(worker["pid"] != initial["pid"])
        require(worker["pid"] not in identities)
        identities.add(worker["pid"])
    require(any(worker["command"] == cli + " session" for worker in cleanup["workers"]))
    connect_workers = [worker for worker in cleanup["workers"] if worker["command"] == cli + " connect"]
    require(len(connect_workers) == 1 and connect_workers[0]["pid"] == child["pid"])
    direct = evidence["direct-connect-process.json"]
    exact(direct, connect_workers[0])


def owned_build_bytes(path):
    path = canonical(str(path))
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid())
        return stream.read()


def verify_debug(evidence, executable, cli):
    reviewed = evidence["manifest"]["reviewed_debug_build"]
    require(hashlib.sha256(owned_build_bytes(executable)).hexdigest() == reviewed["app_sha256"])
    require(hashlib.sha256(owned_build_bytes(cli)).hexdigest() == reviewed["cli_sha256"])
    raw = owned_build_bytes(executable.parent.parent / "Resources/build-manifest.json")
    require(hashlib.sha256(raw).hexdigest() == reviewed["build_manifest_sha256"])
    build = json.loads(raw, object_pairs_hook=pairs)
    require(type(build) is dict and type(build.get("schemaVersion")) is int and build["schemaVersion"] == 1)
    require(build.get("commit") == reviewed["revision"] and build.get("configuration") == "debug"
            and build.get("sourceDirty") is False)
