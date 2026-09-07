#!/usr/bin/env python3
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "Scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


UI = load("balance-ui-proof")
INSTALL = load("install-app")
UIFailure = UI.UIFailure
private_write = UI.private_write


def require_reviewed_artifact(artifact):
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if artifact.get("sourceDirty") is not False or artifact.get("commit") != head:
        raise UIFailure("clean-current-commit-install-required")


def login_receipt(value):
    if (not isinstance(value, dict) or set(value) != {"schema_version", "status", "passed"}
            or type(value["schema_version"]) is not int or value["schema_version"] != 1
            or value["passed"] is not True
            or value["status"] not in ("notRegistered", "enabled", "requiresApproval", "unavailable")):
        raise UIFailure("invalid-login-item-receipt")
    return value["status"]


def preferences(tree):
    result = {}
    for name in ("showRemainingGB", "dataDisplayMode", "refreshInterval"):
        matches = [item for item in tree.get("elements", []) if item.get("AXIdentifier") == "vikingbar." + name]
        if len(matches) != 1 or not isinstance(matches[0].get("AXValue"), str):
            raise UIFailure("settings-values-missing")
        result[name] = matches[0]["AXValue"]
    if (result["showRemainingGB"] not in ("0", "1") or result["dataDisplayMode"] not in ("Remaining", "Used")
            or result["refreshInterval"] not in ("Every 5 minutes", "Every 15 minutes", "Every 30 minutes", "Every hour")):
        raise UIFailure("settings-values-invalid")
    return result


def verify_saved_preferences(path, expected):
    try:
        saved = json.loads(path.read_text()) if path.exists() else {}
        actual = {"showRemainingGB": saved.get("showRemainingGB", False),
                  "dataDisplayMode": saved.get("dataDisplayMode", "remaining"),
                  "refreshInterval": saved.get("refreshInterval", 300)}
        intervals = {"Every 5 minutes": 300, "Every 15 minutes": 900,
                     "Every 30 minutes": 1800, "Every hour": 3600}
        wanted = {"showRemainingGB": expected["showRemainingGB"] == "1",
                  "dataDisplayMode": expected["dataDisplayMode"].lower(),
                  "refreshInterval": intervals[expected["refreshInterval"]]}
        if (type(actual["showRemainingGB"]) is not bool or type(actual["refreshInterval"]) is not int
                or actual != wanted):
            raise ValueError()
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        raise UIFailure("saved-preferences-mismatch") from None


