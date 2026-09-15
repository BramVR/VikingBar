#!/usr/bin/env python3
import datetime
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import signal
import sys
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("balance_ui_history", ROOT / "Scripts/balance-ui-proof.py")
UI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UI)
UIFailure = UI.UIFailure
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


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
        chart = history["chartSeries"]
        if (history.get("failure") is not None or history["truncated"]
                or context["connectionID"] != state["connectionID"]
                or context["subscriptionID"] != state["selectedSubscriptionID"]
                or context["bundleIndex"] != state["selectedBundleIndex"]
                or context["revision"] != state["historyRevision"]
                or context["bundle"]["cycleStart"] != bundle["validFrom"]
                or context["bundle"]["cycleEnd"] != bundle["validUntil"]
                or not presentation.get("forecast") or presentation["unit"] != "GB"
                or chart.get("failure") is not None
                or len(presentation["days"]) != 30
                or any(day["isStale"] for day in presentation["days"])
                or len(presentation["days"]) != len(chart["observations"])):
            raise ValueError()
        attempted = datetime.datetime.fromisoformat(history["attemptedAt"].replace("Z", "+00:00"))
        today = attempted.astimezone(ZoneInfo("Europe/Brussels")).replace(hour=0, minute=0, second=0, microsecond=0)
        for index, (day, observation) in enumerate(zip(presentation["days"], chart["observations"])):
            expected = today + datetime.timedelta(days=index - 29)
            actual = datetime.datetime.fromisoformat(day["dayStart"].replace("Z", "+00:00"))
            observed = datetime.datetime.fromisoformat(observation["interval"]["dayStart"].replace("Z", "+00:00"))
            if actual != expected or observed != expected or day.get("bytes") != observation.get("bytes"):
                raise ValueError()
        return attempted
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


def matched_window(tree, screens, *, role, identifier=None, error="native-history-window"):
    elements = [element for element in tree.get("elements", [])
                if element.get("AXRole") == role
                and (identifier is None or element.get("AXIdentifier") == identifier)]
    if len(elements) != 1:
        raise UIFailure(error + "-ambiguous")
    element = elements[0]
    try:
        element_frame = UI.frame(element)
    except UIFailure:
        raise UIFailure(error + "-not-visible") from None
    displays = UI.display_frames(screens)
    matches = []
    for window in tree.get("windows", []):
        try:
            cg_frame = window_frame(window)
            alpha = window["kCGWindowAlpha"]
            if (type(tree["pid"]) is int and tree["pid"] > 0
                    and type(alpha) in (int, float) and math.isfinite(alpha) and alpha >= 0.99
                    and window.get("kCGWindowOwnerPID") == tree["pid"]
                    and window.get("kCGWindowIsOnscreen") is True
                    and same_frame(element["frame"], cg_frame)
                    and any(UI.contained(element, display)
                            and UI.contained({"frame": cg_frame}, display) for display in displays)):
                matches.append(window)
        except (KeyError, TypeError, UIFailure):
            continue
    if len(matches) != 1:
        raise UIFailure(error + "-not-visible")
    return {"element": element, "frame": [list(element_frame[:2]), list(element_frame[2:])],
            "window": matches[0]}


def history_windows(tree, screens):
    parent = matched_window(tree, screens, role="AXPopover", error="native-history-popover")
    companion = matched_window(tree, screens, role="AXWindow", identifier="vikingbar.historyPanel",
                               error="native-history-panel")
    if parent["window"]["kCGWindowNumber"] == companion["window"]["kCGWindowNumber"]:
        raise UIFailure("native-history-window-identity-collision")
    result = {"parent": parent, "companion": companion}
    expected = {result[key]["window"]["kCGWindowNumber"] for key in result}
    status_elements = [element for element in tree.get("elements", [])
                       if element.get("AXIdentifier") == "vikingbar.status"]
    content = []
    for window in tree.get("windows", []):
        try:
            alpha = window["kCGWindowAlpha"]
            if (window.get("kCGWindowOwnerPID") != tree["pid"]
                    or window.get("kCGWindowIsOnscreen") is not True
                    or type(alpha) not in (int, float) or not math.isfinite(alpha) or alpha <= 0):
                continue
            cg_frame = window_frame(window)
            if any(same_frame(element["frame"], cg_frame) for element in status_elements):
                continue
            content.append(window["kCGWindowNumber"])
        except (KeyError, TypeError, UIFailure):
            continue
    if len(content) != 2 or set(content) != expected:
        raise UIFailure("native-history-content-window-ambiguous")
    return result


