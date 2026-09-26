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
                       "nonDataBundles": [],
                       "state": {"snapshot": snapshot,
                                 "connectionID": {"rawValue": "00000000-0000-0000-0000-000000000001"},
                                 "balance": {"bundles": [{"type": "data"}]},
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

    def test_failed_named_command_saves_private_json_without_changing_error(self):
        with tempfile.TemporaryDirectory() as directory:
            proof = object.__new__(UI.NativeProof)
            proof.human_deadline = None
            proof.environment = {}
            proof.directory = Path(directory)
            response = b'{"passed":false,"error":"token-network"}'
            result = subprocess.CompletedProcess(["/synthetic/vikingbar"], 1, response, b"PRIVATE_STDERR")
            with patch.object(UI.subprocess, "run", return_value=result):
                with self.assertRaisesRegex(UI.UIFailure, "^proof-command-failed$"):
                    proof.run(["/synthetic/vikingbar"], "after-refresh-report.json")
            receipt = Path(directory) / "after-refresh-report.failure.json"
            self.assertEqual(json.loads(receipt.read_text()), {
                "returnCode": 1, "response": {"passed": False, "error": "token-network"},
            })
            self.assertEqual(receipt.stat().st_mode & 0o077, 0)
            invalid = subprocess.CompletedProcess(["/synthetic/vikingbar"], 2, b"PRIVATE_STDOUT", b"PRIVATE_STDERR")
            with patch.object(UI.subprocess, "run", return_value=invalid):
                with self.assertRaisesRegex(UI.UIFailure, "^proof-command-failed$"):
                    proof.run(["/synthetic/vikingbar"], "invalid.json")
            self.assertEqual(json.loads((Path(directory) / "invalid.failure.json").read_text()), {"returnCode": 2})

    def test_account_worker_command_accepts_telenet_and_rejects_other_providers(self):
        slot = "304c0ef6-c689-46fd-99dc-1166496f10a4"
        for command in ("session", "connect"):
            with self.subTest(command=command):
                self.assertEqual(
                    UI.account_worker_command({"cli": "/bundle/vikingbar", "accountSelector": "telenet/" + slot},
                                              command),
                    "/bundle/vikingbar " + command + " --account telenet/" + slot,
                )
        for provider in ("fixture-home", "other", "telenet/../../other"):
            with self.subTest(provider=provider):
                with self.assertRaisesRegex(UI.UIFailure, "^runtime-worker-identity-mismatch$"):
                    UI.account_worker_command({"cli": "/bundle/vikingbar",
                                               "accountSelector": provider + "/" + slot}, "session")

    def direct_form(self):
        form = copy.deepcopy(self.tree)
        form["elements"].extend({"AXIdentifier": "vikingbar.connect." + identifier,
                                 "frame": [[120, 100], [200, 20]]}
                                for identifier in ("client-id", "username", "password", "submit", "cancel"))
        form["elements"][-3].update(AXRole="AXTextField", AXSubrole="AXSecureTextField")
        return form

    def test_direct_form_opens_account_change_once_before_waiting_for_fields(self):
        proof = object.__new__(UI.NativeProof)
        proof.screens = self.screens
        proof.human_deadline = None
        form = self.direct_form()
        account = copy.deepcopy(form)
        account["elements"] = [item for item in account["elements"]
                               if not item.get("AXIdentifier", "").startswith("vikingbar.connect.")]
        account["elements"].append({"AXIdentifier": "vikingbar.account.change", "frame": [[120, 100], [200, 20]]})
        with patch.object(proof, "inspect", side_effect=[account, account, form]), \
                patch.object(proof, "press") as press, patch.object(UI.time, "sleep"):
            observed, _ = proof.wait_for_direct_form()
        self.assertEqual(observed, form)
        press.assert_called_once_with("vikingbar.account.change", deadline=ANY)

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
                patch.object(proof, "inspect", return_value=self.tree), patch.object(proof, "press") as press, \
                patch.object(proof, "verify_worker"), patch.object(proof, "peek") as peek:
            proof.matched_balance("synthetic")
        press.assert_not_called()
        self.assertEqual(peek.call_args.args[0][2], "42")
        self.assertEqual(proof.bundle_kinds, {"synthetic": {"data"}})
        self.assertEqual(UI.NativeProof.bundle_kinds, {})

    def test_balance_capture_waits_for_live_card_then_expands_details_once(self):
        proof = object.__new__(UI.NativeProof)
        proof.cli = "synthetic-cli"
        proof.directory = Path("/synthetic")
        proof.screens = self.screens
        proof.direct = None
        proof.human_deadline = None
        proof.capture_suppressed = True

        connecting = copy.deepcopy(self.tree)
        connecting["elements"] = [connecting["elements"][0], connecting["elements"][-1]]
        collapsed = copy.deepcopy(self.tree)
        detail_values = set(self.report["balanceDetails"].values())
        collapsed["elements"] = [element for element in collapsed["elements"]
                                 if element.get("AXValue") not in detail_values]
        collapsed["elements"].insert(-1, {"AXIdentifier": "vikingbar.bundleDetails",
                                           "AXValue": "Bundle details",
                                           "frame": [[120, 100], [200, 20]]})
        expanded = copy.deepcopy(self.tree)
        expanded["elements"].insert(-1, {"AXIdentifier": "vikingbar.bundleDetails",
                                          "AXValue": "Bundle details",
                                          "frame": [[120, 100], [200, 20]]})
        description = next(element for element in expanded["elements"]
                           if element.get("AXValue") == self.report["balanceDetails"]["bundleDescription"])
        description["AXIdentifier"] = "vikingbar.bundleDescription"

        observations = iter([connecting, collapsed, collapsed, expanded])
        events = []

        def run(*_args):
            events.append("report")
            return self.report

        def inspect(*_args):
            tree = next(observations)
            events.append("inspect-details" if any(element.get("AXIdentifier") == "vikingbar.bundleDetails"
                                                    for element in tree["elements"]) else "inspect-connecting")
            return tree

        with patch.object(proof, "run", side_effect=run) as report, \
                patch.object(proof, "inspect", side_effect=inspect) as observe, \
                patch.object(proof, "press", side_effect=lambda identifier: events.append("press-" + identifier)) as press, \
                patch.object(proof, "verify_worker"), patch.object(proof, "peek"), \
                patch.object(UI.time, "sleep"):
            proof.matched_balance("synthetic")

        press.assert_called_once_with("vikingbar.bundleDetails")
        self.assertEqual(report.call_count, 4)
        self.assertEqual(observe.call_count, 4)
        self.assertEqual(events, ["report", "inspect-connecting",
                                  "report", "inspect-details", "press-vikingbar.bundleDetails",
                                  "report", "inspect-details",
                                  "report", "inspect-details"])

    def test_balance_capture_expands_compares_and_collapses_other_bundles(self):
        proof = object.__new__(UI.NativeProof)
        proof.cli = "synthetic-cli"
        proof.directory = Path("/synthetic")
        proof.screens = self.screens
        proof.direct = None
        proof.human_deadline = None
        proof.capture_suppressed = True
        self.add_bundle_rows()
        expanded = copy.deepcopy(self.tree)
        self.collapse_bundle_rows()
        collapsed = self.tree
        observations = iter([collapsed, collapsed, expanded, expanded, collapsed])
        events = []

        def inspect(name):
            tree = next(observations)
            events.append(("inspect-expanded " if tree is expanded else "inspect-collapsed ") + name)
            return tree

        with patch.object(proof, "run", return_value=self.report), \
                patch.object(proof, "inspect", side_effect=inspect), \
                patch.object(proof, "press", side_effect=lambda identifier: events.append("press-" + identifier)), \
                patch.object(proof, "verify_worker"), patch.object(proof, "peek") as peek, \
                patch.object(UI.time, "sleep"):
            proof.matched_balance("synthetic")

        self.assertEqual(events, ["inspect-collapsed synthetic-card.json", "press-vikingbar.otherBundles",
                                  "inspect-collapsed synthetic-other-bundles.json",
                                  "inspect-expanded synthetic-other-bundles.json", "press-vikingbar.otherBundles",
                                  "inspect-expanded synthetic-other-bundles-collapsed.json",
                                  "inspect-collapsed synthetic-other-bundles-collapsed.json"])
        self.assertEqual(proof.bundle_kinds, {"synthetic": {"data", "voice", "sms"}})
        self.assertEqual(peek.call_args.args[0][-1], "/synthetic/synthetic-card.png")

    def test_balance_capture_reopens_unequivocally_closed_popover_once(self):
        proof = object.__new__(UI.NativeProof)
        proof.cli = "synthetic-cli"
        proof.directory = Path("/synthetic")
        proof.screens = self.screens
        proof.direct = None
        proof.human_deadline = None
        proof.capture_suppressed = True

        closed = copy.deepcopy(self.tree)
        closed["elements"] = [closed["elements"][0]]
        closed["windows"] = []
        observations = iter([closed, closed, self.tree])
        events = []

        def run(*_args):
            events.append("report")
            return self.report

        def inspect(*_args):
            tree = next(observations)
            events.append("inspect-open" if tree["windows"] else "inspect-closed")
            return tree

        with patch.object(proof, "run", side_effect=run) as report, \
                patch.object(proof, "inspect", side_effect=inspect) as observe, \
                patch.object(proof, "press", side_effect=lambda identifier: events.append("press-" + identifier)) as press, \
                patch.object(proof, "verify_worker"), patch.object(proof, "peek"), \
                patch.object(UI.time, "sleep"):
            proof.matched_balance("synthetic")

        press.assert_called_once_with("vikingbar.status")
        self.assertEqual(report.call_count, 3)
        self.assertEqual(observe.call_count, 3)
        self.assertEqual(events, ["report", "inspect-closed", "press-vikingbar.status",
                                  "report", "inspect-closed",
                                  "report", "inspect-open"])

    def test_visible_menu_matches_private_live_report(self):
        UI.compare_menu(self.tree, self.report, self.screens)
        self.tree["elements"][1]["AXValue"] = "99.00 GB"
        with self.assertRaisesRegex(UI.UIFailure, "native-menu-mismatch"):
            UI.compare_menu(self.tree, self.report, self.screens)

    def add_bundle_rows(self):
        validity = "Expires 1 Oct 2026, 00:00 UTC"
        rows = [{"index": 1, "kind": "voice", "title": "Call bundle 2", "description": "", "remainingText": "0 min",
                 "usedText": "0 min used", "totalText": "0 min total", "detailText": "Calls · default",
                 "validityText": validity, "state": "exhausted", "percentageRemaining": None},
                {"index": 2, "kind": "sms", "title": "SMS bundle 3", "description": "Texts", "remainingText": "0 SMS",
                 "usedText": "0 SMS used", "totalText": "0 SMS total", "detailText": "SMS · default",
                 "validityText": validity, "state": "exhausted", "percentageRemaining": None}]
        self.report["state"]["balance"]["bundles"] += [{"type": "voice"}, {"type": "sms"}]
        self.report["nonDataBundles"] = rows
        self.tree["elements"].insert(-1, {"AXIdentifier": "vikingbar.otherBundles", "frame": [[120, 270], [300, 330]]})
        self.tree["elements"].insert(-1, {"AXIdentifier": "vikingbar.otherBundles.summary", "AXValue": "Calls, SMS",
                                          "frame": [[330, 275], [80, 10]]})
        for offset, row in enumerate(rows):
            prefix = f"vikingbar.bundle.{row['index']}"
            top = 300 + offset * 100
            self.tree["elements"].insert(-1, {"AXIdentifier": prefix, "frame": [[120, top], [300, 90]]})
            for line, (field, key) in enumerate(UI.BUNDLE_FIELDS.items()):
                if row[key]:
                    self.tree["elements"].insert(-1, {"AXIdentifier": f"{prefix}.{field}", "AXValue": row[key],
                                                      "frame": [[125, top + 2 + line * 12], [200, 10]]})

    def collapse_bundle_rows(self):
        self.tree["elements"] = [item for item in self.tree["elements"]
                                 if not str(item.get("AXIdentifier", "")).startswith("vikingbar.bundle.")]

    def test_native_bundle_rows_match_report_per_field(self):
        self.assertEqual(UI.compare_other_bundles(self.tree, self.report, self.screens, expanded=False), set())
        self.add_bundle_rows()
        self.assertEqual(UI.compare_other_bundles(self.tree, self.report, self.screens, expanded=True),
                         {"voice", "sms"})

    def test_compare_menu_checks_data_without_other_bundle_rows(self):
        self.add_bundle_rows()
        self.tree["elements"] = [item for item in self.tree["elements"]
                                 if not str(item.get("AXIdentifier", "")).startswith("vikingbar.otherBundles")]
        self.collapse_bundle_rows()
        self.assertIsNone(UI.compare_menu(self.tree, self.report, self.screens))

    def test_other_bundles_summary_lists_distinct_kind_labels_in_row_order(self):
        self.add_bundle_rows()
        self.report["nonDataBundles"] += [dict(self.report["nonDataBundles"][0], index=3),
                                          dict(self.report["nonDataBundles"][0], index=4, kind="value")]
        self.assertEqual(UI.other_bundles_summary(self.report), "Calls, SMS, Credit")
        self.report["nonDataBundles"] = []
        self.assertEqual(UI.other_bundles_summary(self.report), "")
        for kind in ("data", "mms", None):
            self.report["nonDataBundles"] = [{"kind": kind}]
            with self.subTest(kind=kind), self.assertRaisesRegex(UI.UIFailure, "^live-report-invalid$"):
                UI.other_bundles_summary(self.report)

    def test_collapsed_other_bundles_match_summary_without_rows(self):
        self.add_bundle_rows()
        self.collapse_bundle_rows()
        self.assertEqual(UI.compare_other_bundles(self.tree, self.report, self.screens, expanded=False), set())

        def wrong_summary(tree):
            next(item for item in tree["elements"]
                 if item.get("AXIdentifier") == "vikingbar.otherBundles.summary")["AXValue"] = "SMS, Calls"

        def missing_disclosure(tree):
            tree["elements"] = [item for item in tree["elements"]
                                if item.get("AXIdentifier") != "vikingbar.otherBundles"]

        def visible_row(tree):
            tree["elements"].insert(-1, {"AXIdentifier": "vikingbar.bundle.1.title", "AXValue": "Call bundle 2",
                                         "frame": [[125, 302], [200, 10]]})

        def outside_popover(tree):
            next(item for item in tree["elements"]
                 if item.get("AXIdentifier") == "vikingbar.otherBundles")["frame"] = [[120, 700], [300, 100]]

        for change in (wrong_summary, missing_disclosure, visible_row, outside_popover):
            self.setUp()
            self.add_bundle_rows()
            self.collapse_bundle_rows()
            change(self.tree)
            with self.subTest(change=change.__name__), self.assertRaisesRegex(UI.UIFailure,
                                                                              "^native-bundles-mismatch$"):
                UI.compare_other_bundles(self.tree, self.report, self.screens, expanded=False)

    def test_other_bundles_disclosure_requires_rows(self):
        self.tree["elements"].insert(-1, {"AXIdentifier": "vikingbar.otherBundles", "frame": [[120, 270], [300, 20]]})
        for expanded in (False, True):
            with self.subTest(expanded=expanded), self.assertRaisesRegex(UI.UIFailure, "^native-bundles-mismatch$"):
                UI.compare_other_bundles(self.tree, self.report, self.screens, expanded=expanded)

    def test_missing_extra_wrong_or_misplaced_bundle_rows_fail(self):
        def missing_row(tree, _report):
            tree["elements"] = [item for item in tree["elements"]
                                if not str(item.get("AXIdentifier", "")).startswith("vikingbar.bundle.2")]

        def extra_row(tree, _report):
            tree["elements"].insert(-1, {"AXIdentifier": "vikingbar.bundle.5", "frame": [[120, 600], [300, 20]]})

        def wrong_string(tree, _report):
            next(item for item in tree["elements"]
                 if item.get("AXIdentifier") == "vikingbar.bundle.1.remaining")["AXValue"] = "0 s"

        def wrong_row(tree, _report):
            next(item for item in tree["elements"]
                 if item.get("AXIdentifier") == "vikingbar.bundle.1.used")["frame"] = [[125, 450], [200, 10]]

        def wrong_kind(_tree, report):
            report["nonDataBundles"][0]["kind"] = "sms"

        def unlisted_description(tree, _report):
            tree["elements"].insert(-1, {"AXIdentifier": "vikingbar.bundle.1.description", "AXValue": "",
                                         "frame": [[125, 380], [200, 10]]})

        def offscreen_row(tree, _report):
            for item in tree["elements"]:
                if str(item.get("AXIdentifier", "")).startswith("vikingbar.bundle.2"):
                    item["frame"][0][1] += 400

        def missing_disclosure(tree, _report):
            tree["elements"] = [item for item in tree["elements"]
                                if item.get("AXIdentifier") != "vikingbar.otherBundles"]

        for change in (missing_row, extra_row, wrong_string, wrong_row, wrong_kind, unlisted_description,
                       offscreen_row, missing_disclosure):
            self.setUp()
            self.add_bundle_rows()
            change(self.tree, self.report)
            with self.subTest(change=change.__name__), self.assertRaisesRegex(UI.UIFailure,
                                                                              "^native-bundles-mismatch$"):
                UI.compare_other_bundles(self.tree, self.report, self.screens, expanded=True)

    def test_missing_or_invalid_bundle_report_keys_fail_as_invalid_reports(self):
        def remove_rows(report):
            del report["nonDataBundles"]

        def remove_field(report):
            del report["nonDataBundles"][0]["usedText"]

        def unknown_kind(report):
            report["state"]["balance"]["bundles"][1]["type"] = "mms"

        def untyped_bundles(report):
            report["state"]["balance"]["bundles"] = [1, 2, 3]

        def non_text_field(report):
            report["nonDataBundles"][1]["title"] = None

        for change in (remove_rows, remove_field, unknown_kind, untyped_bundles, non_text_field):
            self.setUp()
            self.add_bundle_rows()
            change(self.report)
            with self.subTest(change=change.__name__), self.assertRaisesRegex(UI.UIFailure,
                                                                              "^live-report-invalid$"):
                UI.compare_other_bundles(self.tree, self.report, self.screens, expanded=True)

    def test_used_mode_matches_exact_hero_without_changing_preferences(self):
        self.tree["elements"].append({"AXIdentifier": "vikingbar.balanceTitle", "AXValue": "Data used",
                                      "frame": [[120, 100], [200, 20]]})
        self.tree["elements"][1]["AXValue"] = "20.00 GB"
        next(item for item in self.tree["elements"]
             if item.get("AXValue") == self.menu["usedText"])["AXValue"] = "30.00 GB remaining"
        UI.compare_menu(self.tree, self.report, self.screens)
        self.tree["elements"][1]["AXValue"] = "30.00 GB"
        with self.assertRaisesRegex(UI.UIFailure, "native-menu-mismatch"):
            UI.compare_menu(self.tree, self.report, self.screens)

    def test_unknown_or_duplicate_balance_title_cannot_choose_display_mode(self):
        self.tree["elements"].append({"AXIdentifier": "vikingbar.balanceTitle", "AXValue": "Wrong title",
                                      "frame": [[120, 100], [200, 20]]})
        with self.assertRaisesRegex(UI.UIFailure, "native-menu-mismatch"):
            UI.compare_menu(self.tree, self.report, self.screens)
        self.tree["elements"][-1]["AXValue"] = self.menu["balanceTitle"]
        self.tree["elements"].append(dict(self.tree["elements"][-1]))
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

    def test_connection_identity_normalizes_uuid_and_matches_connect_digest(self):
        connection_id, digest = UI.connection_identity(self.report)
        self.assertEqual(connection_id, "00000000-0000-0000-0000-000000000001")
        self.assertEqual(digest, "7ac1b8d7010bb6cd3a3e84e7f90136b880bbc899e428ece49333372911ab9052")
        self.report["state"]["connectionID"] = {
            "rawValue": "00000000-0000-0000-0000-000000000001", "extra": "private",
        }
        with self.assertRaisesRegex(UI.UIFailure, "live-report-invalid"):
            UI.connection_identity(self.report)

    def test_wrong_extra_charges_fail_native_comparison(self):
        self.report["balanceDetails"]["extraChargesText"] = "Extra charges: €0.00"
        with self.assertRaisesRegex(UI.UIFailure, "native-balance-details-mismatch"):
            UI.compare_menu(self.tree, self.report, self.screens)

    def test_api_receipt_rejects_missing_skipped_and_private_fields(self):
        types = {"data": 1, "sms": 1, "voice": 1, "value": 0}
        receipt = {"schema_version": 1, "check": "balance-api", "passed": True, "api_matches": True,
                   "token_refreshed": True, "bundle_count": 3, "bundle_types": types}
        self.assertEqual(UI.validate_api_receipt(receipt), receipt)
        for delta in ({"api_matches": False}, {"token_refreshed": False}, {"raw": "private"},
                      {"bundle_count": 0}, {"bundle_count": True}, {"bundle_count": 4},
                      {"bundle_types": None}, {"bundle_types": dict(types, mms=0)},
                      {"bundle_types": {"data": 1, "sms": 1, "voice": 1}},
                      {"bundle_types": dict(types, value=True, voice=0)},
                      {"bundle_types": dict(types, value=-1, voice=2)},
                      {"bundle_types": dict(types, value=1.0, voice=0)},
                      {"bundle_types": dict(types, data=0, value=1)}):
            with self.assertRaises(UI.UIFailure):
                UI.validate_api_receipt(dict(receipt, **delta))
        missing = dict(receipt)
        del missing["bundle_types"]
        with self.assertRaises(UI.UIFailure):
            UI.validate_api_receipt(missing)

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


if __name__ == "__main__":
    unittest.main()
