#!/usr/bin/env python3
"""Verify real daily summaries, the cycle estimate, and the native history chart."""

import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("balance_ui_history", ROOT / "Scripts/balance-ui-proof.py")
UI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UI)
UIFailure = UI.UIFailure


def validate_api_receipt(value):
    expected = {"schema_version", "check", "passed", "api_matches", "forecast_matches",
                "token_refreshed", "request_count", "observed_days"}
    if (not isinstance(value, dict) or set(value) != expected
            or type(value["schema_version"]) is not int or value["schema_version"] != 1
            or value["check"] != "history-api"
            or any(value[key] is not True for key in ("passed", "api_matches", "forecast_matches", "token_refreshed"))
            or type(value["request_count"]) is not int or not 1 <= value["request_count"] <= 62
            or type(value["observed_days"]) is not int or not 3 <= value["observed_days"] <= value["request_count"]):
        raise UIFailure("history-api-receipt-invalid")
    return value


def history_timestamp(report):
    UI.successful_timestamp(report)
    try:
        state = report["state"]
        history = state["history"]
        context = history["context"]
        bundle = state["balance"]["bundles"][state["selectedBundleIndex"]]
        presentation = report["historyPresentation"]
        if (history.get("failure") is not None or history["truncated"]
                or context["connectionID"] != state["connectionID"]
                or context["subscriptionID"] != state["selectedSubscriptionID"]
                or context["bundleIndex"] != state["selectedBundleIndex"]
                or context["revision"] != state["historyRevision"]
                or context["bundle"]["cycleStart"] != bundle["validFrom"]
                or context["bundle"]["cycleEnd"] != bundle["validUntil"]
                or not presentation.get("forecast") or presentation["unit"] != "GB"
                or not 3 <= len(presentation["days"]) <= 62
                or any(day["isStale"] for day in presentation["days"])
                or len(presentation["days"]) != len(history["observations"])):
            raise ValueError()
        return datetime.datetime.fromisoformat(history["attemptedAt"].replace("Z", "+00:00"))
    except (KeyError, IndexError, TypeError, ValueError, AttributeError):
        raise UIFailure("history-live-report-invalid") from None


def window_frame(window):
    try:
        bounds = window["kCGWindowBounds"]
        result = [[bounds["X"], bounds["Y"]], [bounds["Width"], bounds["Height"]]]
        UI.frame({"frame": result})
        if type(window["kCGWindowNumber"]) is int and window["kCGWindowNumber"] > 0:
            return result
    except (KeyError, TypeError):
        pass
    raise UIFailure("native-history-window-invalid")


def same_frame(left, right):
    return all(abs(a - b) < 1 for a, b in zip(UI.frame({"frame": left}), UI.frame({"frame": right})))


def history_window(tree, screens):
    popovers = [element for element in tree.get("elements", []) if element.get("AXRole") == "AXPopover"]
    if len(popovers) != 1:
        raise UIFailure("native-history-popover-ambiguous")
    matches = []
    for window in tree.get("windows", []):
        try:
            window_frame(window)
            boundary, matched = UI.popover_window({"elements": popovers, "windows": [window]}, screens)
            matches.append((boundary["frame"], matched))
        except UIFailure:
            continue
    if len(matches) != 1:
        raise UIFailure("native-history-popover-not-visible")
    return matches[0]


def validate_capture(data, window, path):
    try:
        files, observations = data["files"], data["observations"]
        identifier = window["kCGWindowNumber"]
        if (len(files) == 1 and len(observations) == 1
                and type(files[0]["window_id"]) is int and files[0]["window_id"] == identifier
                and files[0]["path"] == str(path)
                and type(observations[0]["target"]["window_id"]) is int
                and observations[0]["target"]["window_id"] == identifier
                and same_frame(observations[0]["target"]["bounds"], window_frame(window))):
            return
    except (KeyError, TypeError, UIFailure):
        pass
    raise UIFailure("native-history-capture-mismatch")


