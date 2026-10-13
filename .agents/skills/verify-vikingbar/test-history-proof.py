#!/usr/bin/env python3
"""Exercise maintained capture through the repository's real history comparators."""

import copy
import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


HELPER = load("maintained_history_test", Path(__file__).with_name("history-proof.py"))
HISTORY = HELPER.HISTORY
FIXTURES = load("repository_history_fixtures", ROOT / "Scripts/tests/test_history_proof.py")


class CaptureTests(unittest.TestCase):
    def setUp(self):
        fixture = FIXTURES.HistoryProofTests()
        fixture.setUp()
        self.tree = copy.deepcopy(fixture.tree)
        self.report = fixture.report
        self.windows = HISTORY.compare_history(self.tree, self.report, fixture.screens)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.proof = HELPER.MaintainedHistoryProof.__new__(HELPER.MaintainedHistoryProof)
        self.proof.directory = Path(self.temporary.name)
        self.proof.process = SimpleNamespace(pid=123)
        self.proof.screens = fixture.screens
        self.proof.peekaboo = "/approved/peekaboo"
        self.proof.verify_process = Mock()
        self.proof.inspect = Mock(side_effect=lambda label: self.tree)
        self.proof.run = Mock(side_effect=self.capture)
        self.bad_target = False
        self.group_geometry = False

    def capture(self, arguments, name):
        self.assertEqual(arguments[arguments.index("--capture-engine") + 1], "modern")
        self.assertIn("--no-remote", arguments)
        self.assertEqual(arguments[arguments.index("--pid") + 1], "123")
        identifier = int(arguments[arguments.index("--window-id") + 1])
        window = next(value["window"] for value in self.windows.values()
                      if value["window"]["kCGWindowNumber"] == identifier)
        frame = HISTORY.window_frame(window)
        dimensions = HISTORY.window_group_frame(self.windows) if self.group_geometry else frame
        width, height = (int(value * 2) for value in dimensions[1])
        output = Path(arguments[arguments.index("--path") + 1])
        output.write_bytes(HISTORY.PNG_SIGNATURE + b"\x00\x00\x00\x0dIHDR"
                           + width.to_bytes(4, "big") + height.to_bytes(4, "big"))
        return {"success": True,
                "target_receipt": {"pid": 123, "window_id": identifier + int(self.bad_target)},
                "data": {"files": [{"path": str(output), "window_id": identifier,
                                    "item_label": f"window-{identifier}", "mime_type": "image/png"}],
                         "observations": [{"target": {"window_id": identifier, "requested_kind": "pid",
                                                       "resolved_kind": "window-id", "source": "window-id",
                                                       "bounds": frame},
                                           "coordinates": {"coordinate_space": "global_display_points",
                                                           "logical_bounds": frame}}]}}

    def drive(self):
        self.proof.capture_history_windows("history", self.report, self.windows, 0)

    def test_captures_two_individual_windows_with_real_comparators(self):
        self.drive()
        self.assertEqual(self.proof.run.call_count, 2)
        self.assertEqual(self.proof.inspect.call_count, 2)
        self.assertEqual(len(list(self.proof.directory.glob("*.png"))), 2)

    def test_wrong_target_is_terminal_without_retry(self):
        self.bad_target = True
        with self.assertRaisesRegex(HISTORY.UIFailure, "native-capture-target-mismatch"):
            self.drive()
        self.assertEqual(self.proof.run.call_count, 1)

    def test_group_image_cannot_pass_individual_geometry(self):
        self.group_geometry = True
        with self.assertRaisesRegex(HISTORY.UIFailure, "native-history-capture-geometry-mismatch"):
            self.drive()
        self.assertEqual(self.proof.run.call_count, 1)

    def test_window_identity_change_after_capture_is_terminal(self):
        original = self.windows["companion"]["window"]["kCGWindowNumber"]
        self.proof.inspect.side_effect = None
        changed = copy.deepcopy(self.tree)
        next(window for window in changed["windows"] if window["kCGWindowNumber"] == original)[
            "kCGWindowNumber"] += 100
        self.proof.inspect.return_value = changed
        with self.assertRaisesRegex(HISTORY.UIFailure, "native-history-capture-mismatch"):
            self.drive()
        self.assertEqual(self.proof.run.call_count, 1)

    def test_selected_day_change_after_capture_is_terminal(self):
        changed = copy.deepcopy(self.tree)
        day = self.report["historyPresentation"]["days"][1]
        fields = {"vikingbar.historySelectedDate": "fullDateText",
                  "vikingbar.historySelectedValue": "valueText", "vikingbar.historySelectedStatus": "statusText"}
        for element in changed["elements"]:
            if element.get("AXIdentifier") in fields:
                element["AXValue"] = day[fields[element["AXIdentifier"]]]
        self.proof.inspect.side_effect = None
        self.proof.inspect.return_value = changed
        with self.assertRaisesRegex(HISTORY.UIFailure, "native-history-capture-mismatch"):
            self.drive()
        self.assertEqual(self.proof.run.call_count, 1)


if __name__ == "__main__":
    unittest.main()
