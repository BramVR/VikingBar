import ast
import copy
import importlib.util
import math
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "native_ui_proof", Path(__file__).resolve().parents[1] / "native-ui-proof.py")
UI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UI)


class NativeUIProofTests(unittest.TestCase):
    def setUp(self):
        self.screens = [{"bounds": {"x": 0, "y": 0, "width": 1440, "height": 900}}]
        self.tree = {"elements": [
            {"AXRole": "AXPopover", "frame": [[100, 24], [360, 480]]},
            {"AXIdentifier": "vikingbar.bundlePicker", "AXValue": "Monthly data",
             "frame": [[120, 100], [300, 20]]},
            {"AXIdentifier": "vikingbar.bundleDetails", "AXValue": "Extra charges: €0.00",
             "frame": [[120, 300], [300, 20]]},
        ], "windows": [{"kCGWindowNumber": 42,
                         "kCGWindowBounds": {"X": 100, "Y": 24, "Width": 360, "Height": 480}}]}
        self.description = "Monthly mobile data allowance"
        self.applicability = "Mobile data · Domestic and EU roaming"

    def expand(self):
        self.tree["elements"] += [
            {"AXIdentifier": "vikingbar.bundleDescription", "AXValue": self.description,
             "frame": [[120, 330], [300, 20]]},
            {"AXIdentifier": "vikingbar.bundleApplicability", "AXValue": self.applicability,
             "frame": [[120, 355], [300, 20]]},
        ]

    def details_visible(self, tree=None):
        return UI.bundle_details_visible(tree or self.tree, self.screens, "Monthly data",
                                         self.description, self.applicability)

    def test_matched_offscreen_popover_is_rejected(self):
        for item in self.tree["elements"]:
            item["frame"][0][0] += 4900
            item["frame"][0][1] += 4976
        self.tree["windows"][0]["kCGWindowBounds"].update(X=5000, Y=5000)
        with self.assertRaisesRegex(UI.UIFailure, "native-popover-not-visible"):
            UI.popover_window(self.tree, self.screens)
        self.assertFalse(UI.bundle_details_collapsed(self.tree, self.screens))

    def test_popover_must_fit_one_display(self):
        self.tree["elements"][0]["frame"] = [[1300, 24], [360, 480]]
        self.tree["windows"][0]["kCGWindowBounds"].update(X=1300)
        screens = self.screens + [{"bounds": {"x": 1440, "y": 0, "width": 1440, "height": 900}}]
        with self.assertRaises(UI.UIFailure):
            UI.popover_window(self.tree, screens)

    def test_popover_on_second_display_is_valid(self):
        for item in self.tree["elements"]:
            item["frame"][0][0] += 1440
        self.tree["windows"][0]["kCGWindowBounds"]["X"] += 1440
        screens = self.screens + [{"bounds": {"x": 1440, "y": 0, "width": 1440, "height": 900}}]
        self.assertEqual(UI.popover_window(self.tree, screens)[1]["kCGWindowNumber"], 42)

    def test_invalid_window_or_display_cannot_supply_visibility(self):
        for bad in (0, -1, True, "1440", float("nan"), float("inf")):
            with self.subTest(bad=bad):
                screens = [{"bounds": {"x": 0, "y": 0, "width": bad, "height": 900}}]
                with self.assertRaises(UI.UIFailure):
                    UI.popover_window(self.tree, screens)
                tree = copy.deepcopy(self.tree)
                tree["elements"][0]["frame"][1][0] = bad
                tree["windows"][0]["kCGWindowBounds"]["Width"] = bad
                with self.assertRaises(UI.UIFailure):
                    UI.popover_window(tree, self.screens)

    def test_extra_charges_on_collapsed_label_do_not_prove_expansion(self):
        self.assertTrue(UI.bundle_details_collapsed(self.tree, self.screens))
        self.assertFalse(self.details_visible())
        self.expand()
        self.assertTrue(self.details_visible())
        self.assertFalse(UI.bundle_details_collapsed(self.tree, self.screens))
        self.tree["elements"] = self.tree["elements"][:3]
        self.assertTrue(UI.bundle_details_collapsed(self.tree, self.screens))

    def test_expanded_details_must_match_selected_bundle_and_applicability(self):
        self.expand()
        for identifier in ("vikingbar.bundlePicker", "vikingbar.bundleDescription", "vikingbar.bundleApplicability"):
            tree = copy.deepcopy(self.tree)
            next(item for item in tree["elements"] if item.get("AXIdentifier") == identifier)["AXValue"] = "Other bundle"
            with self.subTest(identifier=identifier):
                self.assertFalse(self.details_visible(tree))

    def test_expanded_text_must_be_visible_and_collapse_must_remove_both_fields(self):
        self.expand()
        for identifier in ("vikingbar.bundleDescription", "vikingbar.bundleApplicability"):
            tree = copy.deepcopy(self.tree)
            item = next(item for item in tree["elements"] if item.get("AXIdentifier") == identifier)
            item["frame"][0][1] = 800
            with self.subTest(identifier=identifier):
                self.assertFalse(self.details_visible(tree))
                self.assertFalse(UI.bundle_details_collapsed(tree, self.screens))
        self.assertFalse(UI.bundle_details_collapsed({"elements": [], "windows": []}, self.screens))