def window_identity(windows):
    return tuple((windows[key]["window"]["kCGWindowNumber"], tuple(UI.frame(windows[key]["element"])),
                  tuple(UI.frame({"frame": window_frame(windows[key]["window"])})))
                 for key in ("parent", "companion"))


def window_group_frame(windows):
    frames = [UI.frame({"frame": window_frame(windows[key]["window"])})
              for key in ("parent", "companion")]
    min_x = min(frame[0] for frame in frames)
    min_y = min(frame[1] for frame in frames)
    max_x = max(frame[0] + frame[2] for frame in frames)
    max_y = max(frame[1] + frame[3] for frame in frames)
    result = [[min_x, min_y], [max_x - min_x, max_y - min_y]]
    UI.frame({"frame": result})
    return result


def validate_capture_geometry(path, expected_frame):
    try:
        header = path.read_bytes()[:24]
        if len(header) != 24 or not header.startswith(PNG_SIGNATURE) or header[12:16] != b"IHDR":
            raise ValueError()
        pixel_width = int.from_bytes(header[16:20], "big")
        pixel_height = int.from_bytes(header[20:24], "big")
        _, _, width, height = UI.frame({"frame": expected_frame})
        scale_x, scale_y = pixel_width / width, pixel_height / height
        if (not 0.5 <= scale_x <= 4 or not 0.5 <= scale_y <= 4
                or abs(scale_x - scale_y) > 0.01):
            raise ValueError()
    except (OSError, TypeError, ValueError, UIFailure, ZeroDivisionError):
        raise UIFailure("native-history-capture-geometry-mismatch") from None


def validate_capture_observation(receipt, window):
    try:
        observations = receipt["data"]["observations"]
        if len(observations) != 1 or not isinstance(observations[0], dict):
            raise ValueError()
        observation = observations[0]
        target = observation["target"]
        coordinates = observation["coordinates"]
        identifier = window["kCGWindowNumber"]
        if (type(target["window_id"]) is not int or target["window_id"] != identifier
                or target.get("resolved_kind") != "window-id"
                or target.get("requested_kind") != "pid"
                or target.get("source") != "window-id"
                or coordinates.get("coordinate_space") != "global_display_points"
                or not same_frame(target["bounds"], window_frame(window))
                or not same_frame(coordinates["logical_bounds"], window_frame(window))):
            raise ValueError()
    except (KeyError, TypeError, ValueError, UIFailure):
        raise UIFailure("native-history-capture-observation-mismatch") from None
    return receipt


def exact_element(tree, boundary, identifier, expected=None, error="native-history-text-mismatch"):
    matches = [element for element in tree.get("elements", []) if element.get("AXIdentifier") == identifier]
    if (len(matches) != 1 or not UI.contained(matches[0], boundary)
            or (expected is not None and expected not in
                [matches[0].get(key) for key in ("AXTitle", "AXValue", "AXDescription")])):
        raise UIFailure(error)
    return matches[0]


def selected_day(tree, report, windows):
    boundary = windows["companion"]["element"]
    fields = (("vikingbar.historySelectedDate", "fullDateText"),
              ("vikingbar.historySelectedValue", "valueText"),
              ("vikingbar.historySelectedStatus", "statusText"))
    selected = [exact_element(tree, boundary, identifier) for identifier, _ in fields]
    matches = []
    for index, day in enumerate(report["historyPresentation"]["days"]):
        try:
            if all(day[field] in [element.get(key) for key in ("AXTitle", "AXValue", "AXDescription")]
                   for element, (_, field) in zip(selected, fields)):
                matches.append(index)
        except (KeyError, TypeError):
            raise UIFailure("history-live-report-invalid") from None
    if len(matches) != 1:
        raise UIFailure("native-history-selected-day-mismatch")
    return matches[0]


def compare_history(tree, report, screens):
    history_timestamp(report)
    if not UI.visible_status(tree, screens):
        raise UIFailure("status-not-visible")
    UI.compare_menu(tree, report, screens)
    windows = history_windows(tree, screens)
    boundary = windows["companion"]["element"]
    capture_boundary = {"frame": window_frame(windows["companion"]["window"])}
    presentation = report["historyPresentation"]
    if cycle_boundary := presentation.get("boundary"):
        exact_element(tree, windows["companion"]["element"], "vikingbar.historyBoundary",
                      cycle_boundary["label"] + " · " + cycle_boundary["dateText"])
    for identifier, field in (("vikingbar.historyForecast", "forecastText"),
                              ("vikingbar.historyTotal", "totalText"),
                              ("vikingbar.historyStatus", "statusText"),
                              ("vikingbar.historyScope", "scopeText")):
        element = exact_element(tree, boundary, identifier, presentation[field])
        if not UI.contained(element, capture_boundary):
            raise UIFailure("native-history-text-mismatch")
    chart = exact_element(tree, boundary, "vikingbar.historyChart",
                          error="native-history-chart-not-visible")
    plot = exact_element(tree, boundary, "vikingbar.historyPlot",
                         error="native-history-plot-not-visible")
    if not UI.contained(chart, capture_boundary) or not UI.contained(plot, chart):
        raise UIFailure("native-history-chart-not-visible")
    values = [chart.get(key, "") for key in ("AXTitle", "AXValue", "AXDescription")]
    expected = "; ".join(day["label"] + ": " + day["valueText"] for day in presentation["days"])
    if expected not in values:
        raise UIFailure("native-history-chart-values-mismatch")
    selected_day(tree, report, windows)
    return windows


