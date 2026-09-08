#!/usr/bin/env python3
"""Private, fail-closed native balance proof. Run only with live authorization."""
import datetime
import hashlib
import importlib.util
import json
import math
import os
import signal
from pathlib import Path
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
CONNECT_SPEC = importlib.util.spec_from_file_location("connect_account", ROOT / "Scripts/connect-account.py")
CONNECT = importlib.util.module_from_spec(CONNECT_SPEC)
CONNECT_SPEC.loader.exec_module(CONNECT)


class UIFailure(Exception):
    """Fixed public diagnostic."""


def private_write(path, value):
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    with os.fdopen(os.open(path, flags, 0o600), "w") as stream:
        json.dump(value, stream, sort_keys=True)


def frame(element):
    try:
        (x, y), (width, height) = element["frame"]
        values = (x, y, width, height)
        if (all(type(value) in (int, float) and math.isfinite(value) for value in values)
                and width > 0 and height > 0 and math.isfinite(x + width) and math.isfinite(y + height)):
            return values
    except (KeyError, TypeError, ValueError, OverflowError):
        pass
    raise UIFailure("native-frame-invalid")


def contained(element, boundary):
    try:
        x, y, width, height = frame(element)
        bx, by, bw, bh = frame(boundary)
        return x >= bx and y >= by and x + width <= bx + bw and y + height <= by + bh
    except UIFailure:
        return False


def display_frames(screens):
    displays = []
    for screen in screens:
        try:
            bounds = screen["bounds"]
            display = {"frame": [[bounds["x"], bounds["y"]], [bounds["width"], bounds["height"]]]}
            frame(display)
            displays.append(display)
        except (KeyError, TypeError, UIFailure):
            pass
    return displays


def visible_status(tree, screens):
    displays = display_frames(screens)
    return any(element.get("AXIdentifier") == "vikingbar.status"
               and any(contained(element, display) for display in displays)
               for element in tree.get("elements", []))


def popover_window(tree, screens):
    displays = display_frames(screens)
    for element in tree.get("elements", []):
        if element.get("AXRole") != "AXPopover":
            continue
        try:
            ax_frame = frame(element)
        except UIFailure:
            continue
        for window in tree.get("windows", []):
            try:
                bounds = window["kCGWindowBounds"]
                cg_element = {"frame": [[bounds["X"], bounds["Y"]], [bounds["Width"], bounds["Height"]]]}
                cg_frame = frame(cg_element)
            except (KeyError, TypeError, UIFailure):
                continue
            if (all(abs(ax - cg) < 1 for ax, cg in zip(ax_frame, cg_frame))
                    and any(contained(element, display) and contained(cg_element, display) for display in displays)):
                return element, window
    raise UIFailure("native-popover-not-visible")


def successful_timestamp(report):
    try:
        state = report["state"]
        snapshot = report["snapshot"]
        if (report["schemaVersion"] != 1 or state["snapshot"] != snapshot
                or not state.get("connectionID") or state.get("failure") or state.get("isRefreshing")
                or not state.get("balance") or "live" not in snapshot["source"]
                or state.get("selectedSubscriptionID") is None or state.get("selectedBundleIndex") is None
                or report.get("error")):
            raise ValueError()
        timestamp = snapshot["freshness"]["current"]["lastUpdated"]
        return datetime.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except (KeyError, TypeError, ValueError, AttributeError):
        raise UIFailure("live-report-invalid") from None


