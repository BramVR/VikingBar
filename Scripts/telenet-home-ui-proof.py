#!/usr/bin/env python3
"""Private native Telenet home proof with one connection and stored-session reads."""
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import resource
import signal
import time
import uuid

SPEC = importlib.util.spec_from_file_location("balance_ui", Path(__file__).with_name("balance-ui-proof.py"))
UI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UI)
HISTORY_SPEC = importlib.util.spec_from_file_location("telenet_history_ui", Path(__file__).with_name("telenet-history-ui.py"))
HISTORY = importlib.util.module_from_spec(HISTORY_SPEC)
HISTORY_SPEC.loader.exec_module(HISTORY)
UIFailure = UI.UIFailure
ROOT = UI.ROOT
FIELDS = {
    "periodText": "period", "categoryText": "category", "policyCounterText": "policy-counter",
    "allocationText": "allocation", "downloadedText": "downloaded", "peakText": "peak",
    "offPeakText": "off-peak", "speedText": "speed", "providerUpdatedText": "provider-updated",
    "fetchedText": "fetched",
}


def selector(key):
    try:
        provider = key["provider"]
        if provider not in {"mobile-vikings", "telenet"}:
            raise ValueError()
        return provider + "/" + str(uuid.UUID(key["slot"]))
    except (KeyError, ValueError, TypeError, AttributeError):
        raise UIFailure("account-identity-invalid") from None


def home_timestamp(report, account, *, allow_stale=False):
    try:
        state = report["state"]
        home = state["homeUsage"]
        context = state["account"]
        key = home["key"]
        if (report["schemaVersion"] != 1 or report.get("error") or state.get("failure")
                or state.get("isRefreshing") or report["snapshot"] != state["snapshot"]
                or "live" not in report["snapshot"]["source"]
                or selector(context["key"]) != account or selector(key["account"]) != account
                or key["kind"] != "home" or context["selectedService"] != key
                or home["connectionID"] != state["connectionID"]
                or state.get("balance") is not None or state.get("subscriptions")
                or not any(service["key"] == key for service in context["services"])
                or set(report["home"]) != set(FIELDS)
                or any(not isinstance(value, str) or not value for value in report["home"].values())):
            raise ValueError()
        UI.connection_identity(report)
        fetched = datetime.datetime.fromisoformat(home["fetchedAt"].replace("Z", "+00:00"))
        freshness = report["snapshot"]["freshness"]
        if set(freshness) == {"current"}:
            label = "current"
        elif allow_stale and set(freshness) == {"stale"}:
            label = "stale"
        else:
            raise ValueError()
        fresh = datetime.datetime.fromisoformat(freshness[label]["lastUpdated"].replace("Z", "+00:00"))
        if fetched != fresh or fetched.tzinfo is None:
            raise ValueError()
        return fetched
    except (KeyError, ValueError, TypeError, AttributeError):
        raise UIFailure("telenet-home-report-invalid") from None


def match_text(tree, boundary, identifier, expected):
    matches = [item for item in tree.get("elements", [])
               if item.get("AXIdentifier") == identifier and UI.contained(item, boundary)]
    if not any(expected in [item.get(key) for key in ("AXTitle", "AXValue", "AXDescription")]
               for item in matches):
        raise UIFailure("telenet-native-value-mismatch")


def compare_home(tree, report, screens, account, *, allow_stale=False):
    home_timestamp(report, account, allow_stale=allow_stale)
    if not UI.visible_status(tree, screens):
        raise UIFailure("status-not-visible")
    boundary, _ = UI.popover_window(tree, screens)
    for field, suffix in FIELDS.items():
        match_text(tree, boundary, "vikingbar.home." + suffix, report["home"][field])
    menu = report["menu"]
    if "Telenet" not in menu["sourceLabel"] or "FIXTURE" in menu["sourceLabel"]:
        raise UIFailure("telenet-live-source-invalid")
    match_text(tree, boundary, "vikingbar.source", menu["sourceLabel"])
    statuses = [item for item in tree.get("elements", [])
                if UI.visible_status({"elements": [item]}, screens)]
    label = f'{menu["accessibilityLabel"]}, {menu["title"]}, {menu["freshnessText"]}'
    if not any(label in [item.get(key) for key in ("AXTitle", "AXValue", "AXDescription")]
               for item in statuses):
        raise UIFailure("telenet-native-status-mismatch")
    if any(item.get("AXIdentifier") in {"vikingbar.bundlePicker", "vikingbar.points", "vikingbar.bills"}
           and UI.contained(item, boundary) for item in tree.get("elements", [])):
        raise UIFailure("telenet-unsupported-capability-visible")


