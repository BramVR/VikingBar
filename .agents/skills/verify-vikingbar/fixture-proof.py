#!/usr/bin/env python3
"""Run the repository fixture gate with bounded read-only popover settling."""

import ast
from pathlib import Path
import time


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
    starts = [index for index, node in enumerate(module.body) if isinstance(node, ast.Try)]
    if len(starts) != 1:
        raise RuntimeError("fixture gate entry point changed; review the maintained helper")
    start = starts[0]
    namespace = {"__file__": str(source), "__name__": "__main__"}
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
