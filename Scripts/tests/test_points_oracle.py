"""Verify independent points proof rejects incorrect production mappings without account access."""

import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
DATE = "2026-09-07T08:00:00Z"


def payload():
    balance = {"available": 12.75, "pending": 3.5, "blocked": 2.25}
    states = ["completed", "pending", "blocked", "expired", "reserved", "cancelled", "rejected", "future"]
    raw = [{"transaction_id": str(index), "amount": 1.25 if index % 2 == 0 else -2.5,
            "state": state, "last_updated": DATE, "description": "Synthetic transaction"}
           for index, state in enumerate(states)]
    transactions = [{"transactionID": row["transaction_id"], "amount": row["amount"], "state": row["state"],
                     "lastUpdated": row["last_updated"], "description": row["description"]} for row in raw]
    return {"balance": balance,
            "pages": [{"page": 1, "per_page": 20, "total_pages": 1, "total_items": len(raw), "results": raw}],
            "points": {"balance": copy.deepcopy(balance), "balanceFreshness": {"current": {"lastUpdated": DATE}},
                       "historyFreshness": {"current": {"lastUpdated": DATE}},
                       "history": {"transactions": transactions, "totalItems": len(raw), "truncated": False}}}


class PointsOracleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="vikingbar-points-oracle-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.executable = Path(cls.temp.name) / "points-oracle-driver"
        build = ROOT / ".build/debug"
        objects = list((build / "VikingBarCore.build").glob("*.swift.o"))
        if not objects:
            raise AssertionError("Run swift build before points oracle tests")
        sources = [ROOT / "Scripts/tests/points-oracle-driver.swift", ROOT / "Sources/VikingBarCLI/PointsOracle.swift"]
        result = subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", "-I", str(build / "Modules"),
                                 *map(str, sources), *map(str, objects), "-o", str(cls.executable)],
                                cwd=ROOT, capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stderr)

    def run_proof(self, value):
        return subprocess.run([str(self.executable)], input=json.dumps(value), capture_output=True,
                              text=True, timeout=10)

    def test_all_states_and_signed_fractional_amounts_match(self):
        result = self.run_proof(payload())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"schema_version": 1, "check": "points-api", "passed": True,
                                                    "api_matches": True, "token_refreshed": True,
                                                    "transaction_count": 8, "page_count": 1})

    def test_balance_mapping_and_transaction_state_corruption_fail(self):
        for mutate in (
            lambda p: p["points"]["balance"].update(available=16.25),
            lambda p: p["points"]["history"]["transactions"][1].update(state="completed"),
            lambda p: p["points"]["history"]["transactions"][1].update(amount=2.5),
            lambda p: p["points"]["history"].update(truncated=True),
            lambda p: p["points"].update(historyFailure="transport"),
            lambda p: p.update(refresh=False),
        ):
            value = payload()
            mutate(value)
            result = self.run_proof(value)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout), {"passed": False})
            self.assertNotIn("Synthetic transaction", result.stdout)

    def test_empty_history_is_valid_real_response(self):
        value = payload()
        value["pages"][0].update(results=[], total_pages=0, total_items=0)
        value["points"]["history"].update(transactions=[], totalItems=0)
        result = self.run_proof(value)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["transaction_count"], 0)