class InstalledProof(UI.NativeProof):
    def __init__(self, environment, check):
        if environment.get("VIKINGBAR_UI_SLOT") != "held" or environment.get("VIKINGBAR_CREDENTIAL_SLOT") != "held":
            raise UIFailure("explicit-ui-and-credential-slots-required")
        if not environment.get("INSTALL_TARGET"):
            raise UIFailure("explicit-INSTALL_TARGET-required")
        self.bundle = INSTALL.target_path(environment["INSTALL_TARGET"])
        if check == "smoke":
            applications = Path.home() / "Applications"
            if applications not in self.bundle.parents or self.bundle.exists():
                raise UIFailure("fresh-absent-target-under-user-Applications-required")
        self.environment, self.check = environment, check
        self.peekaboo = environment.get("PEEKABOO_BIN")
        if not self.peekaboo or not Path(self.peekaboo).is_file():
            raise UIFailure("configured-peekaboo-required")
        self.directory = ROOT / ".build/proof" / ("installed-" + uuid.uuid4().hex)
        self.directory.mkdir(parents=True, mode=0o700)
        self.settings_file = (self.directory / "settings.json" if check == "smoke" else
                              Path.home() / "Library/Application Support/VikingBar/menu-bar-preferences.json")
        self.executable = self.bundle / "Contents/MacOS/VikingBarApp"
        self.cli = self.bundle / "Contents/MacOS/vikingbar"
        self.process = None
        self.launches, self.workers, self.screens = [], [], []
        self.launch_record = self.identity = None
        self.registration_intent = False
        self.original_preferences = None
        self.preferences_restored = True
        self.install_receipt = None

    def verify_installed(self):
        if self.install_receipt is None or INSTALL.validate_install(self.bundle) != self.install_receipt:
            raise UIFailure("installed-artifact-changed")
        require_reviewed_artifact(self.install_receipt["artifact"])

    def login(self, operation):
        self.verify_installed()
        return login_receipt(self.run([str(self.executable), "--login-item", operation],
                                      "login-" + operation + ".json", timeout=30))

    def capture(self, label):
        tree = self.inspect(label + "-tree.json")
        window = next((window for window in tree.get("windows", [])
                       if window.get("kCGWindowBounds", {}).get("Height", 0) > 100), None)
        if not window:
            raise UIFailure("card-window-missing")
        self.peek(["see", "--window-id", str(window["kCGWindowNumber"]), "--no-elements", "--no-remote",
                   "--path", str(self.directory / (label + ".png"))], label + "-image.json")

    def launch(self, first=False, label="launch"):
        self.verify_installed()
        arguments = [str(self.executable)]
        if self.check == "smoke":
            arguments += ["--fixture", "finite", "--settings-file", str(self.directory / "settings.json"),
                          "--allow-login-item"]
        else:
            arguments += ["--proof-directory", str(self.directory)]
        clean = {key: self.environment[key] for key in ("PATH", "TMPDIR", "LANG", "LC_ALL")
                 if key in self.environment}
        self.process = subprocess.Popen(arguments, cwd=ROOT, env=clean,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.launch_record = {"pid": self.process.pid, "parentPID": os.getpid(), "arguments": arguments,
                              "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                              "executableSHA256": self.executable_hash, "cli": str(self.cli),
                              "cliSHA256": INSTALL.digest(self.cli), "workerOwnershipEstablished": self.check == "smoke"}
        self.launches.append((self.process, self.launch_record))
        private_write(self.directory / (label + "-process.json"), self.launch_record)
        identity = UI.process_identity(self.process.pid)
        if identity is None or identity["parentPID"] != os.getpid() or identity["command"] != " ".join(arguments):
            raise UIFailure("launch-process-ownership-unverified")
        self.identity = identity["identity"]
        self.launch_record.update(identity)
        private_write(self.directory / (label + "-process.json"), self.launch_record)
        if self.check != "smoke":
            if len(self.capture_worker(self.process, self.launch_record, seconds=3)) != 1:
                raise UIFailure("runtime-worker-identity-mismatch")
            self.launch_record["workerOwnershipEstablished"] = True
            private_write(self.directory / (label + "-process.json"), self.launch_record)
        tree = UI.wait_for(self.inspect, lambda value: UI.visible_status(value, self.screens), seconds=20)
        if tree.get("activationPolicy") != 1:
            raise UIFailure("accessory-policy-required")
        self.peek(["see", "--mode", "screen", "--no-elements", "--no-remote", "--path",
                   str(self.directory / (label + "-before.png"))], label + "-before.json")
        self.press("vikingbar.status")
        return UI.wait_for(self.inspect, lambda value: any(
            item.get("AXIdentifier") == "vikingbar.remaining" for item in value.get("elements", [])))

    def quit(self):
        self.press("Data")
        UI.wait_for(self.inspect, lambda tree: any(item.get("AXIdentifier") == "vikingbar.quit"
                    for item in tree.get("elements", [])))
        super().quit()

    def fixture_card(self, label):
        self.press("Data")
        UI.wait_for(self.inspect, lambda tree: all(any(
            item.get("AXIdentifier") == identifier
            and value in [item.get(key) for key in ("AXValue", "AXTitle", "AXDescription")]
            for item in tree.get("elements", [])) for identifier, value in (
                ("vikingbar.balanceTitle", "Data used"), ("vikingbar.remaining", "14.00 GB"),
                ("vikingbar.status", "36 GB"))))
        self.capture(label)
        self.peek(["see", "--mode", "screen", "--no-elements", "--no-remote", "--path",
                   str(self.directory / (label + "-status.png"))], label + "-status-image.json")
        self.settings()

    def settings(self):
        self.press("Settings")
        return UI.wait_for(self.inspect, lambda tree: any(
            item.get("AXIdentifier") == "vikingbar.dataDisplayMode" for item in tree.get("elements", [])))

    def login_ui(self, expected):
        return UI.wait_for(self.inspect, lambda tree: any(
            item.get("AXIdentifier") == "vikingbar.loginItemStatus"
            and expected in [item.get(key) for key in ("AXValue", "AXTitle", "AXDescription")]
            for item in tree.get("elements", [])))

    def choose(self, identifier, value):
        self.press("vikingbar." + identifier)
        UI.wait_for(self.inspect, lambda tree: any(item.get("AXRole") == "AXMenuItem"
                    and item.get("AXTitle") == value for item in tree.get("elements", [])))
        self.press(value)

    def apply_preferences(self, expected):
        current = preferences(self.settings())
        for name, value in expected.items():
            if current[name] != value:
                if name == "showRemainingGB":
                    self.press("vikingbar.showRemainingGB")
                else:
                    self.choose(name, value)
        tree = UI.wait_for(self.inspect, lambda tree: preferences(tree) == expected)
        if any(item.get("AXIdentifier") == "vikingbar.settingsError" for item in tree.get("elements", [])):
            raise UIFailure("settings-persistence-error")
        verify_saved_preferences(self.settings_file, expected)

    def restore_preferences(self):
        if self.preferences_restored:
            return
        if self.process is None or self.process.poll() is not None:
            self.launch(label="restoration")
        self.apply_preferences(self.original_preferences)
        self.preferences_restored = True
        private_write(self.directory / "preferences-restored.json", {"restored": True})

    def perform_smoke(self):
        initial_status = self.login("status")
        if initial_status != "notRegistered":
            raise UIFailure("initial-login-item-must-be-notRegistered")
        self.launch(label="fixture")
        initial = preferences(self.settings())
        changed = {"showRemainingGB": "1",
                   "dataDisplayMode": "Used", "refreshInterval": "Every 30 minutes"}
        private_write(self.directory / "restoration-intent.json", {"loginItem": "notRegistered",
                      "settingsFile": str(self.directory / "settings.json"), "initialPreferences": initial,
                      "bundleRetained": True, "osLoginExecutionProven": False})
        self.apply_preferences(changed)
        self.registration_intent = True
        self.press("vikingbar.launchAtLogin")
        UI.wait_for(lambda: self.login("status"), lambda value: value in ("enabled", "requiresApproval"))
        if self.login("status") != "enabled":
            raise UIFailure("login-item-approval-required-not-enabled")
        self.login_ui("On")
        self.capture("enabled-settings")
        self.fixture_card("used-card")
        self.quit()
        self.launch(label="fixture-resumed")
        if preferences(self.settings()) != changed or self.login("status") != "enabled":
            raise UIFailure("installed-settings-or-registration-not-persisted")
        saved = json.loads((self.directory / "settings.json").read_text())
        if saved.get("dataDisplayMode") != "used" or saved.get("refreshInterval") != 1800:
            raise UIFailure("isolated-settings-not-persisted")
        self.capture("resumed-settings")
        self.fixture_card("resumed-used-card")
        self.press("vikingbar.launchAtLogin")
        UI.wait_for(lambda: self.login("status"), lambda value: value == "notRegistered")
        self.login_ui("Off")
        self.capture("disabled-settings")
        self.quit()
        return {"registration_enabled": True, "registration_restored": True, "preferences_persisted": True,
                "manual_relaunch": True, "os_login_execution": False, "fixture": True}

    def perform_balance(self):
        self.launch(label="stored-session")
        self.original_preferences = preferences(self.settings())
        private_write(self.directory / "restoration-intent.json", {"preferences": self.original_preferences,
                                                                  "restoreTokens": False})
        self.preferences_restored = False
        expected = dict(self.original_preferences, dataDisplayMode="Remaining")
        self.apply_preferences(expected)
        self.press("Data")
        initial = self.matched_balance("initial")
        def api_check():
            try:
                return UI.validate_api_receipt(json.loads(self.run([str(self.cli), "proof", "balance-api"], timeout=180)))
            except UIFailure as error:
                if str(error) == "session-busy":
                    return None
                raise
        private_write(self.directory / "api-result.json", UI.wait_for(api_check, lambda value: value is not None, seconds=30))
        api_report = self.run([str(self.cli), "live", "--cached"], "after-api-report.json")
        time.sleep(1.1)
        self.press("vikingbar.refresh")
        refreshed = self.matched_balance("refreshed", UI.successful_timestamp(api_report))
        self.quit()
        time.sleep(1.1)
        self.launch(label="stored-session-resumed")
        if preferences(self.settings()) != expected:
            raise UIFailure("installed-preferences-not-persisted")
        self.press("Data")
        resumed = self.matched_balance("resumed", UI.successful_timestamp(refreshed))
        for key in ("connectionID", "selectedSubscriptionID", "selectedBundleIndex"):
            if any(report["state"][key] != initial["state"][key] for report in (refreshed, resumed)):
                raise UIFailure("installed-session-selection-changed")
        self.restore_preferences()
        self.quit()
        return {"stored_session": True, "api_matches": True, "visible_menu_matches": True,
                "native_refresh": True, "manual_relaunch": True, "selection_preserved": True,
                "preferences_restored": True, "password_bootstrap": False}

    def before_install(self, candidate):
        require_reviewed_artifact(INSTALL.artifact(candidate))
        value = self.run([str(candidate / "Contents/MacOS/VikingBarApp"), "--login-item", "status"],
                         "login-before-install.json", timeout=30)
        if login_receipt(value) != "notRegistered":
            raise UIFailure("initial-login-item-must-be-notRegistered")
        private_write(self.directory / "restoration-intent.json", {"loginItem": "notRegistered",
                      "target": str(self.bundle), "bundleRetained": True, "osLoginExecutionProven": False})

    def perform(self):
        if self.check != "smoke":
            self.install_receipt = INSTALL.validate_install(self.bundle)
            self.verify_installed()
        self.peek(["permissions", "status", "--all-sources"], "permissions.json")
        apps = self.peek(["app", "list", "--include-hidden", "--include-background"], "apps-before.json")
        if "be.bram.vikingbar" in json.dumps(apps):
            raise UIFailure("existing-app-must-be-quit")
        if self.check == "smoke":
            self.install_receipt = INSTALL.install(str(self.bundle), before_publish=self.before_install)
        self.verify_installed()
        private_write(self.directory / "install.json", self.install_receipt)
        self.run(["swiftc", "Scripts/inspect-ui.swift", "-o", ".build/inspect-ui"], timeout=120)
        self.executable_hash = INSTALL.digest(self.executable)
        self.screens = self.peek(["screen", "list"], "screens.json")["screens"]
        result = self.perform_smoke() if self.check == "smoke" else self.perform_balance()
        if INSTALL.validate_install(self.bundle) != self.install_receipt:
            raise UIFailure("installed-artifact-changed")
        return dict(result, schema_version=1, check="smoke-installed-app" if self.check == "smoke" else "installed-balance",
                    passed=True, bundle_retained=True)

    def verify_owned(self, process, record):
        current = UI.process_identity(process.pid)
        if (current is None or record.get("identity") != current["identity"]
                or current["parentPID"] != os.getpid()
                or INSTALL.digest(self.executable) != record["executableSHA256"]):
            raise UIFailure("cleanup-app-ownership-unverified")

    def graceful_quit(self, process, record):
        if process.poll() is not None:
            return
        self.verify_owned(process, record)
        probe = [str(ROOT / ".build/inspect-ui"), str(process.pid)]
        try:
            tree = json.loads(self.run(probe, timeout=2))
            if not any(item.get("AXIdentifier") == "vikingbar.quit" for item in tree.get("elements", [])):
                if not any(item.get("AXIdentifier") == "vikingbar.dataDisplayMode" for item in tree.get("elements", [])):
                    self.verify_owned(process, record)
                    self.run([*probe, "press", "vikingbar.status"], timeout=2)
                self.verify_owned(process, record)
                self.run([*probe, "press", "Data"], timeout=2)
            self.verify_owned(process, record)
            self.run([*probe, "press", "vikingbar.quit"], timeout=2)
            process.wait(timeout=25)
        except (UIFailure, OSError, ValueError, subprocess.SubprocessError):
            return

    def stop_owned(self, process, record):
        if process.poll() is not None:
            return
        for action in (signal.SIGTERM, signal.SIGKILL):
            self.verify_owned(process, record)
            os.kill(process.pid, action)
            try:
                process.wait(timeout=5)
                return
            except subprocess.TimeoutExpired:
                pass
        raise UIFailure("cleanup-app-still-running")

    def cleanup(self):
        errors = []
        if not self.preferences_restored:
            try:
                self.restore_preferences()
            except Exception:
                errors.append("preferences-restoration-failed")
        if self.registration_intent:
            try:
                if self.login("disable") != "notRegistered" or self.login("status") != "notRegistered":
                    raise UIFailure("login-registration-restoration-failed")
            except Exception:
                errors.append("login-registration-restoration-failed")
        for process, record in self.launches:
            try:
                private_write(self.directory / "cleanup-process.json", record)
                if record["workerOwnershipEstablished"] is not True:
                    errors.append("cleanup-worker-ownership-unverified")
                self.graceful_quit(process, record)
                self.stop_owned(process, record)
            except Exception:
                errors.append("cleanup-app-ownership-or-exit-failed")
        for worker in self.workers:
            try:
                if INSTALL.digest(self.cli) != worker["cliSHA256"]:
                    raise UIFailure("cleanup-worker-artifact-changed")
                deadline = time.monotonic() + 3
                while self.worker_present(worker) and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.stop_worker(worker)
            except Exception:
                errors.append("cleanup-worker-ownership-or-exit-failed")
        private_write(self.directory / "cleanup.json", {"exited": not errors,
                      "preferencesRestored": self.preferences_restored,
                      "registrationRestored": self.registration_intent and "login-registration-restoration-failed" not in errors,
                      "bundleRetained": self.bundle.exists(), "errors": errors})
        if errors:
            raise UIFailure(errors[0])


def run(environment, check="installed-balance"):
    if check not in ("smoke", "installed-balance"):
        raise UIFailure("unknown-installed-check")
    old_mask = os.umask(0o077)
    proof = None
    result = {"passed": False, "error": "installed-proof-failed"}
    try:
        proof = InstalledProof(environment, check)
        try:
            result = proof.perform()
        finally:
            proof.cleanup()
        private_write(proof.directory / "result.json", result)
        return result
    except Exception as error:
        result = {"passed": False, "error": str(error) if isinstance(error, (UIFailure, INSTALL.InstallFailure))
                  else "installed-proof-failed"}
        if proof is not None:
            private_write(proof.directory / "result.json", result)
        raise UIFailure(result["error"]) from None
    finally:
        os.umask(old_mask)


def main():
    try:
        if sys.argv[1:] != ["smoke"]:
            raise UIFailure("use-smoke-or-proof-live-installed-balance")
        result = run(os.environ, "smoke")
        code = 0
    except Exception as error:
        result = {"passed": False, "error": str(error) if isinstance(error, UIFailure) else "installed-proof-failed"}
        code = 1
    print(json.dumps(result, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
