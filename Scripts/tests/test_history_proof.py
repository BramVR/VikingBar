import copy
import importlib.util
from pathlib import Path
import tempfile
import subprocess
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
        days = [{"label": f"Sep {day}", "valueText": "1.00 GB", "isStale": False} for day in range(1, 8)]
        self.presentation = {"days": days, "forecast": {"estimatedCycleBytes": 30_000_000_000},
                             "unit": "GB", "forecastText": "Estimated SIM data this cycle: 30.00 GB",
                             "totalText": "Observed SIM data: 7.00 GB",
                             "statusText": "7 reported days", "scopeText": "All SIM data in this bundle period"}
        snapshot = {"source": {"live": {}}, "freshness": {"current": {"lastUpdated": "2026-09-07T12:00:00Z"}}}
        cycle = {"cycleStart": "2026-09-01T00:00:00Z", "cycleEnd": "2026-10-01T00:00:00Z"}
        self.report = {"schemaVersion": 1, "snapshot": snapshot, "historyPresentation": self.presentation,
                       "state": {"snapshot": snapshot, "connectionID": "connection-one", "historyRevision": "revision-one",
                                 "selectedSubscriptionID": "sim-one", "selectedBundleIndex": 0,
                                 "balance": {"bundles": [{"validFrom": cycle["cycleStart"], "validUntil": cycle["cycleEnd"]}]},
                                 "history": {"context": {"connectionID": "connection-one", "subscriptionID": "sim-one",
                                                         "bundleIndex": 0, "revision": "revision-one", "bundle": cycle},
                                             "attemptedAt": "2026-09-07T12:00:00Z", "truncated": False,
                                             "observations": [{}] * len(days)}}}
        self.screens = [{"bounds": {"x": 0, "y": 0, "width": 1000, "height": 900}}]
        self.chart = {"AXIdentifier": "vikingbar.historyChart", "frame": [[200, 200], [300, 140]],
                      "AXValue": "; ".join(day["label"] + ": " + day["valueText"] for day in days)}
        self.tree = {"elements": [self.chart] + [{"AXIdentifier": identifier, "AXValue": self.presentation[field]}
                                               for identifier, field in (("vikingbar.historyForecast", "forecastText"),
                                                                         ("vikingbar.historyTotal", "totalText"),
                                                                         ("vikingbar.historyStatus", "statusText"),
                                                                         ("vikingbar.historyScope", "scopeText"))],
                     "windows": [{"kCGWindowNumber": 1, "kCGWindowBounds": {"X": 180, "Y": 50, "Width": 360, "Height": 760}}]}

        balance = BALANCE.BalanceUIProofTests()
        balance.setUp()
        self.report.update(menu=balance.report["menu"], balanceDetails=balance.report["balanceDetails"])
        for element in balance.tree["elements"]:
            if element.get("AXIdentifier") != "vikingbar.status":
                element["frame"] = [[210, 100], [100, 20]]
        for element in self.tree["elements"][1:]:
            element["frame"] = [[210, 400], [300, 20]]
        self.tree["elements"] += balance.tree["elements"]
        self.tree["elements"].append({"AXRole": "AXPopover", "frame": [[180, 50], [360, 760]]})

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
        self.assertEqual(HISTORY.compare_history(self.tree, self.report, self.screens)["kCGWindowNumber"], 1)
        for frame in ([[2000, 200], [300, 140]], [[200, 850], [300, 140]], [[200, 200], [0, 0]],
                      [[600, 200], [300, 140]]):
            tree = copy.deepcopy(self.tree)
            tree["elements"][0]["frame"] = frame
            with self.assertRaises(HISTORY.UIFailure):
                HISTORY.compare_history(tree, self.report, self.screens)
        self.chart["AXValue"] = "Sep 1: 99.00 GB"
        with self.assertRaisesRegex(HISTORY.UIFailure, "native-history-chart-values-mismatch"):
            HISTORY.compare_history(self.tree, self.report, self.screens)

    def test_chart_forecast_text_and_stale_samples_fail(self):
        tree = copy.deepcopy(self.tree)
        tree["elements"][1]["AXValue"] = "Not an estimate"
        with self.assertRaisesRegex(HISTORY.UIFailure, "native-history-text-mismatch"):
            HISTORY.compare_history(tree, self.report, self.screens)
        self.presentation["days"][0]["isStale"] = True
        with self.assertRaises(HISTORY.UIFailure):
            HISTORY.compare_history(self.tree, self.report, self.screens)

    def test_every_required_history_element_must_be_fully_visible_in_same_popover(self):
        for index in range(5):
            for frame in (None, [[2100, 100], [300, 20]], [[210, 800], [300, 20]],
                          [[170, 400], [300, 20]], [[210, 400], [True, 20]],
                          [[float("nan"), 400], [300, 20]], [[210, 400], [300, float("inf")]],
                          [[210, 400], [-1, 20]], [[210, 400], [0, 20]], [[210, 400], [300]],
                          [[210, 400], [10**1000, 20]]):
                with self.subTest(index=index, frame=frame):
                    tree = copy.deepcopy(self.tree)
                    tree["elements"][index]["frame"] = frame
                    with self.assertRaises(HISTORY.UIFailure):
                        HISTORY.compare_history(tree, self.report, self.screens)

    def test_popover_window_and_display_geometry_must_match_without_ambiguity(self):
        mutations = [
            lambda t: t["elements"].pop(),
            lambda t: t["elements"].append(copy.deepcopy(t["elements"][-1])),
            lambda t: t["windows"].append(copy.deepcopy(t["windows"][0])),
            lambda t: t["windows"][0]["kCGWindowBounds"].update(X=179),
            lambda t: t["windows"][0]["kCGWindowBounds"].update(Width=float("inf")),
            lambda t: t["windows"][0].update(kCGWindowNumber=True),
            lambda t: t["elements"][-1].update(frame=[[180, True], [360, 760]]),
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
        self.tree["windows"][0]["kCGWindowBounds"].update(X=-820, Y=-850)
        self.screens.append({"bounds": {"x": -1000, "y": -900, "width": 1000, "height": 900}})
        self.tree["windows"].insert(0, {"kCGWindowNumber": 2,
                                      "kCGWindowBounds": {"X": -900, "Y": -900, "Width": 800, "Height": 900}})
        self.assertEqual(HISTORY.compare_history(self.tree, self.report, self.screens)["kCGWindowNumber"], 1)

    def test_capture_receipt_requires_same_window_bounds_and_destination(self):
        window = self.tree["windows"][0]
        path = Path("/synthetic/history-chart.png")
        capture = {"files": [{"window_id": 1, "path": str(path)}],
                   "observations": [{"target": {"window_id": 1, "bounds": [[180, 50], [360, 760]]}}]}
        HISTORY.validate_capture(capture, window, path)
        for mutate in (
                lambda c: c["files"][0].update(window_id=2),
                lambda c: c["files"][0].update(window_id=True),
                lambda c: c["files"][0].update(path="/wrong.png"),
                lambda c: c["observations"][0]["target"].update(window_id=2),
                lambda c: c["observations"][0]["target"].update(bounds=[[180, 50], [360, float("inf")]]),
                lambda c: c["observations"][0]["target"].update(bounds=[[181, 50], [360, 760]]),
                lambda c: c.update(observations=[])):
            altered = copy.deepcopy(capture)
            mutate(altered)
            with self.assertRaisesRegex(HISTORY.UIFailure, "native-history-capture-mismatch"):
                HISTORY.validate_capture(altered, window, path)

    def test_capture_uses_matched_window_and_rechecks_card_after_capture(self):
        path = Path("/synthetic/history-chart.png")
        capture = {"files": [{"window_id": 1, "path": str(path)}],
                   "observations": [{"target": {"window_id": 1, "bounds": [[180, 50], [360, 760]]}}]}
        self.tree["windows"].insert(0, {"kCGWindowNumber": 2,
                                      "kCGWindowBounds": {"X": 0, "Y": 0, "Width": 1000, "Height": 900}})
        for changed in (False, True):
            proof = object.__new__(HISTORY.HistoryProof)
            proof.directory, proof.cli, proof.screens = Path("/synthetic"), Path("/synthetic/cli"), self.screens
            after = copy.deepcopy(self.tree)
            if changed:
                after["elements"][1]["frame"] = [[2100, 400], [300, 20]]
            with (patch.object(proof, "run", return_value=self.report),
                  patch.object(proof, "inspect", side_effect=[self.tree, after]),
                  patch.object(proof, "verify_worker"),
                  patch.object(proof, "peek", return_value=capture) as peek):
                if changed:
                    with self.assertRaises(HISTORY.UIFailure):
                        proof.matched_history("history")
                else:
                    self.assertEqual(proof.matched_history("history"), self.report)
                command = peek.call_args.args[0]
                self.assertEqual(command[command.index("--window-id") + 1], "1")

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