class CaptureUIProofTests(unittest.TestCase):
    PID = 1234

    def setUp(self):
        self.screens = [{"bounds": {"x": 0, "y": 0, "width": 1000, "height": 900}}]

    def tree(self, *, window_id=42, x=100, width=360, owner=None, onscreen=True, alpha=1.0):
        return {
            "elements": [{"AXRole": "AXPopover", "frame": [[x, 24], [width, 480]]}],
            "windows": [{
                "kCGWindowNumber": window_id,
                "kCGWindowOwnerPID": self.PID if owner is None else owner,
                "kCGWindowIsOnscreen": onscreen,
                "kCGWindowAlpha": alpha,
                "kCGWindowBounds": {"X": x, "Y": 24, "Width": width, "Height": 480},
            }],
        }

    def receipt(self, output, *, pid=None, window_id=42):
        return {
            "success": True,
            "target_receipt": {"pid": self.PID if pid is None else pid, "window_id": window_id},
            "data": {"files": [{
                "path": str(output), "window_id": window_id, "item_label": f"window-{window_id}",
                "mime_type": "image/png",
            }]},
        }

    def test_saved_transitional_ax_and_cg_shape_is_rejected_before_stability(self):
        tree = self.tree(alpha=0.147)
        tree["windows"][0]["kCGWindowBounds"] = {"X": 91, "Y": 31, "Width": 58, "Height": 84}
        tracker = UI.CapturePopoverStability()
        calls = []
        with self.assertRaisesRegex(UI.UIFailure, "native-capture-popover-match-count-0"):
            UI.capture_popover_window(tree, self.screens, self.PID)
        if tracker.observe(tree, self.screens, self.PID) is not None:
            calls.append("capture")
        self.assertEqual(calls, [])
        self.assertEqual(tracker.count, 0)

    def test_positive_finite_ax_and_cg_frames_must_match_within_one_point(self):
        tree = self.tree()
        tree["windows"][0]["kCGWindowBounds"]["X"] += 2
        with self.assertRaisesRegex(UI.UIFailure, "native-capture-popover-match-count-0"):
            UI.capture_popover_window(tree, self.screens, self.PID)
        tracker = UI.CapturePopoverStability()
        self.assertIsNone(tracker.observe(self.tree(), self.screens, self.PID))
        self.assertIsNone(tracker.observe(tree, self.screens, self.PID))
        self.assertEqual(tracker.count, 0)

    def test_same_valid_shape_must_be_observed_twice(self):
        tracker = UI.CapturePopoverStability()
        tree = self.tree()
        self.assertIsNone(tracker.observe(tree, self.screens, self.PID))
        selected = tracker.observe(copy.deepcopy(tree), self.screens, self.PID)
        self.assertEqual(selected[1]["kCGWindowNumber"], 42)

    def test_changed_id_or_bounds_resets_consecutive_streak(self):
        first = self.tree()
        for name, changed in (("ID", self.tree(window_id=43)), ("bounds", self.tree(x=101))):
            with self.subTest(name=name):
                tracker = UI.CapturePopoverStability()
                self.assertIsNone(tracker.observe(first, self.screens, self.PID))
                self.assertIsNone(tracker.observe(changed, self.screens, self.PID))
                self.assertIsNotNone(tracker.observe(copy.deepcopy(changed), self.screens, self.PID))

    def test_invalid_or_ambiguous_capture_targets_reset_readiness(self):
        invalid = {
            "wrong owner": self.tree(owner=self.PID + 1),
            "offscreen": self.tree(onscreen=False),
            "nonboolean onscreen": self.tree(onscreen=1),
            "low alpha": self.tree(alpha=0.5),
            "nan alpha": self.tree(alpha=math.nan),
            "infinite alpha": self.tree(alpha=math.inf),
            "boolean alpha": self.tree(alpha=True),
            "string alpha": self.tree(alpha="1.0"),
            "zero geometry": self.tree(width=0),
            "nan geometry": self.tree(width=math.nan),
            "missing": {"elements": [], "windows": []},
        }
        ambiguous = self.tree()
        ambiguous["windows"].append(copy.deepcopy(ambiguous["windows"][0]))
        ambiguous["windows"][1]["kCGWindowNumber"] = 43
        invalid["ambiguous"] = ambiguous
        tracker = UI.CapturePopoverStability()
        self.assertIsNone(tracker.observe(self.tree(), self.screens, self.PID))
        for name, tree in invalid.items():
            with self.subTest(name=name):
                self.assertIsNone(tracker.observe(tree, self.screens, self.PID))
                self.assertEqual(tracker.count, 0)

    def test_capture_target_must_fit_wholly_on_one_display(self):
        screens = self.screens + [{"bounds": {"x": 1000, "y": 0, "width": 1000, "height": 900}}]
        tracker = UI.CapturePopoverStability()
        crossing = self.tree(x=900, width=200)
        self.assertIsNone(tracker.observe(crossing, screens, self.PID))
        second_display = self.tree(x=1100, width=200)
        self.assertIsNone(tracker.observe(second_display, screens, self.PID))
        self.assertIsNotNone(tracker.observe(copy.deepcopy(second_display), screens, self.PID))

    def test_qualifier_failure_resets_readiness(self):
        tracker = UI.CapturePopoverStability()
        tree = self.tree()
        self.assertIsNone(tracker.observe(tree, self.screens, self.PID))
        self.assertIsNone(tracker.observe(tree, self.screens, self.PID, lambda _element, _window: False))
        self.assertEqual(tracker.count, 0)

    def test_exact_capture_uses_one_classic_pid_and_window_call(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "card.png"
            output.write_bytes(UI.PNG_SIGNATURE + b"pixels")
            calls = []

            def invoke(arguments):
                calls.append(arguments)
                return self.receipt(output)

            UI.capture_exact_window("/tmp/peekaboo", self.PID, 42, output, invoke)
            self.assertEqual(calls, [[
                "/tmp/peekaboo", "see", "--pid", str(self.PID), "--window-id", "42",
                "--capture-engine", "classic", "--no-elements", "--no-remote",
                "--path", str(output), "--json",
            ]])

    def test_capture_failures_are_terminal_after_one_call(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "card.png"
            cases = {
                "command": RuntimeError("command failed"),
                "malformed json": ValueError("malformed json"),
                "failed receipt": {"success": False},
                "wrong target": self.receipt(output, pid=self.PID + 1),
                "wrong output": {
                    **self.receipt(output),
                    "data": {"files": [{"path": str(output), "window_id": 99,
                                         "item_label": "window-99", "mime_type": "image/png"}]},
                },
                "missing image": self.receipt(output),
            }
            for name, result in cases.items():
                with self.subTest(name=name):
                    output.unlink(missing_ok=True)
                    calls = []

                    def invoke(arguments):
                        calls.append(arguments)
                        if isinstance(result, Exception):
                            raise result
                        return result

                    with self.assertRaises(Exception):
                        UI.capture_exact_window("peekaboo", self.PID, 42, output, invoke)
                    self.assertEqual(len(calls), 1)

    def test_invalid_png_is_terminal_after_one_call(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "card.png"
            for image in (b"", UI.PNG_SIGNATURE, b"not a png"):
                with self.subTest(image=image):
                    output.write_bytes(image)
                    calls = []

                    def invoke(arguments):
                        calls.append(arguments)
                        return self.receipt(output)

                    with self.assertRaisesRegex(UI.UIFailure, "native-capture-image-invalid"):
                        UI.capture_exact_window("peekaboo", self.PID, 42, output, invoke)
                    self.assertEqual(len(calls), 1)

    def test_smoke_capture_has_one_exact_dispatch_and_no_area_fallback(self):
        source = (Path(__file__).resolve().parents[1] / "smoke-app-fixture.py").read_text()
        module = ast.parse(source)
        function = next(node for node in module.body if isinstance(node, ast.FunctionDef)
                        and node.name == "capture_card")
        exact_calls = [node for node in ast.walk(function) if isinstance(node, ast.Call)
                       and isinstance(node.func, ast.Attribute)
                       and node.func.attr == "capture_exact_window"]
        area_literals = [node.value for node in ast.walk(function) if isinstance(node, ast.Constant)
                         and node.value == "area"]
        self.assertEqual(len(exact_calls), 1)
        self.assertEqual(area_literals, [])
