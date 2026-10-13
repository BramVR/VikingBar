#!/usr/bin/env python3
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import resource
import signal
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


UI = module("recovery_balance_ui", "balance-ui-proof.py")
HOME = module("recovery_home_ui", "telenet-home-ui-proof.py")
WRAPPER = module("recovery_credential_wrapper", "proof-live.py")
UIFailure = UI.UIFailure
CHECKS = {"mobile-session-recovery", "mobile-remembered-sign-in", "telenet-remembered-sign-in"}
SETUP_CHECKS = {"direct-connect-ui", "telenet-home-ui"}
STAGES = ("provider", "native", "relaunch", "independent_usage", "option_off", "logout", "cleanup")


def private_json(path):
    path = Path(path)
    if (not path.is_file() or path.is_symlink() or path.stat().st_mode & 0o077
            or path.resolve().is_relative_to(ROOT) or path.stat().st_size > 32768):
        raise ValueError()
    return json.loads(path.read_bytes())


def configuration(check, environment, now=None):
    try:
        path = Path(environment["VIKINGBAR_SESSION_RECOVERY_CONFIG"])
        value = private_json(path)
        keys = {"schema_version", "check", "source_sha256", "credential_reference_sha256", "expires_at",
                "tmux_session", "credential_slot", "mac_ui_slot", "evidence_root", "account", "account_root",
                "timeout_seconds"}
        if (set(value) != keys or type(value["schema_version"]) is not int or value["schema_version"] != 1
                or check not in CHECKS | SETUP_CHECKS or value["check"] != check
                or value["source_sha256"] != UI.source_digest()
                or hashlib.sha256(path.read_bytes()).hexdigest()
                    != environment["VIKINGBAR_SESSION_RECOVERY_CONFIG_SHA256"]):
            raise ValueError()
        for key, variable in (("credential_slot", "VIKINGBAR_CREDENTIAL_SLOT"),
                              ("mac_ui_slot", "VIKINGBAR_MAC_UI_SLOT")):
            if (not isinstance(value[key], str) or not value[key].strip()
                    or value[key].upper() in {"INACTIVE", "DISABLED", "PENDING", "NONE"}
                    or value[key] != environment.get(variable)):
                raise ValueError()
        if (not environment.get("TMUX") or not environment.get("BRAM_OP_SERVICE_ACCOUNT_TOKEN")
                or value["expires_at"] != environment["VIKINGBAR_SLOT_BINDINGS_EXPIRES_AT"]
                or not isinstance(value["tmux_session"], str) or not value["tmux_session"].strip()):
            raise ValueError()
        expires = datetime.datetime.fromisoformat(value["expires_at"].replace("Z", "+00:00"))
        now = now or datetime.datetime.now(datetime.timezone.utc)
        remaining = (expires - now).total_seconds()
        if (not 0 < remaining <= 3600 or type(value["timeout_seconds"]) is not int
                or not 60 <= value["timeout_seconds"] <= min(3300, remaining - 120)):
            raise ValueError()
        provider = "telenet" if check.startswith("telenet-") else "mobile-vikings"
        prefix, slot = value["account"].split("/")
        if prefix != provider or str(uuid.UUID(slot)) != slot or slot == "00000000-0000-0000-0000-000000000001":
            raise ValueError()
        evidence = Path(value["evidence_root"])
        storage = Path(value["account_root"])
        if (not evidence.is_absolute() or not evidence.is_dir() or evidence.is_symlink()
                or evidence.stat().st_mode & 0o077 or evidence.resolve().is_relative_to(ROOT)
                or not re.fullmatch(r"/[A-Za-z0-9._/-]+", str(storage))
                or storage.exists() or storage.is_symlink() or not storage.parent.is_dir()
                or storage.parent.stat().st_mode & 0o077 or storage.parent.is_symlink()
                or storage.resolve().is_relative_to(ROOT)
                or storage.name != "session-recovery-" + slot):
            raise ValueError()
        reference_variable = ("VIKINGBAR_TELENET_CREDENTIAL_REFERENCE" if provider == "telenet"
                              else "VIKINGBAR_CREDENTIAL_REFERENCE")
        reference_path = Path(environment[reference_variable])
        reference = private_json(reference_path)
        expected_fields = ["username", "password"] if provider == "telenet" else ["client_id", "username", "password"]
        if (set(reference) != {"vault", "item_id", "fields"} or reference["vault"] != "Codex Automation"
                or reference["fields"] != expected_fields or not isinstance(reference["item_id"], str)
                or not re.fullmatch(r"[A-Za-z0-9._ -]{1,100}", reference["item_id"])
                or hashlib.sha256(reference_path.read_bytes()).hexdigest() != value["credential_reference_sha256"]):
            raise ValueError()
        value["reference"] = reference
        return value
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        raise UIFailure("session-recovery-configuration-required") from None