def compare_menu(tree, report, screens):
    successful_timestamp(report)
    if not visible_status(tree, screens):
        raise UIFailure("status-not-visible")
    boundary, _ = popover_window(tree, screens)
    menu = report["menu"]
    elements = tree.get("elements", [])
    card_elements = [element for element in elements if contained(element, boundary)]
    status_elements = [element for element in elements
                       if visible_status({"elements": [element]}, screens)]
    expected = dict(menu)
    titles = [item for item in elements if item.get("AXIdentifier") == "vikingbar.balanceTitle"]
    if titles:
        if len(titles) != 1:
            raise UIFailure("native-menu-mismatch")
        title_values = [titles[0].get(key) for key in ("AXTitle", "AXValue", "AXDescription")]
        if "Data used" in title_values:
            expected["balanceTitle"] = "Data used"
            if menu["usedText"] == "Usage unavailable":
                expected["remainingText"] = "Unavailable"
            elif menu["usedText"].endswith(" used"):
                expected["remainingText"] = menu["usedText"][:-5]
            else:
                raise UIFailure("native-menu-mismatch")
        elif menu["balanceTitle"] not in title_values:
            raise UIFailure("native-menu-mismatch")
    expected["accessibilityLabel"] = f'{menu["accessibilityLabel"]}, {menu["title"]}, {menu["freshnessText"]}'
    for identifier, field in (("vikingbar.remaining", "remainingText"),
                              ("vikingbar.freshness", "freshnessText"),
                              ("vikingbar.status", "accessibilityLabel")):
        candidates = status_elements if identifier == "vikingbar.status" else card_elements
        matches = [element for element in candidates if element.get("AXIdentifier") == identifier]
        if not any(expected[field] in [element.get(key) for key in ("AXTitle", "AXValue", "AXDescription")]
                   for element in matches):
            raise UIFailure("native-menu-mismatch")
    visible_text = {element.get(key) for element in card_elements
                    for key in ("AXTitle", "AXValue", "AXDescription") if isinstance(element.get(key), str)}
    for field in ("title", "balanceTitle", "usedText", "totalText", "expiryText", "sourceLabel"):
        if expected[field] not in visible_text:
            raise UIFailure("native-menu-mismatch")
    for text in report["balanceDetails"].values():
        if text and text not in visible_text:
            raise UIFailure("native-balance-details-mismatch")
    if "FIXTURE" in menu["sourceLabel"]:
        raise UIFailure("fixture-is-not-live-proof")


def validate_api_receipt(value):
    if (not isinstance(value, dict)
            or set(value) != {"schema_version", "check", "passed", "api_matches", "token_refreshed", "bundle_count"}
            or type(value["schema_version"]) is not int or value["schema_version"] != 1
            or value["check"] != "balance-api"
            or any(value[key] is not True for key in ("passed", "api_matches", "token_refreshed"))
            or type(value["bundle_count"]) is not int or value["bundle_count"] < 1):
        raise UIFailure("api-proof-receipt-invalid")
    return value


def validate_connect_receipt(value):
    code = CONNECT.failure_code(value)
    if code:
        raise UIFailure("native-connect-" + code)
    try:
        CONNECT.validate_receipt(value)
    except CONNECT.ConnectFailure:
        raise UIFailure("native-connect-failed") from None


def wait_for(operation, predicate, seconds=90):
    deadline = time.monotonic() + seconds
    while True:
        value = operation()
        if predicate(value):
            return value
        if time.monotonic() >= deadline:
            raise UIFailure("native-proof-timeout")
        time.sleep(0.25)


def process_identity(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "pid=,ppid=,lstart=,command="],
                            capture_output=True, timeout=5, check=False,
                            env={"PATH": os.defpath, "LC_ALL": "C"})
    if result.returncode == 1 and not result.stdout.strip():
        return None
    row = result.stdout.decode().strip()
    parts = row.split(None, 7)
    if (result.returncode or len(parts) != 8 or parts[0] != str(pid)
            or not parts[1].isdigit() or len(row.splitlines()) != 1):
        raise UIFailure("cleanup-process-inspection-failed")
    return {"pid": pid, "parentPID": int(parts[1]), "startTime": " ".join(parts[2:7]),
            "command": parts[7], "identity": row}


