#!/usr/bin/env python3
"""Bootstrap one account through one task-owned tmux session."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


class ConnectFailure(Exception):
    """Fixed public diagnostic."""


def child_environment(environment):
    return {key: environment[key] for key in ("PATH", "TMPDIR", "LANG", "LC_ALL") if key in environment}


def reference_at(path):
    try:
        value = json.loads(Path(path).read_text())
        if (value["vault"] != "Codex Automation" or not isinstance(value["item_id"], str)
                or not value["item_id"].isalnum()
                or value["fields"] != ["client_id", "username", "password"]):
            raise ValueError()
        return value
    except (OSError, ValueError, KeyError, TypeError):
        raise ConnectFailure("invalid-credential-reference") from None


def credentials_from(data):
    try:
        fields = json.loads(data)["fields"]
        credentials = {}
        for label in ("client_id", "username", "password"):
            values = [field["value"] for field in fields if field.get("label") == label]
            if len(values) != 1 or not isinstance(values[0], str) or not values[0]:
                raise ValueError()
            credentials[label] = values[0]
        return credentials
    except (ValueError, KeyError, TypeError, AttributeError):
        raise ConnectFailure("invalid-credential-fields") from None


def validate_receipt(receipt):
    if receipt != {"schema_version": 1, "check": "connect", "passed": True, "connected": True}:
        raise ConnectFailure("invalid-connect-receipt")
    if (type(receipt["schema_version"]) is not int
            or receipt["passed"] is not True or receipt["connected"] is not True):
        raise ConnectFailure("invalid-connect-receipt")
    return receipt


def write_receipt(path, receipt):
    target = Path(path)
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(receipt, stream, sort_keys=True)


def inside(cli, reference, environment, execute=subprocess.run):
    if not environment.get("TMUX") or not environment.get("BRAM_OP_SERVICE_ACCOUNT_TOKEN"):
        raise ConnectFailure("credential-context-required")
    selector = reference_at(reference)
    op = shutil.which("op", path=environment.get("PATH"))
    if not op or not Path(cli).is_file():
        raise ConnectFailure("dependency-required")
    op_environment = child_environment(environment)
    op_environment["OP_SERVICE_ACCOUNT_TOKEN"] = environment["BRAM_OP_SERVICE_ACCOUNT_TOKEN"]
    item = execute([op, "item", "get", selector["item_id"], "--vault", selector["vault"], "--format", "json"],
                   env=op_environment, capture_output=True, timeout=60, check=False)
    del op_environment
    if item.returncode:
        raise ConnectFailure("credential-read-failed")
    credentials = credentials_from(item.stdout)
    del item
    payload = json.dumps(credentials).encode()
    del credentials
    result = execute([str(cli), "connect"], input=payload, env=child_environment(environment),
                     capture_output=True, timeout=90, check=False)
    del payload
    if result.returncode:
        raise ConnectFailure("connect-failed")
    try:
        return validate_receipt(json.loads(result.stdout))
    except (ValueError, TypeError):
        raise ConnectFailure("invalid-connect-receipt") from None


def supervise(cli, reference, environment, execute=subprocess.run, sleep=time.sleep, clock=time.monotonic):
    reference_at(reference)
    tmux = shutil.which("tmux", path=environment.get("PATH"))
    if not tmux or not Path(cli).is_file():
        raise ConnectFailure("dependency-required")
    session = "vikingbar-connect-" + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="vikingbar-connect-") as directory:
        result_path = Path(directory) / "result.json"
        script = Path(__file__).resolve()
        child = [sys.executable, "-I", str(script), "--inside-tmux", "--cli", str(Path(cli).resolve()),
                 "--reference", str(Path(reference).resolve()), "--result", str(result_path)]
        command = 'set +x; source "$HOME/.profile" >/dev/null 2>&1; set +x; exec ' + shlex.join(child)
        clean = child_environment(environment)
        # A private tmux server cannot inherit an existing server's credential environment.
        prefix = [tmux, "-L", session, "-f", "/dev/null"]
        created = False
        try:
            created = True
            result = execute([*prefix, "new-session", "-d", "-s", session,
                              "/bin/zsh", "-f", "-c", command], env=clean, capture_output=True,
                             timeout=10, check=False)
            if result.returncode:
                raise ConnectFailure("tmux-start-failed")
            deadline = clock() + 160
            while clock() < deadline:
                if result_path.exists():
                    try:
                        return validate_receipt(json.loads(result_path.read_text()))
                    except ValueError:
                        sleep(0.2)
                        continue
                    except (TypeError, ConnectFailure):
                        raise ConnectFailure("connect-failed") from None
                sleep(0.2)
            raise ConnectFailure("connect-timeout")
        finally:
            if created:
                execute([*prefix, "kill-session", "-t", "=" + session], env=clean,
                        capture_output=True, timeout=10, check=False)


def main(arguments=None, environment=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True)
    parser.add_argument("--reference", required=True)
    parser.add_argument("--result")
    parser.add_argument("--inside-tmux", action="store_true")
    args = parser.parse_args(arguments)
    environment = os.environ if environment is None else environment
    previous_handlers = {}
    def interrupted(_signal, _frame):
        raise ConnectFailure("connect-cancelled")
    if not args.inside_tmux:
        for signum in (signal.SIGTERM, signal.SIGINT):
            previous_handlers[signum] = signal.signal(signum, interrupted)
    try:
        operation = inside if args.inside_tmux else supervise
        receipt = operation(args.cli, args.reference, environment)
    except ConnectFailure as error:
        receipt = {"passed": False, "error": str(error)}
    except Exception:
        receipt = {"passed": False, "error": "connect-helper-failed"}
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
    if args.result:
        try:
            write_receipt(args.result, receipt)
        except OSError:
            receipt = {"passed": False, "error": "receipt-write-failed"}
    print(json.dumps(receipt, sort_keys=True))
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
