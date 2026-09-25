import datetime
import math
from zoneinfo import ZoneInfo

import importlib.util
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("vikingbar_history_geometry", Path(__file__).with_name("history-proof.py"))
HISTORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HISTORY)
UIFailure = HISTORY.UIFailure
BRUSSELS = ZoneInfo("Europe/Brussels")


def validate_presentation(report, now=None):
    try:
        home = report["state"]["homeUsage"]
        presentation = report["historyPresentation"]
        days = presentation["days"]
        fetched = datetime.datetime.fromisoformat(home["fetchedAt"].replace("Z", "+00:00"))
        observed_at = now or datetime.datetime.now(datetime.timezone.utc)
        today = observed_at.astimezone(BRUSSELS).date()
        fetch_day = fetched.astimezone(BRUSSELS).date()
        daily = home["dailyHistory"]
        rows = daily["rows"]
        cycle_start = datetime.date.fromisoformat(home["period"]["start"])
        cycle_end = datetime.date.fromisoformat(home["period"]["end"])
        if (fetched.tzinfo is None or observed_at.tzinfo is None
                or not cycle_start <= fetch_day <= today <= cycle_end
                or report["state"].get("homeFailure") is not None
                or datetime.date.fromisoformat(daily["fetchedDay"]) != fetch_day
                or not 3 <= len(rows) <= 62
                or len(days) != 30 or presentation["unit"] != "GB"
                or "Telenet" not in presentation["scopeText"]
                or any(not isinstance(presentation[field], str) or not presentation[field]
                       for field in ("forecastText", "totalText", "statusText", "scopeText"))
                or "SIM" in " ".join(presentation[field] for field in
                                     ("forecastText", "totalText", "statusText", "scopeText"))):
            raise ValueError()
        row_days = [datetime.date.fromisoformat(row["day"]) for row in rows]
        if (row_days != sorted(set(row_days))
                or any(not cycle_start <= day <= fetch_day for day in row_days)):
            raise ValueError()
        stale = ("stale" in report["snapshot"]["freshness"]
                 or observed_at < fetched or (observed_at - fetched).total_seconds() >= 3600)
        for index, day in enumerate(days):
            expected = today - datetime.timedelta(days=29 - index)
            start = datetime.datetime.fromisoformat(day["dayStart"].replace("Z", "+00:00"))
            if (start.tzinfo is None or start.astimezone(BRUSSELS).date() != expected
                    or start.astimezone(BRUSSELS).time() != datetime.time()
                    or any(not isinstance(day[field], str) or not day[field]
                           for field in ("label", "fullDateText", "valueText", "statusText"))
                    or type(day["isMissing"]) is not bool or type(day["isToday"]) is not bool
                    or type(day["isPartial"]) is not bool or type(day["isStale"]) is not bool
                    or day["isToday"] is not (expected == today)
                    or (expected == today and not day["isPartial"])
                    or (expected == fetch_day and fetch_day < today and not day["isPartial"])):
                raise ValueError()
            amount = day.get("bytes")
            if (expected < cycle_start and (amount is not None or day["isMissing"]
                                            or day["statusText"] != "Outside billing period"
                                            or day["valueText"] != "Outside period")):
                raise ValueError()
            if amount is not None and day["isStale"] is not stale:
                raise ValueError()
            if (expected >= cycle_start and amount is None and not day["isMissing"] or amount is not None
                    and (type(amount) is not int or amount < 0 or day["isMissing"])):
                raise ValueError()
        elapsed = [day for day in days if cycle_start <= datetime.datetime.fromisoformat(
            day["dayStart"].replace("Z", "+00:00")).astimezone(BRUSSELS).date() < today]
        continuous = bool(elapsed) and datetime.datetime.fromisoformat(
            elapsed[0]["dayStart"].replace("Z", "+00:00")).astimezone(BRUSSELS).date() == cycle_start
        continuous = continuous and all(not day["isMissing"] and not day["isStale"]
                                        and not day["isPartial"] for day in elapsed)
        forecast = presentation.get("forecast")
        if continuous and len(elapsed) >= 3 and forecast is None:
            raise ValueError()
        if forecast is not None:
            if (type(forecast["completeDays"]) is not int or forecast["completeDays"] < 3
                    or type(forecast["estimatedCycleBytes"]) not in (int, float)
                    or not math.isfinite(forecast["estimatedCycleBytes"])
                    or forecast["estimatedCycleBytes"] < 0
                    or (cycle_start >= today - datetime.timedelta(days=29) and not continuous)
                    or any(day["isMissing"] or day["isStale"] or day["isPartial"] for day in elapsed)):
                raise ValueError()
        return presentation
    except (KeyError, TypeError, ValueError, OverflowError, AttributeError):
        raise UIFailure("telenet-history-report-invalid") from None


