#!/usr/bin/env python3
"""Authorized stored-session points proof; private evidence, no credential bootstrap."""
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("points_balance_ui", ROOT / "Scripts/balance-ui-proof.py")
UI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UI)
UIFailure = UI.UIFailure


def validate_api_receipt(value):
    fields = {"schema_version", "check", "passed", "api_matches", "token_refreshed",
              "transaction_count", "page_count"}
    if (not isinstance(value, dict) or set(value) != fields
            or type(value["schema_version"]) is not int or value["schema_version"] != 1
            or value["check"] != "points-api"
            or any(value[key] is not True for key in ("passed", "api_matches", "token_refreshed"))
            or type(value["transaction_count"]) is not int or value["transaction_count"] < 0
            or type(value["page_count"]) is not int or not 1 <= value["page_count"] <= 3):
        raise UIFailure("points-api-receipt-invalid")
    return value


def points_timestamps(report):
    UI.successful_timestamp(report)
    try:
        points = report["state"]["points"]
        if (not isinstance(points["balance"], dict) or not isinstance(points["history"], dict)
                or points.get("balanceFailure") or points.get("historyFailure")
                or not isinstance(report["points"]["transactions"], list)):
            raise ValueError()
        timestamps = tuple(datetime.datetime.fromisoformat(
            points[key]["current"]["lastUpdated"].replace("Z", "+00:00"))
            for key in ("balanceFreshness", "historyFreshness"))
        if any(value.tzinfo is None for value in timestamps):
            raise ValueError()
        return timestamps
    except (KeyError, TypeError, ValueError, AttributeError):
        raise UIFailure("points-report-invalid") from None


def match_text(tree, identifier, expected, boundary):
    if not isinstance(expected, str) or not expected:
        raise UIFailure("points-presentation-invalid")
    for element in tree.get("elements", []):
        if (element.get("AXIdentifier") == identifier and UI.contained(element, boundary)
                and expected in [element.get(key) for key in ("AXTitle", "AXValue", "AXDescription")]):
            return
    raise UIFailure("native-points-mismatch")


def is_transactions_scroll(element):
    return (element.get("AXRole") == "AXScrollArea"
            and element.get("AXIdentifier") in ("vikingbar.points.transactionsScroll",
                                                 "vikingbar.points.transactionsToggle"))


def compare_points(tree, report, screens, expanded=False):
    points_timestamps(report)
    if not UI.visible_status(tree, screens):
        raise UIFailure("status-not-visible")
    boundary, _ = UI.popover_window(tree, screens)
    presentation = report["points"]
    for suffix, field in (("customerLabel", "customerLabel"), ("available", "availableText"),
                          ("pending", "pendingText"), ("blocked", "blockedText"),
                          ("balanceStatus", "balanceStatus"), ("historyStatus", "historyStatus"),
                          ("historySummary", "historySummary")):
        match_text(tree, "vikingbar.points." + suffix, presentation[field], boundary)
    if not expanded:
        return 0
    scroll = next((item for item in tree["elements"] if is_transactions_scroll(item)), None)
    if scroll is None or not UI.contained(scroll, boundary):
        raise UIFailure("points-scroll-not-visible")
    if not presentation["transactions"]:
        return 0
    for suffix, field in (("amount", "amountText"), ("state", "stateText"),
                          ("updated", "updatedText"), ("description", "descriptionText")):
        match_text(tree, "vikingbar.points.transaction.0." + suffix,
                   presentation["transactions"][0][field], scroll)
    return 1


