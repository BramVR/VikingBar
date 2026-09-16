"""Exercise the real gate wiring with isolated, deliberately failing commands."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CHECK_STAGES = ["payment-helper", "format", "lint", "build", "test", "docs", "cli", "python-tests"]
CI_STAGES = ["check", "workflow-check", "smoke-package"]
STUB = '''#!/bin/sh
case "${0##*/}" in
    swiftformat) stage=format ;;
    swiftlint) stage=lint ;;
    swift) stage="$1" ;;
    python3)
        case "$1" in
            Scripts/check-docs.py) stage=docs ;;
            Scripts/smoke-cli.py) stage=cli ;;
            -m) stage=python-tests ;;
            *) exit 98 ;;
        esac ;;
    make) stage="$1" ;;
    xcode-select) echo /synthetic/Xcode.app/Contents/Developer; exit 0 ;;
    build-payment-qr-helper.sh) stage=payment-helper ;;
    *) exit 99 ;;
esac
printf '%s\\n' "$stage" >> "$STAGE_LOG"
printf 'synthetic stage: %s\\n' "$stage"
if [ "$stage" = "$FAIL_STAGE" ]; then exit 47; fi
'''


class CIGateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.root / "Scripts").mkdir()
        for relative in ["Makefile", "Scripts/test.sh", "Scripts/ci-build.sh", "Scripts/build-payment-qr-helper.sh"]:
            shutil.copy2(ROOT / relative, self.root / relative)
        (self.root / "Scripts/build-payment-qr-helper.sh").write_text("#!/bin/sh\n" + STUB)
        (self.root / "Scripts/build-payment-qr-helper.sh").chmod(0o755)
        self.log = self.root / "stages.txt"
        self.environment = {**os.environ, "PATH": f"{self.bin}:/usr/bin:/bin", "STAGE_LOG": str(self.log)}
        for key in ["MAKEFLAGS", "MFLAGS", "MAKELEVEL", "SWIFTFORMAT", "SWIFTLINT", "SHELL"]:
            self.environment.pop(key, None)

    def stub(self, *names):
        for name in names:
            path = self.bin / name
            path.write_text(STUB)
            path.chmod(0o755)

    def run_gate(self, command, failure):
        self.log.write_text("")
        result = subprocess.run(command, cwd=self.root, env={**self.environment, "FAIL_STAGE": failure},
                                capture_output=True, text=True, timeout=10)
        return result, self.log.read_text().splitlines()

    def test_make_check_stops_at_every_failed_stage(self):
        self.stub("swiftformat", "swiftlint", "swift", "python3", "xcode-select")
        for index, stage in enumerate(CHECK_STAGES):
            with self.subTest(stage=stage):
                result, recorded = self.run_gate(["/usr/bin/make", "check"], stage)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(recorded, CHECK_STAGES[:index + 1])

    def test_check_success_runs_all_stages(self):
        self.stub("swiftformat", "swiftlint", "swift", "python3", "xcode-select")
        result, recorded = self.run_gate(["/usr/bin/make", "check"], "")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(recorded, CHECK_STAGES)

    def test_ci_build_preserves_failure_through_tee(self):
        self.stub("make")
        for index, stage in enumerate(CI_STAGES):
            with self.subTest(stage=stage):
                result, recorded = self.run_gate(["./Scripts/ci-build.sh"], stage)
                self.assertEqual(result.returncode, 47, result.stdout + result.stderr)
                self.assertEqual(recorded, CI_STAGES[:index + 1])
                for attempted in recorded:
                    log = self.root / ".build/ci-logs" / f"{attempted}.log"
                    self.assertIn(f"synthetic stage: {attempted}", log.read_text())

    def test_ci_build_success_runs_every_gate_and_keeps_logs(self):
        self.stub("make")
        result, recorded = self.run_gate(["./Scripts/ci-build.sh"], "")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(recorded, CI_STAGES)
        self.assertEqual({path.stem for path in (self.root / ".build/ci-logs").iterdir()}, set(CI_STAGES))


if __name__ == "__main__":
    unittest.main()