def validate_api_receipt(value):
    expected = {"schema_version", "check", "passed", "api_matches", "service_count",
                "daily_usage_matches", "daily_row_count", "daily_history_matches",
                "forecast_matches", "session_reused"}
    if (not isinstance(value, dict) or set(value) != expected or type(value["schema_version"]) is not int
            or value["schema_version"] != 1 or value["check"] != "telenet-home-api"
            or any(value[key] is not True for key in ("passed", "api_matches", "daily_usage_matches",
                                                       "daily_history_matches", "forecast_matches", "session_reused"))
            or type(value["service_count"]) is not int or not 1 <= value["service_count"] <= 8
            or type(value["daily_row_count"]) is not int or not 3 <= value["daily_row_count"] <= 62):
        raise UIFailure("telenet-api-receipt-invalid")
    return value


def initial_history_needs_refresh(report, now=None):
    try:
        observed_at = now or datetime.datetime.now(datetime.timezone.utc)
        home = report["state"]["homeUsage"]
        fetched = datetime.datetime.fromisoformat(home["fetchedAt"].replace("Z", "+00:00"))
        daily = home.get("dailyHistory")
        today = observed_at.astimezone(HISTORY.BRUSSELS).date().isoformat()
        if observed_at.tzinfo is None or fetched.tzinfo is None:
            raise ValueError()
        return (daily is None or daily["fetchedDay"] != today
                or report["state"].get("homeFailure") is not None
                or "stale" in report["snapshot"]["freshness"]
                or observed_at < fetched or (observed_at - fetched).total_seconds() >= 3600
                or any(day["isStale"] for day in report["historyPresentation"]["days"]))
    except (KeyError, TypeError, ValueError, AttributeError):
        raise UIFailure("telenet-history-report-invalid") from None


