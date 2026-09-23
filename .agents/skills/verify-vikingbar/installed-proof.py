#!/usr/bin/env python3
"""Installed proof with picker settling and account-bound worker receipts."""
import argparse
import importlib.util
import json
import os
import subprocess
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("installed_proof", ROOT / "Scripts/installed-app-proof.py")
PROOF = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROOF)
Base = PROOF.InstalledProof


class InstalledProof(Base):
    def run(self, command, name=None, timeout=120):
        try:
            return super().run(command, name, timeout)
        except PROOF.UIFailure:
            PROOF.private_write(self.directory / "failed-command.json", {
                "executable": Path(command[0]).name, "receipt": name,
            })
            raise

    def __init__(self, environment, check):
        previous = environment.get("VIKINGBAR_RESUME_OWNED_PROOF")
        super().__init__(environment, "installed-balance" if previous else check)
        self.previous = None
        if previous:
            if check != "smoke":
                raise PROOF.UIFailure("resume-requires-smoke")
            directory = Path(previous)
            if (directory.is_symlink() or directory.resolve().parent != ROOT / ".build/proof"
                    or not directory.name.startswith("installed-")
                    or Path.home() / "Applications" not in self.bundle.parents):
                raise PROOF.UIFailure("owned-install-resume-invalid")
            cleanup = json.loads((directory / "cleanup.json").read_text())
            baselines = json.loads((directory / "login-baselines.json").read_text())
            receipt = json.loads((directory / "install.json").read_text())
            intent = json.loads((directory / "restoration-intent.json").read_text())
            candidate = Path(baselines.get("candidate", {}).get("path", ""))
            if (cleanup.get("exited") is not True or cleanup.get("errors") != []
                    or "beforeToggle" in baselines
                    or candidate.name != "VikingBar.app" or candidate.parent.parent != self.bundle.parent
                    or not candidate.parent.name.startswith(".vikingbar-install-")
                    or baselines["candidate"].get("status") not in ("notFound", "notRegistered")
                    or intent.get("initialLoginStates") != baselines
                    or intent.get("registrationScope") != "exact-task-owned-paths"
                    or baselines.get("installed", {}).get("path") != str(self.bundle)
                    or baselines["installed"].get("status") not in ("notFound", "notRegistered")
                    or PROOF.INSTALL.validate_install(self.bundle) != receipt):
                raise PROOF.UIFailure("owned-install-resume-invalid")
            PROOF.require_reviewed_artifact(receipt["artifact"])
            self.check = "smoke"
            self.fresh_install = True
            self.settings_file = self.directory / "settings.json"
            self.install_receipt = receipt
            self.previous = str(directory.resolve())

    def choose(self, identifier, value):
        selector = "vikingbar." + identifier
        self.verify_process()
        try:
            result = subprocess.run(
                [str(ROOT / ".build/inspect-ui"), str(self.process.pid), "choose", selector, value],
                cwd=ROOT, capture_output=True, text=True, timeout=120,
                env={key: self.environment[key] for key in ("PATH", "TMPDIR", "LANG", "LC_ALL")
                     if key in self.environment})
            PROOF.private_write(self.directory / ("choose-" + identifier + ".json"), {
                "returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr,
            })
            if result.returncode:
                raise PROOF.UIFailure("picker-command-failed")
        except PROOF.UIFailure:
            self.inspect("failed-picker-tree.json")
            raise

        def settled(tree):
            try:
                boundary, _ = PROOF.UI.popover_window(tree, self.screens)
            except PROOF.UIFailure as error:
                if str(error) == "native-popover-not-visible":
                    return False
                raise
            matches = [item for item in tree.get("elements", [])
                       if item.get("AXIdentifier") == selector and item.get("AXRole") == "AXPopUpButton"
                       and PROOF.UI.contained(item, boundary)]
            displays = PROOF.UI.display_frames(self.screens)
            menu_visible = any(item.get("AXRole") == "AXMenuItem"
                               and any(PROOF.UI.contained(item, display) for display in displays)
                               for item in tree.get("elements", []))
            return len(matches) == 1 and matches[0].get("AXValue") == value and not menu_visible

        # A closed AX menu can still be completing its dismissal animation.
        time.sleep(0.7)
        PROOF.UI.wait_for(self.inspect, settled)

    def launch(self, first=False, label="launch"):
        if self.check != "smoke":
            catalog = self.run([str(self.cli), "accounts", "list"], "account-catalog.json")
            key = catalog["selected"]
            if key["provider"] != "mobile-vikings":
                raise PROOF.UIFailure("runtime-worker-identity-mismatch")
            self.account_selector = key["provider"] + "/" + str(uuid.UUID(key["slot"]))
        return super().launch(first, label)

    def capture_worker(self, process, launch, seconds=0):
        if self.check != "smoke" and "accountSelector" not in launch:
            launch["accountSelector"] = self.account_selector
            PROOF.private_write(self.directory / "worker-account-binding.json", launch)
        return super().capture_worker(process, launch, seconds)

    def perform(self):
        if not self.previous:
            return super().perform()
        self.verify_installed()
        self.peek(["permissions", "status", "--all-sources"], "permissions.json")
        apps = self.peek(["app", "list", "--include-hidden", "--include-background"], "apps-before.json")
        if "be.bram.vikingbar" in json.dumps(apps):
            raise PROOF.UIFailure("existing-app-must-be-quit")
        PROOF.private_write(self.directory / "install.json", self.install_receipt)
        PROOF.private_write(self.directory / "resumed-install.json", {"previousProof": self.previous})
        self.run(["swiftc", "Scripts/inspect-ui.swift", "-o", ".build/inspect-ui"], timeout=120)
        self.executable_hash = PROOF.INSTALL.digest(self.executable)
        self.screens = self.peek(["screen", "list"], "screens.json")["screens"]
        result = self.perform_smoke()
        self.verify_installed()
        return dict(result, schema_version=1, check="smoke-installed-app", passed=True, bundle_retained=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("check", choices=("smoke", "installed-balance"))
    parser.add_argument("--resume-owned-proof", type=Path)
    arguments = parser.parse_args()
    environment = dict(os.environ)
    if arguments.resume_owned_proof:
        environment["VIKINGBAR_RESUME_OWNED_PROOF"] = str(arguments.resume_owned_proof.resolve())
    PROOF.InstalledProof = InstalledProof
    try:
        print(json.dumps(PROOF.run(environment, arguments.check), sort_keys=True))
    except Exception as error:
        code = str(error) if isinstance(error, PROOF.UIFailure) else "installed-proof-failed"
        print(json.dumps({"passed": False, "error": code}))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
