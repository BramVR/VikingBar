#!/usr/bin/env python3
"""Drive the opt-in synthetic payment fixture without touching accounts or the system clipboard."""
import datetime
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
UI_SPEC = importlib.util.spec_from_file_location("native_ui_proof", ROOT / "Scripts/native-ui-proof.py")
UI = importlib.util.module_from_spec(UI_SPEC)
UI_SPEC.loader.exec_module(UI)
PROOF = ROOT / ".build/proof" / ("payment-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
PROOF.mkdir(parents=True)
PEEKABOO = os.environ.get("PEEKABOO_BIN") or shutil.which("peekaboo")
if not PEEKABOO:
    raise SystemExit("Peekaboo 4 is required. See docs/development.md.")

process = None
log = None
screens = []
launches = []


def run(arguments, receipt=None, timeout=120):
    result = subprocess.run(arguments, cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    if receipt:
        (PROOF / receipt).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"{arguments[0]} failed; inspect {PROOF / receipt if receipt else PROOF}")
    return result.stdout


def peek(arguments, receipt):
    value = json.loads(run([PEEKABOO, *arguments, "--json"], receipt))
    if value.get("success") is not True:
        raise RuntimeError(f"Peekaboo failed; inspect {PROOF / receipt}")
    return value["data"]


def inspect(receipt):
    assert process is not None and process.poll() is None, "Payment fixture app exited."
    return json.loads(run([str(ROOT / ".build/inspect-ui"), str(process.pid)], receipt))


def element(tree, identifier):
    return next((item for item in tree["elements"] if item.get("AXIdentifier") == identifier), {})


def wait_for(operation, predicate, seconds=20):
    deadline = time.monotonic() + seconds
    while True:
        value = operation()
        if predicate(value):
            return value
        if time.monotonic() >= deadline:
            raise RuntimeError("Payment fixture UI readiness timed out.")
        time.sleep(0.25)


def press(identifier, receipt):
    run([str(ROOT / ".build/inspect-ui"), str(process.pid), "press", identifier], receipt)


def boundary(tree):
    return UI.popover_window(tree, screens)[0]


def same_frame(actual, expected):
    return all(abs(a - b) <= 1 for actual_pair, expected_pair in zip(actual, expected)
               for a, b in zip(actual_pair, expected_pair))


def visible(tree, identifier):
    item = element(tree, identifier)
    try:
        if not item or not UI.contained(item, boundary(tree)):
            return False
        if identifier.startswith("vikingbar.payment."):
            return any(area.get("AXRole") == "AXScrollArea" and UI.contained(item, area)
                       for area in tree["elements"])
        return True
    except UI.UIFailure as error:
        if str(error) == "native-popover-not-visible":
            return False
        raise


def capture(tree, name):
    stability = UI.CapturePopoverStability()
    settled = None

    def ready(current):
        nonlocal settled
        settled = stability.observe(current, screens, process.pid)
        return settled is not None

    tree = wait_for(lambda: inspect(f"{name}-settle.json"), ready)
    _, window = settled
    path = PROOF / f"{name}.png"

    def invoke(arguments):
        return json.loads(run(arguments, f"{name}-capture.json"))

    UI.capture_exact_window(PEEKABOO, process.pid, window["kCGWindowNumber"], path, invoke)
    return path


def process_identity(pid):
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "pid=,ppid=,lstart=,command="],
        capture_output=True, timeout=5, check=False, env={"PATH": os.defpath, "LC_ALL": "C"},
    )
    parts = result.stdout.decode().strip().split(None, 7)
    if result.returncode or len(parts) != 8 or parts[0] != str(pid):
        raise RuntimeError("Payment fixture process identity unavailable.")
    return {"pid": pid, "parentPID": int(parts[1]), "startTime": " ".join(parts[2:7]), "command": parts[7]}