def validate_provider(value, check, phase, account):
    keys = {"schema_version", "check", "phase", "account_sha256", "passed", "bootstrap", "owned", "savedSignIn", "serviceRetained", "remembered",
            "restored", "loss", "recovered", "usage", "disabled", "loggedOut", "password_grants",
            "refresh_grants", "failure"}
    optional = {"connection_sha256", "original_connection_sha256"}
    booleans = {"passed", "bootstrap", "owned", "savedSignIn", "serviceRetained", "remembered", "restored", "recovered", "usage", "disabled", "loggedOut"}
    failures = {"none", "observation-timeout", "operation-failed", "required-stage-unobserved",
                "natural-expiry-unverified", "provider-session-loss-unobserved"}
    if (not isinstance(value, dict) or not keys <= set(value) or set(value) - keys - optional
            or type(value["schema_version"]) is not int or value["schema_version"] != 1
            or value["check"] != check or value["phase"] != phase
            or value["account_sha256"] != hashlib.sha256(account.encode()).hexdigest()
            or any(type(value[key]) is not bool for key in booleans)
            or value["loss"] not in {"unobserved", "access-rejected", "grant-rejected", "unclassified-cookie-loss"}
            or value["failure"] not in failures
            or any(type(value[key]) is not int or not 0 <= value[key] <= 64
                   for key in ("password_grants", "refresh_grants"))
            or any(not isinstance(value[key], str) or not re.fullmatch(r"[a-f0-9]{64}", value[key])
                   for key in optional if key in value)):
        raise UIFailure("session-recovery-receipt-invalid")
    if value["passed"]:
        if value["failure"] != "none":
            raise UIFailure("session-recovery-receipt-invalid")
        if phase == "exercise":
            loss = "access-rejected" if check == "mobile-session-recovery" else "grant-rejected"
            if (check == "telenet-remembered-sign-in" or value["loss"] != loss
                    or any(value[key] is not True for key in ("bootstrap", "owned", "restored", "recovered", "usage"))
                    or not optional <= set(value)
                    or value["password_grants"] != (1 if check == "mobile-session-recovery" else 2)
                    or value["refresh_grants"] < 1
                    or (check != "mobile-session-recovery" and not value["remembered"])
                    or (check != "mobile-session-recovery" and not value["savedSignIn"])
                    or (check != "mobile-session-recovery" and not value["serviceRetained"])
                    or ((value["connection_sha256"] == value["original_connection_sha256"])
                        != (check == "mobile-session-recovery"))):
                raise UIFailure("session-recovery-receipt-invalid")
        if phase == "prepare" and (not value["owned"] or value["bootstrap"] or value["password_grants"]
                                    or value["refresh_grants"] or "connection_sha256" in value):
            raise UIFailure("session-recovery-receipt-invalid")
        if phase == "disable" and (not value["disabled"] or value["loggedOut"]):
            raise UIFailure("session-recovery-receipt-invalid")
        if phase == "logout" and (not value["disabled"] or not value["loggedOut"]
                                   or "connection_sha256" in value):
            raise UIFailure("session-recovery-receipt-invalid")
    return value