def chart_position(index, count):
    if type(index) is not int or type(count) is not int or count < 2 or not 0 <= index < count:
        raise UIFailure("native-history-chart-position-invalid")
    return (index + 0.5) / count


def selection_indices(days):
    if not isinstance(days, list) or len(days) < 2:
        raise UIFailure("history-live-report-invalid")
    missing = next((index for index, day in enumerate(days) if day.get("isMissing") is True), None)
    zero = next((index for index, day in enumerate(days)
                 if day.get("isMissing") is False and day.get("bytes") == 0), None)
    return (missing, zero) if missing is not None and zero is not None else (0, len(days) - 1)


def validate_hover_receipt(value, *, pid, selector, normalized_x, normalized_y):
    try:
        if (not isinstance(value, dict)
                or set(value) != {"hovered", "normalized", "destination", "frame", "pid"}
                or value["hovered"] != selector or value["pid"] != pid
                or value["normalized"] != [normalized_x, normalized_y]):
            raise ValueError()
        x, y, width, height = UI.frame({"frame": value["frame"]})
        destination_x, destination_y = value["destination"]
        if (any(type(number) not in (int, float) or not math.isfinite(number)
                for number in (destination_x, destination_y))
                or not x < destination_x < x + width or not y < destination_y < y + height):
            raise ValueError()
    except (KeyError, TypeError, ValueError, UIFailure):
        raise UIFailure("native-hover-receipt-invalid") from None
    return value