def capture_status(tree, name):
    status = element(tree, "vikingbar.status")
    assert status and UI.visible_status(tree, screens)
    (x, y), (width, height) = status["frame"]
    region = [math.floor(x), math.floor(y), math.ceil(x + width) - math.floor(x),
              math.ceil(y + height) - math.floor(y)]
    peek([
        "see", "--mode", "area", "--region", ",".join(map(str, region)), "--retina",
        "--no-elements", "--no-remote", "--path", str(PROOF / f"{name}.png"),
    ], f"{name}.json")


def scroll(direction, amount, receipt):
    tree = inspect(f"{receipt}-before.json")
    assert tree.get("active") is True, "Payment fixture must own foreground input."
    popover, window = UI.popover_window(tree, screens)
    areas = [item for item in tree["elements"]
             if item.get("AXRole") == "AXScrollArea" and UI.contained(item, popover)]
    assert len(areas) == 1, "Expected one visible Bills scroll area."
    (x, y), (width, height) = areas[0]["frame"]
    peek([
        "move", "--at", f"{x + width / 2},{y + height / 2}", "--global", "--foreground",
        "--no-remote",
    ], f"{receipt}-pointer.json")
    peek([
        "scroll",
        "--direction", direction, "--amount", str(amount), "--foreground", "--no-auto-focus", "--no-remote",
    ], f"{receipt}.json")


