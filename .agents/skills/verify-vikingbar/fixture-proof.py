#!/usr/bin/env python3
"""Run the repository fixture gate with bounded read-only popover settling."""

import ast
import calendar
from datetime import datetime
from pathlib import Path
import time
from zoneinfo import ZoneInfo


def billing_period_text(started_at):
    launched = datetime.fromisoformat(started_at).astimezone(ZoneInfo("Europe/Brussels"))
    days = calendar.monthrange(launched.year, launched.month)[1]
    month = launched.strftime("%Y-%m")
    return f"Billing period {month}-01 to {month}-{days:02d}"


class FixtureMonth(ast.NodeTransformer):
    def __init__(self):
        self.replacements = 0

    def visit_Constant(self, node):
        if node.value != "Billing period 2026-09-01 to 2026-09-30":
            return node
        self.replacements += 1
        return ast.copy_location(ast.Call(func=ast.Name(id="_maintained_home_period", ctx=ast.Load()),
                                         args=[], keywords=[]), node)


def settled_geometry(initial, selector, geometry, observe, failure_type, seconds=15):
    """Keep strict window matching; never repeat a pointer action."""
    deadline = time.monotonic() + seconds
    reading = initial
    while True:
        try:
            return geometry(reading, selector)
        except failure_type as error:
            if str(error) != "native-popover-not-visible" or time.monotonic() >= deadline:
                raise
        time.sleep(0.25)
        reading = observe()


def main():
    root = Path(__file__).resolve().parents[3]
    source = root / "Scripts/smoke-app-fixture.py"
    module = ast.parse(source.read_text(), filename=str(source))
    month = FixtureMonth()
    module = ast.fix_missing_locations(month.visit(module))
    if month.replacements != 1:
        raise RuntimeError("fixture billing-period expectation changed; review the maintained helper")
    starts = [index for index, node in enumerate(module.body) if isinstance(node, ast.Try)]
    if len(starts) != 1:
        raise RuntimeError("fixture gate entry point changed; review the maintained helper")
    start = starts[0]
    namespace = {"__file__": str(source), "__name__": "__main__"}
    namespace["_maintained_home_period"] = lambda: billing_period_text(namespace["launches"][-1]["startedAt"])
    exec(compile(ast.Module(body=module.body[:start], type_ignores=[]), str(source), "exec"), namespace)
    original = namespace["control_geometry"]
    if original.__code__.co_varnames[:2] != ("data", "selector") or original.__code__.co_argcount != 2:
        raise RuntimeError("fixture geometry interface changed; review the maintained helper")

    def geometry(data, selector):
        # AX can omit the popover role for one reading while its controls remain present.
        return settled_geometry(
            data, selector, original,
            lambda: namespace["inspect"](f"{selector}-geometry-settling.json"),
            namespace["UI"].UIFailure,
        )

    namespace["control_geometry"] = geometry
    exec(compile(ast.Module(body=module.body[start:], type_ignores=[]), str(source), "exec"), namespace)


if __name__ == "__main__":
    main()