class HistoryProof(UI.NativeProof):
    def __init__(self, environment):
        super().__init__(environment, stored_session=True)
        self.hover_count = 0

    def hover(self, identifier, normalized_x=0.5, normalized_y=0.5, *, label=None):
        self.hover_count = getattr(self, "hover_count", 0) + 1
        value = self.run([str(ROOT / ".build/inspect-ui"), str(self.process.pid), "hover", identifier,
                          format(normalized_x, ".17g"), format(normalized_y, ".17g")],
                         label or f"hover-{self.hover_count}-{identifier}.json")
        self.verify_process()
        return validate_hover_receipt(value, pid=self.process.pid, selector=identifier,
                                      normalized_x=normalized_x, normalized_y=normalized_y)

    def wait_report(self, label, after):
        def observe():
            try:
                report = self.run([str(self.cli), "live", "--cached"], label + "-report.json")
                history_timestamp(report)
                if after is not None and UI.successful_timestamp(report) <= after:
                    return None
                return report
            except UIFailure:
                return None

        return UI.wait_for(observe, lambda value: value is not None, seconds=90)

    def wait_history_windows(self, label, report):
        previous = None
        consecutive = 0
        observations = 0

        def observe():
            nonlocal previous, consecutive, observations
            try:
                observations += 1
                tree = self.inspect(f"{label}-card-{observations}.json")
                windows = compare_history(tree, report, self.screens)
                identity = window_identity(windows)
            except UIFailure:
                previous = None
                consecutive = 0
                return None
            consecutive = consecutive + 1 if identity == previous else 1
            previous = identity
            return (tree, windows) if consecutive >= 2 else None

        return UI.wait_for(observe, lambda value: value is not None, seconds=90)

    def hover_day(self, label, report, baseline, index):
        days = report["historyPresentation"]["days"]
        self.hover("vikingbar.historyPlot", chart_position(index, len(days)), 0.5,
                   label=label + "-hover.json")

        def observe():
            try:
                tree = self.inspect(label + "-selected.json")
                windows = compare_history(tree, report, self.screens)
                if window_identity(windows) != window_identity(baseline):
                    raise UIFailure("native-history-window-resized")
                return tree if selected_day(tree, report, windows) == index else None
            except UIFailure:
                return None

        return UI.wait_for(observe, lambda value: value is not None)

    def capture_history_windows(self, label, report, windows, selected_index):
        group_frame = window_group_frame(windows)
        for key, suffix in (("parent", "main-target-group"),
                            ("companion", "companion-target-group")):
            window = windows[key]["window"]
            path = self.directory / f"{label}-{suffix}.png"
            self.verify_process()
            receipt = UI.UI.capture_exact_window(
                self.peekaboo,
                self.process.pid,
                window["kCGWindowNumber"],
                path,
                lambda arguments, receipt=f"{label}-{suffix}-image.json": self.run(arguments, receipt),
            )
            validate_capture_observation(receipt, window)
            validate_capture_geometry(path, group_frame)
            settled_tree = self.inspect(f"{label}-{suffix}-after-capture.json")
            settled = compare_history(settled_tree, report, self.screens)
            self.verify_process()
            if (window_identity(settled) != window_identity(windows)
                    or selected_day(settled_tree, report, settled) != selected_index):
                raise UIFailure("native-history-capture-mismatch")

    def prime_history_hover(self, label, report, companion_window_id=None):
        self.hover("vikingbar.refresh", label=label + "-pointer-out-hover.json")

        def observe():
            try:
                tree = self.inspect(label + "-panel-absent.json")
                if any(element.get("AXIdentifier") == "vikingbar.historyPanel"
                       for element in tree.get("elements", [])) or (companion_window_id is not None and any(
                           window.get("kCGWindowNumber") == companion_window_id
                           for window in tree.get("windows", []))):
                    return False
                UI.compare_menu(tree, report, self.screens)
                return True
            except UIFailure:
                return False

        UI.wait_for(observe, bool)

    def dismiss_history(self, label, report, windows):
        companion_window_id = windows["companion"]["window"]["kCGWindowNumber"]
        self.prime_history_hover(label, report, companion_window_id)

    def matched_history(self, label, after=None):
        report = self.wait_report(label, after)
        self.prime_history_hover(label + "-prime", report)
        self.hover("vikingbar.historyDisclosure", label=label + "-open-hover.json")
        tree, windows = self.wait_history_windows(label, report)
        baseline = windows
        first, second = selection_indices(report["historyPresentation"]["days"])
        self.hover_day(label + "-first", report, baseline, first)
        selected_tree = self.hover_day(label + "-second", report, baseline, second)
        if first == second:
            raise UIFailure("native-history-selection-insufficient")
        self.verify_worker(label)
        if selected_day(selected_tree, report, windows) != second:
            raise UIFailure("native-history-selected-day-mismatch")
        self.capture_history_windows(label, report, windows, second)
        self.dismiss_history(label, report, windows)
        self.hover("vikingbar.historyDisclosure", label=label + "-reopen-hover.json")
        _, reopened = self.wait_history_windows(label + "-reopened", report)
        if (window_identity(reopened)[0] != window_identity(windows)[0]
                or window_identity(reopened)[1][1:] != window_identity(windows)[1][1:]):
            raise UIFailure("native-history-reopen-mismatch")
        self.dismiss_history(label + "-reopened", report, reopened)
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
        UI.wait_for(self.inspect, lambda tree: all(any(element.get("AXIdentifier") == identifier
                                                       for element in tree.get("elements", []))
                                                  for identifier in ("vikingbar.bundleDetails",
                                                                     "vikingbar.historyDisclosure")))
        self.press("vikingbar.bundleDetails")
        UI.wait_for(self.inspect, lambda tree: any(element.get("AXIdentifier") == "vikingbar.bundleDescription"
                                                  for element in tree.get("elements", [])))
        initial = self.matched_history("history")
        self.press("vikingbar.refresh")
        refreshed = self.matched_history("refreshed", after=UI.successful_timestamp(initial))
        if refreshed["state"]["connectionID"] != initial["state"]["connectionID"]:
            raise UIFailure("history-connection-changed")
        self.quit()
        receipt = {"schema_version": 1, "check": "history", "passed": True,
                   "api_matches": True, "forecast_matches": True, "native_chart_matches": True,
                   "native_refresh": True, "native_hover": True, "native_window_group_capture": True}
        UI.private_write(self.directory / "result.json", receipt)
        return receipt


def run(environment):
    old_mask = os.umask(0o077)
    proof = None
    handlers = {}
    cleanup_started = False

    def interrupted(_number, _frame):
        if cleanup_started:
            return
        if proof is not None and proof.launch_in_progress:
            proof.termination_requested = True
            return
        raise UI.ProofTerminated()

    try:
        for number in (signal.SIGTERM, signal.SIGINT):
            handlers[number] = signal.signal(number, interrupted)
        proof = HistoryProof(environment)
        return proof.perform()
    except UI.ProofTerminated:
        raise UIFailure("history-proof-interrupted") from None
    finally:
        cleanup_started = True
        try:
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
