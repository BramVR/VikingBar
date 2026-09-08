import copy
import importlib.util
from pathlib import Path
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
