import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("points_proof", ROOT / "Scripts/points-proof.py")
POINTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POINTS)


class PointsProofTests(unittest.TestCase):
    def setUp(self):
        freshness = {"current": {"lastUpdated": "2026-09-07T12:00:00Z"}}
        snapshot = {"source": {"live": {}}, "freshness": freshness}
        self.report = {"schemaVersion": 1, "snapshot": snapshot, "state": {
            "snapshot": snapshot, "connectionID": {"rawValue": "00000000-0000-0000-0000-000000000001"},
            "balance": {"bundles": [1]},
            "selectedSubscriptionID": "synthetic", "selectedBundleIndex": 0,
            "points": {"balance": {"available": 1}, "history": {"transactions": []},
                       "balanceFreshness": freshness, "historyFreshness": freshness}},
            "points": {"customerLabel": "Customer", "availableText": "Available: 1", "pendingText": "Pending: 0",
                       "blockedText": "Blocked: 0", "balanceStatus": "Up to date", "historyStatus": "Up to date",
                       "historySummary": "1 recent transactions", "transactions": [
                           {"amountText": "+1", "stateText": "Completed", "updatedText": "7 Sep 2026, 12:00",
                            "descriptionText": "Synthetic"}]}}
        self.screens = [{"bounds": {"x": 0, "y": 0, "width": 1000, "height": 1000}}]
        self.tree = {"elements": [
            {"AXIdentifier": "vikingbar.status", "frame": [[10, 0], [25, 20]]},
            {"AXRole": "AXPopover", "frame": [[10, 20], [500, 700]]},
            {"AXRole": "AXScrollArea", "AXIdentifier": "vikingbar.points.transactionsScroll",
             "frame": [[20, 200], [480, 300]]}],
            "windows": [{"kCGWindowNumber": 42,
                         "kCGWindowBounds": {"X": 10, "Y": 20, "Width": 500, "Height": 700}}]}
        for suffix, field in (("customerLabel", "customerLabel"), ("available", "availableText"),
                              ("pending", "pendingText"), ("blocked", "blockedText"),
                              ("balanceStatus", "balanceStatus"), ("historyStatus", "historyStatus"),
                              ("historySummary", "historySummary")):
            self.tree["elements"].append({"AXIdentifier": "vikingbar.points." + suffix,
                                          "AXValue": self.report["points"][field], "frame": [[30, 50], [100, 20]]})
        for suffix, field in (("amount", "amountText"), ("state", "stateText"),
                              ("updated", "updatedText"), ("description", "descriptionText")):
            self.tree["elements"].append({"AXIdentifier": "vikingbar.points.transaction.0." + suffix,
                                          "AXValue": self.report["points"]["transactions"][0][field],
                                          "frame": [[30, 210], [100, 20]]})

    def test_receipt_strict_public_schema(self):
        receipt = {"schema_version": 1, "check": "points-api", "passed": True, "api_matches": True,
                   "token_refreshed": True, "transaction_count": 0, "page_count": 1}
        self.assertEqual(POINTS.validate_api_receipt(receipt), receipt)
        for delta in ({"transaction_count": -1}, {"transaction_count": True}, {"page_count": 0},
                      {"page_count": 4}, {"page_count": True}, {"schema_version": True},
                      {"token_refreshed": False}, {"passed": False}, {"api_matches": False},
                      {"check": "balance-api"}, {"raw": "private"}):
            with self.subTest(delta=delta), self.assertRaises(POINTS.UIFailure):
                POINTS.validate_api_receipt(dict(receipt, **delta))

    def test_points_require_both_current_timestamps_and_live_usage(self):
        self.assertEqual(len(POINTS.points_timestamps(self.report)), 2)
        for key in ("balanceFreshness", "historyFreshness"):
            report = copy.deepcopy(self.report)
            report["state"]["points"][key] = {"stale": {"lastUpdated": "2026-09-07T12:00:00Z"}}
            with self.assertRaises(POINTS.UIFailure):
                POINTS.points_timestamps(report)
        for key in ("balanceFailure", "historyFailure"):
            report = copy.deepcopy(self.report)
            report["state"]["points"][key] = "transport"
            with self.assertRaises(POINTS.UIFailure):
                POINTS.points_timestamps(report)
        self.report["state"]["failure"] = "transport"
        with self.assertRaises(POINTS.UIFailure):
            POINTS.points_timestamps(self.report)

    def test_native_comparison_counts_only_first_visible_complete_row(self):
        self.report["points"]["transactions"] *= 60
        self.assertEqual(POINTS.compare_points(self.tree, self.report, self.screens, expanded=True), 1)
        self.tree["elements"][-1]["frame"] = [[30, 501], [100, 20]]
        with self.assertRaisesRegex(POINTS.UIFailure, "native-points-mismatch"):
            POINTS.compare_points(self.tree, self.report, self.screens, expanded=True)

    def test_wrong_value_and_missing_popover_fail(self):
        self.tree["elements"][-1]["AXValue"] = "wrong description"
        with self.assertRaises(POINTS.UIFailure):
            POINTS.compare_points(self.tree, self.report, self.screens, expanded=True)
        self.tree["windows"] = []
        with self.assertRaisesRegex(POINTS.UIFailure, "popover"):
            POINTS.compare_points(self.tree, self.report, self.screens)

    def test_propagated_disclosure_identifier_accepts_only_scroll_area(self):
        self.tree["elements"][2]["AXIdentifier"] = "vikingbar.points.transactionsToggle"
        self.tree["elements"].insert(2, {"AXRole": "AXDisclosureTriangle",
                                       "AXIdentifier": "vikingbar.points.transactionsToggle",
                                       "frame": [[20, 180], [100, 20]]})
        self.assertFalse(POINTS.is_transactions_scroll(self.tree["elements"][2]))
        self.assertTrue(POINTS.is_transactions_scroll(self.tree["elements"][3]))
        self.assertEqual(POINTS.compare_points(self.tree, self.report, self.screens, expanded=True), 1)
        self.tree["elements"].pop(3)
        with self.assertRaisesRegex(POINTS.UIFailure, "points-scroll-not-visible"):
            POINTS.compare_points(self.tree, self.report, self.screens, expanded=True)

    def test_scroll_identifiers_require_scroll_area_role(self):
        for identifier in ("vikingbar.points.transactionsScroll", "vikingbar.points.transactionsToggle"):
            for role in (None, "AXGroup", "AXDisclosureTriangle"):
                with self.subTest(identifier=identifier, role=role):
                    self.tree["elements"][2].update({"AXIdentifier": identifier, "AXRole": role})
                    with self.assertRaisesRegex(POINTS.UIFailure, "points-scroll-not-visible"):
                        POINTS.compare_points(self.tree, self.report, self.screens, expanded=True)

    def shifted_card(self, dx, dy):
        tree = copy.deepcopy(self.tree)
        for element in tree["elements"]:
            if element.get("AXIdentifier") != "vikingbar.status":
                element["frame"][0][0] += dx
                element["frame"][0][1] += dy
        bounds = tree["windows"][0]["kCGWindowBounds"]
        bounds["X"] += dx
        bounds["Y"] += dy
        return tree

    def test_offscreen_and_clipped_popover_fail_with_visible_status(self):
        for dx, dy in ((2000, 0), (-11, 0), (491, 0), (0, -21), (0, 281)):
            tree = self.shifted_card(dx, dy)
            with self.subTest(dx=dx, dy=dy):
                self.assertTrue(POINTS.UI.visible_status(tree, self.screens))
                for expanded in (False, True):
                    with self.assertRaises(POINTS.UIFailure):
                        POINTS.compare_points(tree, self.report, self.screens, expanded=expanded)

    def test_popover_on_secondary_display_accepts_positive_and_negative_origins(self):
        for x, y in ((2000, 1000), (-2000, -1000)):
            screens = self.screens + [{"bounds": {"x": x, "y": y, "width": 1000, "height": 1000}}]
            with self.subTest(x=x, y=y):
                self.assertEqual(POINTS.compare_points(self.shifted_card(x, y), self.report,
                                                      screens, expanded=True), 1)

    def test_popover_in_display_gap_fails(self):
        screens = self.screens + [{"bounds": {"x": 2000, "y": 0, "width": 1000, "height": 1000}}]
        with self.assertRaises(POINTS.UIFailure):
            POINTS.compare_points(self.shifted_card(1100, 0), self.report, screens, expanded=True)

    def test_mismatched_window_and_clipped_matching_window_fail(self):
        self.tree["windows"][0]["kCGWindowBounds"]["X"] += 2
        with self.assertRaises(POINTS.UIFailure):
            POINTS.compare_points(self.tree, self.report, self.screens, expanded=True)
        self.tree["windows"][0]["kCGWindowBounds"]["X"] -= 2
        tree = self.shifted_card(490, 0)
        tree["windows"][0]["kCGWindowBounds"]["Width"] += 0.5
        with self.assertRaises(POINTS.UIFailure):
            POINTS.compare_points(tree, self.report, self.screens, expanded=True)

    def test_scroll_outside_popover_fails(self):
        self.tree["elements"][2]["frame"][0][1] = 600
        for identifier in ("vikingbar.points.transactionsScroll", "vikingbar.points.transactionsToggle"):
            with self.subTest(identifier=identifier):
                self.tree["elements"][2]["AXIdentifier"] = identifier
                with self.assertRaisesRegex(POINTS.UIFailure, "points-scroll-not-visible"):
                    POINTS.compare_points(self.tree, self.report, self.screens, expanded=True)

    def test_exact_display_edges_and_subpixel_window_match_pass(self):
        tree = self.shifted_card(-10, -20)
        screens = [{"bounds": {"x": 0, "y": 0, "width": 500, "height": 700}}]
        self.assertEqual(POINTS.compare_points(tree, self.report, screens, expanded=True), 1)
        tree["windows"][0]["kCGWindowBounds"].update({"X": 0.5, "Width": 499.5})
        self.assertEqual(POINTS.compare_points(tree, self.report, screens, expanded=True), 1)

    def test_points_capture_rejects_offscreen_popover(self):
        proof = object.__new__(POINTS.PointsProof)
        proof.screens = self.screens
        with patch.object(proof, "peek") as peek, self.assertRaises(POINTS.UIFailure):
            proof.capture_points("synthetic", self.shifted_card(2000, 0))
        peek.assert_not_called()

    def test_stored_session_init_does_not_request_credential_reference(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(POINTS.UI, "ROOT", Path(directory)):
            binary = Path(directory) / "peekaboo"
            binary.touch()
            environment = {"PEEKABOO_BIN": str(binary)}
            with self.assertRaisesRegex(POINTS.UIFailure, "credential-reference-required"):
                POINTS.UI.NativeProof(environment)
            with patch.object(POINTS.UI.CONNECT, "run", side_effect=AssertionError("no bootstrap"), create=True):
                proof = POINTS.PointsProof(environment)
            self.assertIsNone(proof.reference)
            self.assertEqual(proof.launches, [])

    def test_stored_session_orchestration_packages_once_and_quits(self):
        calls = []
        report = self.report
        self.tree["elements"][2]["AXIdentifier"] = "vikingbar.points.transactionsToggle"
        self.tree["elements"].append({"AXRole": "AXDisclosureTriangle",
                                      "AXIdentifier": "vikingbar.points.transactionsToggle",
                                      "frame": [[20, 180], [100, 20]]})
        collapsed = copy.deepcopy(self.tree)
        collapsed["elements"] = [item for item in collapsed["elements"]
                                 if not POINTS.is_transactions_scroll(item)
                                 and not item.get("AXIdentifier", "").startswith("vikingbar.points.transaction.")]
        expanded_tree = self.tree

        class SyntheticProof:
            def run(self, command, name=None, timeout=None):
                calls.append(command)
                if command[1:] == ["proof", "points-api"]:
                    return json.dumps({"schema_version": 1, "check": "points-api", "passed": True,
                                       "api_matches": True, "token_refreshed": True,
                                       "transaction_count": 1, "page_count": 1})
                return report

            def peek(self, command, name):
                return {"screens": []} if command == ["screen", "list"] else {}

            def launch(self, first, label):
                calls.append(("launch", first))

            def matched_balance(self, label, after=None):
                return report

            def matched_points(self, label, after=None):
                calls.append(("matched", label, after is not None))
                return report

            def press(self, identifier):
                calls.append(("press", identifier))

            def inspect(self, name=None):
                return expanded_tree if name == "expanded-card.json" else collapsed

            def capture_points(self, label, tree):
                calls.append(("capture", label))

            def quit(self):
                calls.append(("quit",))

        with tempfile.TemporaryDirectory() as directory, patch.object(POINTS.time, "sleep"):
            proof = SyntheticProof()
            proof.directory = Path(directory)
            proof.executable = Path(directory) / "synthetic-app"
            proof.executable.write_bytes(b"synthetic")
            proof.cli = "synthetic-cli"
            proof.screens = self.screens
            with patch.object(POINTS, "compare_points", return_value=1):
                receipt = POINTS.PointsProof.perform(proof)
        self.assertTrue(receipt["native_quit"])
        self.assertEqual(calls.count(["./Scripts/package-app.sh"]), 1)
        self.assertIn(("launch", False), calls)
        self.assertIn(("matched", "refreshed", True), calls)
        self.assertEqual(calls[-1], ("quit",))
        self.assertNotIn("connect", str(calls))

    def test_cleanup_failure_cannot_publish_success(self):
        class FailedCleanup:
            def __init__(self, _environment):
                pass

            def perform(self):
                return {"passed": True}

            def cleanup(self):
                raise POINTS.UIFailure("cleanup-worker-still-running")

        with patch.object(POINTS, "PointsProof", FailedCleanup), patch.object(POINTS.UI, "private_write") as write:
            with self.assertRaisesRegex(POINTS.UIFailure, "cleanup-worker-still-running"):
                POINTS.run({})
            write.assert_not_called()

    def test_failure_still_attempts_cleanup_and_redacts_unexpected_errors(self):
        calls = []

        class FailedProof:
            def __init__(self, _environment):
                pass

            def perform(self):
                raise ValueError("private-provider-sentinel")

            def cleanup(self):
                calls.append("cleanup")

        output = io.StringIO()
        with patch.object(POINTS, "PointsProof", FailedProof), contextlib.redirect_stdout(output):
            self.assertEqual(POINTS.main(), 1)
        self.assertEqual(calls, ["cleanup"])
        self.assertEqual(json.loads(output.getvalue()), {"passed": False, "error": "points-proof-failed"})

    def test_dispatch_routes_points_without_credential_bootstrap(self):
        spec = importlib.util.spec_from_file_location("points_dispatch_test", ROOT / "Scripts/proof-live.py")
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        safe = {"check": "points", "passed": True}
        with patch.object(runner.importlib.util, "module_from_spec", return_value=POINTS), \
                patch.object(runner.importlib.util, "spec_from_file_location") as make_spec, \
                patch.object(POINTS, "run", return_value=safe) as run, \
                patch.object(runner, "credential_reference", side_effect=AssertionError("no bootstrap")):
            self.assertEqual(runner.run("points", {}), safe)
            run.assert_called_once_with({})
            self.assertEqual(make_spec.call_args.args[1].name, "points-proof.py")
            run.side_effect = POINTS.UIFailure("points-report-invalid")
            with self.assertRaisesRegex(runner.ProofFailure, "points-report-invalid"):
                runner.run("points", {})


if __name__ == "__main__":
    unittest.main()
