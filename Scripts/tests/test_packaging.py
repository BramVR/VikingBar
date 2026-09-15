from contextlib import redirect_stderr
import importlib.util
import io
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch
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
    def test_bundle_versions_match_release_or_prerelease_manifest(self):
        for version in ("0.1.0", "2.3.4-beta.2"):
            numeric = version.split("-")[0]
            plist = dict(CFBundleExecutable="VikingBarApp", CFBundleIdentifier="be.bram.vikingbar",
                         CFBundleName="VikingBar", CFBundlePackageType="APPL",
                         CFBundleShortVersionString=numeric, CFBundleVersion=numeric,
                         LSMinimumSystemVersion="14.0", LSUIElement=True)
            with self.subTest(version=version):
                smoke.verify_bundle_metadata(plist, {"version": version})
                for field in ("CFBundleVersion", "CFBundleShortVersionString", "CFBundleIdentifier"):
                    with self.assertRaisesRegex(AssertionError, field):
                        smoke.verify_bundle_metadata(dict(plist, **{field: "1"}), {"version": version})

    def test_missing_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            residue = root / "user.txt"
            residue.write_text("preserve me")
            stderr = io.StringIO()
            with patch("sys.argv", ["package-artifacts.py", "--output", str(root)]), \
                    patch.object(package, "metadata") as metadata, \
                    patch.object(package, "build_bundle") as build, redirect_stderr(stderr):
                with self.assertRaises(SystemExit) as result:
                    package.main()
            self.assertEqual(result.exception.code, 2)
            self.assertIn("Unexpected artifact residue; choose a fresh --output directory", stderr.getvalue())
            self.assertNotIn("Traceback", stderr.getvalue())
            self.assertEqual({p.name: p.read_bytes() for p in root.iterdir()}, {"user.txt": b"preserve me"})
            metadata.assert_not_called()
            build.assert_not_called()

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

    def test_packaged_connection_helper_must_match_build_and_remain_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = root / "connect-account.py"
            helper.write_bytes(b"synthetic connection helper")
            helper.chmod(0o755)
            manifest = {"connectHelperSHA256": package.digest(helper)}
            smoke.verify_connect_helper(root, manifest)
            helper.chmod(0o644)
            with self.assertRaisesRegex(AssertionError, "not executable"):
                smoke.verify_connect_helper(root, manifest)
            helper.chmod(0o755)
            helper.write_bytes(b"changed helper")
            with self.assertRaisesRegex(AssertionError, "differs from build manifest"):
                smoke.verify_connect_helper(root, manifest)
            with self.assertRaisesRegex(AssertionError, "missing"):
                smoke.verify_connect_helper(root / "missing", manifest)


if __name__ == "__main__":
    unittest.main()
