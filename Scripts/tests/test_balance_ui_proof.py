import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("balance_ui_proof", ROOT / "Scripts/balance-ui-proof.py")
UI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UI)


class BalanceUIProofTests(unittest.TestCase):
    def setUp(self):
        self.screens = [{"bounds": {"x": 0, "y": 0, "width": 1000, "height": 800}}]
        self.menu = {"remainingText": "30.00 GB", "freshnessText": "Last updated today", "accessibilityLabel": "VikingBar",
                     "title": "Synthetic SIM", "balanceTitle": "Data remaining", "usedText": "20.00 GB used",
                     "totalText": "50.00 GB total", "expiryText": "Expires tomorrow", "sourceLabel": "Live"}
        snapshot = {"source": {"live": {}}, "freshness": {"current": {"lastUpdated": "2026-09-07T12:00:00Z"}}}
        self.report = {"schemaVersion": 1, "snapshot": snapshot, "menu": self.menu,
                       "balanceDetails": {"extraChargesText": "Extra charges: €1.23", "bundleTitle": "Data",
                                          "bundleDescription": "Domestic", "applicabilityText": "national"},
                       "state": {"snapshot": snapshot, "connectionID": "synthetic", "balance": {"bundles": [1]},
                                 "selectedSubscriptionID": "synthetic", "selectedBundleIndex": 0}}
        self.tree = {"elements": [{"AXIdentifier": "vikingbar.status", "AXDescription": "VikingBar, Synthetic SIM, Last updated today",
                                   "frame": [[100, 0], [50, 24]]},
                                  {"AXIdentifier": "vikingbar.remaining", "AXValue": "30.00 GB"},
                                  {"AXIdentifier": "vikingbar.freshness", "AXValue": "Last updated today"}]
                                + [{"AXValue": value} for value in self.menu.values()]
                                + [{"AXValue": value} for value in self.report["balanceDetails"].values()]}
        for element in self.tree["elements"][1:]:
            element["frame"] = [[120, 100], [200, 20]]
        self.tree["elements"].append({"AXRole": "AXPopover", "frame": [[100, 24], [500, 700]]})
        self.tree["windows"] = [{"kCGWindowNumber": 42,
                                 "kCGWindowBounds": {"X": 100, "Y": 24, "Width": 500, "Height": 700}}]

    def test_offscreen_card_fails_with_visible_status(self):
        for element in self.tree["elements"][1:]:
            element["frame"][0][0] += 2000
        self.tree["windows"][0]["kCGWindowBounds"]["X"] += 2000
        self.assertTrue(UI.visible_status(self.tree, self.screens))
        with self.assertRaises(UI.UIFailure):
            UI.compare_menu(self.tree, self.report, self.screens)

    def test_popover_match_required(self):
        for change in ("ax", "cg", "mismatch"):
            tree = copy.deepcopy(self.tree)
            if change == "ax":
                tree["elements"].pop()
            elif change == "cg":
                tree["windows"] = []
            else:
                tree["windows"][0]["kCGWindowBounds"]["Y"] += 2
            with self.subTest(change=change), self.assertRaises(UI.UIFailure):
                UI.compare_menu(tree, self.report, self.screens)

    def test_card_text_requires_contained_valid_frames(self):
        for identifier in ("vikingbar.remaining", "vikingbar.freshness", None):
            for bad_frame in (None, [[2000, 100], [200, 20]], [[120, 100], [True, 20]],
                              [[120, 100], [float("inf"), 20]], [["120", 100], [200, 20]]):
                tree = copy.deepcopy(self.tree)
                for element in tree["elements"]:
                    if element.get("AXIdentifier") == identifier and element.get("AXRole") != "AXPopover":
                        element["frame"] = bad_frame
                with self.subTest(identifier=identifier, frame=bad_frame), self.assertRaises(UI.UIFailure):
                    UI.compare_menu(tree, self.report, self.screens)

    def test_invalid_popover_and_window_geometry_fails(self):
        for target in ("ax", "cg"):
            for index, key in enumerate(("X", "Y", "Width", "Height")):
                for bad in (True, "100", None, float("nan"), float("inf"), float("-inf")):
                    tree = copy.deepcopy(self.tree)
                    if target == "ax":
                        tree["elements"][-1]["frame"][index // 2][index % 2] = bad
                    else:
                        tree["windows"][0]["kCGWindowBounds"][key] = bad
                    with self.subTest(target=target, key=key, bad=bad), self.assertRaises(UI.UIFailure):
                        UI.compare_menu(tree, self.report, self.screens)

    def test_missing_or_nonpositive_geometry_fails(self):
        for target in ("ax", "cg", "display"):
            for bad in (None, 0, -1):
                tree, screens = copy.deepcopy(self.tree), copy.deepcopy(self.screens)
                if target == "ax":
                    if bad is None:
                        del tree["elements"][-1]["frame"]
                    else:
                        tree["elements"][-1]["frame"][1][0] = bad
                else:
                    bounds = tree["windows"][0]["kCGWindowBounds"] if target == "cg" else screens[0]["bounds"]
                    key = "Width" if target == "cg" else "width"
                    if bad is None:
                        del bounds[key]
                    else:
                        bounds[key] = bad
                with self.subTest(target=target, bad=bad), self.assertRaises(UI.UIFailure):
                    UI.compare_menu(tree, self.report, screens)

    def test_hidden_status_label_cannot_match_visible_wrong_status(self):
        hidden_status = copy.deepcopy(self.tree["elements"][0])
        hidden_status["frame"][0][0] = 2000
        self.tree["elements"][0]["AXDescription"] = "Wrong account"
        self.tree["elements"].append(hidden_status)
        with self.assertRaisesRegex(UI.UIFailure, "native-menu-mismatch"):
            UI.compare_menu(self.tree, self.report, self.screens)

    def test_invalid_display_cannot_make_offscreen_card_visible(self):
        for key in ("x", "y", "width", "height"):
            for bad in (True, "100", None, float("nan"), float("inf"), float("-inf")):
                screen = {"bounds": {"x": 0, "y": 0, "width": 3000, "height": 3000}}
                screen["bounds"][key] = bad
                tree = copy.deepcopy(self.tree)
                for element in tree["elements"][1:]:
                    element["frame"][0][0] += 1500
                    element["frame"][0][1] += 1000
                tree["windows"][0]["kCGWindowBounds"]["X"] += 1500
                tree["windows"][0]["kCGWindowBounds"]["Y"] += 1000
                with self.subTest(key=key, bad=bad), self.assertRaises(UI.UIFailure):
                    UI.compare_menu(tree, self.report, self.screens + [screen])

    def test_balance_capture_uses_matched_popover_window(self):
        self.tree["windows"].insert(0, {"kCGWindowNumber": 99,
                                       "kCGWindowBounds": {"X": 0, "Y": 0, "Width": 900, "Height": 750}})
        proof = object.__new__(UI.NativeProof)
        proof.cli = "synthetic-cli"
        proof.directory = Path("/synthetic")
        proof.screens = self.screens
        with patch.object(proof, "run", return_value=self.report), \
                patch.object(proof, "inspect", return_value=self.tree), \
                patch.object(proof, "verify_worker"), patch.object(proof, "peek") as peek:
            proof.matched_balance("synthetic")
        self.assertEqual(peek.call_args.args[0][2], "42")

    def test_visible_menu_matches_private_live_report(self):
        UI.compare_menu(self.tree, self.report, self.screens)
        self.tree["elements"][1]["AXValue"] = "99.00 GB"
        with self.assertRaisesRegex(UI.UIFailure, "native-menu-mismatch"):
            UI.compare_menu(self.tree, self.report, self.screens)

    def test_offscreen_fixture_stale_and_cross_sim_reports_fail(self):
        tree = copy.deepcopy(self.tree)
        tree["elements"][0]["frame"] = [[2000, 0], [50, 24]]
        self.assertFalse(UI.visible_status(tree, self.screens))
        for change in ("fixture", "stale", "snapshot"):
            report = copy.deepcopy(self.report)
            if change == "fixture":
                report["snapshot"]["source"] = {"fixture": {}}
            elif change == "stale":
                report["snapshot"]["freshness"] = {"stale": {"lastUpdated": "2026-09-07T12:00:00Z"}}
            else:
                report["state"]["snapshot"] = {}
            with self.assertRaises(UI.UIFailure):
                UI.successful_timestamp(report)

    def test_wrong_extra_charges_fail_native_comparison(self):
        self.report["balanceDetails"]["extraChargesText"] = "Extra charges: €0.00"
        with self.assertRaisesRegex(UI.UIFailure, "native-balance-details-mismatch"):
            UI.compare_menu(self.tree, self.report, self.screens)

    def test_api_receipt_rejects_missing_skipped_and_private_fields(self):
        receipt = {"schema_version": 1, "check": "balance-api", "passed": True, "api_matches": True,
                   "token_refreshed": True, "bundle_count": 1}
        self.assertEqual(UI.validate_api_receipt(receipt), receipt)
        for delta in ({"api_matches": False}, {"token_refreshed": False}, {"raw": "private"},
                      {"bundle_count": 0}, {"bundle_count": True}):
            with self.assertRaises(UI.UIFailure):
                UI.validate_api_receipt(dict(receipt, **delta))

    def test_private_evidence_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "result.json"
            UI.private_write(target, self.report)
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)

    def test_native_connect_reports_only_allowlisted_failure_stage(self):
        for code in UI.CONNECT.FAILURE_CODES:
            with self.assertRaisesRegex(UI.UIFailure, "^native-connect-" + code + "$"):
                UI.validate_connect_receipt({"passed": False, "error": code})
        for receipt in ({"passed": False, "error": "private-provider-sentinel"},
                        {"passed": False, "error": "token-network", "raw": "private-provider-sentinel"},
                        {"schema_version": True, "check": "connect", "passed": True, "connected": True}):
            with self.assertRaisesRegex(UI.UIFailure, "^native-connect-failed$"):
                UI.validate_connect_receipt(receipt)