class TelenetHomeProof(UI.NativeProof):
    hover = HISTORY.HISTORY.HistoryProof.hover
    click = HISTORY.HISTORY.HistoryProof.click

    def __init__(self, environment):
        super().__init__(environment, stored_session=True)
        reference = environment.get("VIKINGBAR_TELENET_CREDENTIAL_REFERENCE", "")
        if not Path(reference).is_file():
            raise UIFailure("telenet-credential-reference-required")
        self.reference = str(Path(reference).resolve())
        self.original_selection = None
        self.telenet_account = None
        self.connection_digest = None
        self.resume_directory = environment.get("VIKINGBAR_TELENET_RESUME_DIRECTORY")

    def preserved_connection(self):
        try:
            path = Path(self.resume_directory).resolve()
            if not path.is_relative_to(ROOT / ".build/proof") or not path.is_dir():
                raise ValueError()
            entry = json.loads((path / "reserved-account.json").read_bytes())
            account = selector(entry["key"])
            if not account.startswith("telenet/"):
                raise ValueError()
            connected = UI.validate_connect_receipt(json.loads((path / "connect-result.json").read_bytes()))
            process = json.loads((path / "native-connect-process.json").read_bytes())
            ownership = json.loads((path / "connect-result-ownership.json").read_bytes())
            cleanup = json.loads((path / "cleanup.json").read_bytes())
            if (cleanup.get("exited") is not True or ownership.get("cleanupAttempted") is not True
                    or ownership.get("parentPID") != process["pid"]
                    or ownership.get("cliSHA256") != process["cliSHA256"]
                    or process.get("accountSelector") != account
                    or not ownership.get("session", "").startswith("vikingbar-connect-")):
                raise ValueError()
            self.telenet_account = account
            self.connection_digest = connected["connection_sha256"]
            UI.private_write(self.directory / "preserved-bootstrap.json", {
                "directory": str(path), "connection_sha256": self.connection_digest,
                "executable_sha256": process["executableSHA256"], "cli_sha256": process["cliSHA256"],
            })
        except (OSError, KeyError, TypeError, ValueError, UIFailure):
            raise UIFailure("telenet-preserved-bootstrap-invalid") from None

    def choose(self, identifier, value):
        self.verify_process()
        self.run([str(ROOT / ".build/inspect-ui"), str(self.process.pid), "choose", identifier, value],
                 "choose-" + identifier + ".json")

    def cached(self, label, account=None):
        return self.run([str(self.cli), "live", "--account", account or self.telenet_account, "--cached"],
                        label + "-report.json")

    def capture_home(self, label):
        stability = UI.UI.CapturePopoverStability()
        settled = UI.wait_for(lambda: stability.observe(self.inspect(label + "-capture-tree.json"),
                                                        self.screens, self.process.pid),
                              lambda value: value is not None, seconds=20)
        UI.UI.capture_exact_window(self.peekaboo, self.process.pid, settled[1]["kCGWindowNumber"],
                                   self.directory / (label + ".png"),
                                   lambda args: self.run(args, label + "-image.json"))

    def matched_home(self, label, after=None, *, allow_stale=False):
        opened = False
        expanded = False
        def observe():
            nonlocal opened, expanded
            try:
                report = self.cached(label)
            except UIFailure as error:
                if str(error) == "session-busy":
                    return None
                raise
            stamp = home_timestamp(report, self.telenet_account, allow_stale=allow_stale or after is not None)
            if self.connection_digest is not None and UI.connection_identity(report)[1] != self.connection_digest:
                raise UIFailure("telenet-connection-changed")
            if after is not None and stamp <= after:
                return None
            if after is not None and not allow_stale:
                home_timestamp(report, self.telenet_account)
            tree = self.inspect(label + "-card.json")
            ids = {item.get("AXIdentifier") for item in tree.get("elements", [])}
            if not tree.get("windows") and "vikingbar.status" in ids and not opened:
                opened = True
                self.press("vikingbar.status")
                return None
            if "vikingbar.home.details" in ids and "vikingbar.home.fetched" not in ids and not expanded:
                expanded = True
                self.press("vikingbar.home.details")
                return None
            try:
                compare_home(tree, report, self.screens, self.telenet_account, allow_stale=allow_stale)
            except UIFailure:
                return None
            return report
        report = UI.wait_for(observe, lambda value: value is not None, seconds=90)
        self.verify_worker(label)
        self.capture_home(label)
        return report

    def initial_history_report(self, report, now=None):
        if not initial_history_needs_refresh(report, now):
            HISTORY.validate_presentation(report, now)
            return report
        stamp = home_timestamp(report, self.telenet_account, allow_stale=True)
        self.wait_manual_floor(report, allow_stale=True)
        self.refresh_home()
        refreshed = self.matched_home("connected-home-fresh", stamp)
        HISTORY.validate_presentation(refreshed, now)
        return refreshed

    def compare_history_home(self, tree, report, screens):
        compare_home(tree, report, screens, self.telenet_account)
        HISTORY.validate_presentation(report)

    def panel_absent(self, label, report, companion_id=None):
        self.hover("vikingbar.refresh", label=label + "-pointer-out-hover.json")
        def observe():
            tree = self.inspect(label + "-panel-absent.json")
            if any(item.get("AXIdentifier") == "vikingbar.historyPanel" for item in tree.get("elements", [])):
                return False
            if companion_id is not None and any(window.get("kCGWindowNumber") == companion_id
                                                 for window in tree.get("windows", [])):
                return False
            try:
                self.compare_history_home(tree, report, self.screens)
                return True
            except (UIFailure, HISTORY.UIFailure):
                return False
        UI.wait_for(observe, bool)

    def history_open(self, label, report):
        previous = None
        count = 0
        def observe():
            nonlocal previous, count
            try:
                tree = self.inspect(label + "-detail-tree.json")
                windows = HISTORY.compare_companion(tree, report, self.screens, self.compare_history_home)
                identity = HISTORY.HISTORY.window_identity(windows)
            except (UIFailure, HISTORY.UIFailure):
                previous, count = None, 0
                return None
            count = count + 1 if identity == previous else 1
            previous = identity
            return (tree, windows) if count >= 2 else None
        return UI.wait_for(observe, lambda result: result is not None, seconds=90)

    def hover_history_day(self, label, report, index, baseline=None):
        days = report["historyPresentation"]["days"]
        plot = "vikingbar.historyPlot" if baseline else "vikingbar.historyMainPlot"
        self.hover(plot, HISTORY.HISTORY.chart_position(index, len(days)), 0.5, label=label + "-hover.json")
        def observe():
            try:
                tree = self.inspect(label + "-selected.json")
                if baseline is None:
                    HISTORY.compare_main(tree, report, self.screens, index, self.compare_history_home)
                else:
                    windows = HISTORY.compare_companion(tree, report, self.screens, self.compare_history_home)
                    if (HISTORY.HISTORY.window_identity(windows) != HISTORY.HISTORY.window_identity(baseline)
                            or HISTORY.HISTORY.selected_day(tree, report, windows) != index):
                        return None
                return tree
            except (UIFailure, HISTORY.UIFailure):
                return None
        return UI.wait_for(observe, lambda tree: tree is not None)

    def capture_history(self, label, report, windows, index):
        geometry = HISTORY.HISTORY
        group_frame = geometry.window_group_frame(windows)
        for key, suffix in (("parent", "main-target-group"), ("companion", "companion-target-group")):
            window = windows[key]["window"]
            path = self.directory / f"{label}-{suffix}.png"
            self.verify_process()
            receipt = UI.UI.capture_exact_window(
                self.peekaboo, self.process.pid, window["kCGWindowNumber"], path,
                lambda args, name=f"{label}-{suffix}-image.json": self.run(args, name))
            geometry.validate_capture_observation(receipt, window)
            geometry.validate_capture_geometry(path, group_frame)
            settled_tree = self.inspect(f"{label}-{suffix}-after-capture.json")
            settled = HISTORY.compare_companion(settled_tree, report, self.screens, self.compare_history_home)
            if (geometry.window_identity(settled) != geometry.window_identity(windows)
                    or geometry.selected_day(settled_tree, report, settled) != index):
                raise UIFailure("native-history-capture-mismatch")

    def prove_history(self, label, report):
        days = HISTORY.validate_presentation(report)["days"]
        self.panel_absent(label + "-prime", report)
        first, second = HISTORY.HISTORY.selection_indices(days)
        self.hover_history_day(label + "-main-first", report, first)
        main_tree = self.hover_history_day(label + "-main-second", report, second)
        geometry = HISTORY.HISTORY
        parent = HISTORY.compare_main(main_tree, report, self.screens, second, self.compare_history_home)
        window = parent["window"]
        path = self.directory / f"{label}-main-hover.png"
        receipt = UI.UI.capture_exact_window(self.peekaboo, self.process.pid, window["kCGWindowNumber"], path,
                                             lambda args: self.run(args, label + "-main-hover-image.json"))
        geometry.validate_capture_observation(receipt, window)
        geometry.validate_capture_geometry(path, geometry.window_frame(window))
        settled = self.inspect(label + "-main-hover-after-capture.json")
        current = HISTORY.compare_main(settled, report, self.screens, second, self.compare_history_home)
        if (current["window"]["kCGWindowNumber"] != window["kCGWindowNumber"]
                or not geometry.same_frame(current["frame"], parent["frame"])):
            raise UIFailure("native-history-capture-mismatch")
        self.click("vikingbar.historyMainPlot", geometry.chart_position(second, len(days)), 0.5,
                   label=label + "-open-click.json")
        tree, windows = self.history_open(label, report)
        if geometry.selected_day(tree, report, windows) != second:
            raise UIFailure("native-history-click-selection-mismatch")
        self.hover_history_day(label + "-detail-first", report, first, windows)
        selected = self.hover_history_day(label + "-detail-second", report, second, windows)
        if first == second or geometry.selected_day(selected, report, windows) != second:
            raise UIFailure("native-history-selection-insufficient")
        self.verify_worker(label)
        self.capture_history(label, report, windows, second)
        companion_id = windows["companion"]["window"]["kCGWindowNumber"]
        self.press("vikingbar.historyClose")
        self.panel_absent(label + "-closed", report, companion_id)

    def wait_manual_floor(self, report, *, allow_stale=False):
        deadline = home_timestamp(report, self.telenet_account, allow_stale=allow_stale) + datetime.timedelta(seconds=61)
        while datetime.datetime.now(datetime.timezone.utc) < deadline:
            self.verify_process()
            time.sleep(min(1, max(0, (deadline - datetime.datetime.now(datetime.timezone.utc)).total_seconds())))

    def refresh_home(self):
        def state(tree):
            if not UI.visible_status(tree, self.screens):
                raise UIFailure("telenet-refresh-status-not-visible")
            if not tree.get("windows"):
                return None
            try:
                boundary, _ = UI.popover_window(tree, self.screens)
            except UIFailure as error:
                if str(error) == "native-popover-not-visible":
                    return None
                raise
            controls = [item for item in tree.get("elements", [])
                        if item.get("AXIdentifier") == "vikingbar.refresh" and UI.contained(item, boundary)]
            fetched = [item for item in tree.get("elements", [])
                       if item.get("AXIdentifier") == "vikingbar.home.fetched" and UI.contained(item, boundary)]
            if (len(controls) != 1 or controls[0].get("AXRole") != "AXButton"
                    or controls[0].get("AXEnabled") not in (True, False, 1, 0, "1", "0", "true", "false")
                    or len(fetched) != 1 or fetched[0].get("AXRole") != "AXStaticText"):
                raise UIFailure("telenet-refresh-control-invalid")
            label = next((fetched[0].get(key) for key in ("AXValue", "AXDescription", "AXTitle")
                          if isinstance(fetched[0].get(key), str) and fetched[0][key]), None)
            if label is None:
                raise UIFailure("telenet-refresh-fetched-invalid")
            return label, controls[0]["AXEnabled"] in (True, 1, "1", "true")

        tree = self.inspect("refresh-readiness.json")
        if not tree.get("windows"):
            if not UI.visible_status(tree, self.screens):
                raise UIFailure("telenet-refresh-status-not-visible")
            self.press("vikingbar.status")
            before = UI.wait_for(lambda: state(self.inspect("refresh-opened.json")),
                                 lambda value: value is not None and value[1], seconds=20)
        else:
            before = state(tree)
        if before is None or not before[1]:
            raise UIFailure("telenet-refresh-control-invalid")
        self.press("vikingbar.refresh")
        UI.wait_for(lambda: state(self.inspect("refresh-settled.json")),
                    lambda value: value is not None and value[1] and value[0] != before[0], seconds=90)

    def switch_provider(self, provider, account):
        self.choose("vikingbar.providerPicker", provider)
        catalog = UI.wait_for(lambda: self.run([str(self.cli), "accounts", "list"], "switch-catalog.json"),
                              lambda value: value["selected"]["provider"] == account.split("/")[0])
        if selector(catalog["selected"]) != account:
            entry = next((entry for entry in catalog["accounts"] if selector(entry["key"]) == account), None)
            if entry is None:
                raise UIFailure("switch-account-missing")
            UI.wait_for(lambda: self.inspect("switch-account-tree.json"), lambda tree: any(
                item.get("AXIdentifier") == "vikingbar.accountPicker"
                and item.get("AXEnabled") in (True, "true", "1", 1) for item in tree.get("elements", [])))
            legacy = "mobile-vikings/00000000-0000-0000-0000-000000000001"
            title = entry["label"] if account == legacy else entry["label"] + " · " + account.split("/")[1][:8].upper()
            self.choose("vikingbar.accountPicker", title)
        self.account_selector = account
        self.launch_record["accountSelector"] = account
        UI.wait_for(lambda: self.run([str(self.cli), "accounts", "list"], "switch-catalog.json"),
                    lambda value: selector(value["selected"]) == account)

    def perform(self):
        self.peek(["permissions", "status", "--all-sources"], "permissions.json")
        apps = self.peek(["app", "list", "--include-hidden", "--include-background"], "apps-before.json")
        if "be.bram.vikingbar" in json.dumps(apps):
            raise UIFailure("existing-app-must-be-quit")
        self.run(["./Scripts/package-app.sh"], timeout=300)
        self.run(["swiftc", "Scripts/inspect-ui.swift", "-o", ".build/inspect-ui"], timeout=120)
        self.executable_hash = hashlib.sha256(self.executable.read_bytes()).hexdigest()
        self.screens = self.peek(["screen", "list"], "screens.json")["screens"]
        catalog = self.run([str(self.cli), "accounts", "list"], "catalog-before.json")
        self.original_selection = selector(catalog["selected"])
        mobile = next((entry for entry in catalog["accounts"] if entry["key"]["provider"] == "mobile-vikings"), None)
        if mobile is None:
            raise UIFailure("mobile-vikings-comparison-account-required")
        mobile_account = selector(mobile["key"])
        mobile_report = self.run([str(self.cli), "live", "--account", mobile_account], "mobile-before-report.json")
        UI.successful_timestamp(mobile_report)
        if self.resume_directory:
            self.preserved_connection()
        else:
            entry = self.run([str(self.cli), "accounts", "add", "--provider", "telenet"], "reserved-account.json")
            self.telenet_account = selector(entry["key"])
        UI.CONNECT.reference_at(self.reference, self.telenet_account)
        self.account_selector = self.telenet_account
        self.run([str(self.cli), "accounts", "select", self.telenet_account], "selected-account.json")
        tree = self.launch(first=not self.resume_directory, label="stored-continuation" if self.resume_directory else "native-connect")
        if not self.resume_directory:
            connected = self.connect_with_one_password(tree, self.directory / "connect-result.json")
            self.connection_digest = connected["connection_sha256"]
        initial = self.matched_home("connected-home", allow_stale=True)
        initial = self.initial_history_report(initial)
        self.prove_history("connected-history", initial)
        self.wait_manual_floor(initial)
        api = validate_api_receipt(json.loads(self.run(
            [str(self.cli), "proof", "telenet-home-api", "--account", self.telenet_account], timeout=180)))
        UI.private_write(self.directory / "api-result.json", api)
        after_api = self.cached("after-api")
        self.wait_manual_floor(after_api)
        self.refresh_home()
        refreshed = self.matched_home("refreshed-home", home_timestamp(after_api, self.telenet_account))
        self.prove_history("refreshed-history", refreshed)
        self.switch_provider("Mobile Vikings", mobile_account)
        mobile_current = self.matched_balance("mobile-switched")
        if UI.connection_identity(mobile_current) != UI.connection_identity(mobile_report):
            raise UIFailure("mobile-vikings-connection-changed")
        self.switch_provider("Telenet", self.telenet_account)
        returned = self.matched_home("returned-home")
        self.prove_history("returned-history", returned)
        if returned["state"]["account"]["selectedService"] != refreshed["state"]["account"]["selectedService"]:
            raise UIFailure("telenet-service-selection-changed")
        self.wait_manual_floor(returned)
        self.quit()
        self.launch(first=False, label="stored-session")
        restored = self.matched_home("restored-home")
        self.prove_history("restored-history", restored)
        self.refresh_home()
        stored = self.matched_home("stored-session-home", home_timestamp(returned, self.telenet_account))
        self.prove_history("stored-session-history", stored)
        self.quit()
        receipt = {"schema_version": 1, "check": "telenet-home-ui", "passed": True,
                   "api_matches": True, "daily_history_matches": True, "forecast_matches": True,
                   "native_history_chart_matches": True, "native_history_hover": True,
                   "native_history_window_group_capture": True,
                   "native_values_match": True, "native_status_matches": True,
                   "native_refresh": True, "provider_switching": True, "service_selection_preserved": True,
                   "stored_session_relaunch": True, "single_credential_read": True,
                   "preserved_native_bootstrap": bool(self.resume_directory),
                   "native_quit": True, "expiry_evidence": "unobserved", "renewal_evidence": "unobserved",
                   "mfa_evidence": "unobserved"}
        return receipt

    def restore_selection(self):
        if self.original_selection and self.telenet_account:
            self.run([str(self.cli), "accounts", "select", self.original_selection,
                      "--if-selected", self.account_selector], "selection-restored.json")


