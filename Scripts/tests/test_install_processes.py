import ctypes
import errno
import importlib.util
import os
import hashlib
import json
import sys
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location("install_processes", Path(__file__).resolve().parents[1] / "install-app.py")
INSTALL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALL)


class InstallProcessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.target = self.root / "VikingBar.app"
        self.executables = self.target / "Contents/MacOS"
        self.executables.mkdir(parents=True)
        for name in INSTALL.EXECUTABLES:
            (self.executables / name).write_bytes(b"synthetic executable")

    def library(self, path=None, path_error=errno.EPERM, info=None, info_error=0, info_size=None):
        def pidpath(pid, buffer, size):
            self.assertEqual(pid, 42)
            self.assertEqual(size, 4096)
            ctypes.set_errno(path_error)
            if path is None:
                return 0
            buffer.value = os.fsencode(path)
            return len(buffer.value)
        def pidinfo(pid, flavor, arg, pointer, size):
            self.assertEqual((pid, flavor, arg, size), (42, 13, 0, 64))
            ctypes.set_errno(info_error)
            if info is not None:
                result = ctypes.cast(pointer, ctypes.POINTER(INSTALL.ProcessInfo)).contents
                for key, value in info.items():
                    setattr(result, key, value)
            return (64 if info is not None else 0) if info_size is None else info_size
        return Mock(proc_pidpath=Mock(side_effect=pidpath), proc_pidinfo=Mock(side_effect=pidinfo))

    def test_libproc_path_is_independent_of_absolute_relative_or_symlink_argv(self):
        for invocation in (str(self.executables / "vikingbar"), "./vikingbar", "../alias"):
            with self.subTest(invocation=invocation):
                library = self.library(path=self.executables / "vikingbar")
                with patch.object(INSTALL.ctypes, "CDLL", return_value=library), \
                        patch.object(INSTALL.subprocess, "run", return_value=Mock(returncode=0, stdout="42\n")) as run:
                    with self.assertRaisesRegex(INSTALL.InstallFailure, "running-target-refused"):
                        INSTALL.refuse_running(self.target)
                self.assertEqual(run.call_args.args[0], ["ps", "-axo", "pid="])
                library.proc_pidinfo.assert_not_called()
                self.assertEqual(library.proc_pidpath.argtypes, [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32])

    def test_resolved_symlink_paths_match_actual_target(self):
        link = self.root / "alias"
        link.symlink_to(self.executables / "vikingbar")
        for path in (link, self.executables / "VikingBarApp"):
            with self.subTest(path=path), patch.object(INSTALL, "process_paths", return_value=iter([path])):
                with self.assertRaisesRegex(INSTALL.InstallFailure, "running-target-refused"):
                    INSTALL.refuse_running(self.target)

    def test_similarly_named_bundle_and_argv_references_are_unrelated(self):
        unrelated = self.root / "VikingBar.app.other/Contents/MacOS/vikingbar"
        unrelated.parent.mkdir(parents=True)
        unrelated.write_bytes(b"another executable")
        with patch.object(INSTALL, "process_paths", return_value=iter([unrelated])):
            INSTALL.refuse_running(self.target)

    def test_unknown_live_path_fails_closed_even_for_root_uid_or_other_name(self):
        for info in ({"pid": 42, "status": 2, "uid": 0, "comm": b"unrelated"},
                     {"pid": 42, "status": 2, "uid": os.getuid()}, None):
            with self.subTest(info=info):
                with self.assertRaisesRegex(INSTALL.InstallFailure, "process-inspection-failed"):
                    INSTALL.process_executable(42, self.library(info=info))

    def test_confirmed_exited_zombie_or_system_process_does_not_block(self):
        for library in (self.library(path_error=errno.ESRCH), self.library(info_error=errno.ESRCH),
                        self.library(info={"pid": 42, "status": 5}),
                        self.library(info={"pid": 42, "flags": 1, "status": 2})):
            with self.subTest(library=library):
                self.assertIsNone(INSTALL.process_executable(42, library))

    def test_failed_or_malformed_bsd_info_does_not_establish_unrelated_process(self):
        for library in (self.library(info={"pid": 43, "flags": 1}),
                        self.library(info={"pid": 42, "flags": 1}, info_size=63),
                        self.library(info_error=errno.EACCES)):
            with self.subTest(library=library):
                with self.assertRaisesRegex(INSTALL.InstallFailure, "process-inspection-failed"):
                    INSTALL.process_executable(42, library)

    def test_malformed_non_absolute_or_truncated_paths_fail_closed(self):
        for path in ("relative/path", ""):
            with self.subTest(path=path):
                with self.assertRaisesRegex(INSTALL.InstallFailure, "process-inspection-failed"):
                    INSTALL.process_executable(42, self.library(path=path))
        library = self.library(path="/absolute")
        def oversized(_pid, buffer, _size):
            buffer.value = b"/absolute"
            return 4096
        library.proc_pidpath.side_effect = oversized
        with self.assertRaisesRegex(INSTALL.InstallFailure, "process-inspection-failed"):
            INSTALL.process_executable(42, library)

    def test_unrelated_kernel_path_does_not_require_reading_inaccessible_system_file(self):
        unrelated = self.root / "system-binary"
        original_stat = Path.stat
        def stat(path, *args, **kwargs):
            if path == unrelated:
                raise PermissionError("synthetic system protection")
            return original_stat(path, *args, **kwargs)
        with patch.object(INSTALL, "process_paths", return_value=iter([unrelated])), patch.object(Path, "stat", stat):
            INSTALL.refuse_running(self.target)

    @unittest.skipUnless(sys.platform == "darwin", "macOS libproc contract")
    def test_task_owned_plain_cli_relative_and_symlink_invocations(self):
        executable = Path("/bin/sleep")
        alias = self.root / "sleep-alias"
        alias.symlink_to(executable)
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        library.proc_pidpath.restype = ctypes.c_int
        for invocation in (str(executable), "./sleep", str(alias)):
            with self.subTest(invocation=invocation):
                child = subprocess.Popen([invocation, "1"], cwd=executable.parent)
                try:
                    metadata = subprocess.check_output(
                        ["ps", "-p", str(child.pid), "-o", "pid=,ppid=,lstart=,command="], text=True).strip()
                    (self.root / "plain-cli-process.json").write_text(json.dumps({
                        "pid": child.pid, "parentPID": os.getpid(), "psIdentity": metadata,
                        "arguments": [invocation, "1"],
                        "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest()}))
                    path = INSTALL.process_executable(child.pid, library)
                    self.assertIsNotNone(path)
                    with patch.object(INSTALL, "process_paths", return_value=iter([path])):
                        with self.assertRaisesRegex(INSTALL.InstallFailure, "running-target-refused"):
                            INSTALL.refuse_running(executable.parent)
                finally:
                    child.wait(timeout=3)
                self.assertEqual(child.returncode, 0)

    def test_pid_enumeration_failures_do_not_claim_target_is_idle(self):
        for result in (Mock(returncode=1, stdout=""), Mock(returncode=0, stdout=""),
                       Mock(returncode=0, stdout="42 garbage"), Mock(returncode=0, stdout="-1")):
            with self.subTest(result=result), patch.object(INSTALL.ctypes, "CDLL", return_value=Mock()), \
                    patch.object(INSTALL.subprocess, "run", return_value=result):
                with self.assertRaisesRegex(INSTALL.InstallFailure, "process-inspection-failed"):
                    INSTALL.refuse_running(self.target)
        with patch.object(INSTALL.ctypes, "CDLL", side_effect=OSError("unavailable")):
            with self.assertRaisesRegex(INSTALL.InstallFailure, "process-inspection-failed"):
                INSTALL.refuse_running(self.target)
        with patch.object(INSTALL.ctypes, "CDLL", return_value=Mock()), \
                patch.object(INSTALL.subprocess, "run", side_effect=subprocess.TimeoutExpired("ps", 10)):
            with self.assertRaisesRegex(INSTALL.InstallFailure, "process-inspection-failed"):
                INSTALL.refuse_running(self.target)


if __name__ == "__main__":
    unittest.main()
