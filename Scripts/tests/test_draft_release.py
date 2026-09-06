import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("draft_release", Path(__file__).parents[1] / "draft-release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
COMMIT = "a" * 40
APP = f"VikingBar-0.1.0-test.1-arm64-{COMMIT}.zip"
CLI = f"vikingbar-cli-0.1.0-test.1-arm64-{COMMIT}.zip"


class DraftReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "VERSION").write_text("0.1.0-test.1\n")
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## Unreleased\n\n## 0.1.0-test.1\n\n- Fixture release.\n")
        self.metadata = release.release_metadata("v0.1.0-test.1", COMMIT, self.root)
        self.existing = {"draft": True, "tag_name": self.metadata["tag"], "target_commitish": COMMIT,
                         "body": self.metadata["body"], "assets": []}

    def assets(self):
        directory = self.root / "assets"
        directory.mkdir()
        files = []
        for name in [APP, CLI]:
            (directory / name).write_bytes(b"synthetic archive")
            files.append({"path": name, "sha256": release.sha256(directory / name), "bytes": 17})
        manifest = {"schemaVersion": 1, "version": self.metadata["version"], "commit": COMMIT,
                    "architecture": "arm64", "minimumMacOS": "14.0", "configuration": "release", "developmentBuild": True,
                    "developerIDSigned": False, "notarized": False, "sourceDirty": False, "files": files}
        (directory / "manifest.json").write_text(json.dumps(manifest))
        (directory / "SHA256SUMS").write_text("".join(f"{release.sha256(path)}  {path.name}\n"
                                                    for path in sorted(directory.iterdir())))
        return directory

    def test_semver_and_exact_nonempty_notes(self):
        self.assertIn("- Fixture release.", self.metadata["body"])
        self.assertIn(COMMIT, self.metadata["body"])
        for tag in ["main", "v01.0.0", "v0.1.0-01", "v0.1.0/a", "v0.1.0\n"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.validate_tag(tag)
        for notes in ["## 0.1.0-test.1\n", "## 0.1.0\n- Wrong.\n", "## 0.1.0-test.1\n- One.\n## 0.1.0-test.1\n- Two."]:
            (self.root / "CHANGELOG.md").write_text(notes)
            with self.assertRaises(ValueError):
                release.release_metadata(self.metadata["tag"], COMMIT, self.root)

    def test_version_disagreement(self):
        (self.root / "VERSION").write_text("0.1.0")
        with self.assertRaises(ValueError):
            release.release_metadata(self.metadata["tag"], COMMIT, self.root)

    def test_bad_checksums_and_extra_files(self):
        directory = self.assets()
        self.assertEqual(len(release.verify_assets(directory, self.metadata)), 4)
        (directory / "extra").write_text("unexpected")
        with self.assertRaises(ValueError):
            release.verify_assets(directory, self.metadata)
        (directory / "extra").unlink()
        (directory / APP).write_bytes(b"changed")
        with self.assertRaises(ValueError):
            release.verify_assets(directory, self.metadata)

    def test_matching_digest_retained_and_missing_assets_returned(self):
        self.existing["assets"] = [{"name": "one.zip", "digest": "sha256:abc"}]
        self.assertEqual(release.missing_assets(self.existing, self.metadata, {"one.zip": "abc", "two.zip": "def"},
                                               lambda _: self.fail("Unexpected download")), ["two.zip"])

    def test_digest_falls_back_to_download(self):
        self.existing["assets"] = [{"name": "one.zip", "id": 12}]
        self.assertEqual(release.missing_assets(self.existing, self.metadata, {"one.zip": "abc"}, lambda _: "abc"), [])
        with self.assertRaises(ValueError):
            release.missing_assets(self.existing, self.metadata, {"one.zip": "abc"}, lambda _: "other")

    def test_conflicting_release_rejected(self):
        for key, value in [("draft", False), ("tag_name", "v2.0.0"), ("target_commitish", "main"), ("body", "changed")]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                release.missing_assets({**self.existing, key: value}, self.metadata, {}, lambda _: "")

    def test_publish_preflights_all_assets_before_any_mutation(self):
        directory = self.assets()
        hashes = release.verify_assets(directory, self.metadata)
        self.existing["assets"] = [{"name": "manifest.json", "digest": "sha256:wrong"}]
        (self.root / "release.json").write_text(json.dumps(self.metadata))
        calls = []
        def fake_gh(*args):
            calls.append(args)
            return json.dumps([[self.existing]])
        with patch.object(release, "gh", fake_gh), patch.object(release, "remote_commit", return_value=COMMIT):
            with self.assertRaises(ValueError):
                release.publish("owner/repo", self.metadata["tag"], COMMIT, directory, self.root)
        self.assertTrue(all(call[0] == "api" for call in calls))
        self.existing["assets"] = [{"name": name, "digest": "sha256:" + digest} for name, digest in hashes.items()]
        with patch.object(release, "gh", fake_gh), patch.object(release, "remote_commit", return_value=COMMIT):
            release.publish("owner/repo", self.metadata["tag"], COMMIT, directory, self.root)
        self.assertTrue(all(call[0] == "api" for call in calls))

    def test_moved_tag_prevents_writes(self):
        directory = self.assets()
        (self.root / "release.json").write_text(json.dumps(self.metadata))
        with patch.object(release, "gh") as gh, patch.object(release, "remote_commit", return_value="b" * 40):
            with self.assertRaises(ValueError):
                release.publish("owner/repo", self.metadata["tag"], COMMIT, directory, self.root)
            gh.assert_not_called()


if __name__ == "__main__":
    unittest.main()
