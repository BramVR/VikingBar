import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import ANY, Mock, patch

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

    def direct_form(self):
        form = copy.deepcopy(self.tree)
        form["elements"].extend({"AXIdentifier": "vikingbar.connect." + identifier,
                                 "frame": [[120, 100], [200, 20]]}
                                for identifier in ("client-id", "username", "password", "submit", "cancel"))
        form["elements"][-3].update(AXRole="AXTextField", AXSubrole="AXSecureTextField")
        return form

    def test_direct_form_wait_observes_transient_mismatch_before_configuration(self):
        proof = object.__new__(UI.NativeProof)
        proof.screens = self.screens
        stable = self.direct_form()
        transient = copy.deepcopy(stable)
        transient["windows"][0]["kCGWindowBounds"]["Height"] += 2
        observations = iter([transient, stable])
        events = []
        def inspect(*, deadline):
            self.assertIsInstance(deadline, float)
            events.append("observe")
            return next(observations)
        def configure(_environment):
            events.append("configure")
            raise UI.UIFailure("synthetic-stop-after-readiness")
        proof.environment = {}
        opening = {"elements": [{"AXIdentifier": "vikingbar.connect.direct"}]}
        with patch.object(proof, "press", side_effect=lambda _identifier: events.append("press")) as press, \
                patch.object(proof, "inspect", side_effect=inspect) as observe, \
                patch.object(UI, "direct_configuration", side_effect=configure), \
                patch.object(UI.CONNECT, "reference_at") as reference, \
                patch.object(UI.subprocess, "run") as execute, patch.object(UI.time, "sleep") as sleep:
            with self.assertRaisesRegex(UI.UIFailure, "^synthetic-stop-after-readiness$"):
                proof.connect_direct(opening)
        press.assert_called_once_with("vikingbar.connect.direct")
        self.assertEqual(observe.call_count, 2)
        self.assertEqual(events, ["press", "observe", "observe", "configure"])
        sleep.assert_called_once_with(0.25)
        reference.assert_not_called()
        execute.assert_not_called()

    def test_direct_form_wait_accepts_repeated_same_physical_match(self):
        proof = object.__new__(UI.NativeProof)
        proof.screens = self.screens
        form = self.direct_form()
        original = next(element for element in form["elements"] if element.get("AXRole") == "AXPopover")
        form["elements"].append(copy.deepcopy(original))
        form["windows"].append(copy.deepcopy(form["windows"][0]))
        with patch.object(proof, "inspect", return_value=form) as observe, patch.object(UI.time, "sleep") as sleep:
            observed, boundary = proof.wait_for_direct_form()
        self.assertIs(observed, form)
        self.assertIs(boundary, original)
        self.assertEqual(UI.popover_window(form, self.screens)[1]["kCGWindowNumber"], 42)
        observe.assert_called_once_with(deadline=ANY)
        sleep.assert_not_called()

    def test_distinct_exact_window_matches_fail_without_retry_or_credentials(self):
        proof = object.__new__(UI.NativeProof)
        proof.screens = self.screens
        form = self.direct_form()
        form["windows"].append(dict(form["windows"][0], kCGWindowNumber=43))
        opening = {"elements": [{"AXIdentifier": "vikingbar.connect.direct"}]}
        with patch.object(proof, "press") as press, \
                patch.object(proof, "inspect", side_effect=[form, self.direct_form()]) as observe, \
                patch.object(UI, "direct_configuration") as configure, \
                patch.object(UI.CONNECT, "reference_at") as reference, \
                patch.object(UI.subprocess, "run") as execute, patch.object(UI.time, "sleep") as sleep:
            with self.assertRaisesRegex(UI.UIFailure, "^native-popover-ambiguous$"):
                proof.connect_direct(opening)
        press.assert_called_once_with("vikingbar.connect.direct")
        observe.assert_called_once_with(deadline=ANY)
        sleep.assert_not_called()
        configure.assert_not_called()
        reference.assert_not_called()
        execute.assert_not_called()

    def test_direct_form_wait_does_not_mask_unrelated_failures(self):
        proof = object.__new__(UI.NativeProof)
        proof.screens = self.screens
        for code in ("process-identity-changed", "native-popover-not-visible"):
            with self.subTest(code=code), patch.object(proof, "inspect", side_effect=UI.UIFailure(code)) as observe, \
                    patch.object(UI.time, "sleep") as sleep:
                with self.assertRaisesRegex(UI.UIFailure, "^" + code + "$"):
                    proof.wait_for_direct_form()
                observe.assert_called_once_with(deadline=ANY)
                sleep.assert_not_called()
        with patch.object(proof, "inspect", return_value=self.direct_form()) as observe, \
                patch.object(UI, "popover_window", side_effect=UI.UIFailure("synthetic-unrelated")), \
                patch.object(UI.time, "sleep") as sleep:
            with self.assertRaisesRegex(UI.UIFailure, "^synthetic-unrelated$"):
                proof.wait_for_direct_form()
            observe.assert_called_once_with(deadline=ANY)
            sleep.assert_not_called()

    def test_direct_form_wait_requires_secure_contained_control_and_stops_at_fifteen_seconds(self):
        proof = object.__new__(UI.NativeProof)
        proof.screens = self.screens
        for change in ("missing", "unmasked", "outside"):
            form = self.direct_form()
            password = form["elements"][-3]
            if change == "missing":
                form["elements"].remove(password)
            elif change == "unmasked":
                password.pop("AXSubrole")
            else:
                password["frame"][0][0] = 2000
            with self.subTest(change=change), patch.object(proof, "inspect", return_value=form) as observe, \
                    patch.object(UI.time, "monotonic", side_effect=[0, 0, 0, 14.75, 15]), patch.object(UI.time, "sleep") as sleep:
                with self.assertRaisesRegex(UI.UIFailure, "^native-proof-timeout$"):
                    proof.wait_for_direct_form()
                observe.assert_called_once_with(deadline=ANY)
                sleep.assert_called_once_with(0.25)

    def test_direct_form_shares_one_deadline_across_sequential_subprocesses(self):
        with tempfile.TemporaryDirectory() as directory:
            proof = object.__new__(UI.NativeProof)
            proof.screens, proof.environment, proof.directory = self.screens, {}, Path(directory)
            proof.process = Mock(pid=123)
            proof.process.poll.return_value = None
            proof.executable = Path(directory) / "synthetic-app"
            proof.executable.write_bytes(b"synthetic")
            proof.executable_hash = hashlib.sha256(b"synthetic").hexdigest()
            proof.identity = f"123 99 Wed Sep 9 00:00:00 2026 {proof.executable}"
            stable = self.direct_form()
            transient = copy.deepcopy(stable)
            transient["windows"][0]["kCGWindowBounds"]["Y"] += 2
            observations = iter([transient, stable])
            clock = [100.0]
            timeouts = []
            helper_calls = []
            def execute(command, **kwargs):
                timeouts.append(kwargs["timeout"])
                if command[0] == "/bin/ps":
                    clock[0] += 4
                    return subprocess.CompletedProcess(command, 0, proof.identity.encode())
                helper_calls.append(command)
                clock[0] += 3 if len(helper_calls) == 1 else 1
                return subprocess.CompletedProcess(command, 0, json.dumps(next(observations)).encode())
            def sleep(seconds):
                clock[0] += seconds
            with patch.object(UI.subprocess, "run", side_effect=execute), \
                    patch.object(UI.time, "monotonic", side_effect=lambda: clock[0]), \
                    patch.object(UI.time, "sleep", side_effect=sleep) as pause:
                observed, _ = proof.wait_for_direct_form()
            self.assertEqual(observed, stable)
            self.assertEqual(timeouts, [5, 11, 5, 3.75])
            self.assertEqual(helper_calls, [[str(ROOT / ".build/inspect-ui"), "123"]] * 2)
            pause.assert_called_once_with(0.25)
            self.assertLess(clock[0], 115)

    def test_stalled_readiness_subprocess_maps_to_fixed_timeout(self):
        for stalled in ("identity", "inspection"):
            with self.subTest(stalled=stalled), tempfile.TemporaryDirectory() as directory:
                proof = object.__new__(UI.NativeProof)
                proof.screens, proof.environment, proof.directory = self.screens, {}, Path(directory)
                proof.process = Mock(pid=123)
                proof.process.poll.return_value = None
                proof.executable = Path(directory) / "synthetic-app"
                proof.executable.write_bytes(b"synthetic")
                proof.executable_hash = hashlib.sha256(b"synthetic").hexdigest()
                proof.identity = f"123 99 Wed Sep 9 00:00:00 2026 {proof.executable}"
                clock = [0.0]
                timeouts = []
                def execute(command, **kwargs):
                    timeouts.append(kwargs["timeout"])
                    if stalled == "inspection" and command[0] == "/bin/ps":
                        clock[0] += 4
                        return subprocess.CompletedProcess(command, 0, proof.identity.encode())
                    clock[0] += kwargs["timeout"]
                    raise subprocess.TimeoutExpired(command, kwargs["timeout"], output=b"private-sentinel")
                with patch.object(UI.subprocess, "run", side_effect=execute), \
                        patch.object(UI.time, "monotonic", side_effect=lambda: clock[0]), \
                        patch.object(UI.time, "sleep") as sleep:
                    with self.assertRaisesRegex(UI.UIFailure, "^native-proof-timeout$"):
                        proof.wait_for_direct_form()
                self.assertEqual(timeouts, [5] if stalled == "identity" else [5, 11])
                self.assertLessEqual(clock[0], 15)
                sleep.assert_not_called()

    def test_readiness_sleep_never_exceeds_remaining_budget(self):
        proof = object.__new__(UI.NativeProof)
        proof.screens = self.screens
        clock = [0.0]
        def inspect(*, deadline):
            self.assertEqual(deadline, 15)
            clock[0] = 14.9
            return self.tree
        def sleep(seconds):
            clock[0] += seconds
        with patch.object(proof, "inspect", side_effect=inspect) as observe, \
                patch.object(UI.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(UI.time, "sleep", side_effect=sleep) as pause:
            with self.assertRaisesRegex(UI.UIFailure, "^native-proof-timeout$"):
                proof.wait_for_direct_form()
        observe.assert_called_once_with(deadline=15)
        self.assertEqual(pause.call_count, 1)
        self.assertAlmostEqual(pause.call_args.args[0], 0.1)
        self.assertEqual(clock[0], 15)

    def test_popover_match_requires_positive_integer_window_identity(self):
        for invalid in (None, True, 0, -1, "42", 42.0):
            tree = copy.deepcopy(self.tree)
            if invalid is None:
                tree["windows"][0].pop("kCGWindowNumber")
            else:
                tree["windows"][0]["kCGWindowNumber"] = invalid
            with self.subTest(invalid=invalid), self.assertRaisesRegex(UI.UIFailure, "^native-popover-not-visible$"):
                UI.popover_window(tree, self.screens)

    def test_popover_match_retains_strict_subpixel_tolerance_and_both_display_bounds(self):
        for delta in (0.5, 1):
            tree = copy.deepcopy(self.tree)
            tree["windows"][0]["kCGWindowBounds"]["Y"] += delta
            with self.subTest(delta=delta):
                if delta < 1:
                    self.assertEqual(UI.popover_window(tree, self.screens)[1]["kCGWindowNumber"], 42)
                else:
                    with self.assertRaisesRegex(UI.UIFailure, "^native-popover-not-visible$"):
                        UI.popover_window(tree, self.screens)
        for outside in ("ax", "cg"):
            tree = copy.deepcopy(self.tree)
            tree["elements"][-1]["frame"][0][0] = -0.5 if outside == "ax" else 0
            tree["windows"][0]["kCGWindowBounds"]["X"] = -0.5 if outside == "cg" else 0
            with self.subTest(outside=outside), self.assertRaisesRegex(UI.UIFailure, "^native-popover-not-visible$"):
                UI.popover_window(tree, self.screens)

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