def validate_final(value, check):
    if (not isinstance(value, dict) or set(value) != {"schema_version", "check", "passed", "stages", "failure"}
            or type(value["schema_version"]) is not int or value["schema_version"] != 1
            or value["check"] != check or type(value["passed"]) is not bool
            or not isinstance(value["stages"], dict) or set(value["stages"]) != set(STAGES)
            or any(type(flag) is not bool for flag in value["stages"].values())
            or value["failure"] not in {"none", "provider-failed", "native-failed", "cleanup-failed"}
            or value["passed"] != (all(value["stages"].values()) and value["failure"] == "none")):
        raise UIFailure("session-recovery-final-receipt-invalid")
    return value


def require_permissions(value):
    try:
        selected = [source for source in value["sources"] if source["isSelected"] is True]
        if len(selected) != 1:
            raise ValueError()
        required = {item["name"]: item["isGranted"] for item in selected[0]["permissions"]
                    if item["isRequired"] is True}
        if required.get("Screen Recording") is not True or required.get("Accessibility") is not True:
            raise ValueError()
    except (KeyError, TypeError, ValueError):
        raise UIFailure("native-permissions-denied") from None


class RecoveryNative(UI.NativeProof):
    def __init__(self, check, environment, config, execute):
        super().__init__(environment, stored_session=True)
        self.check = check
        self.config = config
        self.execute = execute
        self.directory = Path(config["evidence_root"]) / uuid.uuid4().hex
        self.directory.mkdir(mode=0o700)
        self.account_selector = config["account"]
        self.account_root = config["account_root"]
        self.executable_hash = None
        self.expected_connection = None
        self.phase_processes = []
        self.protocol_check = ("telenet-remembered-sign-in" if check.startswith("telenet-")
                               else "mobile-session-recovery") if check in SETUP_CHECKS else check

    def run(self, command, name=None, timeout=120):
        if command[0] == str(self.cli) and command[1] in {"live", "proof"}:
            command = [*command, "--account", self.account_selector, "--account-root", self.account_root]
        return super().run(command, name, timeout)

    def launch(self, first=False, label="recovered"):
        configuration_path = Path(self.environment["VIKINGBAR_SESSION_RECOVERY_CONFIG"])
        if (hashlib.sha256(configuration_path.read_bytes()).hexdigest()
                != self.environment["VIKINGBAR_SESSION_RECOVERY_CONFIG_SHA256"]
                or datetime.datetime.now(datetime.timezone.utc) >= datetime.datetime.fromisoformat(
                    self.config["expires_at"].replace("Z", "+00:00"))):
            raise UIFailure("session-recovery-configuration-required")
        arguments = ["/usr/bin/sandbox-exec", "-p", UI.direct_sandbox(self.executable, self.cli),
                     str(self.executable), "--proof-directory", str(self.directory),
                     "--proof-account-root", self.account_root, "--proof-account", self.account_selector]
        self.process = subprocess.Popen(arguments, cwd=ROOT, env=WRAPPER.child_environment(self.environment),
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        launch = {"pid": self.process.pid, "parentPID": os.getpid(), "arguments": arguments,
                  "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  "executableSHA256": self.executable_hash, "workerOwnershipEstablished": False,
                  "cli": str(self.cli), "cliSHA256": hashlib.sha256(self.cli.read_bytes()).hexdigest(),
                  "accountSelector": self.account_selector, "accountRoot": self.account_root}
        self.launch_record = launch
        self.launches.append((self.process, launch))
        identity = UI.wait_for(lambda: UI.process_identity(self.process.pid), lambda value:
                               value is not None and value["command"].startswith(str(self.executable) + " "), seconds=5)
        if identity is None or identity["parentPID"] != os.getpid():
            raise UIFailure("app-exited")
        self.identity = identity["identity"]
        launch["identity"] = self.identity
        if len(self.capture_worker(self.process, launch, seconds=5)) != 1:
            raise UIFailure("runtime-worker-identity-mismatch")
        launch["workerOwnershipEstablished"] = True
        UI.private_write(self.directory / (label + "-process.json"), launch)
        tree = UI.wait_for(self.inspect, lambda value: UI.visible_status(value, self.screens), seconds=20)
        if tree.get("activationPolicy") != 1:
            raise UIFailure("accessory-policy-required")
        self.peek(["see", "--mode", "screen", "--no-elements", "--no-remote",
                   "--path", str(self.directory / (label + "-before.png"))], label + "-before.json")
        self.press("vikingbar.status")
        return UI.wait_for(self.inspect, lambda value: any(item.get("AXRole") == "AXPopover"
                                                         for item in value.get("elements", [])), seconds=20)

    def phase(self, phase, credentials=None):
        self.phase_number = getattr(self, "phase_number", 0) + 1
        label = str(self.phase_number).zfill(2) + "-" + phase
        payload = {"account": self.account_selector, "root": self.account_root, "phase": phase,
                   "timeout_seconds": self.config["timeout_seconds"]}
        if credentials is not None:
            payload["credentials"] = credentials
        protocol_check = getattr(self, "protocol_check", self.check)
        command = [str(self.cli), "proof", protocol_check]
        options = {"input": json.dumps(payload).encode(), "env": WRAPPER.child_environment(self.environment),
                   "capture_output": True, "check": False, "timeout": self.config["timeout_seconds"] + 60}
        if self.execute is subprocess.run:
            result = self.owned_phase(command, options, label)
        else:
            result = self.execute(command, **options)
        try:
            safe = validate_provider(json.loads(result.stdout), protocol_check, phase, self.account_selector)
        except (ValueError, TypeError, UnicodeDecodeError):
            raise UIFailure("session-recovery-receipt-invalid") from None
        if result.returncode != (0 if safe["passed"] else 1):
            raise UIFailure("session-recovery-receipt-invalid")
        UI.private_write(self.directory / (phase + "-receipt.json"), safe)
        UI.private_write(self.directory / (label + "-receipt.json"), safe)
        return safe

    def owned_phase(self, command, options, phase):
        executable_hash = hashlib.sha256(self.cli.read_bytes()).hexdigest()
        process = subprocess.Popen(command, cwd=ROOT, env=options["env"], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.phase_processes.append(process)
        identity = None
        recorded = False
        try:
            identity = UI.process_identity(process.pid)
            if (identity is None or identity["parentPID"] != os.getpid()
                    or identity["command"] != " ".join(command)):
                raise UIFailure("proof-cli-ownership-unverified")
            identity["executableSHA256"] = executable_hash
            UI.private_write(self.directory / (phase + "-cli-process.json"), identity)
            recorded = True
            output, errors = process.communicate(options["input"], timeout=options["timeout"])
        except BaseException:
            try:
                if process.stdin is not None and not process.stdin.closed:
                    process.stdin.close()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    current = UI.process_identity(process.pid)
                    if not recorded or current is None:
                        raise UIFailure("proof-cli-ownership-unverified") from None
                    if (current["identity"] != identity["identity"]
                            or hashlib.sha256(self.cli.read_bytes()).hexdigest() != executable_hash):
                        raise UIFailure("proof-cli-ownership-unverified") from None
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        current = UI.process_identity(process.pid)
                        if current is None or current["identity"] != identity["identity"]:
                            raise UIFailure("proof-cli-ownership-unverified") from None
                        process.kill()
                        process.wait(timeout=10)
            finally:
                process.stdout.close()
                process.stderr.close()
            raise
        identity["exited"] = True
        identity["returncode"] = process.returncode
        UI.private_write(self.directory / (phase + "-cli-process.json"), identity)
        return subprocess.CompletedProcess(command, process.returncode, output, errors)

    def cleanup(self):
        super().cleanup()
        for process in self.phase_processes:
            if process.stdin is not None and not process.stdin.closed:
                process.stdin.close()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                raise UIFailure("proof-cli-ownership-unverified") from None

    def matched(self, label, after=None):
        expanded = False
        def observe():
            nonlocal expanded
            try:
                report = self.run([str(self.cli), "live", "--cached"], label + "-report.json")
            except UIFailure as error:
                if str(error) == "session-busy":
                    return None
                raise
            if after is not None:
                timestamp = (HOME.home_timestamp(report, self.account_selector) if self.check.startswith("telenet-")
                             else UI.successful_timestamp(report))
                if timestamp <= after:
                    return None
            tree = self.inspect(label + "-card.json")
            if (not expanded and not self.check.startswith("telenet-")
                    and any(item.get("AXIdentifier") == "vikingbar.bundleDetails" for item in tree.get("elements", []))
                    and not any(item.get("AXIdentifier") == "vikingbar.bundleDescription"
                                for item in tree.get("elements", []))):
                expanded = True
                self.press("vikingbar.bundleDetails")
                return None
            if (not expanded and self.check.startswith("telenet-")
                    and any(item.get("AXIdentifier") == "vikingbar.home.details" for item in tree.get("elements", []))
                    and not any(item.get("AXIdentifier") == "vikingbar.home.fetched" for item in tree.get("elements", []))):
                expanded = True
                self.press("vikingbar.home.details")
                return None
            try:
                if not self.check.startswith("telenet-"):
                    UI.compare_menu(tree, report, self.screens)
                else:
                    HOME.compare_home(tree, report, self.screens, self.account_selector)
            except UIFailure:
                return None
            return report
        report = UI.wait_for(observe, lambda value: value is not None, seconds=60)
        self.verify_worker(label)
        if UI.connection_identity(report)[1] != self.expected_connection:
            raise UIFailure("recovery-connection-mismatch")
        context = report["state"]["account"]["key"]
        if context["provider"] + "/" + str(uuid.UUID(context["slot"])) != self.account_selector:
            raise UIFailure("recovery-account-mismatch")
        if any(item.get("AXIdentifier") == "vikingbar.connect.password"
               for item in self.inspect(label + "-before-capture.json").get("elements", [])):
            raise UIFailure("direct-form-capture-forbidden")
        self.capture_suppressed = False
        stability = UI.UI.CapturePopoverStability()
        settled = UI.wait_for(lambda: stability.observe(self.inspect(label + "-capture.json"), self.screens,
                                                       self.process.pid), lambda value: value is not None, seconds=10)
        _, window = settled
        UI.UI.capture_exact_window(self.peekaboo, self.process.pid, window["kCGWindowNumber"],
                                   self.directory / (label + "-card.png"),
                                   lambda arguments: self.run(arguments, label + "-image.json"))
        return report

    def prepare(self):
        require_permissions(self.peek(["permissions", "status", "--all-sources"], "permissions.json"))
        apps = self.peek(["app", "list", "--include-hidden", "--include-background"], "apps-before.json")
        if UI.UI.live_bundle_processes(apps, "be.bram.vikingbar"):
            raise UIFailure("existing-app-must-be-quit")
        self.run(["./Scripts/package-app.sh"], timeout=300)
        self.run(["swiftc", "Scripts/inspect-ui.swift", "-o", ".build/inspect-ui"], timeout=120)
        self.executable_hash = hashlib.sha256(self.executable.read_bytes()).hexdigest()
        self.screens = self.peek(["screen", "list"], "screens.json")["screens"]


def credential_once(config, environment, execute):
    session = execute(["tmux", "display-message", "-p", "#{session_name} #{pane_pid}"], capture_output=True,
                      timeout=5, check=False, env=WRAPPER.child_environment(environment) | {"TMUX": environment["TMUX"]})
    parts = session.stdout.decode().strip().split()
    if session.returncode or len(parts) != 2 or parts[0] != config["tmux_session"] or not parts[1].isdigit():
        raise UIFailure("named-tmux-session-required")
    ancestor = os.getpid()
    for _ in range(64):
        if ancestor == int(parts[1]):
            break
        identity = UI.process_identity(ancestor)
        if identity is None or identity["parentPID"] <= 1:
            raise UIFailure("named-tmux-session-required")
        ancestor = identity["parentPID"]
    else:
        raise UIFailure("named-tmux-session-required")
    op_binary = shutil.which("op", path=environment.get("PATH"))
    if not op_binary:
        raise UIFailure("one-password-cli-required")
    reference = config["reference"]
    op_environment = WRAPPER.child_environment(environment)
    op_environment["OP_SERVICE_ACCOUNT_TOKEN"] = environment["BRAM_OP_SERVICE_ACCOUNT_TOKEN"]
    try:
        item = execute([op_binary, "item", "get", reference["item_id"], "--vault", reference["vault"],
                       "--format", "json"], env=op_environment, capture_output=True, timeout=60, check=False)
    except subprocess.TimeoutExpired:
        raise UIFailure("credential-read-timeout") from None
    if item.returncode:
        raise UIFailure("credential-read-failed")
    decode = WRAPPER.telenet_credentials if config["check"].startswith("telenet-") else WRAPPER.extract_credentials
    credentials = decode(item.stdout)
    del item
    return credentials


def run(check, environment, execute=subprocess.run):
    config = configuration(check, environment)
    proof = RecoveryNative(check, environment, config, execute)
    receipt = {"schema_version": 1, "check": check, "passed": False,
               "stages": dict.fromkeys(STAGES, False), "failure": "none"}
    old_umask = os.umask(0o077)
    core_limit = resource.getrlimit(resource.RLIMIT_CORE)
    attempted = False
    previous_handler = signal.getsignal(signal.SIGTERM)
    def terminate(_signum, _frame):
        raise UI.ProofTerminated()
    try:
        signal.signal(signal.SIGTERM, terminate)
        resource.setrlimit(resource.RLIMIT_CORE, (0, core_limit[1]))
        proof.prepare()
        configuration(check, environment)
        prepared = proof.phase("prepare")
        attempted = prepared["owned"]
        if not prepared["passed"] or not attempted:
            raise UIFailure("owned-record-preparation-failed")
        credentials = credential_once(config, environment, execute)
        provider = proof.phase("exercise", credentials)
        del credentials
        if not provider["passed"]:
            receipt["failure"] = "provider-failed"
        usable = all(provider[key] for key in ("owned", "bootstrap", "restored", "recovered", "usage"))
        if check != "mobile-session-recovery":
            usable = usable and all(provider[key] for key in ("remembered", "savedSignIn", "serviceRetained"))
        if usable:
            receipt["stages"]["provider"] = provider["passed"]
            proof.expected_connection = provider["connection_sha256"]
            proof.launch(label="recovered")
            proof.matched("recovered")
            receipt["stages"]["native"] = True
            proof.quit()
            proof.launch(label="relaunch")
            proof.matched("relaunch")
            receipt["stages"]["relaunch"] = True
            oracle = "telenet-home-api" if check == "telenet-remembered-sign-in" else "balance-api"
            def api_check():
                try:
                    result = json.loads(proof.run([str(proof.cli), "proof", oracle], timeout=180))
                    return (HOME.validate_api_receipt if check == "telenet-remembered-sign-in"
                            else UI.validate_api_receipt)(result)
                except UIFailure as error:
                    if str(error) == "session-busy":
                        return None
                    raise
            result = UI.wait_for(api_check, lambda value: value is not None, seconds=30)
            UI.private_write(proof.directory / "independent-usage.json", result)
            receipt["stages"]["independent_usage"] = True
            proof.quit()
            disabled = proof.phase("disable")
            if not disabled["passed"]:
                raise UIFailure("disable-remembered-sign-in-failed")
            inspected = proof.phase("inspect")
            if not inspected["disabled"] or inspected["loggedOut"]:
                raise UIFailure("disabled-sign-in-restore-failed")
            receipt["stages"]["option_off"] = True
            logged_out = proof.phase("logout")
            inspected = proof.phase("inspect")
            if not logged_out["passed"] or not inspected["loggedOut"]:
                raise UIFailure("logout-restore-failed")
            proof.launch(label="logout")
            tree = proof.inspect("logout-card.json")
            if not any(item.get("AXIdentifier") == "vikingbar.connect.direct" for item in tree.get("elements", [])):
                raise UIFailure("logout-native-state-mismatch")
            proof.quit()
            receipt["stages"]["logout"] = True
    except (Exception, UI.ProofTerminated) as error:
        code = str(error) if isinstance(error, (UIFailure, WRAPPER.ProofFailure)) else "runner-failed"
        allowed = {"native-permissions-denied", "existing-app-must-be-quit", "credential-read-failed",
                   "credential-read-timeout",
                   "named-tmux-session-required", "one-password-cli-required", "session-recovery-receipt-invalid",
                   "runtime-worker-identity-mismatch", "recovery-connection-mismatch", "recovery-account-mismatch",
                   "logout-native-state-mismatch", "runner-failed"}
        UI.private_write(proof.directory / "failure.json", {"passed": False,
                         "error": code if code in allowed else "native-stage-failed"})
        receipt["failure"] = "native-failed"
    finally:
        try:
            proof.cleanup()
            if attempted:
                cleanup = proof.phase("logout")
                if not cleanup["passed"]:
                    raise UIFailure("owned-record-cleanup-failed")
            receipt["stages"]["cleanup"] = True
        except Exception:
            receipt["failure"] = "cleanup-failed"
        resource.setrlimit(resource.RLIMIT_CORE, core_limit)
        os.umask(old_umask)
        signal.signal(signal.SIGTERM, previous_handler)
    receipt["passed"] = all(receipt["stages"].values()) and receipt["failure"] == "none"
    UI.private_write(proof.directory / "result.json", receipt)
    return validate_final(receipt, check)


class SetupNative(RecoveryNative):
    def connect_form(self, credentials):
        self.press("vikingbar.connect.direct")
        form, boundary = self.wait_for_direct_form()
        ids = {item.get("AXIdentifier"): item for item in form.get("elements", []) if UI.contained(item, boundary)}
        required = {"username", "password", "submit", "cancel", "remember-password"}
        if not self.check.startswith("telenet-"):
            required.add("client-id")
        if (not all("vikingbar.connect." + name in ids for name in required)
                or any(ids["vikingbar.connect." + name].get("valueEmpty") is not True
                       for name in required & {"client-id", "username", "password"})
                or str(ids["vikingbar.connect.remember-password"].get("AXValue")) not in {"0", "false", "False"}
                or (self.check.startswith("telenet-") and "vikingbar.connect.client-id" in ids)):
            raise UIFailure("native-direct-form-not-visible")
        self.capture_suppressed = True
        fill = self.execute([str(ROOT / ".build/inspect-ui"), str(self.process.pid), "fill-direct"],
                            input=json.dumps(credentials).encode(), env=WRAPPER.child_environment(self.environment),
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10, check=False)
        if fill.returncode or fill.stdout.strip() != b'{"filled":true}':
            raise UIFailure("native-direct-fill-failed")
        self.launch_record["connectOwnershipRequired"] = True
        self.launch_record["connectOwnershipEstablished"] = False
        self.press("vikingbar.connect.submit")
        child = self.capture_direct_child(self.launch_record, acknowledge=True, seconds=10)
        path = self.directory / "connect-result.json"
        UI.wait_for(path.exists, bool, seconds=170)
        receipt = UI.validate_connect_receipt(json.loads(path.read_bytes()))
        UI.wait_for(lambda: self.worker_present(child), lambda present: not present, seconds=10)
        UI.private_write(self.directory / "direct-input.json", {"credentialReads": 1, "privatePipe": True,
                         "formCaptureSkipped": True, "appCredentialReference": False, "processExecRestricted": True})
        self.expected_connection = receipt["connection_sha256"]
        return receipt


def run_setup(check, environment, execute=subprocess.run):
    config = configuration(check, environment)
    proof = SetupNative(check, environment, config, execute)
    stages = ("native_connect", "native_values", "independent_usage", "native_refresh", "stored_relaunch",
              "release_relaunch", "cleanup")
    if check == "telenet-home-ui":
        stages += ("provider_switching", "native_history")
    receipt = {"schema_version": 1, "check": check, "passed": False,
               "stages": dict.fromkeys(stages, False), "failure": "none"}
    old_umask = os.umask(0o077)
    limits = resource.getrlimit(resource.RLIMIT_CORE)
    owned = False
    previous_handler = signal.getsignal(signal.SIGTERM)
    def terminate(_signum, _frame):
        raise UI.ProofTerminated()
    try:
        signal.signal(signal.SIGTERM, terminate)
        resource.setrlimit(resource.RLIMIT_CORE, (0, limits[1]))
        proof.prepare()
        configuration(check, environment)
        prepared = proof.phase("prepare")
        owned = prepared["owned"]
        if not prepared["passed"] or not owned:
            raise UIFailure("owned-record-preparation-failed")
        credentials = credential_once(config, environment, execute)
        proof.launch(label="native-setup")
        proof.connect_form(credentials)
        del credentials
        receipt["stages"]["native_connect"] = True
        report = proof.matched("connected")
        receipt["stages"]["native_values"] = True
        home = check.startswith("telenet-")
        if home:
            floor = HOME.home_timestamp(report, proof.account_selector) + datetime.timedelta(seconds=61)
            while datetime.datetime.now(datetime.timezone.utc) < floor:
                proof.verify_process()
                time.sleep(1)
        oracle = "telenet-home-api" if home else "balance-api"
        def api_check():
            try:
                result = json.loads(proof.run([str(proof.cli), "proof", oracle], timeout=180))
                return (HOME.validate_api_receipt if home else UI.validate_api_receipt)(result)
            except UIFailure as error:
                if str(error) == "session-busy":
                    return None
                raise
        result = UI.wait_for(api_check, lambda value: value is not None, seconds=30)
        UI.private_write(proof.directory / "independent-usage.json", result)
        receipt["stages"]["independent_usage"] = True
        def after_api_timestamp():
            try:
                report = proof.run([str(proof.cli), "live", "--cached"], "after-api-report.json")
                return HOME.home_timestamp(report, proof.account_selector) if home else UI.successful_timestamp(report)
            except UIFailure as error:
                if str(error) == "session-busy":
                    return None
                raise
        stamp = UI.wait_for(after_api_timestamp, lambda value: value is not None, seconds=30)
        if home:
            floor = stamp + datetime.timedelta(seconds=61)
            while datetime.datetime.now(datetime.timezone.utc) < floor:
                proof.verify_process()
                time.sleep(1)
        else:
            time.sleep(1.1)
        proof.press("vikingbar.refresh")
        proof.matched("refreshed", after=stamp)
        receipt["stages"]["native_refresh"] = True
        proof.quit()
        proof.launch(label="stored-session")
        proof.matched("stored-session")
        receipt["stages"]["stored_relaunch"] = True
        proof.quit()
        proof.run(["python3", "Scripts/package-artifacts.py", "--app-only", "--configuration", "release",
                   "--output", str(proof.bundle)], timeout=300)
        proof.executable_hash = hashlib.sha256(proof.executable.read_bytes()).hexdigest()
        proof.launch(label="release-relaunch")
        proof.matched("release-relaunch")
        receipt["stages"]["release_relaunch"] = True
        proof.quit()
        if home:
            receipt["failure"] = "isolated-provider-switching-and-history-unverified"
    except (Exception, UI.ProofTerminated) as error:
        receipt["failure"] = "native-setup-failed"
        code = str(error) if isinstance(error, UIFailure) else "runner-failed"
        UI.private_write(proof.directory / "failure.json", {"passed": False,
                         "error": code if re.fullmatch(r"[a-z-]{1,80}", code) else "runner-failed"})
    finally:
        try:
            proof.cleanup()
            if owned and not proof.phase("logout")["passed"]:
                raise UIFailure("owned-record-cleanup-failed")
            receipt["stages"]["cleanup"] = True
        except Exception:
            receipt["failure"] = "cleanup-failed"
        resource.setrlimit(resource.RLIMIT_CORE, limits)
        os.umask(old_umask)
        signal.signal(signal.SIGTERM, previous_handler)
    receipt["passed"] = all(receipt["stages"].values()) and receipt["failure"] == "none"
    UI.private_write(proof.directory / "result.json", receipt)
    return receipt
