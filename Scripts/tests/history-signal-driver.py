"""Inert subprocess driver for the real history retry and launch boundaries."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("history_signals", ROOT / "Scripts/history-proof.py")
HISTORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HISTORY)
UI = HISTORY.UI
directory = Path(sys.argv[1])
mode = sys.argv[2]
number = getattr(signal, sys.argv[3])
real_popen = subprocess.Popen
owned = None
observations = 0
cleaned = False


def interrupt():
    identity = UI.process_identity(os.getpid())
    assert identity["parentPID"] == os.getppid()
    UI.private_write(directory / "runner.json", identity)
    os.kill(os.getpid(), number)


class InertProof(HISTORY.HistoryProof):
    def __init__(self, environment):
        self.environment = {"PATH": os.defpath}
        self.directory = directory
        self.executable = directory / "inert-app"
        self.executable.write_text(
            "#!" + sys.executable + "\nimport json, pathlib, signal, time\n"
            "pathlib.Path(__file__).with_suffix('.ready').write_text(json.dumps({"
            "'default': signal.getsignal(signal.SIGTERM) == signal.SIG_DFL,"
            "'unblocked': signal.SIGTERM not in signal.pthread_sigmask(signal.SIG_BLOCK, [])}))\n"
            "time.sleep(30)\n")
        self.executable.chmod(0o700)
        self.executable_hash = hashlib.sha256(self.executable.read_bytes()).hexdigest()
        self.cli = self.executable
        self.process = None
        self.launches, self.workers = [], []

    def perform(self):
        global owned
        if mode == "retry":
            def once(observe, predicate, **kwargs):
                value = observe()
                if not predicate(value):
                    raise AssertionError("cancellation swallowed by actual history retry")
                return value
            UI.wait_for = once
            self.matched_history("inert")
        else:
            def spawn(arguments, **kwargs):
                global owned
                if arguments[0] != str(self.executable):
                    return real_popen(arguments, **kwargs)
                if mode == "before-spawn":
                    interrupt()
                    interrupt()
                owned = real_popen(arguments, **kwargs)
                UI.private_write(directory / "spawn.json", {
                    "pid": owned.pid, "parentPID": os.getpid(), "arguments": arguments})
                UI.wait_for(lambda: self.executable.with_suffix('.ready').is_file(), bool, seconds=5)
                identity = UI.process_identity(owned.pid)
                assert identity["parentPID"] == os.getpid()
                assert str(self.executable) in identity["command"]
                UI.private_write(directory / "owned.json", identity)
                if mode == "registration":
                    interrupt()
                return owned
            UI.subprocess.Popen = spawn
            self.launch(first=False)
        raise AssertionError("terminated operation returned")

    def run(self, command, *args, **kwargs):
        global observations
        if mode == "retry":
            observations += 1
            interrupt()
            return {}
        return b'{"elements": []}'

    def inspect(self, *args):
        raise AssertionError("native inspection attempted after cancellation")

    def capture_worker(self, process, launch, **kwargs):
        return [UI.process_identity(process.pid)]

    def cleanup(self):
        global cleaned
        cleaned = True
        interrupt()
        if owned is not None:
            assert self.process is owned and len(self.launches) == 1
            assert self.launches[0][1]["workerOwnershipEstablished"] is True
            super().cleanup()
            assert json.loads((directory / "cleanup.json").read_text())["exited"] is True


HISTORY.HistoryProof = InertProof
try:
    code = HISTORY.main()
    assert code == 1 and cleaned
    if mode == "retry":
        assert observations == 1
    else:
        assert owned.poll() is not None
        assert json.loads((directory / "inert-app.ready").read_text()) == {"default": True, "unblocked": True}
    print(json.dumps({"behavior_passed": True, "mode": mode}))
finally:
    UI.subprocess.Popen = real_popen
    if owned is not None and owned.poll() is None:
        identity = UI.process_identity(owned.pid)
        assert identity["parentPID"] == os.getpid()
        assert str(directory / "inert-app") in identity["command"]
        UI.private_write(directory / "fallback-cleanup.json", identity)
        owned.terminate()
        owned.wait(timeout=5)
