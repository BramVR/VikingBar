import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("balance_ui_signals", ROOT / "Scripts/balance-ui-proof.py")
UI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UI)


class BalanceUISignalTests(unittest.TestCase):
    def test_sigterm_cleans_owned_process_and_restores_state(self):
        for mode in ("running", "registration", "before-spawn", "cleanup-failure"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix="vikingbar-signal-test-") as directory:
                root = Path(directory)
                script = root / "signal-test.py"
                script.write_text(SIGNAL_TEST)
                try:
                    result = subprocess.run([sys.executable, str(script), str(ROOT / "Scripts/balance-ui-proof.py"),
                                             str(root), mode], capture_output=True, timeout=20, check=False,
                                            env={"PATH": os.defpath, "LC_ALL": "C"})
                    self.assertEqual(result.returncode, 0, result.stderr.decode()[-4000:])
                    receipt = json.loads(result.stdout)
                    self.assertEqual(receipt["error"], "synthetic-cleanup-failed" if mode == "cleanup-failure"
                                     else "native-proof-terminated")
                    for key in ("cleanupRan", "repeatedSignalIgnored", "handlerRestored", "umaskRestored",
                                "coreLimitRestored", "workerExited", "childSignalUnblocked", "childSignalDefault"):
                        self.assertIs(receipt[key], True, key)
                    self.assertFalse(receipt["retryCaught"])
                    self.assertEqual(receipt["signalTargets"],
                                     [receipt["runnerPID"]] * (3 if mode == "before-spawn" else 2)
                                     + [receipt["workerPID"]])
                    if mode in ("registration", "before-spawn"):
                        self.assertTrue(receipt["registeredBeforeCleanup"])
                    owned = json.loads((root / "owned.json").read_text())
                    self.assertIsNone(UI.process_identity(owned["pid"]))
                finally:
                    evidence = root / "owned.json"
                    if evidence.is_file():
                        owned = json.loads(evidence.read_text())
                        current = UI.process_identity(owned["pid"])
                        if current is not None:
                            self.assertEqual(current["command"], owned["command"])
                            self.assertEqual(current["startTime"], owned["startTime"])
                            self.assertIn(current["parentPID"], (owned["parentPID"], 1))
                            os.kill(owned["pid"], signal.SIGTERM)
                            UI.wait_for(lambda: UI.process_identity(owned["pid"]), lambda value: value is None, seconds=5)


