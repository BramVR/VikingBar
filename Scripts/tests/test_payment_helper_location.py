import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PaymentHelperLocationTests(unittest.TestCase):
    def test_path_and_symlink_launches_resolve_beside_actual_executable(self):
        with tempfile.TemporaryDirectory(prefix="vikingbar-helper-location-") as directory:
            root = Path(directory)
            installed = root / "installed"
            installed.mkdir()
            links = root / "bin"
            links.mkdir()
            unrelated = root / "unrelated"
            unrelated.mkdir()
            source = root / "main.swift"
            source.write_text("import VikingBarCore\nprint(PaymentQRHelper.productionExecutableURL().path)\n")
            executable = installed / "payment-location"
            build = ROOT / ".build/debug"
            objects = list((build / "VikingBarCore.build").glob("*.swift.o"))
            self.assertTrue(objects, "Run swift build before this test")
            subprocess.run(["swiftc", "-I", str(build / "Modules"), str(source),
                            *map(str, objects), "-o", str(executable)], check=True,
                           capture_output=True, timeout=60)
            (links / executable.name).symlink_to(executable)
            for search_path in (installed, links):
                with self.subTest(search_path=search_path.name):
                    result = subprocess.run([executable.name], cwd=unrelated,
                                            env={"PATH": f"{search_path}:{os.defpath}"},
                                            capture_output=True, text=True, check=True, timeout=10)
                    self.assertEqual(Path(result.stdout.strip()).resolve(), (installed / "payment-qr").resolve())
                    self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