def launch(appearance):
    global process, log
    executable = ROOT / ".build/app/VikingBar.app/Contents/MacOS/VikingBarApp"
    log = (PROOF / f"{appearance}-app.log").open("w")
    arguments = [
        "--fixture", "finite", "--payment-fixture", "--fixture-appearance", appearance,
        "--settings-file", str(PROOF / f"{appearance}-settings.json"),
    ]
    process = subprocess.Popen([str(executable), *arguments], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    launch_record = {
        "appearance": appearance, "pid": process.pid, "parentPID": os.getpid(),
        "executable": str(executable), "sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "arguments": arguments,
    }
    launch_record.update(process_identity(process.pid))
    if launch_record["parentPID"] != os.getpid() or launch_record["command"] != " ".join([str(executable), *arguments]):
        raise RuntimeError("Payment fixture process ownership mismatch.")
    launches.append(launch_record)
    (PROOF / f"{appearance}-process.json").write_text(json.dumps(launch_record, indent=2))
    tree = wait_for(lambda: inspect(f"{appearance}-status.json"), lambda value: UI.visible_status(value, screens))
    capture_status(tree, f"{appearance}-helmet")
    peek(["app", "switch", "--to", "be.bram.vikingbar", "--verify", "--no-remote"],
         f"{appearance}-activate.json")
    press("vikingbar.status", f"{appearance}-status-press.json")
    wait_for(lambda: inspect(f"{appearance}-card.json"), lambda value: bool(element(value, "vikingbar.bills")))
    return tree


def open_payment(appearance):
    press("vikingbar.bills", f"{appearance}-bills.json")
    tree = wait_for(
        lambda: inspect(f"{appearance}-bills-ready.json"),
        lambda value: visible(value, "vikingbar.payment.toggle") and visible(value, "vikingbar.back")
        and visible(value, "vikingbar.invoices.freshness"),
    )
    back_frame = element(tree, "vikingbar.back")["frame"]
    window_width = boundary(tree)["frame"][1][0]
    run([str(ROOT / ".build/inspect-ui"), str(process.pid), "choose", "vikingbar.invoices.picker",
         "Invoice FIXTURE-2026-002"], f"{appearance}-select-paid.json")
    tree = wait_for(lambda: inspect(f"{appearance}-paid.json"),
                    lambda value: "FIXTURE-2026-002" in json.dumps(value)
                    and visible(value, "vikingbar.payment.toggle"))
    assert element(tree, "vikingbar.invoice.pdf"), "Paid document PDF action must remain available."
    press("vikingbar.payment.toggle", f"{appearance}-paid-review.json")
    wait_for(lambda: inspect(f"{appearance}-paid-unavailable.json"),
             lambda value: bool(element(value, "vikingbar.payment.unavailable"))
             and not element(value, "vikingbar.payment.ready"))
    run([str(ROOT / ".build/inspect-ui"), str(process.pid), "choose", "vikingbar.invoices.picker",
         "Invoice FIXTURE-2026-001"], f"{appearance}-select-payable.json")
    tree = wait_for(lambda: inspect(f"{appearance}-payable.json"),
                    lambda value: visible(value, "vikingbar.payment.toggle")
                    and element(value, "vikingbar.payment.toggle").get("AXDescription") == "Review bank transfer QR")
    press("vikingbar.payment.toggle", f"{appearance}-expand.json")
    controls = ("qr", "copy.recipient", "copy.iban", "copy.bic", "copy.reference")
    tree = wait_for(
        lambda: inspect(f"{appearance}-payment-ready.json"),
        lambda value: bool(element(value, "vikingbar.payment.ready"))
        and all(visible(value, f"vikingbar.payment.{identifier}") for identifier in controls),
    )
    summary = element(tree, "vikingbar.invoice.summary")
    assert summary and UI.contained(summary, boundary(tree)), "Invoice summary disappeared on QR expansion."
    assert UI.contained(summary, next(area for area in tree["elements"] if area.get("AXRole") == "AXScrollArea"))
    assert same_frame(element(tree, "vikingbar.back")["frame"], back_frame)
    assert boundary(tree)["frame"][1][0] == window_width
    assert "Scan with your banking app. Review the details before authorizing." in json.dumps(tree)
    image = capture(tree, f"{appearance}-payment")
    run([
        str(ROOT / ".build/decode-payment-qr"), str(image),
        str(ROOT / "Scripts/fixtures/payment-fixture.epc"),
    ], f"{appearance}-decode.json")
    return back_frame


def prove_copy_rows(back_frame):
    expected = {
        "recipient": "Mobile Vikings NV",
        "iban": "BE02737026917240",
        "bic": "KREDBEBB",
        "reference": "+++123/4567/89002+++",
    }
    for field, value in expected.items():
        identifier = f"vikingbar.payment.copy.{field}"
        for attempt in range(5):
            tree = inspect(f"copy-{field}-target-{attempt}.json")
            if visible(tree, identifier):
                break
            scroll("down", 4, f"copy-{field}-scroll-{attempt}")
        else:
            raise RuntimeError(f"Copy control never became visible: {field}")
        before = element(tree, identifier)["frame"]
        assert UI.contained(element(tree, "vikingbar.back"), boundary(tree))
        assert same_frame(element(tree, "vikingbar.back")["frame"], back_frame)
        press(identifier, f"copy-{field}-press.json")
        copied = wait_for(
            lambda: inspect(f"copy-{field}-copied.json"),
            lambda current: value in json.dumps(element(current, "vikingbar.payment.fixtureClipboard"))
            and "Copied" in json.dumps(element(current, identifier)),
        )
        assert element(copied, identifier)["frame"][1] == before[1], "Copy feedback resized the control."
        assert same_frame(element(copied, identifier)["frame"], before), "Copy feedback shifted the control."
        assert UI.contained(element(copied, identifier), boundary(copied))
    capture(copied, "payment-copy-rows")

    identifier = "vikingbar.payment.copy.iban"
    for attempt in range(5):
        tree = inspect(f"keyboard-target-{attempt}.json")
        if visible(tree, identifier):
            break
        scroll("up", 3, f"keyboard-scroll-{attempt}")
    else:
        raise RuntimeError("Keyboard copy control never became visible.")
    peek(["app", "switch", "--to", "be.bram.vikingbar", "--verify", "--no-remote"], "keyboard-activate.json")
    run([str(ROOT / ".build/inspect-ui"), str(process.pid), "focus", identifier], "keyboard-focus.json")
    focused = inspect("keyboard-focused.json")
    assert element(focused, identifier).get("AXFocused") in ("1", "true")
    assert focused.get("active") is True, "Payment fixture must own keyboard input."
    capture(focused, "keyboard-focus")
    peek([
        "press", "space", "--foreground", "--no-remote",
    ], "keyboard-space.json")
    wait_for(
        lambda: inspect("keyboard-copied.json"),
        lambda current: "BE02737026917240" in json.dumps(element(current, "vikingbar.payment.fixtureClipboard"))
        and element(current, identifier).get("AXValue") == "Copied",
    )


def collapse_reopen(back_frame, appearance):
    for attempt in range(5):
        tree = inspect(f"{appearance}-collapse-target-{attempt}.json")
        if visible(tree, "vikingbar.payment.toggle"):
            break
        scroll("up", 5, f"{appearance}-collapse-scroll-{attempt}")
    else:
        raise RuntimeError("Payment collapse control never became visible.")
    assert same_frame(element(tree, "vikingbar.back")["frame"], back_frame)
    press("vikingbar.payment.toggle", f"{appearance}-collapse.json")
    wait_for(lambda: inspect(f"{appearance}-collapsed.json"), lambda value: not element(value, "vikingbar.payment.ready"))
    press("vikingbar.payment.toggle", f"{appearance}-reopen.json")
    wait_for(lambda: inspect(f"{appearance}-reopened.json"), lambda value: bool(element(value, "vikingbar.payment.ready")))

    press("vikingbar.invoices.load", f"{appearance}-refresh.json")
    refreshed = wait_for(lambda: inspect(f"{appearance}-refreshed.json"),
                         lambda value: not element(value, "vikingbar.payment.ready")
                         and bool(element(value, "vikingbar.invoice.summary")))
    assert UI.contained(element(refreshed, "vikingbar.invoice.summary"), boundary(refreshed))


def quit_app(appearance):
    global process, log
    press("vikingbar.back", f"{appearance}-back.json")
    wait_for(lambda: inspect(f"{appearance}-balance.json"), lambda value: bool(element(value, "vikingbar.settings")))
    press("vikingbar.settings", f"{appearance}-settings.json")
    wait_for(lambda: inspect(f"{appearance}-settings-ready.json"), lambda value: bool(element(value, "vikingbar.quit")))
    press("vikingbar.quit", f"{appearance}-quit.json")
    assert process.wait(timeout=10) == 0
    launches[-1].update(exited=True, returncode=process.returncode, quitVerified=True)
    log.close()
    process = None
    log = None


try:
    version = peek(["--version"], "peekaboo-version.json")
    assert version["current"].startswith("Peekaboo 4.")
    peek(["permissions", "status", "--all-sources"], "permissions.json")
    existing = peek(["app", "list", "--include-hidden", "--include-background"], "apps-before.json")
    if "be.bram.vikingbar" in json.dumps(existing):
        raise RuntimeError("A VikingBar instance is already running.")
    run(["./Scripts/package-app.sh"], "build.log")
    run(["swiftc", "Scripts/inspect-ui.swift", "-o", ".build/inspect-ui"], "inspect-build.log")
    run(["swiftc", "Scripts/decode-payment-qr.swift", "-o", ".build/decode-payment-qr"], "decode-build.log")
    screens = peek(["screen", "list"], "screens.json")["screens"]

    launch("light")
    light_back = open_payment("light")
    prove_copy_rows(light_back)
    collapse_reopen(light_back, "light")
    quit_app("light")

    launch("dark")
    dark_back = open_payment("dark")
    collapse_reopen(dark_back, "dark")
    quit_app("dark")
finally:
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    if log is not None:
        log.close()
    (PROOF / "cleanup.json").write_text(json.dumps({
        "exited": all(item.get("exited") for item in launches), "processes": launches,
    }, indent=2))

assert len(launches) == 2 and all(item.get("quitVerified") for item in launches)
(PROOF / "result.json").write_text(json.dumps({
    "passed": True,
    "features": [
        "opt-in synthetic payment fixture", "actual bundled QR decoded from native screenshot",
        "light and dark", "expand collapse reopen", "pinned Back and freshness", "isolated copy values",
        "stable Copied feedback", "keyboard copy activation", "QR and all bank details visible without scrolling", "balance navigation",
        "visible helmet before open", "verified Quit",
    ],
}, indent=2))
print(f"Payment fixture proof retained at {PROOF}")
