#!/usr/bin/env python3
"""Bootstrap one account through one task-owned tmux session."""
import argparse
import datetime
import hashlib
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


CLI_FAILURE_CODES = frozenset({
    "credential-input", "local-filesystem", "session-busy", "token-network", "token-rejected",
    "token-response", "token-rate-limited", "token-server", "keychain-write", "connect-cancelled", "connect-failed",
})
FAILURE_CODES = CLI_FAILURE_CODES | {
    "invalid-credential-reference", "credential-context-required", "dependency-required",
    "credential-read-failed", "credential-read-timeout", "invalid-credential-fields",
    "connect-command-timeout", "invalid-connect-receipt", "tmux-start-failed", "tmux-start-timeout",
    "tmux-ownership-invalid", "tmux-cleanup-failed", "connect-timeout", "connect-helper-failed", "receipt-write-failed",
}


def failure_code(value, allowed=FAILURE_CODES):
    if (isinstance(value, dict) and set(value) == {"passed", "error"} and value["passed"] is False
            and isinstance(value["error"], str) and value["error"] in allowed):
        return value["error"]
    return None


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
    try:
        item = execute([op, "item", "get", selector["item_id"], "--vault", selector["vault"], "--format", "json"],
                       env=op_environment, capture_output=True, timeout=60, check=False)
    except subprocess.TimeoutExpired:
        raise ConnectFailure("credential-read-timeout") from None
    except OSError:
        raise ConnectFailure("credential-read-failed") from None
    del op_environment
    if item.returncode:
        raise ConnectFailure("credential-read-failed")
    credentials = credentials_from(item.stdout)
    del item
    payload = json.dumps(credentials).encode()
    del credentials
    try:
        result = execute([str(cli), "connect"], input=payload, env=child_environment(environment),
                         capture_output=True, timeout=90, check=False)
    except subprocess.TimeoutExpired:
        raise ConnectFailure("connect-command-timeout") from None
    except OSError:
        raise ConnectFailure("connect-failed") from None
    del payload
    try:
        value = json.loads(result.stdout) if len(result.stdout) <= 4096 else None
    except (ValueError, TypeError):
        raise ConnectFailure("invalid-connect-receipt") from None
    if result.returncode:
        raise ConnectFailure(failure_code(value, CLI_FAILURE_CODES) or "connect-failed")
    return validate_receipt(value)


def supervise(cli, reference, environment, execute=subprocess.run, sleep=time.sleep, clock=time.monotonic,
              ownership=None):
    reference_at(reference)
    tmux = shutil.which("tmux", path=environment.get("PATH"))
    if not tmux or not Path(cli).is_file():
        raise ConnectFailure("dependency-required")
    session = "vikingbar-connect-" + uuid.uuid4().hex
    if ownership is not None:
        ownership.update(helperPID=os.getpid(), parentPID=os.getppid(), arguments=sys.argv,
                         startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), session=session,
                         helperSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                         cliSHA256=hashlib.sha256(Path(cli).read_bytes()).hexdigest())
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
        completed = False
        try:
            created = True
            try:
                result = execute([*prefix, "new-session", "-d", "-P", "-F", "#{pid} #{pane_pid} #{session_name}",
                                  "-s", session,
                                  "/bin/zsh", "-f", "-c", command], env=clean, capture_output=True,
                                 timeout=10, check=False)
            except subprocess.TimeoutExpired:
                raise ConnectFailure("tmux-start-timeout") from None
            except OSError:
                raise ConnectFailure("tmux-start-failed") from None
            if result.returncode:
                raise ConnectFailure("tmux-start-failed")
            if ownership is not None:
                parts = result.stdout.decode().strip().split()
                if len(parts) != 3 or not all(part.isdigit() for part in parts[:2]) or parts[2] != session:
                    raise ConnectFailure("tmux-ownership-invalid")
                ownership.update(serverPID=int(parts[0]), panePID=int(parts[1]))
            deadline = clock() + 160
            while clock() < deadline:
                if result_path.exists():
                    try:
                        value = json.loads(result_path.read_text())
                    except ValueError:
                        sleep(0.2)
                        continue
                    code = failure_code(value)
                    if code:
                        raise ConnectFailure(code)
                    receipt = validate_receipt(value)
                    completed = True
                    return receipt
                sleep(0.2)
            raise ConnectFailure("connect-timeout")
        finally:
            if created:
                if ownership is not None:
                    ownership["cleanupAttempted"] = True
                try:
                    cleanup = execute([*prefix, "kill-session", "-t", "=" + session], env=clean,
                                      capture_output=True, timeout=10, check=False)
                    if ownership is not None:
                        ownership["cleanupReturncode"] = cleanup.returncode
                except (OSError, subprocess.TimeoutExpired):
                    if ownership is not None:
                        ownership["cleanupError"] = "tmux-cleanup-failed"
                    if completed:
                        raise ConnectFailure("tmux-cleanup-failed") from None


def main(arguments=None, environment=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True)
    parser.add_argument("--reference", required=True)
    parser.add_argument("--result")
    parser.add_argument("--inside-tmux", action="store_true")
    args = parser.parse_args(arguments)
    environment = os.environ if environment is None else environment
    previous_handlers = {}
    ownership = {} if args.result and not args.inside_tmux else None
    def interrupted(_signal, _frame):
        raise ConnectFailure("connect-cancelled")
    if not args.inside_tmux:
        for signum in (signal.SIGTERM, signal.SIGINT):
            previous_handlers[signum] = signal.signal(signum, interrupted)
    try:
        receipt = (inside(args.cli, args.reference, environment) if args.inside_tmux
                   else supervise(args.cli, args.reference, environment, ownership=ownership))
    except ConnectFailure as error:
        code = str(error)
        receipt = {"passed": False, "error": code if code in FAILURE_CODES else "connect-helper-failed"}
    except OSError:
        receipt = {"passed": False, "error": "local-filesystem"}
    except Exception:
        receipt = {"passed": False, "error": "connect-helper-failed"}
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
    if args.result:
        try:
            if ownership is not None:
                path = Path(args.result)
                write_receipt(path.with_name(path.stem + "-ownership.json"), ownership)
            write_receipt(args.result, receipt)
        except OSError:
            receipt = {"passed": False, "error": "receipt-write-failed"}
    print(json.dumps(receipt, sort_keys=True))
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
