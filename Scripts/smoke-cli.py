#!/usr/bin/env python3
"""Exercise explicit synthetic fixture CLI paths without account access."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import subprocess
from zoneinfo import ZoneInfo


def run(executable, *arguments):
    return subprocess.run([str(executable), "--fixture", *arguments], text=True, capture_output=True, timeout=30)


def verify(executable):
    expected = {"finite": "36.00 GB", "unlimited": "Unlimited", "exhausted": "0.00 GB",
                "stale": "36.00 GB", "error": "Unavailable"}
    for fixture, remaining in expected.items():
        result = run(executable, fixture, "--time-zone", "UTC")
        assert result.returncode == 0, result.stderr
        report = json.loads(result.stdout)
        assert report["schemaVersion"] == 1
        assert report["snapshot"]["source"] == {"fixture": {"_0": fixture}}
        menu = report["menu"]
        assert menu["remainingText"] == remaining
        assert "Synthetic data" in menu["sourceLabel"]
        assert ("Stale" in menu["freshnessText"]) == (fixture == "stale")
        assert bool(menu.get("warningText")) == (fixture in ("stale", "error"))
    result = run(executable, "finite", "--unit", "GiB", "--time-zone", "Europe/Brussels")
    assert result.returncode == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["menu"]["remainingText"] == "33.53 GiB"
    expiry = datetime.fromisoformat(report["snapshot"]["expiresAt"].replace("Z", "+00:00"))
    local = expiry.astimezone(ZoneInfo("Europe/Brussels"))
    assert local.strftime("%H:%M") in report["menu"]["expiryText"]
    for arguments, message in [(('unknown',), "Unknown fixture"),
                               (("finite", "--unit", "bogus"), "Unknown unit"),
                               (("finite", "--time-zone", "bogus"), "Unknown time zone"),
                               (("finite", "--unit"), "incomplete argument")]:
        result = run(executable, *arguments)
        assert result.returncode == 2 and not result.stdout and message in result.stderr, result
    print(f"CLI fixture smoke passed: {executable}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", nargs="?", type=Path, default=Path(".build/debug/vikingbar"))
    verify(parser.parse_args().executable.resolve())