class BalanceOracleTests(unittest.TestCase):
    def test_independent_oracle_detects_mapping_and_identity_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "OracleTest.swift"
            source.write_text(ORACLE_TEST)
            executable = Path(directory) / "oracle-test"
            objects = sorted((ROOT / ".build/debug/VikingBarCore.build").glob("*.swift.o"))
            self.assertTrue(objects, "swift build must precede the synthetic oracle check")
            result = subprocess.run(["swiftc", "-parse-as-library", "-I", str(ROOT / ".build/debug/Modules"),
                                     str(ROOT / "Sources/VikingBarCLI/BalanceOracle.swift"), str(source),
                                     *map(str, objects), "-o", str(executable)], capture_output=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            result = subprocess.run([str(executable)], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(result.stdout.strip(), b"oracle-passed")


ORACLE_TEST = r'''
import Foundation
import VikingBarCore

struct SyntheticTransport: ProofHTTPTransport {
    func send(_ request: URLRequest) async throws -> ProofHTTPResponse {
        let value: String
        switch request.url!.path {
        case "/mv/oauth2/token/": value = "{}"
        case "/mv/subscriptions": value = #"[{"id":"sim-one","type":"postpaid","sim":{"pin":"not-exported"}}]"#
        default: value = #"{"bundles":[{"descriptions":{"title":"Data","description":"Domestic"},"category":"default","type":"data","total":50000000000,"used":20000000000,"remaining":30000000000,"valid_from":"2026-09-01T00:00:00Z","valid_until":"2026-10-01T00:00:00Z"}],"regionality":"national","out_of_bundle_cost":0}"#
        }
        return ProofHTTPResponse(statusCode: 200, data: Data(value.utf8))
    }
}

@main struct OracleTest {
    static func main() async throws {
        let oracle = BalanceOracleTransport(base: SyntheticTransport())
        var token = try ProofEndpoint.token.request()
        token.httpBody = Data("grant_type=refresh_token".utf8)
        _ = try await oracle.send(token)
        _ = try await oracle.send(ProofEndpoint.subscriptions.request())
        _ = try await oracle.send(ProofEndpoint.balance(subscriptionID: "sim-one").request())
        let raw = #"{"connectionID":{"rawValue":"00000000-0000-0000-0000-000000000001"},"subscriptions":[{"id":"sim-one","type":"postpaid","displayName":"SIM"}],"selectedSubscriptionID":"sim-one","balance":{"bundles":[{"title":"Data","description":"Domestic","category":"default","type":"data","total":50000000000,"used":20000000000,"remaining":30000000000,"validFrom":"2026-09-01T00:00:00Z","validUntil":"2026-10-01T00:00:00Z"}],"regionality":"national","outOfBundleCost":0},"selectedBundleIndex":0,"snapshot":{"source":{"live":{}},"subscriptionName":"SIM","allowance":{"finite":{"totalBytes":50000000000,"usedBytes":20000000000,"remainingBytes":30000000000}},"expiresAt":"2026-10-01T00:00:00Z","freshness":{"current":{"lastUpdated":"2026-09-07T12:00:00Z"}}},"isRefreshing":false,"scopeMismatch":true}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(LiveSessionState.self, from: Data(raw.utf8))
        _ = try await oracle.receipt(state: state)
        for altered in [raw.replacingOccurrences(of: "remainingBytes\":30000000000", with: "remainingBytes\":10000000000"),
                        raw.replacingOccurrences(of: "selectedSubscriptionID\":\"sim-one", with: "selectedSubscriptionID\":\"sim-two"),
                        raw.replacingOccurrences(of: "outOfBundleCost\":0", with: "outOfBundleCost\":7")] {
            let changed = try decoder.decode(LiveSessionState.self, from: Data(altered.utf8))
            do {
                _ = try await oracle.receipt(state: changed)
                fatalError("Oracle accepted a mapping mismatch")
            } catch ProofFailure.malformedResponse {}
        }
        print("oracle-passed")
    }
}
'''


if __name__ == "__main__":
    unittest.main()
