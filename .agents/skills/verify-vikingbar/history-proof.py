#!/usr/bin/env python3
"""Stored-session history gate with modern, individual exact-window captures."""

import importlib.util
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("maintained_history_gate", ROOT / "Scripts/history-proof.py")
HISTORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HISTORY)


def modern_arguments(arguments):
    """Keep the exact target and request attested caller-local ownership."""
    result = list(arguments)
    index = result.index("--capture-engine")
    if result[index + 1] != "classic" or result.count("--no-remote") != 1:
        raise HISTORY.UIFailure("history-capture-interface-changed")
    result[index + 1] = "modern"
    return result


class MaintainedHistoryProof(HISTORY.HistoryProof):
    def capture_history_windows(self, label, report, windows, selected_index):
        for key in ("parent", "companion"):
            window = windows[key]["window"]
            suffix = "main-window" if key == "parent" else "companion-window"
            path = self.directory / f"{label}-{suffix}.png"
            self.verify_process()
            receipt = HISTORY.UI.UI.capture_exact_window(
                self.peekaboo, self.process.pid, window["kCGWindowNumber"], path,
                lambda arguments, name=f"{label}-{suffix}-image.json":
                    self.run(modern_arguments(arguments), name),
            )
            HISTORY.validate_capture_observation(receipt, window)
            HISTORY.validate_capture_geometry(path, HISTORY.window_frame(window))
            settled_tree = self.inspect(f"{label}-{suffix}-after-capture.json")
            settled = HISTORY.compare_history(settled_tree, report, self.screens)
            self.verify_process()
            if (HISTORY.window_identity(settled) != HISTORY.window_identity(windows)
                    or HISTORY.selected_day(settled_tree, report, settled) != selected_index):
                raise HISTORY.UIFailure("native-history-capture-mismatch")

    def perform(self):
        receipt = super().perform()
        if receipt.pop("native_window_group_capture", None) is not True:
            raise HISTORY.UIFailure("history-result-interface-changed")
        receipt["native_individual_window_capture"] = True
        HISTORY.UI.private_write(self.directory / "result.json", receipt)
        return receipt


def main():
    HISTORY.HistoryProof = MaintainedHistoryProof
    try:
        receipt, code = HISTORY.run(os.environ), 0
    except HISTORY.UIFailure as error:
        receipt, code = {"passed": False, "error": str(error)}, 1
    except Exception:
        receipt, code = {"passed": False, "error": "history-proof-failed"}, 1
    print(json.dumps(receipt, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
