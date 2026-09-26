"""Verify the independent balance proof rejects incorrect production mappings for every bundle kind."""

import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
UPDATED = "2026-09-07T12:00:00Z"


def raw_bundle(kind, title, total, used, remaining, category="default", description="Synthetic",
               valid_from="2026-09-01T00:00:00Z", valid_until="2026-10-01T00:00:00Z"):
    return {"descriptions": {"title": title, "description": description}, "category": category, "type": kind,
            "total": total, "used": used, "remaining": remaining, "valid_from": valid_from,
            "valid_until": valid_until}


def payload():
    raw = [raw_bundle("data", "Data", 50000000000, 20000000000, 30000000000),
           raw_bundle("sms", "Monthly SMS", 100, 40, 60),
           raw_bundle("voice", "", 2400, 1230, 1170, description=""),
           raw_bundle("value", "Prepaid credit", 15, 2.5, 12.5),
           raw_bundle("sms", "", -1, 12, -1, category="super_on_net"),
           raw_bundle("voice", "Roaming calls", 600, 0, 600, valid_until="2026-09-06T00:00:00Z"),
           raw_bundle("data", "Extra data", 5000000000, 1000000000, 4000000000)]
    bundles = [{"title": b["descriptions"]["title"], "description": b["descriptions"]["description"],
                "category": b["category"], "type": b["type"], "total": b["total"], "used": b["used"],
                "remaining": b["remaining"], "validFrom": b["valid_from"], "validUntil": b["valid_until"]}
               for b in raw]
    snapshot = {"source": {"live": {}}, "subscriptionName": "SIM", "expiresAt": "2026-10-01T00:00:00Z",
                "allowance": {"finite": {"totalBytes": 50000000000, "usedBytes": 20000000000,
                                         "remainingBytes": 30000000000}},
                "freshness": {"current": {"lastUpdated": UPDATED}}}
    state = {"connectionID": {"rawValue": "00000000-0000-0000-0000-000000000001"},
             "subscriptions": [{"id": "sim-one", "type": "postpaid", "displayName": "SIM"}],
             "selectedSubscriptionID": "sim-one", "selectedBundleIndex": 0, "snapshot": snapshot,
             "balance": {"bundles": bundles, "regionality": "national", "outOfBundleCost": 0},
             "isRefreshing": False, "scopeMismatch": True}
    return {"balance": {"bundles": raw, "regionality": "national", "out_of_bundle_cost": 0}, "state": state}


class BalanceOracleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="vikingbar-balance-oracle-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.executable = Path(cls.temp.name) / "balance-oracle-driver"
        build = ROOT / ".build/debug"
        objects = list((build / "VikingBarCore.build").glob("*.swift.o"))
        if not objects:
            raise AssertionError("Run swift build before balance oracle tests")
        sources = [ROOT / "Scripts/tests/balance-oracle-driver.swift", ROOT / "Sources/VikingBarCLI/BalanceOracle.swift"]
        result = subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", "-I", str(build / "Modules"),
                                 *map(str, sources), *map(str, objects), "-o", str(cls.executable)],
                                cwd=ROOT, capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stderr)

    def run_oracle(self, value):
        result = subprocess.run([str(self.executable)], input=json.dumps(value), capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_every_kind_matches_and_receipt_counts_raw_types(self):
        value = payload()
        value["cases"] = [{"index": index} for index in range(7)]
        output = self.run_oracle(value)
        self.assertEqual(output["receipt"], {"schema_version": 1, "check": "balance-api", "passed": True,
                                             "api_matches": True, "token_refreshed": True, "bundle_count": 7,
                                             "bundle_types": {"data": 2, "sms": 2, "voice": 2, "value": 1}})
        self.assertEqual(output["cases"], [True] * 7)
        self.assertNotIn("Monthly SMS", json.dumps(output))

    def test_state_mapping_and_identity_errors_fail_the_receipt(self):
        for mutate in (
            lambda p: p["state"]["snapshot"]["allowance"]["finite"].update(remainingBytes=10000000000),
            lambda p: p["state"].update(selectedSubscriptionID="sim-two"),
            lambda p: p["state"]["balance"].update(outOfBundleCost=7),
            lambda p: p["state"]["balance"]["bundles"][1].update(remaining=61),
            lambda p: p["state"]["balance"]["bundles"][1].update(type="voice"),
            lambda p: p["state"].update(selectedBundleIndex=1),
            lambda p: p.update(refresh=False),
        ):
            value = payload()
            mutate(value)
            self.assertIsNone(self.run_oracle(value)["receipt"])

    def test_production_values_and_strings_are_checked_per_kind(self):
        tampered = [
            {"index": 1, "bundle": {"remaining": 61}},
            {"index": 1, "row": {"remainingText": "61 SMS"}},
            {"index": 1, "bundle": {"type": "voice"}},
            {"index": 1, "row": {"kind": "voice"}},
            {"index": 1, "row": {"detailText": "Calls · default"}},
            {"index": 2, "bundle": {"used": 1231}},
            {"index": 2, "row": {"usedText": "20 min 31 s used"}},
            {"index": 2, "row": {"title": "Call bundle 2"}},
            {"index": 3, "bundle": {"remaining": 12.51}},
            {"index": 3, "row": {"remainingText": "€12.51"}},
            {"index": 3, "row": {"description": "Changed"}},
            {"index": 4, "row": {"title": "SMS bundle 1"}},
            {"index": 4, "row": {"state": "finite"}},
            {"index": 4, "bundle": {"total": 100}},
            {"index": 5, "row": {"validityText": "Expires 6 Sep 2026, 00:00 UTC"}},
            {"index": 5, "row": {"remainingText": "10 min"}},
            {"index": 6, "bundle": {"remaining": 3000000000}},
            {"index": 6, "bundle": {"type": "sms"}},
        ]
        value = payload()
        value["cases"] = tampered
        self.assertEqual(self.run_oracle(value)["cases"], [False] * len(tampered))

    def test_raw_types_outside_the_documented_set_fail(self):
        value = payload()
        value["balance"]["bundles"][1]["type"] = "mms"
        self.assertIsNone(self.run_oracle(value)["receipt"])
        value = copy.deepcopy(payload())
        del value["balance"]["bundles"][1]
        self.assertIsNone(self.run_oracle(value)["receipt"])


if __name__ == "__main__":
    unittest.main()
