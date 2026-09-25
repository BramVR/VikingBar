import copy
import datetime
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from zoneinfo import ZoneInfo

SPEC = importlib.util.spec_from_file_location("telenet_home_ui", Path(__file__).parents[1] / "telenet-home-ui-proof.py")
PROOF = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROOF)


class TelenetHomeUIProofTests(unittest.TestCase):
    def setUp(self):
        self.account = "telenet/00000000-0000-0000-0000-000000000042"
        key = {"provider": "telenet", "slot": "00000000-0000-0000-0000-000000000042"}
        service = {"account": key, "kind": "home", "providerID": "synthetic-home"}
        connection = {"rawValue": "00000000-0000-0000-0000-000000000123"}
        snapshot = {"source": {"live": {}}, "freshness": {"current": {"lastUpdated": "2026-09-24T12:00:00Z"}}}
        self.report = {"schemaVersion": 1, "snapshot": snapshot, "state": {
            "snapshot": snapshot, "connectionID": connection,
            "account": {"key": key, "selectedService": service, "services": [{"key": service}]},
            "homeUsage": {"key": service, "connectionID": connection, "fetchedAt": "2026-09-24T12:00:00Z",
                          "period": {"start": "2026-09-01", "end": "2026-09-30"},
                          "dailyHistory": {"fetchedDay": "2026-09-24", "rows": [
                              {"day": (datetime.date(2026, 9, 1) + datetime.timedelta(days=index)).isoformat()}
                              for index in range(24)]}}},
            "home": {"periodText": "Billing period 1 Sep to 30 Sep", "categoryText": "FUP",
                     "policyCounterText": "Fair-use counter 12.50 GB", "allocationText": "Reported threshold 100 GB",
                     "downloadedText": "Downloaded 80 GB", "peakText": "Peak 20 GB", "offPeakText": "Off-peak 60 GB",
                     "speedText": "Speed state not reported", "providerUpdatedText": "Provider updated 24 Sep",
                     "fetchedText": "Checked 24 Sep"},
            "menu": {"sourceLabel": "Telenet · Live account", "accessibilityLabel": "VikingBar policy counter",
                     "title": "Home", "freshnessText": "Last updated 24 Sep"}}
        self.screens = [{"bounds": {"x": 0, "y": 0, "width": 1000, "height": 1000}}]
        self.tree = {"elements": [
            {"AXIdentifier": "vikingbar.status", "frame": [[10, 0], [25, 20]],
             "AXDescription": "VikingBar policy counter, Home, Last updated 24 Sep"},
            {"AXRole": "AXPopover", "frame": [[10, 20], [500, 700]]},
            {"AXIdentifier": "vikingbar.source", "AXValue": "Telenet · Live account", "frame": [[30, 620], [400, 20]]}],
            "windows": [{"kCGWindowNumber": 42,
                         "kCGWindowBounds": {"X": 10, "Y": 20, "Width": 500, "Height": 700}}]}
        for index, (field, suffix) in enumerate(PROOF.FIELDS.items()):
            self.tree["elements"].append({"AXIdentifier": "vikingbar.home." + suffix,
                                          "AXValue": self.report["home"][field],
                                          "frame": [[30, 50 + index * 30], [400, 20]]})
        start = datetime.date(2026, 8, 26)
        days = []
        for index in range(30):
            day = start + datetime.timedelta(days=index)
            before = day < datetime.date(2026, 9, 1)
            days.append({"dayStart": day.isoformat() + "T00:00:00+02:00", "bytes": None if before else 1000,
                         "label": day.strftime("%-d %b"), "fullDateText": day.strftime("%-d %B %Y"),
                         "valueText": "Missing" if before else "0.00 GB", "statusText": "No data" if before else "Used",
                         "isMissing": False, "isToday": index == 29, "isPartial": index == 29,
                         "isStale": False})
            if before:
                days[-1].update(statusText="Outside billing period", valueText="Outside period")
        self.report["historyPresentation"] = {
            "days": days, "unit": "GB", "forecast": {"completeDays": 3, "estimatedCycleBytes": 2000.0},
            "forecastText": "Estimated home data this cycle: 0.00 GB",
            "totalText": "Observed home data: 0.00 GB", "statusText": "Daily home data",
            "scopeText": "Telenet home traffic for the current billing period."}

    def test_current_report_requires_matching_account_service_and_connection(self):
        self.assertEqual(PROOF.home_timestamp(self.report, self.account),
                         datetime.datetime(2026, 9, 24, 12, tzinfo=datetime.timezone.utc))
        for field, value in (("key", {"account": {"provider": "mobile-vikings", "slot": self.account.split('/')[1]},
                                      "kind": "home", "providerID": "synthetic-home"}),
                             ("connectionID", {"rawValue": "00000000-0000-0000-0000-000000000999"}),
                             ("fetchedAt", "2026-09-23T12:00:00Z")):
            changed = copy.deepcopy(self.report)
            changed["state"]["homeUsage"][field] = value
            with self.subTest(field=field), self.assertRaises(PROOF.UIFailure):
                PROOF.home_timestamp(changed, self.account)

    def test_native_fields_and_status_must_match_and_be_visible(self):
        self.assertIsNone(PROOF.compare_home(self.tree, self.report, self.screens, self.account))
        for index in (0, 3, 4, 5, 6):
            changed = copy.deepcopy(self.tree)
            changed["elements"][index]["AXValue"] = "wrong-value"
            changed["elements"][index]["AXDescription"] = "wrong-value"
            with self.subTest(index=index), self.assertRaises(PROOF.UIFailure):
                PROOF.compare_home(changed, self.report, self.screens, self.account)
        changed = copy.deepcopy(self.tree)
        changed["elements"][-1]["frame"][0][1] = 800
        with self.assertRaises(PROOF.UIFailure):
            PROOF.compare_home(changed, self.report, self.screens, self.account)

    def test_raw_total_cannot_substitute_for_policy_counter(self):
        changed = copy.deepcopy(self.tree)
        counter = next(item for item in changed["elements"] if item.get("AXIdentifier") == "vikingbar.home.policy-counter")
        counter["AXValue"] = "Fair-use counter 80 GB"
        with self.assertRaises(PROOF.UIFailure):
            PROOF.compare_home(changed, self.report, self.screens, self.account)

    def test_api_receipt_rejects_skips_and_extra_private_fields(self):
        receipt = {"schema_version": 1, "check": "telenet-home-api", "passed": True, "api_matches": True,
                   "service_count": 1, "daily_usage_matches": True, "daily_row_count": 24,
                   "daily_history_matches": True, "forecast_matches": True, "session_reused": True}
        self.assertEqual(PROOF.validate_api_receipt(receipt), receipt)
        for delta in ({"passed": False}, {"daily_usage_matches": False}, {"daily_history_matches": False},
                      {"forecast_matches": False}, {"session_reused": False}, {"daily_row_count": 0},
                      {"daily_row_count": True}, {"daily_row_count": 63}, {"service_count": 0},
                      {"service_count": True}, {"schema_version": True}, {"cookies": "private"}):
            with self.subTest(delta=delta), self.assertRaises(PROOF.UIFailure):
                PROOF.validate_api_receipt(dict(receipt, **delta))

    def test_initial_history_refreshes_old_cache_once_then_requires_daily_evidence(self):
        now = datetime.datetime(2026, 9, 24, 12, tzinfo=datetime.timezone.utc)
        old = copy.deepcopy(self.report)
        old["state"]["homeUsage"].pop("dailyHistory")
        self.assertTrue(PROOF.initial_history_needs_refresh(old, now))
        self.assertFalse(PROOF.initial_history_needs_refresh(self.report, now))
        proof = object.__new__(PROOF.TelenetHomeProof)
        proof.telenet_account = self.account
        events = []
        proof.wait_manual_floor = lambda report, *, allow_stale=False: events.append(("floor", allow_stale))
        proof.refresh_home = lambda: events.append("refresh")
        def matched(label, after):
            events.append((label, after))
            return self.report
        proof.matched_home = matched
        self.assertIs(proof.initial_history_report(old, now), self.report)
        self.assertEqual([events[0], events[1], events[2][0]],
                         [("floor", True), "refresh", "connected-home-fresh"])
        self.assertEqual(events[2][1], PROOF.home_timestamp(old, self.account))
        events.clear()
        self.assertIs(proof.initial_history_report(self.report, now), self.report)
        self.assertEqual(events, [])
        proof.matched_home = lambda label, after: old
        with self.assertRaisesRegex(PROOF.HISTORY.UIFailure, "telenet-history-report-invalid"):
            proof.initial_history_report(old, now)
        self.assertEqual(events, [("floor", True), "refresh"])

    def test_initial_stale_snapshot_keeps_identity_checks_and_reaches_refresh(self):
        old = copy.deepcopy(self.report)
        timestamp = old["state"]["homeUsage"]["fetchedAt"]
        snapshot = old["snapshot"]
        snapshot["freshness"] = {"stale": {"lastUpdated": timestamp}}
        old["state"]["snapshot"] = copy.deepcopy(snapshot)
        old["state"]["homeUsage"].pop("dailyHistory")
        self.assertEqual(PROOF.home_timestamp(old, self.account, allow_stale=True),
                         datetime.datetime(2026, 9, 24, 12, tzinfo=datetime.timezone.utc))
        with self.assertRaisesRegex(PROOF.UIFailure, "telenet-home-report-invalid"):
            PROOF.home_timestamp(old, self.account)
        PROOF.compare_home(self.tree, old, self.screens, self.account, allow_stale=True)
        with self.assertRaisesRegex(PROOF.UIFailure, "telenet-home-report-invalid"):
            PROOF.compare_home(self.tree, old, self.screens, self.account)
        proof = object.__new__(PROOF.TelenetHomeProof)
        proof.telenet_account = self.account
        proof.connection_digest = None
        proof.screens = self.screens
        proof.cached = lambda *_: old
        proof.inspect = lambda *_: self.tree
        proof.verify_worker = lambda *_: None
        proof.capture_home = lambda *_: None
        self.assertIs(proof.matched_home("initial", allow_stale=True), old)
        with self.assertRaisesRegex(PROOF.UIFailure, "telenet-home-report-invalid"):
            proof.matched_home("later")
        events = []
        proof.wait_manual_floor = lambda report, *, allow_stale=False: events.append(("floor", allow_stale))
        proof.refresh_home = lambda: events.append("refresh")
        proof.matched_home = lambda label, after: self.report
        now = datetime.datetime(2026, 9, 24, 12, tzinfo=datetime.timezone.utc)
        self.assertIs(proof.initial_history_report(old, now), self.report)
        self.assertEqual(events, [("floor", True), "refresh"])
        mismatched = copy.deepcopy(old)
        mismatched["state"]["homeUsage"]["connectionID"] = {"rawValue": "other"}
        with self.assertRaisesRegex(PROOF.UIFailure, "telenet-home-report-invalid"):
            PROOF.home_timestamp(mismatched, self.account, allow_stale=True)
        failed = copy.deepcopy(old)
        failed["state"]["failure"] = "primary-failure"
        with self.assertRaisesRegex(PROOF.UIFailure, "telenet-home-report-invalid"):
            PROOF.home_timestamp(failed, self.account, allow_stale=True)

    def test_matched_home_waits_past_stale_seed_but_accepts_only_newer_current_report(self):
        old = copy.deepcopy(self.report)
        old["snapshot"]["freshness"] = {"stale": {"lastUpdated": "2026-09-24T12:00:00Z"}}
        old["state"]["snapshot"] = copy.deepcopy(old["snapshot"])
        fresh = copy.deepcopy(self.report)
        fresh["state"]["homeUsage"]["fetchedAt"] = "2026-09-24T12:01:00Z"
        fresh["snapshot"]["freshness"]["current"]["lastUpdated"] = "2026-09-24T12:01:00Z"
        fresh["state"]["snapshot"] = copy.deepcopy(fresh["snapshot"])
        after = PROOF.home_timestamp(old, self.account, allow_stale=True)
        proof = object.__new__(PROOF.TelenetHomeProof)
        proof.telenet_account = self.account
        proof.connection_digest = PROOF.UI.connection_identity(old)[1]
        proof.screens = self.screens
        proof.inspect = lambda *_: self.tree
        proof.verify_worker = lambda *_: None
        proof.capture_home = lambda *_: None
        reports = iter((old, fresh))
        proof.cached = lambda *_: next(reports)
        with patch.object(PROOF.UI.time, "sleep") as sleep:
            self.assertIs(proof.matched_home("fresh", after), fresh)
        sleep.assert_called_once_with(0.25)

        for changed in ("stale", "connection", "primary-failure"):
            candidate = copy.deepcopy(fresh)
            if changed == "stale":
                candidate["snapshot"]["freshness"] = {"stale": {"lastUpdated": "2026-09-24T12:01:00Z"}}
                candidate["state"]["snapshot"] = copy.deepcopy(candidate["snapshot"])
            elif changed == "connection":
                candidate["state"]["connectionID"] = {"rawValue": "00000000-0000-0000-0000-000000000999"}
                candidate["state"]["homeUsage"]["connectionID"] = candidate["state"]["connectionID"]
            else:
                candidate["state"]["failure"] = "primary-failure"
            proof.cached = lambda *_, candidate=candidate: candidate
            with self.subTest(changed=changed), self.assertRaises(PROOF.UIFailure):
                proof.matched_home("invalid-newer", after)

    def test_initial_history_refreshes_previous_day_or_stale_daily_report(self):
        now = datetime.datetime(2026, 9, 24, 12, tzinfo=datetime.timezone.utc)
        previous = copy.deepcopy(self.report)
        previous["state"]["homeUsage"]["dailyHistory"]["fetchedDay"] = "2026-09-23"
        self.assertTrue(PROOF.initial_history_needs_refresh(previous, now))
        stale = copy.deepcopy(self.report)
        stale["historyPresentation"]["days"][12]["isStale"] = True
        self.assertTrue(PROOF.initial_history_needs_refresh(stale, now))
        expired = copy.deepcopy(self.report)
        self.assertTrue(PROOF.initial_history_needs_refresh(
            expired, now + datetime.timedelta(seconds=3600)))

    def test_home_history_requires_rolling_days_cycle_gaps_partial_today_and_finite_forecast(self):
        presentation = self.report["historyPresentation"]
        now = datetime.datetime(2026, 9, 24, 12, tzinfo=datetime.timezone.utc)
        self.assertIs(PROOF.HISTORY.validate_presentation(self.report, now), presentation)
        edits = (
            lambda r: r["historyPresentation"]["days"].pop(),
            lambda r: r["historyPresentation"]["days"][0].update(bytes=0),
            lambda r: r["historyPresentation"]["days"][29].update(isPartial=False),
            lambda r: r["historyPresentation"]["days"][4].update(dayStart="2026-08-01T00:00:00+02:00"),
            lambda r: r["historyPresentation"]["forecast"].update(completeDays=2),
            lambda r: r["historyPresentation"]["forecast"].update(estimatedCycleBytes=float("inf")),
            lambda r: r["historyPresentation"].update(forecast=None),
            lambda r: r["historyPresentation"].update(scopeText="SIM data"),
            lambda r: r["historyPresentation"]["days"][10].update(isStale=True),
            lambda r: r["state"].update(homeFailure="daily-failed"),
            lambda r: r["state"]["homeUsage"]["dailyHistory"].update(fetchedDay="2026-09-23"),
            lambda r: r["state"]["homeUsage"]["dailyHistory"].update(rows=[{"day": "2026-09-01"}]),
        )
        for edit in edits:
            changed = copy.deepcopy(self.report)
            edit(changed)
            with self.assertRaisesRegex(PROOF.HISTORY.UIFailure, "telenet-history-report-invalid"):
                PROOF.HISTORY.validate_presentation(changed, now)

    def test_main_hover_requires_selected_day_and_no_companion(self):
        tree = copy.deepcopy(self.tree)
        tree["pid"] = 123
        window = tree["windows"][0]
        window.update(kCGWindowAlpha=1, kCGWindowOwnerPID=123, kCGWindowIsOnscreen=True)
        tree["elements"].append({"AXIdentifier": "vikingbar.historyMainPlot", "frame": [[30, 300], [400, 70]]})
        day = self.report["historyPresentation"]["days"][0]
        for identifier, field in (("vikingbar.historyMainSelectedDate", "fullDateText"),
                                  ("vikingbar.historyMainSelectedValue", "valueText"),
                                  ("vikingbar.historyMainSelectedStatus", "statusText")):
            tree["elements"].append({"AXIdentifier": identifier, "AXValue": day[field],
                                     "frame": [[30, 400], [400, 20]]})
        compare = lambda value, report, screens: PROOF.compare_home(value, report, screens, self.account)
        now = datetime.datetime(2026, 9, 24, 12, tzinfo=datetime.timezone.utc)
        PROOF.HISTORY.compare_main(tree, self.report, self.screens, 0, compare, now)
        hidden = copy.deepcopy(tree)
        hidden["windows"].append({"kCGWindowNumber": 43, "kCGWindowAlpha": 1,
                                  "kCGWindowOwnerPID": 123, "kCGWindowIsOnscreen": True,
                                  "kCGWindowBounds": {"X": 200, "Y": 100,
                                                      "Width": 380, "Height": 650}})
        with self.assertRaisesRegex(PROOF.HISTORY.UIFailure, "native-history-hover-opened-detail"):
            PROOF.HISTORY.compare_main(hidden, self.report, self.screens, 0, compare, now)
        tree["elements"].append({"AXIdentifier": "vikingbar.historyPanel"})
        with self.assertRaisesRegex(PROOF.HISTORY.UIFailure, "native-history-hover-opened-detail"):
            PROOF.HISTORY.compare_main(tree, self.report, self.screens, 0, compare, now)

    def test_history_uses_brussels_civil_days_across_dst_and_preserves_old_partial_fetch_day(self):
        report = copy.deepcopy(self.report)
        today = datetime.date(2026, 10, 27)
        first = today - datetime.timedelta(days=29)
        report["state"]["homeUsage"]["period"] = {"start": "2026-10-01", "end": "2026-10-31"}
        report["state"]["homeUsage"]["fetchedAt"] = "2026-10-26T12:00:00Z"
        report["state"]["homeUsage"]["dailyHistory"] = {"fetchedDay": "2026-10-26", "rows": [
            {"day": (datetime.date(2026, 10, 1) + datetime.timedelta(days=index)).isoformat()}
            for index in range(3)]}
        report["historyPresentation"]["forecast"] = None
        for index, day in enumerate(report["historyPresentation"]["days"]):
            civil = first + datetime.timedelta(days=index)
            midnight = datetime.datetime.combine(civil, datetime.time(), ZoneInfo("Europe/Brussels"))
            before = civil < datetime.date(2026, 10, 1)
            day.update(dayStart=midnight.isoformat(), bytes=None, isMissing=not before,
                       isToday=civil == today, isPartial=civil in (today, datetime.date(2026, 10, 26)),
                       isStale=False, statusText="Outside billing period" if before else "No data (missing)",
                       valueText="Outside period" if before else "Unavailable")
        now = datetime.datetime(2026, 10, 27, 12, tzinfo=datetime.timezone.utc)
        report["historyPresentation"].pop("forecast")
        report["historyPresentation"]["days"][0].pop("bytes")
        self.assertIs(PROOF.HISTORY.validate_presentation(report, now), report["historyPresentation"])
        changed = copy.deepcopy(report)
        changed["historyPresentation"]["days"][28]["isPartial"] = False
        with self.assertRaisesRegex(PROOF.HISTORY.UIFailure, "telenet-history-report-invalid"):
            PROOF.HISTORY.validate_presentation(changed, now)
        changed = copy.deepcopy(report)
        changed["historyPresentation"]["days"][29]["dayStart"] = "2026-10-27T00:00:00+02:00"
        with self.assertRaisesRegex(PROOF.HISTORY.UIFailure, "telenet-history-report-invalid"):
            PROOF.HISTORY.validate_presentation(changed, now)

    def test_previous_fetch_day_remains_partial_and_fresh_around_midnight(self):
        report = copy.deepcopy(self.report)
        fetched = "2026-09-24T21:50:00Z"
        report["state"]["homeUsage"]["fetchedAt"] = fetched
        report["snapshot"]["freshness"]["current"]["lastUpdated"] = fetched
        report["state"]["snapshot"]["freshness"]["current"]["lastUpdated"] = fetched
        report["historyPresentation"].pop("forecast")
        today = datetime.date(2026, 9, 25)
        first = today - datetime.timedelta(days=29)
        for index, day in enumerate(report["historyPresentation"]["days"]):
            civil = first + datetime.timedelta(days=index)
            before = civil < datetime.date(2026, 9, 1)
            midnight = datetime.datetime.combine(civil, datetime.time(), ZoneInfo("Europe/Brussels"))
            day.update(dayStart=midnight.isoformat(), isToday=civil == today,
                       isPartial=civil in (datetime.date(2026, 9, 24), today), isStale=False)
            if before:
                day.update(bytes=None, isMissing=False, valueText="Outside period",
                           statusText="Outside billing period")
            elif civil == today:
                day.update(bytes=None, isMissing=True, valueText="Unavailable · partial",
                           statusText="No data (missing) · partial")
            else:
                day.update(bytes=1000, isMissing=False)
                if civil == datetime.date(2026, 9, 24):
                    day.update(valueText="0.00 GB · partial", statusText="Downloads reported · partial")
        now = datetime.datetime(2026, 9, 24, 22, 10, tzinfo=datetime.timezone.utc)
        presentation = report["historyPresentation"]
        self.assertIs(PROOF.HISTORY.validate_presentation(report, now), presentation)
        self.assertTrue(presentation["days"][28]["isPartial"])
        self.assertFalse(presentation["days"][28]["isStale"])
        self.assertTrue(presentation["days"][29]["isMissing"])
        self.assertNotIn("forecast", presentation)
        changed = copy.deepcopy(report)
        changed["historyPresentation"]["days"][28]["isStale"] = True
        with self.assertRaisesRegex(PROOF.HISTORY.UIFailure, "telenet-history-report-invalid"):
            PROOF.HISTORY.validate_presentation(changed, now)
        one_hour_later = datetime.datetime(2026, 9, 24, 22, 50, tzinfo=datetime.timezone.utc)
        with self.assertRaisesRegex(PROOF.HISTORY.UIFailure, "telenet-history-report-invalid"):
            PROOF.HISTORY.validate_presentation(report, one_hour_later)

    def test_companion_checks_every_chart_day_and_home_detail_field(self):
        presentation = self.report["historyPresentation"]
        days = presentation["days"]
        parent = {"AXRole": "AXPopover", "frame": [[600, 50], [390, 740]]}
        companion = {"AXRole": "AXWindow", "AXIdentifier": "vikingbar.historyPanel",
                     "frame": [[200, 100], [380, 650]]}
        elements = [self.tree["elements"][0], parent, companion,
                    {"AXIdentifier": "vikingbar.historyChart", "frame": [[220, 180], [340, 180]],
                     "AXDescription": "; ".join(day["label"] + ": " + day["valueText"] for day in days)},
                    {"AXIdentifier": "vikingbar.historyPlot", "frame": [[245, 205], [290, 125]]}]
        for identifier, field in (("vikingbar.historyForecast", "forecastText"),
                                  ("vikingbar.historyTotal", "totalText"),
                                  ("vikingbar.historyStatus", "statusText"),
                                  ("vikingbar.historyScope", "scopeText")):
            elements.append({"AXIdentifier": identifier, "AXValue": presentation[field],
                             "frame": [[230, 400], [320, 20]]})
        for identifier, field in (("vikingbar.historySelectedDate", "fullDateText"),
                                  ("vikingbar.historySelectedValue", "valueText"),
                                  ("vikingbar.historySelectedStatus", "statusText")):
            elements.append({"AXIdentifier": identifier, "AXValue": days[0][field],
                             "frame": [[230, 500], [320, 20]]})
        windows = [{"kCGWindowNumber": number, "kCGWindowAlpha": 1, "kCGWindowOwnerPID": 123,
                    "kCGWindowIsOnscreen": True,
                    "kCGWindowBounds": {"X": frame[0][0], "Y": frame[0][1],
                                        "Width": frame[1][0], "Height": frame[1][1]}}
                   for number, frame in ((1, parent["frame"]), (2, companion["frame"]))]
        tree = {"pid": 123, "elements": elements, "windows": windows}
        now = datetime.datetime(2026, 9, 24, 12, tzinfo=datetime.timezone.utc)
        result = PROOF.HISTORY.compare_companion(tree, self.report, self.screens, lambda *_: None, now)
        self.assertEqual(result["companion"]["window"]["kCGWindowNumber"], 2)
        changed = copy.deepcopy(tree)
        changed["elements"][3]["AXDescription"] = "Only the first day: 1 GB"
        with self.assertRaisesRegex(PROOF.HISTORY.UIFailure, "native-history-chart-values-mismatch"):
            PROOF.HISTORY.compare_companion(changed, self.report, self.screens, lambda *_: None, now)
        changed = copy.deepcopy(tree)
        next(item for item in changed["elements"] if item.get("AXIdentifier") ==
             "vikingbar.historyScope")["AXValue"] = "SIM data"
        with self.assertRaisesRegex(PROOF.HISTORY.UIFailure, "native-history-text-mismatch"):
            PROOF.HISTORY.compare_companion(changed, self.report, self.screens, lambda *_: None, now)

    def test_mobile_payload_or_fixture_does_not_satisfy_home_gate(self):
        for edit in (lambda r: r["state"].update(balance={"bundles": [1]}),
                     lambda r: r["snapshot"].update(source={"fixture": {"_0": "finite"}}),
                     lambda r: r["state"].update(failure="transport")):
            changed = copy.deepcopy(self.report)
            edit(changed)
            with self.assertRaises(PROOF.UIFailure):
                PROOF.home_timestamp(changed, self.account)

    def test_matching_card_expands_timestamps_even_when_period_is_already_visible(self):
        proof = object.__new__(PROOF.TelenetHomeProof)
        proof.telenet_account = self.account
        proof.connection_digest = None
        proof.screens = self.screens
        expanded = copy.deepcopy(self.tree)
        tree = copy.deepcopy(self.tree)
        tree["elements"] = [item for item in tree["elements"] if item.get("AXIdentifier") not in
                            {"vikingbar.home.fetched", "vikingbar.home.provider-updated"}]
        tree["elements"].append({"AXIdentifier": "vikingbar.home.details", "frame": [[30, 500], [400, 20]]})
        pressed = []
        def press(identifier):
            pressed.append(identifier)
            tree.update(expanded)
        proof.press = press
        proof.cached = lambda *args: self.report
        proof.inspect = lambda *args: tree
        proof.verify_worker = lambda *args: None
        proof.capture_home = lambda *args: None
        self.assertEqual(proof.matched_home("home"), self.report)
        self.assertEqual(pressed, ["vikingbar.home.details"])

    def test_matching_card_retries_only_session_busy_while_refresh_holds_lease(self):
        proof = object.__new__(PROOF.TelenetHomeProof)
        proof.telenet_account = self.account
        proof.connection_digest = None
        proof.screens = self.screens
        attempts = iter([PROOF.UIFailure("session-busy"), self.report])
        def cached(*_args):
            value = next(attempts)
            if isinstance(value, Exception):
                raise value
            return value
        proof.cached = cached
        proof.inspect = lambda *args: self.tree
        proof.press = lambda *_args: self.fail("busy observation must not press a control")
        proof.verify_worker = lambda *args: None
        proof.capture_home = lambda *args: None
        with patch.object(PROOF.UI.time, "sleep") as sleep:
            self.assertEqual(proof.matched_home("home"), self.report)
        sleep.assert_called_once_with(0.25)
        def other_failure(*_args):
            raise PROOF.UIFailure("proof-command-failed")
        proof.cached = other_failure
        with self.assertRaisesRegex(PROOF.UIFailure, "^proof-command-failed$"):
            proof.matched_home("home")

    def test_refresh_reopens_verified_closed_popover_then_presses_once(self):
        proof = object.__new__(PROOF.TelenetHomeProof)
        proof.screens = self.screens
        open_tree = self.refresh_tree()
        settled = self.refresh_tree("Fetched after refresh")
        closed_tree = {"elements": [open_tree["elements"][0]], "windows": []}
        pressed = []
        proof.inspect = lambda *args: closed_tree if not pressed else open_tree if len(pressed) == 1 else settled
        proof.press = pressed.append
        proof.refresh_home()
        self.assertEqual(pressed, ["vikingbar.status", "vikingbar.refresh"])

    def refresh_tree(self, fetched="Fetched before refresh"):
        tree = copy.deepcopy(self.tree)
        value = next(item for item in tree["elements"] if item.get("AXIdentifier") == "vikingbar.home.fetched")
        value.update(AXRole="AXStaticText", AXValue=fetched)
        tree["elements"].append({"AXIdentifier": "vikingbar.refresh", "AXRole": "AXButton",
                                 "AXEnabled": "1", "frame": [[30, 600], [150, 24]]})
        return tree

    def test_refresh_waits_through_transitional_popover_before_single_press(self):
        proof = object.__new__(PROOF.TelenetHomeProof)
        proof.screens = self.screens
        open_tree = self.refresh_tree()
        settled = self.refresh_tree("Fetched after refresh")
        transitional = copy.deepcopy(open_tree)
        transitional["windows"][0]["kCGWindowBounds"]["X"] += 2
        closed_tree = {"elements": [open_tree["elements"][0]], "windows": []}
        observed = iter([closed_tree, transitional, open_tree, settled])
        pressed = []
        proof.inspect = lambda *args: next(observed)
        proof.press = pressed.append
        with patch.object(PROOF.UI.time, "sleep"):
            proof.refresh_home()
        self.assertEqual(pressed, ["vikingbar.status", "vikingbar.refresh"])

    def test_refresh_uses_verified_open_popover_without_toggling_status(self):
        proof = object.__new__(PROOF.TelenetHomeProof)
        proof.screens = self.screens
        open_tree = self.refresh_tree()
        settled = self.refresh_tree("Fetched after refresh")
        pressed = []
        proof.inspect = lambda *args: open_tree if not pressed else settled
        proof.press = pressed.append
        proof.refresh_home()
        self.assertEqual(pressed, ["vikingbar.refresh"])

    def test_refresh_waits_for_native_fetched_movement_without_cached_cli_polling(self):
        proof = object.__new__(PROOF.TelenetHomeProof)
        proof.screens = self.screens
        before = self.refresh_tree()
        working = copy.deepcopy(before)
        next(item for item in working["elements"] if item.get("AXIdentifier") ==
             "vikingbar.refresh")["AXEnabled"] = "0"
        unchanged = self.refresh_tree()
        moving = self.refresh_tree("Fetched after refresh")
        next(item for item in moving["elements"] if item.get("AXIdentifier") ==
             "vikingbar.refresh")["AXEnabled"] = "0"
        settled = self.refresh_tree("Fetched after refresh")
        observations = iter((before, working, unchanged, moving, settled))
        events = []
        proof.inspect = lambda *_: events.append("inspect") or next(observations)
        proof.press = lambda identifier: events.append(identifier)
        proof.cached = lambda *_: self.fail("cached CLI must not run before native fetched movement")
        with patch.object(PROOF.UI.time, "sleep"):
            proof.refresh_home()
        self.assertEqual(events, ["inspect", "vikingbar.refresh", "inspect", "inspect", "inspect", "inspect"])

    def test_refresh_rejects_unverified_control_without_pressing(self):
        proof = object.__new__(PROOF.TelenetHomeProof)
        proof.screens = self.screens
        tree = self.refresh_tree()
        next(item for item in tree["elements"] if item.get("AXIdentifier") ==
             "vikingbar.refresh")["AXEnabled"] = "0"
        pressed = []
        proof.inspect = lambda *args: tree
        proof.press = pressed.append
        with self.assertRaisesRegex(PROOF.UIFailure, "telenet-refresh-control-invalid"):
            proof.refresh_home()
        self.assertEqual(pressed, [])

    def test_switch_chooses_reserved_account_when_provider_opens_an_older_slot(self):
        proof = object.__new__(PROOF.TelenetHomeProof)
        proof.cli = Path("/synthetic/vikingbar")
        proof.launch_record = {}
        key = self.report["state"]["account"]["key"]
        older = dict(key, slot="22222222-0000-0000-0000-000000000002")
        catalog = {"selected": older, "accounts": [{"key": older, "label": "Telenet"},
                                                  {"key": key, "label": "Telenet"}]}
        choices = []
        def choose(identifier, title):
            choices.append((identifier, title))
            if identifier == "vikingbar.accountPicker":
                catalog["selected"] = key
        proof.choose = choose
        proof.run = lambda *args: catalog
        proof.inspect = lambda *args: {"elements": [{"AXIdentifier": "vikingbar.accountPicker", "AXEnabled": True}]}
        proof.switch_provider("Telenet", self.account)
        self.assertEqual(choices, [("vikingbar.providerPicker", "Telenet"),
                                   ("vikingbar.accountPicker", "Telenet · 00000000")])
        self.assertEqual(catalog["selected"], key)
        self.assertEqual(proof.account_selector, self.account)

    def test_preserved_bootstrap_requires_matching_connection_worker_and_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            previous = root / ".build/proof/previous"
            previous.mkdir(parents=True)
            current = root / ".build/proof/current"
            current.mkdir()
            artifacts = {
                "reserved-account.json": {"key": self.report["state"]["account"]["key"]},
                "connect-result.json": {"schema_version": 1, "check": "connect", "passed": True,
                                        "connected": True, "connection_sha256": "a" * 64},
                "native-connect-process.json": {"pid": 123, "cliSHA256": "b" * 64,
                                                "executableSHA256": "c" * 64, "accountSelector": self.account},
                "connect-result-ownership.json": {"parentPID": 123, "cliSHA256": "b" * 64,
                                                  "cleanupAttempted": True, "session": "vikingbar-connect-synthetic"},
                "cleanup.json": {"exited": True},
            }
            for name, data in artifacts.items():
                (previous / name).write_text(json.dumps(data))
            instance = object.__new__(PROOF.TelenetHomeProof)
            instance.resume_directory = str(previous)
            instance.directory = current
            with patch.object(PROOF, "ROOT", root):
                instance.preserved_connection()
                self.assertEqual(instance.telenet_account, "telenet/00000000-0000-0000-0000-000000000042")
                self.assertEqual(instance.connection_digest, "a" * 64)
                (previous / "cleanup.json").write_text('{"exited": false}')
                with self.assertRaisesRegex(PROOF.UIFailure, "telenet-preserved-bootstrap-invalid"):
                    instance.preserved_connection()


if __name__ == "__main__":
    unittest.main()
