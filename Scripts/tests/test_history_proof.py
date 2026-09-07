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
        with patch.object(HISTORY.UI, "compare_menu"):
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
        with patch.object(HISTORY.UI, "compare_menu"):
            tree = copy.deepcopy(self.tree)
            tree["elements"][1]["AXValue"] = "Not an estimate"
            with self.assertRaisesRegex(HISTORY.UIFailure, "native-history-text-mismatch"):
                HISTORY.compare_history(tree, self.report, self.screens)
            self.presentation["days"][0]["isStale"] = True
            with self.assertRaises(HISTORY.UIFailure):
                HISTORY.compare_history(self.tree, self.report, self.screens)

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
