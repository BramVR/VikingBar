import copy
import datetime
import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("history_proof_test", ROOT / "Scripts/history-proof.py")
HISTORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HISTORY)
BALANCE_SPEC = importlib.util.spec_from_file_location("balance_history_fixture", ROOT / "Scripts/tests/test_balance_ui_proof.py")
BALANCE = importlib.util.module_from_spec(BALANCE_SPEC)
BALANCE_SPEC.loader.exec_module(BALANCE)


class HistoryProofTests(unittest.TestCase):
    def setUp(self):
        self.receipt = {"schema_version": 1, "check": "history-api", "passed": True, "api_matches": True,
                        "forecast_matches": True, "token_refreshed": True, "request_count": 7, "observed_days": 6}
        first_day = datetime.datetime(2026, 8, 9, tzinfo=datetime.timezone(datetime.timedelta(hours=2)))
        dates = [first_day + datetime.timedelta(days=index) for index in range(30)]
        days = [{"label": f"{day.day} {day:%b}", "fullDateText": f"{day.day} {day:%B %Y}",
                 "dayStart": day.isoformat(),
                 "valueText": "1.00 GB", "statusText": "Complete day", "bytes": 1_000_000_000,
                 "isMissing": False, "isPartial": False, "isStale": False} for day in dates]
        self.presentation = {"days": days, "forecast": {"estimatedCycleBytes": 30_000_000_000},
                             "unit": "GB", "forecastText": "Estimated SIM data this cycle: 30.00 GB",
                             "totalText": "Observed SIM data: 7.00 GB",
                             "statusText": "7 reported days", "scopeText": "All SIM data in this bundle period"}
        snapshot = {"source": {"live": {}}, "freshness": {"current": {"lastUpdated": "2026-09-07T12:00:00Z"}}}
        cycle = {"cycleStart": "2026-09-01T00:00:00Z", "cycleEnd": "2026-10-01T00:00:00Z"}
        connection = {"rawValue": "00000000-0000-0000-0000-000000000001"}
        self.report = {"schemaVersion": 1, "snapshot": snapshot, "historyPresentation": self.presentation,
                       "state": {"snapshot": snapshot, "connectionID": connection, "historyRevision": "revision-one",
                                 "selectedSubscriptionID": "sim-one", "selectedBundleIndex": 0,
                                 "balance": {"bundles": [{"validFrom": cycle["cycleStart"], "validUntil": cycle["cycleEnd"]}]},
                                 "history": {"context": {"connectionID": connection, "subscriptionID": "sim-one",
                                                         "bundleIndex": 0, "revision": "revision-one", "bundle": cycle},
                                             "attemptedAt": "2026-09-07T12:00:00Z", "truncated": False,
                                             "observations": [{}] * 7,
                                             "chartSeries": {"observations": [
                                                 {"interval": {"dayStart": day["dayStart"]}, "bytes": day["bytes"]}
                                                 for day in days]}}}}
        self.screens = [{"bounds": {"x": 0, "y": 0, "width": 1000, "height": 900}}]
        self.chart = {"AXIdentifier": "vikingbar.historyChart", "frame": [[220, 180], [340, 180]],
                      "AXDescription": "; ".join(day["label"] + ": " + day["valueText"] for day in days)}
        companion_elements = [{"AXIdentifier": identifier, "AXValue": self.presentation[field],
                               "frame": [[230, 400], [320, 20]]}
                              for identifier, field in (("vikingbar.historyForecast", "forecastText"),
                                                        ("vikingbar.historyTotal", "totalText"),
                                                        ("vikingbar.historyStatus", "statusText"),
                                                        ("vikingbar.historyScope", "scopeText"))]
        companion_elements += [
            {"AXIdentifier": "vikingbar.historyPlot", "frame": [[245, 205], [290, 125]]},
            {"AXIdentifier": "vikingbar.historySelectedDate", "AXValue": days[0]["fullDateText"],
             "frame": [[230, 500], [320, 20]]},
            {"AXIdentifier": "vikingbar.historySelectedValue", "AXValue": days[0]["valueText"],
             "frame": [[230, 525], [320, 20]]},
            {"AXIdentifier": "vikingbar.historySelectedStatus", "AXValue": days[0]["statusText"],
             "frame": [[230, 550], [320, 20]]},
        ]
        self.tree = {"pid": 123, "elements": [self.chart, *companion_elements],
                     "windows": [
                         {"kCGWindowNumber": 1,
                          "kCGWindowAlpha": 1, "kCGWindowOwnerPID": 123, "kCGWindowIsOnscreen": True,
                          "kCGWindowBounds": {"X": 620, "Y": 50, "Width": 360, "Height": 760}},
                         {"kCGWindowNumber": 2,
                          "kCGWindowAlpha": 1, "kCGWindowOwnerPID": 123, "kCGWindowIsOnscreen": True,
                          "kCGWindowBounds": {"X": 200, "Y": 100, "Width": 380, "Height": 650}},
                     ]}

        balance = BALANCE.BalanceUIProofTests()
        balance.setUp()
        self.report.update(menu=balance.report["menu"], balanceDetails=balance.report["balanceDetails"])
        for element in balance.tree["elements"]:
            if element.get("AXIdentifier") != "vikingbar.status":
                element["frame"] = [[650, 100], [100, 20]]
        self.tree["elements"] += [e for e in balance.tree["elements"] if e.get("AXRole") != "AXPopover"]
        self.tree["elements"] += [
            {"AXRole": "AXPopover", "frame": [[620, 50], [360, 760]]},
            {"AXRole": "AXWindow", "AXIdentifier": "vikingbar.historyPanel",
             "frame": [[200, 100], [380, 650]]},
        ]

    def test_receipt_requires_real_summary_mapping_and_forecast(self):
        self.assertEqual(HISTORY.validate_api_receipt(self.receipt), self.receipt)
        for delta in ({"forecast_matches": False}, {"observed_days": 0}, {"observed_days": True},
                      {"observed_days": 8}, {"request_count": 63}, {"request_count": True},
                      {"schema_version": True}, {"raw": "private-sentinel"}, {"passed": "skipped"}):
            with self.assertRaises(HISTORY.UIFailure):
                HISTORY.validate_api_receipt(dict(self.receipt, **delta))

    def test_report_rejects_other_sim_revision_cycle_and_missing_forecast(self):
        HISTORY.history_timestamp(self.report)
        for key, value in (("subscriptionID", "other"), ("connectionID", "other"), ("revision", "other"),
                           ("bundleIndex", 1), ("bundle", {"cycleStart": "old", "cycleEnd": "old"})):
            report = copy.deepcopy(self.report)
            report["state"]["history"]["context"][key] = value
            with self.assertRaises(HISTORY.UIFailure):
                HISTORY.history_timestamp(report)
        for field, value in (("forecast", None), ("unit", "GiB"), ("days", [])):
            report = copy.deepcopy(self.report)
            report["historyPresentation"][field] = value
            with self.assertRaises(HISTORY.UIFailure):
                HISTORY.history_timestamp(report)
        self.report["state"]["history"]["failure"] = "rate_limited"
        with self.assertRaises(HISTORY.UIFailure):
            HISTORY.history_timestamp(self.report)

    def test_chart_requires_visible_bounds_and_matching_day_values(self):
        windows = HISTORY.compare_history(self.tree, self.report, self.screens)
        self.assertEqual(windows["parent"]["window"]["kCGWindowNumber"], 1)
        self.assertEqual(windows["companion"]["window"]["kCGWindowNumber"], 2)
        for frame in ([[2000, 200], [300, 140]], [[200, 850], [300, 140]], [[200, 200], [0, 0]],
                      [[590, 200], [300, 140]]):
            tree = copy.deepcopy(self.tree)
            tree["elements"][0]["frame"] = frame
            with self.assertRaises(HISTORY.UIFailure):
                HISTORY.compare_history(tree, self.report, self.screens)
        self.chart["AXDescription"] = "Sep 1: 99.00 GB"
        with self.assertRaisesRegex(HISTORY.UIFailure, "native-history-chart-values-mismatch"):
            HISTORY.compare_history(self.tree, self.report, self.screens)

    def test_month_window_is_independent_of_cycle_and_requires_exact_days(self):
        HISTORY.history_timestamp(self.report)
        for mutate in (
                lambda value: value["historyPresentation"]["days"].pop(),
                lambda value: value["historyPresentation"]["days"][0].update(dayStart="2026-08-01T00:00:00Z"),
                lambda value: value["state"]["history"]["chartSeries"]["observations"][0].update(bytes=123),
                lambda value: value["state"]["history"]["chartSeries"].update(failure="transport"),
        ):
            report = copy.deepcopy(self.report)
            mutate(report)
            with self.assertRaisesRegex(HISTORY.UIFailure, "history-live-report-invalid"):
                HISTORY.history_timestamp(report)

    def test_cycle_boundary_requires_visible_matching_text(self):
        self.presentation["boundary"] = {"label": "Cycle started", "dateText": "1 September 2026, 02:00"}
        with self.assertRaises(HISTORY.UIFailure):
            HISTORY.compare_history(self.tree, self.report, self.screens)
        element = {"AXIdentifier": "vikingbar.historyBoundary", "AXValue": "Cycle started · 1 September 2026, 02:00",
                   "frame": [[230, 160], [320, 20]]}
        self.tree["elements"].append(element)
        HISTORY.compare_history(self.tree, self.report, self.screens)
        element["AXValue"] = "Renewed yesterday"
        with self.assertRaises(HISTORY.UIFailure):
            HISTORY.compare_history(self.tree, self.report, self.screens)

    def test_expanded_history_still_requires_visible_menu_bar_status(self):
        tree = copy.deepcopy(self.tree)
        tree["elements"] = [element for element in tree["elements"]
                            if element.get("AXIdentifier") != "vikingbar.status"]
        with self.assertRaisesRegex(HISTORY.UIFailure, "status-not-visible"):
            HISTORY.compare_history(tree, self.report, self.screens)

    def test_chart_forecast_text_and_stale_samples_fail(self):
        tree = copy.deepcopy(self.tree)
        tree["elements"][1]["AXValue"] = "Not an estimate"
        with self.assertRaisesRegex(HISTORY.UIFailure, "native-history-text-mismatch"):
            HISTORY.compare_history(tree, self.report, self.screens)
        self.presentation["days"][0]["isStale"] = True
        with self.assertRaises(HISTORY.UIFailure):
            HISTORY.compare_history(self.tree, self.report, self.screens)

    def test_companion_proof_still_requires_parent_balance(self):
        tree = copy.deepcopy(self.tree)
        tree["elements"] = [element for element in tree["elements"]
                            if element.get("AXIdentifier") != "vikingbar.remaining"]
        with self.assertRaisesRegex(HISTORY.UIFailure, "native-menu-mismatch"):
            HISTORY.compare_history(tree, self.report, self.screens)

    def test_every_required_history_element_must_be_fully_visible_in_companion(self):
        identifiers = {"vikingbar.historyChart", "vikingbar.historyPlot", "vikingbar.historyForecast",
                       "vikingbar.historyTotal", "vikingbar.historyStatus", "vikingbar.historyScope",
                       "vikingbar.historySelectedDate", "vikingbar.historySelectedValue",
                       "vikingbar.historySelectedStatus"}
        for identifier in identifiers:
            for frame in (None, [[2100, 100], [300, 20]], [[210, 800], [300, 20]],
                          [[170, 400], [300, 20]], [[210, 400], [True, 20]],
                          [[float("nan"), 400], [300, 20]], [[210, 400], [300, float("inf")]],
                          [[210, 400], [-1, 20]], [[210, 400], [0, 20]], [[210, 400], [300]],
                          [[210, 400], [10**1000, 20]]):
                with self.subTest(identifier=identifier, frame=frame):
                    tree = copy.deepcopy(self.tree)
                    next(element for element in tree["elements"]
                         if element.get("AXIdentifier") == identifier)["frame"] = frame
                    with self.assertRaises(HISTORY.UIFailure):
                        HISTORY.compare_history(tree, self.report, self.screens)

    def test_both_windows_require_exact_opaque_onscreen_owned_geometry(self):
        mutations = [
            lambda t: t["elements"].pop(),
            lambda t: t["elements"].append(copy.deepcopy(t["elements"][-1])),
            lambda t: t["windows"].append(copy.deepcopy(t["windows"][0])),
            lambda t: t["windows"].append(copy.deepcopy(t["windows"][1])),
            lambda t: t["windows"][0]["kCGWindowBounds"].update(X=619),
            lambda t: t["windows"][1]["kCGWindowBounds"].update(X=199),
            lambda t: t["windows"][0]["kCGWindowBounds"].update(Width=float("inf")),
            lambda t: t["windows"][0].update(kCGWindowNumber=True),
            lambda t: t["windows"][1].update(kCGWindowAlpha=0.5),
            lambda t: t["windows"][1].update(kCGWindowAlpha=True),
            lambda t: t["windows"][1].update(kCGWindowOwnerPID=456),
            lambda t: t["windows"][1].update(kCGWindowIsOnscreen=False),
            lambda t: t["elements"][-1].update(frame=[[200, True], [380, 650]]),
        ]
        for mutate in mutations:
            tree = copy.deepcopy(self.tree)
            mutate(tree)
            with self.assertRaises(HISTORY.UIFailure):
                HISTORY.compare_history(tree, self.report, self.screens)
        for bounds in ({"x": 0, "y": 0, "width": 1000, "height": 800},
                       {"x": False, "y": 0, "width": 1000, "height": 900},
                       {"x": 0, "y": 0, "width": float("inf"), "height": 900}, {}):
            with self.assertRaises(HISTORY.UIFailure):
                HISTORY.compare_history(self.tree, self.report, [{"bounds": bounds}])

    def test_negative_origin_display_and_unrelated_window_do_not_change_capture_target(self):
        for element in self.tree["elements"]:
            element["frame"][0][0] -= 1000
            element["frame"][0][1] -= 900
        self.tree["windows"][0]["kCGWindowBounds"].update(X=-380, Y=-850)
        self.tree["windows"][1]["kCGWindowBounds"].update(X=-800, Y=-800)
        self.screens.append({"bounds": {"x": -1000, "y": -900, "width": 1000, "height": 900}})
        self.tree["windows"].insert(0, {"kCGWindowNumber": 3, "kCGWindowAlpha": 1,
                                      "kCGWindowOwnerPID": 999, "kCGWindowIsOnscreen": True,
                                      "kCGWindowBounds": {"X": 0, "Y": 0, "Width": 800, "Height": 900}})
        windows = HISTORY.compare_history(self.tree, self.report, self.screens)
        self.assertEqual([windows[key]["window"]["kCGWindowNumber"]
                          for key in ("parent", "companion")], [1, 2])

    def test_known_status_item_window_is_excluded_but_third_content_window_fails(self):
        status = next(element for element in self.tree["elements"]
                      if element.get("AXIdentifier") == "vikingbar.status")
        x, y, width, height = HISTORY.UI.frame(status)
        menu_extra = {"kCGWindowNumber": 3, "kCGWindowAlpha": 1, "kCGWindowOwnerPID": 123,
                      "kCGWindowIsOnscreen": True,
                      "kCGWindowBounds": {"X": x, "Y": y, "Width": width, "Height": height}}
        tree = copy.deepcopy(self.tree)
        tree["windows"].append(menu_extra)
        self.assertEqual(HISTORY.history_windows(tree, self.screens)["parent"]["window"]["kCGWindowNumber"], 1)
        menu_extra["kCGWindowBounds"]["Width"] += 10
        tree = copy.deepcopy(self.tree)
        tree["windows"].append(menu_extra)
        with self.assertRaisesRegex(HISTORY.UIFailure, "native-history-content-window-ambiguous"):
            HISTORY.history_windows(tree, self.screens)

    def test_missing_and_zero_select_distinct_exact_day_details(self):
        days = self.report["historyPresentation"]["days"]
        days[1].update(bytes=None, isMissing=True, valueText="Missing", statusText="Missing day")
        days[2].update(bytes=0, isMissing=False, valueText="0.00 GB", statusText="Confirmed zero")
        days[3].update(isPartial=True, valueText="1.00 GB · partial", statusText="Partial boundary day")
        days[4].update(isStale=True, valueText="1.00 GB · stale", statusText="Stale observation")
        self.chart["AXDescription"] = "; ".join(day["label"] + ": " + day["valueText"] for day in days)
        self.assertEqual(HISTORY.selection_indices(days), (1, 2))
        windows = HISTORY.history_windows(self.tree, self.screens)
        for index, expected in ((1, "Missing day"), (2, "Confirmed zero"),
                                (3, "Partial boundary day"), (4, "Stale observation")):
            tree = copy.deepcopy(self.tree)
            for identifier, field in (("vikingbar.historySelectedDate", "fullDateText"),
                                      ("vikingbar.historySelectedValue", "valueText"),
                                      ("vikingbar.historySelectedStatus", "statusText")):
                next(element for element in tree["elements"]
                     if element.get("AXIdentifier") == identifier)["AXValue"] = days[index][field]
            self.assertEqual(HISTORY.selected_day(tree, self.report, windows), index)
            status = next(element for element in tree["elements"]
                          if element.get("AXIdentifier") == "vikingbar.historySelectedStatus")
            self.assertEqual(status["AXValue"], expected)

    def test_chart_positions_address_first_and_last_categories(self):
        self.assertEqual(HISTORY.chart_position(0, 7), 1 / 14)
        self.assertEqual(HISTORY.chart_position(3, 7), 0.5)
        self.assertEqual(HISTORY.chart_position(6, 7), 13 / 14)
        for index, count in ((0, 1), (-1, 7), (7, 7), (True, 7), (0, True)):
            with self.assertRaisesRegex(HISTORY.UIFailure, "native-history-chart-position-invalid"):
                HISTORY.chart_position(index, count)

    def test_hover_receipt_requires_exact_target_and_interior_destination(self):
        receipt = {"hovered": "vikingbar.historyPlot", "normalized": [1, 0.5],
                   "destination": [534, 267.5], "frame": [[245, 205], [290, 125]], "pid": 123}
        self.assertEqual(HISTORY.validate_hover_receipt(
            receipt, pid=123, selector="vikingbar.historyPlot", normalized_x=1, normalized_y=0.5), receipt)
        for mutate in (lambda value: value.update(hovered="other"),
                       lambda value: value.update(pid=True),
                       lambda value: value.update(normalized=[0.5, 0.5]),
                       lambda value: value.update(destination=[535, 267.5]),
                       lambda value: value.update(frame=[[245, 205], [float("inf"), 125]]),
                       lambda value: value.update(extra=True)):
            altered = copy.deepcopy(receipt)
            mutate(altered)
            with self.assertRaisesRegex(HISTORY.UIFailure, "native-hover-receipt-invalid"):
                HISTORY.validate_hover_receipt(
                    altered, pid=123, selector="vikingbar.historyPlot", normalized_x=1, normalized_y=0.5)

    def test_launch_report_waits_for_strictly_newer_successful_balance(self):
        proof = object.__new__(HISTORY.HistoryProof)
        proof.cli = Path("/fixture/vikingbar")
        baseline = HISTORY.UI.successful_timestamp(self.report)
        newer = copy.deepcopy(self.report)
        newer["snapshot"]["freshness"]["current"]["lastUpdated"] = "2026-09-07T12:01:00Z"
        newer["state"]["snapshot"] = copy.deepcopy(newer["snapshot"])
        reports = [self.report, newer]

        def wait_twice(operation, predicate, seconds=90):
            self.assertFalse(predicate(operation()))
            result = operation()
            self.assertTrue(predicate(result))
            return result

        with patch.object(proof, "run", side_effect=reports), \
                patch.object(HISTORY.UI, "wait_for", side_effect=wait_twice):
            self.assertEqual(proof.wait_report("launch", baseline), newer)

    def test_main_hover_requires_exact_selected_day_without_opening_panel(self):
        tree = copy.deepcopy(self.tree)
        tree["elements"] = [element for element in tree["elements"]
                            if element.get("AXIdentifier") != "vikingbar.historyPanel"]
        tree["windows"] = tree["windows"][:1]
        day = self.presentation["days"][0]
        tree["elements"].append({"AXIdentifier": "vikingbar.historyMainPlot",
                                 "frame": [[650, 350], [280, 72]]})
        for identifier, field in (("vikingbar.historyMainSelectedDate", "fullDateText"),
                                  ("vikingbar.historyMainSelectedValue", "valueText"),
                                  ("vikingbar.historyMainSelectedStatus", "statusText")):
            tree["elements"].append({"AXIdentifier": identifier, "AXDescription": day[field],
                                     "frame": [[650, 300], [280, 20]]})
        self.assertTrue(HISTORY.compare_main_selection(tree, self.report, self.screens, 0))
        for identifier in ("vikingbar.historyMainSelectedDate", "vikingbar.historyMainSelectedValue",
                           "vikingbar.historyMainSelectedStatus"):
            altered = copy.deepcopy(tree)
            next(item for item in altered["elements"] if item.get("AXIdentifier") == identifier)["AXDescription"] = "wrong"
            with self.assertRaisesRegex(HISTORY.UIFailure, "native-history-main-selection-mismatch"):
                HISTORY.compare_main_selection(altered, self.report, self.screens, 0)
        with self.assertRaisesRegex(HISTORY.UIFailure, "native-history-main-selection-mismatch"):
            HISTORY.compare_main_selection(tree, self.report, self.screens, 29)
        tree["elements"].append({"AXIdentifier": "vikingbar.historyPanel"})
        with self.assertRaisesRegex(HISTORY.UIFailure, "native-history-hover-opened-detail"):
            HISTORY.compare_main_selection(tree, self.report, self.screens, 0)

    def test_source_hover_is_primed_outside_and_panel_absence_is_required(self):
        proof = object.__new__(HISTORY.HistoryProof)
        proof.screens = self.screens
        collapsed = copy.deepcopy(self.tree)
        collapsed["elements"] = [element for element in collapsed["elements"]
                                 if not element.get("AXIdentifier", "").startswith("vikingbar.history")
                                 or element.get("AXIdentifier") == "vikingbar.historyDisclosure"]
        collapsed["windows"] = [collapsed["windows"][0]]
        events = []

        def inspect(_label):
            self.assertEqual(events, ["vikingbar.refresh"])
            return collapsed

        with patch.object(proof, "hover", side_effect=lambda identifier, **_kwargs: events.append(identifier)), \
                patch.object(proof, "inspect", side_effect=inspect):
            proof.prime_history_hover("history-prime", self.report)
        self.assertEqual(events, ["vikingbar.refresh"])

        def wait_once(operation, predicate, seconds=90):
            if predicate(operation()):
                return True
            raise HISTORY.UIFailure("native-proof-timeout")

        with patch.object(proof, "hover"), patch.object(proof, "inspect", return_value=self.tree), \
                patch.object(HISTORY.UI, "wait_for", side_effect=wait_once):
            with self.assertRaisesRegex(HISTORY.UIFailure, "native-proof-timeout"):
                proof.prime_history_hover("history-prime", self.report)

    def test_capture_targets_both_matched_windows_and_rechecks_frames(self):
        proof = object.__new__(HISTORY.HistoryProof)
        windows = HISTORY.history_windows(self.tree, self.screens)
        group_frame = HISTORY.window_group_frame(windows)
        with tempfile.TemporaryDirectory() as directory:
            proof.directory, proof.screens = Path(directory), self.screens
            proof.peekaboo = "/synthetic/peekaboo"
            proof.process = type("Process", (), {"pid": 123})()

            def capture_window(_peekaboo, _pid, identifier, path, _invoke):
                window = next(item for item in self.tree["windows"]
                              if item["kCGWindowNumber"] == identifier)
                _, _, width, height = HISTORY.UI.frame({"frame": group_frame})
                path.write_bytes(HISTORY.PNG_SIGNATURE + b"\x00\x00\x00\rIHDR"
                                 + int(width * 2).to_bytes(4, "big")
                                 + int(height * 2).to_bytes(4, "big"))
                logical_bounds = HISTORY.window_frame(window)
                return {"success": True, "target_receipt": {"pid": 123, "window_id": identifier},
                        "data": {"files": [{"window_id": identifier, "path": str(path)}],
                                 "observations": [{
                                     "target": {"window_id": identifier, "resolved_kind": "window-id",
                                                "requested_kind": "pid", "source": "window-id",
                                                "bounds": logical_bounds},
                                     "coordinates": {"coordinate_space": "global_display_points",
                                                     "logical_bounds": logical_bounds},
                                 }]}}

            with patch.object(HISTORY.UI.UI, "capture_exact_window", side_effect=capture_window) as capture, \
                    patch.object(proof, "inspect", return_value=self.tree), \
                    patch.object(proof, "verify_process"):
                proof.capture_history_windows("history", self.report, windows, 0)
            self.assertEqual([call.args[2] for call in capture.call_args_list], [1, 2])
            self.assertEqual([call.args[3] for call in capture.call_args_list],
                             [Path(directory) / "history-main-target-group.png",
                              Path(directory) / "history-companion-target-group.png"])

            changed = copy.deepcopy(self.tree)
            changed["windows"][1]["kCGWindowBounds"]["Width"] += 2
            with patch.object(HISTORY.UI.UI, "capture_exact_window", side_effect=capture_window), \
                    patch.object(proof, "inspect", return_value=changed), \
                    patch.object(proof, "verify_process"):
                with self.assertRaises(HISTORY.UIFailure):
                    proof.capture_history_windows("changed", self.report, windows, 0)

            changed_selection = copy.deepcopy(self.tree)
            days = self.report["historyPresentation"]["days"]
            for identifier, field in (("vikingbar.historySelectedDate", "fullDateText"),
                                      ("vikingbar.historySelectedValue", "valueText"),
                                      ("vikingbar.historySelectedStatus", "statusText")):
                next(element for element in changed_selection["elements"]
                     if element.get("AXIdentifier") == identifier)["AXValue"] = days[1][field]
            with patch.object(HISTORY.UI.UI, "capture_exact_window", side_effect=capture_window), \
                    patch.object(proof, "inspect", return_value=changed_selection), \
                    patch.object(proof, "verify_process"):
                with self.assertRaisesRegex(HISTORY.UIFailure, "native-history-capture-mismatch"):
                    proof.capture_history_windows("selection-changed", self.report, windows, 0)

    def test_window_group_frame_is_exact_union_and_capture_rejects_member_size(self):
        windows = HISTORY.history_windows(self.tree, self.screens)
        group_frame = HISTORY.window_group_frame(windows)
        self.assertEqual(group_frame, [[200, 50], [780, 760]])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "group.png"
            for width, height, valid in ((1560, 1520, True), (780, 760, True), (760, 1300, False),
                                         (1560, 760, False), (10, 10, False), (0, 1520, False)):
                with self.subTest(width=width, height=height):
                    path.write_bytes(HISTORY.PNG_SIGNATURE + b"\x00\x00\x00\rIHDR"
                                     + width.to_bytes(4, "big") + height.to_bytes(4, "big"))
                    if valid:
                        HISTORY.validate_capture_geometry(path, group_frame)
                    else:
                        with self.assertRaisesRegex(
                                HISTORY.UIFailure, "native-history-capture-geometry-mismatch"):
                            HISTORY.validate_capture_geometry(path, group_frame)

    def test_capture_observation_requires_exact_window_and_both_reported_bounds(self):
        window = self.tree["windows"][1]
        bounds = HISTORY.window_frame(window)
        receipt = {"data": {"observations": [{
            "target": {"window_id": 2, "resolved_kind": "window-id", "requested_kind": "pid",
                       "source": "window-id", "bounds": bounds},
            "coordinates": {"coordinate_space": "global_display_points", "logical_bounds": bounds},
        }]}}
        self.assertEqual(HISTORY.validate_capture_observation(receipt, window), receipt)
        for mutate in (
                lambda value: value["data"]["observations"][0]["target"].update(requested_kind="window-id"),
                lambda value: value["data"]["observations"][0]["target"].update(resolved_kind="pid"),
                lambda value: value["data"]["observations"][0]["target"].update(source="pid"),
                lambda value: value["data"]["observations"][0]["target"].update(window_id=3),
                lambda value: value["data"]["observations"][0]["target"].update(window_id=True),
                lambda value: value["data"]["observations"][0]["target"]["bounds"][0].__setitem__(0, 201),
                lambda value: value["data"]["observations"][0]["coordinates"]["logical_bounds"][1].__setitem__(
                    0, 381),
                lambda value: value["data"]["observations"][0]["coordinates"].update(
                    coordinate_space="image_pixels"),
                lambda value: value["data"].update(observations=[]),
        ):
            altered = copy.deepcopy(receipt)
            mutate(altered)
            with self.assertRaisesRegex(
                    HISTORY.UIFailure, "native-history-capture-observation-mismatch"):
                HISTORY.validate_capture_observation(altered, window)

    def test_stored_session_proof_does_not_require_credential_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(HISTORY.UI, "ROOT", Path(directory)):
                proof = HISTORY.HistoryProof({"PEEKABOO_BIN": __file__})
                self.assertIsNone(proof.reference)
                self.assertEqual(proof.launches, [])
                self.assertTrue(proof.directory.exists())
                with self.assertRaisesRegex(HISTORY.UIFailure, "credential-reference-required"):
                    proof.launch(first=True)

    def test_failed_run_always_cleans_up(self):
        with patch.object(HISTORY, "HistoryProof") as factory:
            factory.return_value.perform.side_effect = HISTORY.UIFailure("history-evidence-insufficient")
            with self.assertRaisesRegex(HISTORY.UIFailure, "history-evidence-insufficient"):
                HISTORY.run({})
            factory.return_value.cleanup.assert_called_once()

    def test_termination_signals_cleanup_once_and_restore_process_state(self):
        child = """
import importlib.util
import json
import os
import signal
import subprocess
import sys
spec = importlib.util.spec_from_file_location('history_signal', sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
received = getattr(signal, sys.argv[2])
cleanup_fails = sys.argv[3] == 'yes'
handlers = {number: signal.getsignal(number) for number in (signal.SIGTERM, signal.SIGINT)}
mask = os.umask(0o027)
class FakeProof:
    launch_in_progress = False
    def __init__(self, environment): pass
    def perform(self):
        identity = subprocess.check_output(
            ['ps', '-p', str(os.getpid()), '-o', 'pid=,ppid=,lstart=,command='], text=True).strip()
        print(json.dumps({'phase': 'perform', 'identity': identity,
                          'task': 'inert history signal regression'}), flush=True)
        os.kill(os.getpid(), received)
    def cleanup(self):
        print(json.dumps({'phase': 'cleanup'}), flush=True)
        os.kill(os.getpid(), signal.SIGTERM)
        os.kill(os.getpid(), signal.SIGINT)
        if cleanup_fails:
            raise RuntimeError('synthetic cleanup failure')
module.HistoryProof = FakeProof
code = module.main()
restored = all(signal.getsignal(number) == old for number, old in handlers.items())
print(json.dumps({'phase': 'restored', 'handlers': restored, 'umask': os.umask(mask) == 0o027}))
sys.exit(code)
"""
        for signal_name in ("SIGTERM", "SIGINT"):
            for cleanup_fails in ("no", "yes"):
                with self.subTest(signal=signal_name, cleanup_fails=cleanup_fails):
                    result = subprocess.run(
                        [sys.executable, "-c", child, str(ROOT / "Scripts/history-proof.py"),
                         signal_name, cleanup_fails], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    events = [json.loads(line) for line in result.stdout.splitlines()]
                    self.assertEqual(sum(event.get("phase") == "cleanup" for event in events), 1)
                    self.assertEqual(events[-1], {"phase": "restored", "handlers": True, "umask": True})
                    error = "history-proof-interrupted" if cleanup_fails == "no" else "history-proof-failed"
                    self.assertIn({"passed": False, "error": error}, events)
                    self.assertEqual(result.stderr, "")

    def test_signals_escape_real_retry_and_defer_until_inert_launch_registration(self):
        for mode in ("retry", "before-spawn", "registration"):
            for number in ("SIGTERM", "SIGINT"):
                with self.subTest(mode=mode, signal=number):
                    directory = tempfile.mkdtemp(prefix="vikingbar-history-signal-")
                    result = subprocess.run(
                        [sys.executable, str(ROOT / "Scripts/tests/history-signal-driver.py"),
                         directory, mode, number], capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                    events = [json.loads(line) for line in result.stdout.splitlines()]
                    self.assertIn({"passed": False, "error": "history-proof-interrupted"}, events)
                    self.assertIn({"behavior_passed": True, "mode": mode}, events)


class InspectUIHoverGeometryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="vikingbar-hover-geometry-")
        cls.addClassCleanup(cls.directory.cleanup)
        source = (ROOT / "Scripts/inspect-ui.swift").read_text().split("let arguments =", 1)[0]
        harness = Path(cls.directory.name) / "hover-geometry.swift"
        harness.write_text(source + r'''
let display = CGRect(x: -1200, y: -900, width: 1200, height: 900)
let target = CGRect(x: -900, y: -700, width: 300, height: 120)
let first = try hoverPoint(frame: target, normalizedX: 0, normalizedY: 0, displays: [display])
let last = try hoverPoint(frame: target, normalizedX: 1, normalizedY: 1, displays: [display])
precondition(first == CGPoint(x: -899, y: -699))
precondition(last == CGPoint(x: -601, y: -581))
precondition(target.contains(first) && target.contains(last))
for invalid in [-0.01, Double.nan, Double.infinity, 1.01] {
    do {
        _ = try hoverPoint(frame: target, normalizedX: invalid, normalizedY: 0.5, displays: [display])
        fatalError("Invalid normalized coordinate was accepted")
    } catch ResolutionFailure.unavailable {}
}
do {
    _ = try hoverPoint(frame: target, normalizedX: 0.5, normalizedY: 0.5,
                       displays: [CGRect(x: 0, y: 0, width: 100, height: 100)])
    fatalError("Off-display target was accepted")
} catch ResolutionFailure.unavailable {}
do {
    _ = try hoverPoint(frame: CGRect(x: -900, y: -700, width: 2, height: 120),
                       normalizedX: 0.5, normalizedY: 0.5, displays: [display])
    fatalError("Target without an interior point was accepted")
} catch ResolutionFailure.unavailable {}
print("hover-geometry-passed")
''')
        cls.executable = Path(cls.directory.name) / "hover-geometry"
        result = subprocess.run(["swiftc", str(harness), "-o", str(cls.executable)],
                                capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError(result.stderr)

    def test_normalized_endpoints_are_interior_and_invalid_targets_do_not_dispatch(self):
        result = subprocess.run([str(self.executable)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "hover-geometry-passed")


class HistoryOracleTests(unittest.TestCase):
    def test_independent_oracle_rejects_mapping_identity_and_forecast_mutations(self):
        with tempfile.TemporaryDirectory(prefix="vikingbar-history-oracle-") as directory:
            executable = Path(directory) / "history-oracle"
            objects = sorted((ROOT / ".build/debug/VikingBarCore.build").glob("*.swift.o"))
            self.assertTrue(objects, "swift build must precede the synthetic oracle check")
            sources = [ROOT / "Sources/VikingBarCLI/HistoryOracle.swift", ROOT / "Scripts/tests/history-oracle-driver.swift"]
            result = subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library",
                                     "-I", str(ROOT / ".build/debug/Modules"), *map(str, sources),
                                     *map(str, objects), "-o", str(executable)], capture_output=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            result = subprocess.run([str(executable)], capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(result.stdout.strip(), b"history-oracle-passed")


if __name__ == "__main__":
    unittest.main()
