#!/usr/bin/env python3
"""Run one local API proof using a targeted 1Password bootstrap."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


class ProofFailure(Exception):
    """A fixed diagnostic safe for public output."""


def credential_reference(path):
    try:
        reference = json.loads(Path(path).read_text())
        if (reference["vault"] != "Codex Automation"
                or not isinstance(reference["item_id"], str)
                or not reference["item_id"].isalnum()
                or reference["fields"] != ["client_id", "username", "password"]):
            raise ValueError()
        return reference
    except (OSError, ValueError, KeyError, TypeError):
        raise ProofFailure("invalid-credential-reference") from None


def extract_credentials(item_bytes):
    try:
        fields = json.loads(item_bytes)["fields"]
        result = {}
        for label in ("client_id", "username", "password"):
            matches = [field["value"] for field in fields if field.get("label") == label]
            if len(matches) != 1 or not isinstance(matches[0], str) or not matches[0]:
                raise ValueError()
            result[label] = matches[0]
        return result
    except (ValueError, KeyError, TypeError, AttributeError):
        raise ProofFailure("missing-or-ambiguous-credential-field") from None


def child_environment(environment):
    allowed = ("PATH", "TMPDIR", "LANG", "LC_ALL")
    return {key: environment[key] for key in allowed if key in environment}


def run(check, environment, execute=subprocess.run):
    if check == "points":
        spec = importlib.util.spec_from_file_location("points_proof", Path(__file__).with_name("points-proof.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        try:
            return module.run(environment)
        except module.UIFailure as error:
            raise ProofFailure(str(error)) from None
    if check == "balance-ui":
        spec = importlib.util.spec_from_file_location("balance_ui_proof", Path(__file__).with_name("balance-ui-proof.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        try:
            return module.run(environment)
        except module.UIFailure as error:
            raise ProofFailure(str(error)) from None
    if check != "auth-balance":
        raise ProofFailure("unknown-check")
    if not environment.get("TMUX"):
        raise ProofFailure("named-tmux-session-required")
    if not environment.get("BRAM_OP_SERVICE_ACCOUNT_TOKEN"):
        raise ProofFailure("service-account-token-required")
    reference = credential_reference(environment.get("VIKINGBAR_CREDENTIAL_REFERENCE", ""))
    op_binary = shutil.which("op", path=environment.get("PATH"))
    if not op_binary:
        raise ProofFailure("one-password-cli-required")
    executable = Path(__file__).resolve().parent.parent / ".build/debug/vikingbar"
    if not executable.is_file():
        raise ProofFailure("build-required")
    op_environment = child_environment(environment)
    op_environment["OP_SERVICE_ACCOUNT_TOKEN"] = environment["BRAM_OP_SERVICE_ACCOUNT_TOKEN"]
    item = execute(
        [op_binary, "item", "get", reference["item_id"], "--vault", reference["vault"], "--format", "json"],
        env=op_environment, capture_output=True, timeout=60, check=False,
    )
    if item.returncode:
        raise ProofFailure("credential-read-failed")
    credentials = extract_credentials(item.stdout)
    del item
    result = execute(
        [str(executable), "proof", check], input=json.dumps(credentials).encode(),
        env=child_environment(environment), capture_output=True, timeout=180, check=False,
    )
    del credentials
    if result.returncode:
        raise ProofFailure("api-proof-failed")
    try:
        receipt = json.loads(result.stdout)
        safe = validate_receipt(receipt)
    except (ValueError, TypeError, KeyError):
        raise ProofFailure("invalid-proof-receipt") from None
    return safe


def validate_receipt(receipt):
    expected = {"schema_version", "check", "passed", "password_grant", "refresh_grant",
                "subscription_count", "balance_count", "scope_mismatch", "failure"}
    if not isinstance(receipt, dict) or set(receipt) != expected:
        raise ValueError()
    if type(receipt["schema_version"]) is not int or receipt["schema_version"] != 1:
        raise ValueError()
    if receipt["check"] != "auth-balance" or receipt["failure"] is not None:
        raise ValueError()
    for key in ("passed", "password_grant", "refresh_grant"):
        if receipt[key] is not True:
            raise ValueError()
    if type(receipt["scope_mismatch"]) is not bool:
        raise ValueError()
    for key in ("subscription_count", "balance_count"):
        if type(receipt[key]) is not int or receipt[key] < 1:
            raise ValueError()
    if receipt["subscription_count"] != receipt["balance_count"]:
        raise ValueError()
    return receipt


def main(arguments=None, environment=None):
    try:
        args = sys.argv[1:] if arguments is None else arguments
        if len(args) != 1:
            raise ProofFailure("one-check-required")
        receipt = run(args[0], os.environ if environment is None else environment)
        print(json.dumps(receipt, sort_keys=True))
        return 0
    except ProofFailure as error:
        print(json.dumps({"passed": False, "error": str(error)}))
    except (OSError, subprocess.SubprocessError):
        print(json.dumps({"passed": False, "error": "dependency-failed"}))
    except Exception:
        print(json.dumps({"passed": False, "error": "runner-failed"}))
    return 1


if __name__ == "__main__":
    sys.exit(main())