def compare_main(tree, report, screens, index, compare_home, now=None):
    compare_home(tree, report, screens)
    if any(item.get("AXIdentifier") == "vikingbar.historyPanel" for item in tree.get("elements", [])):
        raise UIFailure("native-history-hover-opened-detail")
    parent = HISTORY.matched_window(tree, screens, role="AXPopover", error="native-history-popover")
    status_frames = [item["frame"] for item in tree.get("elements", [])
                     if item.get("AXIdentifier") == "vikingbar.status" and "frame" in item]
    for window in tree.get("windows", []):
        try:
            alpha = window["kCGWindowAlpha"]
            if (window.get("kCGWindowOwnerPID") == tree["pid"]
                    and window.get("kCGWindowIsOnscreen") is True
                    and type(alpha) in (int, float) and math.isfinite(alpha) and alpha > 0
                    and window["kCGWindowNumber"] != parent["window"]["kCGWindowNumber"]
                    and not any(HISTORY.same_frame(frame, HISTORY.window_frame(window))
                                for frame in status_frames)):
                raise UIFailure("native-history-hover-opened-detail")
        except (KeyError, TypeError):
            continue
    HISTORY.exact_element(tree, parent["element"], "vikingbar.historyMainPlot",
                          error="native-history-main-plot-not-visible")
    day = validate_presentation(report, now)["days"][index]
    for identifier, field in (("vikingbar.historyMainSelectedDate", "fullDateText"),
                              ("vikingbar.historyMainSelectedValue", "valueText"),
                              ("vikingbar.historyMainSelectedStatus", "statusText")):
        HISTORY.exact_element(tree, parent["element"], identifier, day[field],
                              error="native-history-main-selection-mismatch")
    return parent


def compare_companion(tree, report, screens, compare_home, now=None):
    compare_home(tree, report, screens)
    windows = HISTORY.history_windows(tree, screens)
    boundary = windows["companion"]["element"]
    capture_boundary = {"frame": HISTORY.window_frame(windows["companion"]["window"])}
    presentation = validate_presentation(report, now)
    if marker := presentation.get("boundary"):
        HISTORY.exact_element(tree, boundary, "vikingbar.historyBoundary",
                              marker["label"] + " · " + marker["dateText"])
    for identifier, field in (("vikingbar.historyForecast", "forecastText"),
                              ("vikingbar.historyTotal", "totalText"),
                              ("vikingbar.historyStatus", "statusText"),
                              ("vikingbar.historyScope", "scopeText")):
        item = HISTORY.exact_element(tree, boundary, identifier, presentation[field])
        if not HISTORY.UI.contained(item, capture_boundary):
            raise UIFailure("native-history-text-mismatch")
    chart = HISTORY.exact_element(tree, boundary, "vikingbar.historyChart",
                                  error="native-history-chart-not-visible")
    plot = HISTORY.exact_element(tree, boundary, "vikingbar.historyPlot",
                                 error="native-history-plot-not-visible")
    if not HISTORY.UI.contained(chart, capture_boundary) or not HISTORY.UI.contained(plot, chart):
        raise UIFailure("native-history-chart-not-visible")
    expected = "; ".join(day["label"] + ": " + day["valueText"] for day in presentation["days"])
    if expected not in [chart.get(key) for key in ("AXTitle", "AXValue", "AXDescription")]:
        raise UIFailure("native-history-chart-values-mismatch")
    HISTORY.selected_day(tree, report, windows)
    return windows
