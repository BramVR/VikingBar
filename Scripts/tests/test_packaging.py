import importlib.util
from pathlib import Path
import tempfile
import subprocess
import unittest
import zipfile


SCRIPTS = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


package = load("package-artifacts")
smoke = load("smoke-package")


class PackagingTests(unittest.TestCase):
    def test_packaging_refuses_unrecognized_residue_without_removing_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            residue = root / "user.txt"
            residue.write_text("preserve me")
            package.write_json(root / "manifest.json", {"files": []})
            result = subprocess.run(["python3", str(SCRIPTS / "package-artifacts.py"),
                                     "--output", str(root)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Unexpected artifact residue", result.stderr)
            self.assertEqual(residue.read_text(), "preserve me")

    def test_archive_is_stable_and_preserves_executable_mode(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            executable = source / "vikingbar"
            executable.write_bytes(b"fixture executable")
            executable.chmod(0o755)
            first, second = root / "first.zip", root / "second.zip"
            package.archive(source, first, 1700000000)
            executable.touch()
            package.archive(source, second, 1700000000)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            smoke.extract(first, root / "extracted")
            self.assertEqual((root / "extracted/vikingbar").stat().st_mode & 0o777, 0o755)

    def test_archive_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            (source / "outside").symlink_to("/etc/passwd")
            with self.assertRaises(ValueError):
                package.archive(source, root / "bad.zip", 1700000000)

    def test_inspection_rejects_traversal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with zipfile.ZipFile(root / "bad.zip", "w") as archive:
                archive.writestr("../escaped", "bad")
            with self.assertRaises(AssertionError):
                smoke.extract(root / "bad.zip", root / "extracted")
            self.assertFalse((root / "escaped").exists())

    def test_checksums_detect_tampering_and_extra_delivered_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "app.zip"
            archive.write_bytes(b"original")
            package.checksums(root)
            smoke.verify_checksums(root)
            archive.write_bytes(b"modified")
            with self.assertRaises(AssertionError):
                smoke.verify_checksums(root)
            archive.write_bytes(b"original")
            (root / "untracked.log").write_text("residue")
            with self.assertRaises(AssertionError):
                smoke.verify_checksums(root)


if __name__ == "__main__":
    unittest.main()
