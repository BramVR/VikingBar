#!/usr/bin/env python3
"""Exercise the real geometry comparator with a transient missing AX root."""

import ast
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


HELPER = load("maintained_fixture", Path(__file__).with_name("fixture-proof.py"))
UI = load("fixture_geometry_ui", ROOT / "Scripts/native-ui-proof.py")
SCREEN = [{"bounds": {"x": 0, "y": 0, "width": 1800, "height": 1169}}]
TARGET = {"AXIdentifier": "vikingbar.fixtureMarker", "frame": [[1378.5, 65.9], [43.5, 13]]}
POPOVER = {"AXRole": "AXPopover", "frame": [[1069, 30], [386, 487]]}
WINDOW = {"kCGWindowNumber": 31454, "kCGWindowBounds": {"X": 1069, "Y": 30, "Width": 386, "Height": 487}}


def comparator():
    module = ast.parse((ROOT / "Scripts/smoke-app-fixture.py").read_text())
    functions = [node for node in module.body if isinstance(node, ast.FunctionDef)
                 and node.name in {"element", "control_geometry"}]
    namespace = {"UI": UI, "screens": SCREEN}
    exec(compile(ast.Module(body=functions, type_ignores=[]), "fixture geometry", "exec"), namespace)
    return namespace["control_geometry"]


class GeometryTests(unittest.TestCase):
    def test_october_fixture_does_not_expect_september(self):
        self.assertEqual(HELPER.billing_period_text("2026-10-13T09:05:23+00:00"),
                         "Billing period 2026-10-01 to 2026-10-31")

    def test_month_uses_brussels_at_the_utc_boundary(self):
        self.assertEqual(HELPER.billing_period_text("2026-09-30T22:30:00+00:00"),
                         "Billing period 2026-10-01 to 2026-10-31")

    def test_missing_role_settles_against_actual_comparator(self):
        missing = {"elements": [{"frame": [[0, 0], [0, 0]]}, TARGET], "windows": [WINDOW]}
        healthy = {"elements": [POPOVER, TARGET], "windows": [WINDOW]}
        geometry = comparator()
        with self.assertRaisesRegex(UI.UIFailure, "native-popover-not-visible"):
            geometry(missing, "vikingbar.fixtureMarker")
        observations = []
        actual = HELPER.settled_geometry(missing, "vikingbar.fixtureMarker", geometry,
                                        lambda: observations.append(True) or healthy, UI.UIFailure)
        self.assertEqual(actual, (TARGET["frame"], WINDOW["kCGWindowBounds"]))
        self.assertEqual(len(observations), 1)

    def test_offscreen_window_still_fails(self):
        offscreen = {"elements": [dict(POPOVER, frame=[[1900, 30], [386, 487]]), TARGET],
                     "windows": [dict(WINDOW, kCGWindowBounds={"X": 1900, "Y": 30, "Width": 386, "Height": 487})]}
        with self.assertRaisesRegex(UI.UIFailure, "native-popover-not-visible"):
            HELPER.settled_geometry(offscreen, "vikingbar.fixtureMarker", comparator(),
                                    lambda: self.fail("expired observation wait retried"), UI.UIFailure, seconds=0)

    def test_ambiguous_popover_is_terminal(self):
        ambiguous = {"elements": [POPOVER, TARGET], "windows": [WINDOW, dict(WINDOW, kCGWindowNumber=31455)]}
        with self.assertRaisesRegex(UI.UIFailure, "native-popover-ambiguous"):
            HELPER.settled_geometry(ambiguous, "vikingbar.fixtureMarker", comparator(),
                                    lambda: self.fail("ambiguous window retried"), UI.UIFailure)


if __name__ == "__main__":
    unittest.main()