def compare_history(tree, report, screens):
    history_timestamp(report)
    UI.compare_menu(tree, report, screens)
    boundary, window = history_window(tree, screens)
    capture_boundary = window_frame(window)
    presentation = report["historyPresentation"]
    elements = tree.get("elements", [])
    for identifier, field in (("vikingbar.historyForecast", "forecastText"),
                              ("vikingbar.historyTotal", "totalText"),
                              ("vikingbar.historyStatus", "statusText"),
                              ("vikingbar.historyScope", "scopeText")):
        matches = [element for element in elements if element.get("AXIdentifier") == identifier]
        if (len(matches) != 1 or not UI.contained(matches[0], {"frame": boundary})
                or not UI.contained(matches[0], {"frame": capture_boundary})
                or presentation[field] not in
                [matches[0].get(key) for key in ("AXTitle", "AXValue", "AXDescription")]):
            raise UIFailure("native-history-text-mismatch")
    charts = [element for element in elements if element.get("AXIdentifier") == "vikingbar.historyChart"]
    if (len(charts) != 1 or not UI.contained(charts[0], {"frame": boundary})
            or not UI.contained(charts[0], {"frame": capture_boundary})):
        raise UIFailure("native-history-chart-not-visible")
    chart = charts[0]
    values = [chart.get(key, "") for key in ("AXTitle", "AXValue", "AXDescription")]
    expected = "; ".join(day["label"] + ": " + day["valueText"] for day in presentation["days"])
    if expected not in values:
        raise UIFailure("native-history-chart-values-mismatch")
    return window


class HistoryProof(UI.NativeProof):
    def __init__(self, environment):
        super().__init__(environment, stored_session=True)

    def matched_history(self, label, after=None):
        def observe():
            try:
                report = self.run([str(self.cli), "live", "--cached"], label + "-report.json")
                history_timestamp(report)
                timestamp = UI.successful_timestamp(report)
                if after is not None and timestamp <= after:
                    return None
                tree = self.inspect(label + "-card.json")
                window = compare_history(tree, report, self.screens)
                return report, window
            except UIFailure:
                return None
        report, window = UI.wait_for(observe, lambda value: value is not None, seconds=90)
        self.verify_worker(label)
        path = self.directory / (label + "-chart.png")
        capture = self.peek(["see", "--window-id", str(window["kCGWindowNumber"]), "--no-elements", "--no-remote",
                             "--path", str(path)], label + "-image.json")
        validate_capture(capture, window, path)
        settled = compare_history(self.inspect(label + "-after-capture.json"), report, self.screens)
        if (settled["kCGWindowNumber"] != window["kCGWindowNumber"]
                or not same_frame(window_frame(settled), window_frame(window))):
            raise UIFailure("native-history-capture-mismatch")
        return report

    def perform(self):
        self.peek(["permissions", "status", "--all-sources"], "permissions.json")
        apps = self.peek(["app", "list", "--include-hidden", "--include-background"], "apps-before.json")
        if "be.bram.vikingbar" in json.dumps(apps):
            raise UIFailure("existing-app-must-be-quit")
        self.run(["./Scripts/package-app.sh"], timeout=300)
        self.run(["swiftc", "Scripts/inspect-ui.swift", "-o", ".build/inspect-ui"], timeout=120)
        self.executable_hash = hashlib.sha256(self.executable.read_bytes()).hexdigest()
        api = self.run([str(self.cli), "proof", "history-api"], "api-result.json", timeout=180)
        validate_api_receipt(api)
        self.screens = self.peek(["screen", "list"], "screens.json")["screens"]
        self.launch(first=False, label="history")
        UI.wait_for(self.inspect, lambda tree: any(element.get("AXIdentifier") == "vikingbar.historyDisclosure"
                                                  for element in tree.get("elements", [])))
        self.press("vikingbar.historyDisclosure")
        initial = self.matched_history("history")
        self.press("vikingbar.refresh")
        refreshed = self.matched_history("refreshed", after=UI.successful_timestamp(initial))
        if refreshed["state"]["connectionID"] != initial["state"]["connectionID"]:
            raise UIFailure("history-connection-changed")
        self.quit()
        receipt = {"schema_version": 1, "check": "history", "passed": True,
                   "api_matches": True, "forecast_matches": True, "native_chart_matches": True,
                   "native_refresh": True}
        UI.private_write(self.directory / "result.json", receipt)
        return receipt


def run(environment):
    old_mask = os.umask(0o077)
    proof = None
    handlers = {}

    def interrupted(_number, _frame):
        raise UIFailure("history-proof-interrupted")

    try:
        for number in (signal.SIGTERM, signal.SIGINT):
            handlers[number] = signal.signal(number, interrupted)
        proof = HistoryProof(environment)
        return proof.perform()
    finally:
        try:
            # A second cancellation must not interrupt owned-process cleanup.
            for number in handlers:
                signal.signal(number, signal.SIG_IGN)
            if proof is not None:
                proof.cleanup()
        finally:
            for number, handler in handlers.items():
                signal.signal(number, handler)
            os.umask(old_mask)


def main():
    try:
        receipt, code = run(os.environ), 0
    except UIFailure as error:
        receipt, code = {"passed": False, "error": str(error)}, 1
    except Exception:
        receipt, code = {"passed": False, "error": "history-proof-failed"}, 1
    print(json.dumps(receipt, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