class NativeProof:
    def __init__(self, environment, *, stored_session=False):
        self.environment = environment
        self.peekaboo = environment.get("PEEKABOO_BIN")
        if not self.peekaboo or not Path(self.peekaboo).is_file():
            raise UIFailure("configured-peekaboo-required")
        self.reference = None
        if not stored_session:
            reference = environment.get("VIKINGBAR_CREDENTIAL_REFERENCE", "")
            if not Path(reference).is_file():
                raise UIFailure("credential-reference-required")
            self.reference = str(Path(reference).resolve())
        self.directory = ROOT / ".build/proof" / uuid.uuid4().hex
        self.directory.mkdir(parents=True, mode=0o700)
        self.bundle = ROOT / ".build/app/VikingBar.app"
        self.executable = self.bundle / "Contents/MacOS/VikingBarApp"
        self.cli = self.bundle / "Contents/MacOS/vikingbar"
        self.process = None
        self.launches = []
        self.workers = []
        self.launch_record = None
        self.identity = None
        self.screens = []

    def run(self, command, name=None, timeout=120):
        clean = {key: self.environment[key] for key in ("PATH", "TMPDIR", "LANG", "LC_ALL")
                 if key in self.environment}
        result = subprocess.run(command, cwd=ROOT, env=clean, capture_output=True, timeout=timeout, check=False)
        if result.returncode:
            try:
                failure = json.loads(result.stdout)
                if failure == {"passed": False, "error": "session-busy"}:
                    raise UIFailure("session-busy")
            except ValueError:
                pass
            raise UIFailure("proof-command-failed")
        if name:
            try:
                value = json.loads(result.stdout)
            except ValueError:
                raise UIFailure("proof-json-invalid") from None
            private_write(self.directory / name, value)
            return value
        return result.stdout

    def peek(self, command, name):
        value = self.run([self.peekaboo, *command, "--json"], name)
        if value.get("success") is not True:
            raise UIFailure("peekaboo-failed")
        return value["data"]

    def inspect(self, name="card.json"):
        self.verify_process()
        return self.run([str(ROOT / ".build/inspect-ui"), str(self.process.pid)], name)

    def press(self, identifier):
        self.verify_process()
        self.run([str(ROOT / ".build/inspect-ui"), str(self.process.pid), "press", identifier],
                 "press-" + identifier + ".json")

    def verify_process(self):
        if self.process is None or self.process.poll() is not None:
            raise UIFailure("app-exited")
        identity = process_identity(self.process.pid)
        if (identity is None or identity["identity"].split() != self.identity.split()
                or str(self.executable) not in identity["command"]):
            raise UIFailure("process-identity-changed")
        if hashlib.sha256(self.executable.read_bytes()).hexdigest() != self.executable_hash:
            raise UIFailure("running-artifact-changed")

    def launch(self, first, label=None):
        arguments = [str(self.executable), "--proof-directory", str(self.directory)]
        if first:
            arguments += ["--credential-reference", self.reference]
        clean = {key: self.environment[key] for key in ("PATH", "TMPDIR", "LANG", "LC_ALL")
                 if key in self.environment}
        self.process = subprocess.Popen(arguments, cwd=ROOT, env=clean,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        label = label or ("initial" if first else "resumed")
        self.launch_record = {
            "pid": self.process.pid, "parentPID": os.getpid(), "arguments": arguments,
            "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "executableSHA256": self.executable_hash, "workerOwnershipEstablished": False}
        self.launches.append((self.process, self.launch_record))
        identity = process_identity(self.process.pid)
        if identity is None:
            raise UIFailure("app-exited")
        self.identity = identity["identity"]
        self.launch_record.update(identity=self.identity, cli=str(self.cli),
                                  cliSHA256=hashlib.sha256(self.cli.read_bytes()).hexdigest())
        workers = self.capture_worker(self.process, self.launch_record, seconds=3)
        if len(workers) != 1:
            raise UIFailure("runtime-worker-identity-mismatch")
        self.launch_record["workerOwnershipEstablished"] = True
        private_write(self.directory / (label + "-process.json"), self.launch_record)
        tree = wait_for(self.inspect, lambda value: visible_status(value, self.screens), seconds=20)
        if tree.get("activationPolicy") != 1:
            raise UIFailure("accessory-policy-required")
        self.peek(["see", "--mode", "screen", "--no-elements", "--path",
                   str(self.directory / (label + "-before.png"))], label + "-before.json")
        self.press("vikingbar.status")
        return wait_for(self.inspect, lambda value: any(
            item.get("AXIdentifier") == "vikingbar.remaining" for item in value.get("elements", [])))

    def matched_balance(self, label, after=None):
        def observe():
            try:
                report = self.run([str(self.cli), "live", "--cached"], label + "-report.json")
                timestamp = successful_timestamp(report)
                if after is not None and timestamp <= after:
                    return None
                tree = self.inspect(label + "-card.json")
                compare_menu(tree, report, self.screens)
                return report, tree
            except UIFailure:
                return None
        report, tree = wait_for(observe, lambda value: value is not None)
        self.verify_worker(label)
        _, window = popover_window(tree, self.screens)
        self.peek(["see", "--window-id", str(window["kCGWindowNumber"]), "--no-elements", "--no-remote",
                   "--path", str(self.directory / (label + "-card.png"))], label + "-image.json")
        return report

    def capture_worker(self, process, launch, seconds=0):
        deadline = time.monotonic() + seconds
        while process.poll() is None:
            current = process_identity(process.pid)
            if current is None or current["identity"].split() != launch.get("identity", "").split():
                raise UIFailure("process-identity-changed")
            children = subprocess.run(["pgrep", "-P", str(process.pid)], capture_output=True,
                                      timeout=5, check=False)
            if children.returncode not in (0, 1) or (children.returncode == 1 and children.stdout.strip()):
                raise UIFailure("runtime-worker-inspection-failed")
            pids = children.stdout.decode().split()
            if any(not pid.isdigit() for pid in pids):
                raise UIFailure("runtime-worker-inspection-failed")
            matches = []
            for pid in pids:
                worker = process_identity(int(pid))
                if (worker is not None and worker["parentPID"] == process.pid
                        and worker["command"] == launch["cli"] + " session"):
                    worker["cliSHA256"] = launch["cliSHA256"]
                    if not any(saved["pid"] == worker["pid"] and saved["startTime"] == worker["startTime"]
                               for saved in self.workers):
                        self.workers.append(worker)
                        private_write(self.directory / "workers.json", self.workers)
                    matches.append(worker)
            if matches or time.monotonic() >= deadline:
                return matches
            time.sleep(0.05)
        return []

    def verify_worker(self, label):
        self.verify_process()
        matches = self.capture_worker(self.process, self.launch_record)
        if len(matches) != 1:
            raise UIFailure("runtime-worker-identity-mismatch")
        private_write(self.directory / (label + "-worker.json"), matches[0])

    def quit(self):
        self.press("vikingbar.quit")
        self.process.wait(timeout=10)
        if self.process.returncode != 0:
            raise UIFailure("native-quit-failed")
        self.process = None

    def perform(self):
        self.peek(["permissions", "status", "--all-sources"], "permissions.json")
        apps = self.peek(["app", "list", "--include-hidden", "--include-background"], "apps-before.json")
        if "be.bram.vikingbar" in json.dumps(apps):
            raise UIFailure("existing-app-must-be-quit")
        self.run(["./Scripts/package-app.sh"], timeout=300)
        self.run(["swiftc", "Scripts/inspect-ui.swift", "-o", ".build/inspect-ui"], timeout=120)
        self.executable_hash = hashlib.sha256(self.executable.read_bytes()).hexdigest()
        initial_cli_hash = hashlib.sha256(self.cli.read_bytes()).hexdigest()
        self.screens = self.peek(["screen", "list"], "screens.json")["screens"]
        tree = self.launch(first=True)
        if not any(item.get("AXIdentifier") == "vikingbar.connect" for item in tree["elements"]):
            raise UIFailure("native-connect-missing")
        self.press("vikingbar.connect")
        self.capture_worker(self.process, self.launch_record)
        receipt_path = self.directory / "connect-result.json"
        wait_for(lambda: receipt_path.exists(), bool, seconds=170)
        connect_receipt = json.loads(receipt_path.read_text())
        self.capture_worker(self.process, self.launch_record)
        validate_connect_receipt(connect_receipt)
        ownership = json.loads((self.directory / "connect-result-ownership.json").read_text())
        if (ownership.get("parentPID") != self.process.pid
                or any(type(ownership.get(key)) is not int or ownership[key] <= 0
                       for key in ("helperPID", "serverPID", "panePID"))
                or not ownership.get("session", "").startswith("vikingbar-connect-")
                or ownership.get("cleanupAttempted") is not True
                or ownership.get("cliSHA256") != initial_cli_hash
                or ownership.get("helperSHA256") != hashlib.sha256(
                    (self.bundle / "Contents/Resources/connect-account.py").read_bytes()).hexdigest()):
            raise UIFailure("connect-ownership-invalid")
        initial = self.matched_balance("connected")
        def api_check():
            try:
                result = self.run([str(self.cli), "proof", "balance-api"], timeout=180)
                receipt = validate_api_receipt(json.loads(result))
                private_write(self.directory / "api-result.json", receipt)
                return receipt
            except UIFailure as error:
                if str(error) == "session-busy":
                    return None
                raise
        api = wait_for(api_check, lambda value: value is not None, seconds=30)
        validate_api_receipt(api)
        api_report = self.run([str(self.cli), "live", "--cached"], "after-api-report.json")
        time.sleep(1.1)
        self.press("vikingbar.refresh")
        refreshed = self.matched_balance("refreshed", successful_timestamp(api_report))
        receipt_bytes = receipt_path.read_bytes()
        receipt_modified = receipt_path.stat().st_mtime_ns
        self.quit()
        time.sleep(1.1)
        self.launch(first=False)
        resumed = self.matched_balance("resumed", successful_timestamp(refreshed))
        if (receipt_path.read_bytes() != receipt_bytes or receipt_path.stat().st_mtime_ns != receipt_modified
                or resumed["state"]["connectionID"] != initial["state"]["connectionID"]):
            raise UIFailure("resume-reconnected")
        self.quit()
        self.run(["python3", "Scripts/package-artifacts.py", "--app-only", "--configuration", "release",
                  "--output", str(self.bundle)], timeout=300)
        self.executable_hash = hashlib.sha256(self.executable.read_bytes()).hexdigest()
        if hashlib.sha256(self.cli.read_bytes()).hexdigest() == initial_cli_hash:
            raise UIFailure("rebuilt-cli-identity-unchanged")
        time.sleep(1.1)
        self.launch(first=False, label="rebuilt")
        rebuilt = self.matched_balance("rebuilt", successful_timestamp(resumed))
        if (receipt_path.read_bytes() != receipt_bytes or receipt_path.stat().st_mtime_ns != receipt_modified
                or rebuilt["state"]["connectionID"] != initial["state"]["connectionID"]):
            raise UIFailure("rebuild-reconnected")
        self.quit()
        receipt = {"schema_version": 1, "check": "balance-ui", "passed": True, "native_connect": True,
                   "api_matches": True, "native_refresh": True, "keychain_resume": True,
                   "keychain_rebuild": True, "visible_menu_matches": True}
        private_write(self.directory / "result.json", receipt)
        return receipt

    def worker_present(self, worker):
        current = process_identity(worker["pid"])
        if current is None or current["startTime"] != worker["startTime"]:
            return False
        if (current["command"] != worker["command"]
                or current["parentPID"] not in (worker["parentPID"], 1)):
            raise UIFailure("cleanup-worker-identity-changed")
        return True

    def stop_worker(self, worker):
        for action in (signal.SIGTERM, signal.SIGKILL):
            if not self.worker_present(worker):
                return
            try:
                os.kill(worker["pid"], action)
            except ProcessLookupError:
                pass
            deadline = time.monotonic() + 3
            while self.worker_present(worker):
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.05)
            else:
                return
        raise UIFailure("cleanup-worker-still-running")

    def cleanup(self):
        failures = []
        for process, launch in self.launches:
            if launch.get("workerOwnershipEstablished") is not True:
                failures.append(UIFailure("cleanup-worker-ownership-unverified"))
            if process.poll() is not None:
                continue
            if (launch["pid"] != process.pid or launch["parentPID"] != os.getpid()
                    or launch["arguments"] != process.args):
                failures.append(UIFailure("cleanup-ownership-unverified"))
                continue
            try:
                if launch.get("identity"):
                    self.capture_worker(process, launch)
            except Exception as error:
                failures.append(error)
            try:
                private_write(self.directory / "cleanup-process.json", launch)
            except Exception as error:
                failures.append(error)
            try:
                current = process_identity(process.pid)
                if current is not None and current["identity"].split() == launch.get("identity", "").split():
                    tree = self.run([str(ROOT / ".build/inspect-ui"), str(process.pid)], timeout=2)
                    if any(item.get("AXIdentifier") == "vikingbar.quit"
                           for item in json.loads(tree).get("elements", [])):
                        self.run([str(ROOT / ".build/inspect-ui"), str(process.pid), "press", "vikingbar.quit"],
                                 timeout=2)
                        process.wait(timeout=3)
            except Exception:
                pass
            try:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=10)
            except Exception as error:
                failures.append(error)
        for worker in self.workers:
            try:
                self.stop_worker(worker)
            except Exception as error:
                failures.append(error)
        exited = all(process.poll() is not None for process, _launch in self.launches)
        for worker in self.workers:
            try:
                exited = not self.worker_present(worker) and exited
            except Exception as error:
                exited = False
                failures.append(error)
        receipt = {"exited": exited and not failures, "workers": self.workers,
                   "apps": [launch for _process, launch in self.launches]}
        if failures:
            receipt["error"] = str(failures[0]) if isinstance(failures[0], UIFailure) else "cleanup-failed"
        private_write(self.directory / "cleanup.json", receipt)
        if failures:
            raise failures[0]
        if not exited:
            raise UIFailure("cleanup-process-still-running")


def run(environment):
    old_mask = os.umask(0o077)
    proof = None
    try:
        proof = NativeProof(environment)
        return proof.perform()
    finally:
        try:
            if proof is not None:
                proof.cleanup()
        finally:
            os.umask(old_mask)


def main():
    try:
        receipt = run(os.environ)
        code = 0
    except UIFailure as error:
        receipt, code = {"passed": False, "error": str(error)}, 1
    except Exception:
        receipt, code = {"passed": False, "error": "balance-ui-proof-failed"}, 1
    print(json.dumps(receipt, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
