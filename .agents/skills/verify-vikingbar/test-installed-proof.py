#!/usr/bin/env python3
"""Synthetic regression checks; never launch an app or read Keychain."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("skill_installed", Path(__file__).with_name("installed-proof.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PickerTests(unittest.TestCase):
    def setUp(self):
        self.proof = object.__new__(MODULE.InstalledProof)
        self.proof.process = type("Process", (), {"pid": 123})()
        self.proof.environment = {}
        self.proof.cli = Path("/synthetic/vikingbar")
        self.proof.screens = [{"bounds": {"x": 0, "y": 0, "width": 100, "height": 100}}]
        self.proof.verify_process = lambda: None
        self.proof.inspect = lambda *args: {}
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.proof.directory = Path(self.directory.name)
        self.boundary = {"frame": [[0, 0], [100, 100]]}
        self.picker = {"AXIdentifier": "vikingbar.dataDisplayMode", "AXRole": "AXPopUpButton",
                       "AXValue": "Used", "frame": [[10, 10], [20, 20]]}

    def test_hidden_app_menus_do_not_block_but_visible_menus_do(self):
        hidden = {"AXRole": "AXMenuItem", "frame": [[0, 0], [0, 0]]}
        visible = {"AXRole": "AXMenuItem", "frame": [[5, 5], [20, 20]]}
        def wait(_inspect, settled):
            self.assertFalse(settled({"elements": [self.picker, visible]}))
            self.assertTrue(settled({"elements": [self.picker, hidden]}))
        with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "{}", "")), \
                patch.object(MODULE.time, "sleep"), patch.object(MODULE.PROOF.UI, "wait_for", side_effect=wait), \
                patch.object(MODULE.PROOF.UI, "popover_window", return_value=(self.boundary, {})):
            self.proof.choose("dataDisplayMode", "Used")

    def test_transient_popover_absence_waits_without_repeating_action(self):
        def wait(_inspect, settled):
            self.assertFalse(settled({}))
            self.assertTrue(settled({"elements": [self.picker]}))
        with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "{}", "")) as run, \
                patch.object(MODULE.time, "sleep"), patch.object(MODULE.PROOF.UI, "wait_for", side_effect=wait), \
                patch.object(MODULE.PROOF.UI, "popover_window", side_effect=[
                    MODULE.PROOF.UIFailure("native-popover-not-visible"), (self.boundary, {})]):
            self.proof.choose("dataDisplayMode", "Used")
            self.assertEqual(run.call_count, 1)

    def test_failed_dispatch_is_not_retried(self):
        with patch.object(MODULE.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "failed")) as run:
            with self.assertRaisesRegex(MODULE.PROOF.UIFailure, "picker-command-failed"):
                self.proof.choose("dataDisplayMode", "Used")
            self.assertEqual(run.call_count, 1)

    def test_account_resolves_before_launch(self):
        self.proof.check = "installed-balance"
        events = []
        def catalog(*_args):
            events.append("catalog")
            return {"selected": {"provider": "mobile-vikings", "slot": "00000000-0000-0000-0000-000000000001"}}
        self.proof.run = catalog
        with patch.object(MODULE.Base, "launch", side_effect=lambda *_args: events.append("launch")):
            self.proof.launch()
        self.assertEqual(events, ["catalog", "launch"])
        self.assertEqual(self.proof.account_selector, "mobile-vikings/00000000-0000-0000-0000-000000000001")

    def test_unsupported_account_cannot_launch(self):
        self.proof.check = "installed-balance"
        self.proof.run = lambda *_args: {"selected": {"provider": "fixture-home", "slot": "invalid"}}
        with patch.object(MODULE.Base, "launch") as launch:
            with self.assertRaisesRegex(MODULE.PROOF.UIFailure, "runtime-worker-identity-mismatch"):
                self.proof.launch()
            launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