class PointsProof(UI.NativeProof):
    def __init__(self, environment):
        super().__init__(environment, stored_session=True)

    def capture_points(self, label, tree):
        _, window = UI.popover_window(tree, self.screens)
        target = self.directory / (label + ".png")
        self.peek(["see", "--window-id", str(window["kCGWindowNumber"]), "--no-elements", "--no-remote",
                   "--path", str(target)], label + "-image.json")
        if not target.is_file() or target.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
            raise UIFailure("points-capture-missing")

    def matched_points(self, label, after=None):
        def observe():
            try:
                report = self.run([str(self.cli), "live", "--cached"], label + "-report.json")
                timestamps = points_timestamps(report)
                if after is not None and any(new <= old for new, old in zip(timestamps, after)):
                    return None
                tree = self.inspect(label + "-card.json")
                compare_points(tree, report, self.screens)
                return report, tree
            except UIFailure:
                return None
        report, tree = UI.wait_for(observe, lambda value: value is not None)
        self.verify_worker(label)
        self.capture_points(label, tree)
        return report

    def perform(self):
        self.peek(["permissions", "status", "--all-sources"], "permissions.json")
        apps = self.peek(["app", "list", "--include-hidden", "--include-background"], "apps-before.json")
        if "be.bram.vikingbar" in json.dumps(apps):
            raise UIFailure("existing-app-must-be-quit")
        self.run(["./Scripts/package-app.sh"], timeout=300)
        self.run(["swiftc", "Scripts/inspect-ui.swift", "-o", ".build/inspect-ui"], timeout=120)
        self.executable_hash = hashlib.sha256(self.executable.read_bytes()).hexdigest()
        self.screens = self.peek(["screen", "list"], "screens.json")["screens"]
        self.launch(first=False, label="stored-session")
        initial = self.matched_balance("usage")
        self.press("vikingbar.points")
        self.matched_points("points")

        def api_check():
            try:
                raw = self.run([str(self.cli), "proof", "points-api"], timeout=180)
                receipt = validate_api_receipt(json.loads(raw))
                UI.private_write(self.directory / "api-result.json", receipt)
                return receipt
            except UIFailure as error:
                if str(error) == "session-busy":
                    return None
                raise
        api = UI.wait_for(api_check, lambda value: value is not None, seconds=30)
        api_report = self.run([str(self.cli), "live", "--cached"], "after-api-report.json")
        after = points_timestamps(api_report)
        time.sleep(1.1)
        self.press("vikingbar.back")
        self.press("vikingbar.refresh")
        self.matched_balance("refreshed-usage", UI.successful_timestamp(api_report))
        self.press("vikingbar.points")
        refreshed = self.matched_points("refreshed", after)
        if refreshed["state"]["connectionID"] != initial["state"]["connectionID"]:
            raise UIFailure("points-connection-changed")
        collapsed = self.inspect("collapsed-card.json")
        if any(is_transactions_scroll(item) for item in collapsed.get("elements", [])):
            raise UIFailure("points-history-not-collapsed")
        self.press("vikingbar.points.transactionsToggle")
        def expanded():
            tree = self.inspect("expanded-card.json")
            try:
                compare_points(tree, refreshed, self.screens, expanded=True)
                return tree
            except UIFailure:
                return None
        tree = UI.wait_for(expanded, lambda value: value is not None)
        visible_count = compare_points(tree, refreshed, self.screens, expanded=True)
        self.capture_points("expanded", tree)
        self.press("vikingbar.points.transactionsToggle")
        UI.wait_for(self.inspect, lambda tree: not any(
            is_transactions_scroll(item)
            or item.get("AXIdentifier", "").startswith("vikingbar.points.transaction.")
            for item in tree.get("elements", [])))
        self.press("vikingbar.back")
        self.quit()
        return {"schema_version": 1, "check": "points", "passed": True, "api_matches": True,
                "token_refreshed": True, "native_refresh": True, "stored_session": True,
                "visible_points_match": True, "transactions_expanded": True,
                "visible_transaction_count": visible_count, "transaction_count": api["transaction_count"],
                "page_count": api["page_count"], "native_quit": True}


def run(environment):
    old_mask = os.umask(0o077)
    proof = None
    try:
        try:
            proof = PointsProof(environment)
            receipt = proof.perform()
        finally:
            if proof is not None:
                proof.cleanup()
        receipt["cleanup_passed"] = True
        UI.private_write(proof.directory / "result.json", receipt)
        return receipt
    finally:
        os.umask(old_mask)


def main():
    try:
        receipt, code = run(os.environ), 0
    except UIFailure as error:
        receipt, code = {"passed": False, "error": str(error)}, 1
    except Exception:
        receipt, code = {"passed": False, "error": "points-proof-failed"}, 1
    print(json.dumps(receipt, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