SIGNAL_TEST = r'''
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import time

spec = importlib.util.spec_from_file_location("native_proof", sys.argv[1])
UI = importlib.util.module_from_spec(spec)
spec.loader.exec_module(UI)
directory, mode = Path(sys.argv[2]), sys.argv[3]
worker_source = directory / "worker.py"
worker_source.write_text("import json, pathlib, signal, sys, time\n"
                        "pathlib.Path(sys.argv[1]).write_text(json.dumps({"
                        "'unblocked': signal.SIGTERM not in signal.pthread_sigmask(signal.SIG_BLOCK, []),"
                        "'default': signal.getsignal(signal.SIGTERM) == signal.SIG_DFL}))\n"
                        "while True: time.sleep(60)\n")
real_popen = subprocess.Popen
owned_process = None
owned_identity = None
signal_targets = []
retry_caught = False
cleanup_ran = False
repeated_ignored = False
registered = False
previous_calls = []

def previous_handler(signum, frame):
    previous_calls.append(signum)

signal.signal(signal.SIGTERM, previous_handler)
os.umask(0o027)
core = resource.getrlimit(resource.RLIMIT_CORE)
expected_core = (4096 if core[1] == resource.RLIM_INFINITY else min(4096, core[1]), core[1])
resource.setrlimit(resource.RLIMIT_CORE, expected_core)

def start_worker():
    global owned_process, owned_identity
    owned_process = real_popen([sys.executable, str(worker_source), str(directory / "worker-ready.json")],
                              env={"PATH": os.defpath, "LC_ALL": "C"},
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    UI.wait_for(lambda: (directory / "worker-ready.json").is_file(), bool, seconds=5)
    owned_identity = UI.process_identity(owned_process.pid)
    assert owned_identity["parentPID"] == os.getpid()
    assert str(worker_source) in owned_identity["command"]
    UI.private_write(directory / "owned.json", owned_identity)
    return owned_process

def terminate_runner():
    signal_targets.append(os.getpid())
    os.kill(os.getpid(), signal.SIGTERM)

class FakeNativeProof(UI.NativeProof):
    def __init__(self, environment, **kwargs):
        self.environment = environment
        self.directory = directory
        self.executable = directory / "synthetic-app"
        self.executable.write_bytes(b"synthetic app")
        self.cli = worker_source
        self.reference = "synthetic-reference"
        self.executable_hash = hashlib.sha256(self.executable.read_bytes()).hexdigest()
        self.launches, self.workers = [], []
        self.process = None
        assert resource.getrlimit(resource.RLIMIT_CORE)[0] == 0
        current_mask = os.umask(0o077)
        assert current_mask == 0o077

    def perform(self):
        global retry_caught
        if mode in ("registration", "before-spawn"):
            def interrupted_popen(arguments, *args, **kwargs):
                if arguments[0] != str(self.executable):
                    return real_popen(arguments, *args, **kwargs)
                if mode == "before-spawn":
                    terminate_runner()
                    terminate_runner()
                process = start_worker()
                if mode == "registration":
                    terminate_runner()
                return process
            subprocess.Popen = interrupted_popen
            self.launch(first=True)
            raise AssertionError("termination did not interrupt registered launch")
        start_worker()
        try:
            terminate_runner()
        except Exception:
            retry_caught = True
        raise AssertionError("termination was swallowed by retry")

    def capture_worker(self, process, launch, seconds=0):
        return [owned_identity]

    def inspect(self, *args):
        raise AssertionError("UI inspection must not run after deferred termination")

    def cleanup(self):
        global cleanup_ran, repeated_ignored, registered
        cleanup_ran = True
        registered = self.process is owned_process and len(self.launches) == 1 if mode in ("registration", "before-spawn") else False
        terminate_runner()
        repeated_ignored = not previous_calls
        assert callable(signal.getsignal(signal.SIGTERM))
        current = UI.process_identity(owned_process.pid)
        assert current == owned_identity
        signal_targets.append(owned_process.pid)
        owned_process.terminate()
        owned_process.wait(timeout=5)
        if mode == "cleanup-failure":
            raise UI.UIFailure("synthetic-cleanup-failed")

UI.NativeProof = FakeNativeProof
try:
    UI.run({"PATH": os.defpath, "LC_ALL": "C"}, direct_connect=True)
    raise AssertionError("terminated proof returned success")
except UI.UIFailure as failure:
    error = str(failure)
finally:
    subprocess.Popen = real_popen
    if owned_process is not None and owned_process.poll() is None:
        assert UI.process_identity(owned_process.pid) == owned_identity
        owned_process.terminate()
        owned_process.wait(timeout=5)
child_state = json.loads((directory / "worker-ready.json").read_text())
print(json.dumps({"error": error, "cleanupRan": cleanup_ran, "repeatedSignalIgnored": repeated_ignored,
                  "handlerRestored": signal.getsignal(signal.SIGTERM) is previous_handler,
                  "umaskRestored": os.umask(0o027) == 0o027,
                  "coreLimitRestored": resource.getrlimit(resource.RLIMIT_CORE) == expected_core,
                  "workerExited": owned_process.poll() is not None,
                  "childSignalUnblocked": child_state["unblocked"], "childSignalDefault": child_state["default"],
                  "retryCaught": retry_caught, "registeredBeforeCleanup": registered,
                  "signalTargets": signal_targets, "runnerPID": os.getpid(), "workerPID": owned_process.pid}))
'''


if __name__ == "__main__":
    unittest.main()