def run(environment):
    old_mask = os.umask(0o077)
    limits = resource.getrlimit(resource.RLIMIT_CORE)
    old_handler = signal.getsignal(signal.SIGTERM)
    proof = None
    stopping = False
    def terminated(_signal, _frame):
        nonlocal stopping
        if stopping:
            return
        stopping = True
        if proof is not None and proof.launch_in_progress:
            proof.termination_requested = True
            return
        raise UIFailure("telenet-native-proof-terminated")
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, limits[1]))
        signal.signal(signal.SIGTERM, terminated)
        proof = TelenetHomeProof(environment)
        try:
            receipt = proof.perform()
        finally:
            stopping = True
            try:
                proof.cleanup()
            finally:
                proof.restore_selection()
        receipt["cleanup_passed"] = True
        UI.private_write(proof.directory / "result.json", receipt)
        return receipt
    except UI.ProofTerminated:
        if proof is not None:
            UI.private_write(proof.directory / "result.json", {"passed": False, "error": "telenet-native-proof-terminated"})
        raise UIFailure("telenet-native-proof-terminated") from None
    except Exception as error:
        code = str(error) if isinstance(error, (UIFailure, HISTORY.UIFailure)) else "telenet-home-ui-proof-failed"
        if proof is not None:
            UI.private_write(proof.directory / "result.json", {"passed": False, "error": code})
        raise
    finally:
        signal.signal(signal.SIGTERM, old_handler)
        resource.setrlimit(resource.RLIMIT_CORE, limits)
        os.umask(old_mask)


def main():
    try:
        receipt, code = run(os.environ), 0
    except (UIFailure, HISTORY.UIFailure) as error:
        receipt, code = {"passed": False, "error": str(error)}, 1
    except Exception:
        receipt, code = {"passed": False, "error": "telenet-home-ui-proof-failed"}, 1
    print(json.dumps(receipt, sort_keys=True))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
