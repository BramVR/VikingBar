import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


INSTALL = load("install-app")
PROOF = load("installed-app-proof")
PACKAGE = load("package-artifacts")
ROUTER = load("proof-live")
SEAL = {"kind": "local-adhoc", "verified": True, "distributionTrust": False}


def synthetic_bundle(path, content=b"new"):
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Resources").mkdir()
    for name in INSTALL.EXECUTABLES:
        executable = path / "Contents/MacOS" / name
        executable.write_bytes(content)
        executable.chmod(0o755)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": INSTALL.IDENTIFIER, "CFBundleExecutable": "VikingBarApp",
        "CFBundleVersion": "0.1.0", "CFBundleShortVersionString": "0.1.0"}))
    (path / "Contents/Resources/build-manifest.json").write_text(json.dumps({
        "schemaVersion": 1, "commit": "a" * 40, "version": "0.1.0", "sourceDirty": True,
        "localAdHocSealed": True, "developerIDSigned": False, "notarized": False}))


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.target = self.root / "VikingBar.app"
        self.boundaries = dict(builder=synthetic_bundle, verify=lambda _path: SEAL, check_running=lambda _path: None)

    def install(self, **kwargs):
        return INSTALL.install(str(self.target), **dict(self.boundaries, **kwargs))

    def test_fresh_install_has_private_receipt_and_both_hashes(self):
        receipt = self.install()
        self.assertTrue(receipt["passed"])
        self.assertEqual(set(receipt["artifact"]["executables"]), set(INSTALL.EXECUTABLES))
        self.assertFalse(receipt["artifact"]["signature"]["distributionTrust"])
        self.assertEqual(INSTALL.receipt_path(self.target).stat().st_mode & 0o777, 0o600)
        self.assertEqual(INSTALL.validate_install(self.target, self.boundaries["verify"]), receipt)

    def test_destination_created_during_build_is_preserved_even_with_replace(self):
        for replace in (False, True):
            self.target = self.root / str(replace) / "VikingBar.app"
            def race(_candidate):
                synthetic_bundle(self.target, b"raced")
            with self.assertRaisesRegex(INSTALL.InstallFailure, "target-created-during-build"):
                self.install(replace=replace, before_publish=race)
            self.assertEqual((self.target / "Contents/MacOS/vikingbar").read_bytes(), b"raced")

    def test_atomic_publication_preserves_raced_in_empty_directory(self):
        rename = INSTALL.rename_exclusive
        def race(source, destination):
            destination.mkdir()
            rename(source, destination)
        with patch.object(INSTALL, "rename_exclusive", side_effect=race):
            with self.assertRaisesRegex(INSTALL.InstallFailure, "target-created-during-build"):
                self.install(replace=True)
        self.assertTrue(self.target.is_dir())
        self.assertEqual(list(self.target.iterdir()), [])
        self.assertFalse(INSTALL.receipt_path(self.target).exists())

    def test_late_destination_race_never_enters_update_path(self):
        exists = Path.exists
        built = False
        def builder(candidate):
            nonlocal built
            synthetic_bundle(candidate)
            built = True
        def race(path):
            if built and path == INSTALL.receipt_path(self.target) and not exists(self.target):
                synthetic_bundle(self.target, b"late race")
            return exists(path)
        with patch.object(Path, "exists", race):
            with self.assertRaisesRegex(INSTALL.InstallFailure, "target-created-during-build"):
                self.install(replace=True, builder=builder)
        self.assertEqual((self.target / "Contents/MacOS/vikingbar").read_bytes(), b"late race")
        self.assertEqual(list(self.root.glob(".vikingbar-install-*/previous.app")), [])

    def test_existing_target_refused_before_build_and_preserved(self):
        synthetic_bundle(self.target, b"original")
        builder = Mock()
        with self.assertRaisesRegex(INSTALL.InstallFailure, "explicit-replace"):
            self.install(builder=builder)
        builder.assert_not_called()
        self.assertEqual((self.target / "Contents/MacOS/vikingbar").read_bytes(), b"original")

    def test_explicit_update_retains_original_and_original_receipt(self):
        old = self.install()
        receipt = self.install(replace=True, builder=lambda path: synthetic_bundle(path, b"updated"))
        backup = Path(receipt["backup"])
        self.assertEqual((backup / "Contents/MacOS/vikingbar").read_bytes(), b"new")
        self.assertEqual(json.loads((backup.parent / "previous-install.json").read_text()), old)

    def test_unrelated_bundle_and_symlinks_refused(self):
        self.target.mkdir()
        with self.assertRaisesRegex(INSTALL.InstallFailure, "unrelated"):
            self.install(replace=True)
        link = self.root / "link"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(INSTALL.InstallFailure, "symlink"):
            INSTALL.install(str(link / "VikingBar.app"), **self.boundaries)

    def test_running_target_refused_without_build_or_signal(self):
        builder = Mock()
        with self.assertRaisesRegex(INSTALL.InstallFailure, "running"):
            self.install(builder=builder, check_running=Mock(side_effect=INSTALL.InstallFailure("running")))
        builder.assert_not_called()

    def test_preexisting_receipt_without_app_is_preserved(self):
        path = INSTALL.receipt_path(self.target)
        path.write_bytes(b"unrelated")
        with self.assertRaisesRegex(INSTALL.InstallFailure, "receipt-refused"):
            self.install()
        self.assertEqual(path.read_bytes(), b"unrelated")
        self.assertFalse(self.target.exists())

    def test_post_rename_failure_rolls_back_original_and_receipt(self):
        original = self.install()
        verify = Mock(side_effect=[SEAL, SEAL, INSTALL.InstallFailure("synthetic-verification-failure")])
        with self.assertRaisesRegex(INSTALL.InstallFailure, "synthetic-verification"):
            self.install(replace=True, verify=verify, builder=lambda path: synthetic_bundle(path, b"bad"))
        self.assertEqual(INSTALL.validate_install(self.target, self.boundaries["verify"]), original)
        self.assertEqual((self.target / "Contents/MacOS/vikingbar").read_bytes(), b"new")
        self.assertEqual(len(list(self.root.glob(".vikingbar-install-*/failed.app"))), 1)

    def test_partial_receipt_write_rolls_back_without_destroying_previous(self):
        old = self.install()
        write = INSTALL.private_write
        def fail(path, value):
            if path.name == "install.json":
                path.write_bytes(b"partial")
                raise OSError("synthetic disk failure")
            write(path, value)
        with patch.object(INSTALL, "private_write", side_effect=fail):
            with self.assertRaises(OSError):
                self.install(replace=True)
        self.assertEqual(INSTALL.validate_install(self.target, self.boundaries["verify"]), old)
        self.assertEqual(next(self.root.glob(".vikingbar-install-*/install.json")).read_bytes(), b"partial")

    def test_raced_receipt_is_preserved_during_fresh_and_update_publication(self):
        rename = INSTALL.rename_exclusive
        for update in (False, True):
            for boundary in ("VikingBar.app", "install.json"):
                with self.subTest(update=update, boundary=boundary):
                    self.target = self.root / str(update) / boundary / "VikingBar.app"
                    old = self.install() if update else None
                    receipt = INSTALL.receipt_path(self.target)
                    payload = b"external raced receipt"
                    def race(source, destination):
                        if source.name == boundary:
                            receipt.write_bytes(payload)
                        rename(source, destination)
                    with patch.object(INSTALL, "rename_exclusive", side_effect=race):
                        with self.assertRaisesRegex(INSTALL.InstallFailure, "target-created-during-build"):
                            self.install(replace=update)
                    self.assertEqual(receipt.read_bytes(), payload)
                    self.assertEqual(self.target.exists(), update)
                    self.assertEqual(list(self.target.parent.glob(".vikingbar-install-*/failed-install.json")), [])
                    if update:
                        saved = next(self.target.parent.glob(".vikingbar-install-*/previous-install.json"))
                        self.assertEqual(json.loads(saved.read_text()), old)

    def test_rollback_preserves_external_receipt_after_artifact_failure(self):
        old = self.install()
        receipt = INSTALL.receipt_path(self.target)
        def verify(path):
            if path == self.target and list(self.root.glob(".vikingbar-install-*/previous.app")):
                receipt.write_bytes(b"external during rollback")
                raise INSTALL.InstallFailure("synthetic-verification-failure")
            return SEAL
        with self.assertRaisesRegex(INSTALL.InstallFailure, "synthetic-verification-failure"):
            self.install(replace=True, verify=verify)
        self.assertEqual(receipt.read_bytes(), b"external during rollback")
        saved = next(self.root.glob(".vikingbar-install-*/previous-install.json"))
        self.assertEqual(json.loads(saved.read_text()), old)
        self.assertTrue(self.target.exists())

    def test_changed_original_receipt_is_never_moved_by_update_or_rollback(self):
        self.install()
        receipt = INSTALL.receipt_path(self.target)
        def race(_candidate):
            receipt.write_bytes(b"changed external receipt")
        with self.assertRaisesRegex(INSTALL.InstallFailure, "install-receipt-changed-during-build"):
            self.install(replace=True, before_publish=race)
        self.assertEqual(receipt.read_bytes(), b"changed external receipt")
        self.assertEqual(list(self.root.glob(".vikingbar-install-*/previous-install.json")), [])
        self.assertTrue(self.target.exists())

    def test_receipt_swapped_at_backup_is_detected_and_restored_without_overwrite(self):
        rename = INSTALL.rename_exclusive
        for conflict in (False, True):
            with self.subTest(conflict=conflict):
                self.target = self.root / str(conflict) / "VikingBar.app"
                self.install()
                receipt = INSTALL.receipt_path(self.target)
                def race(source, destination):
                    if destination.name == "previous-install.json":
                        receipt.write_bytes(b"external at backup")
                    rename(source, destination)
                    if destination.name == "previous-install.json" and conflict:
                        receipt.write_bytes(b"external at rollback")
                with patch.object(INSTALL, "rename_exclusive", side_effect=race):
                    with self.assertRaisesRegex(INSTALL.InstallFailure, "install-receipt-changed-during-backup"):
                        self.install(replace=True)
                self.assertEqual(receipt.read_bytes(), b"external at rollback" if conflict else b"external at backup")
                backups = list(self.target.parent.glob(".vikingbar-install-*/previous-install.json"))
                self.assertEqual(len(backups), int(conflict))
                if conflict:
                    self.assertEqual(backups[0].read_bytes(), b"external at backup")
                self.assertTrue(self.target.exists())

    def test_dangling_receipt_swapped_at_backup_is_restored(self):
        self.install()
        receipt = INSTALL.receipt_path(self.target)
        rename = INSTALL.rename_exclusive
        def race(source, destination):
            if destination.name == "previous-install.json":
                receipt.rename(self.root / "test-owned-original-receipt.json")
                receipt.symlink_to(self.root / "missing-external-target")
            rename(source, destination)
        with patch.object(INSTALL, "rename_exclusive", side_effect=race):
            with self.assertRaisesRegex(INSTALL.InstallFailure, "symlink-or-invalid-receipt-refused"):
                self.install(replace=True)
        self.assertTrue(receipt.is_symlink())
        self.assertEqual(receipt.readlink(), self.root / "missing-external-target")
        self.assertTrue(self.target.exists())

    def test_invalid_receipt_or_changed_binary_rejected(self):
        original = self.install()
        path = INSTALL.receipt_path(self.target)
        for value in ({}, dict(original, schema_version=True), dict(original, target="/unrelated"),
                      dict(original, passed=False), dict(original, artifact={})):
            INSTALL.private_write(path, value)
            with self.assertRaises(INSTALL.InstallFailure):
                INSTALL.validate_install(self.target, self.boundaries["verify"])
        INSTALL.private_write(path, original)
        (self.target / "Contents/MacOS/vikingbar").write_bytes(b"changed")
        with self.assertRaises(INSTALL.InstallFailure):
            INSTALL.validate_install(self.target, self.boundaries["verify"])

    def test_before_publish_refusal_keeps_target_absent(self):
        with self.assertRaisesRegex(RuntimeError, "registration"):
            self.install(before_publish=Mock(side_effect=RuntimeError("registration already enabled")))
        self.assertFalse(self.target.exists())

    def test_installer_rejects_bundle_version_mismatched_to_manifest(self):
        synthetic_bundle(self.target)
        path = self.target / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["CFBundleVersion"] = "0.2.0"
        path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(INSTALL.InstallFailure, "invalid-build-manifest"):
            INSTALL.artifact(self.target, self.boundaries["verify"])

    def test_seal_only_signs_app_and_preserves_cli(self):
        synthetic_bundle(self.target)
        with patch.object(PACKAGE.subprocess, "run") as run:
            PACKAGE.seal_local(self.target)
        self.assertEqual(run.call_args_list[0].args[0], ["codesign", "--force", "--sign", "-", str(self.target)])
        self.assertEqual(run.call_count, 2)
        with patch.object(PACKAGE.subprocess, "run"), patch.object(PACKAGE, "digest", side_effect=["before", "after"]):
            with self.assertRaisesRegex(ValueError, "CLI identity"):
                PACKAGE.seal_local(self.target)


class InstalledProofTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.proof = PROOF.InstalledProof.__new__(PROOF.InstalledProof)
        self.proof.directory = self.root
        self.proof.bundle = self.root / "VikingBar.app"
        synthetic_bundle(self.proof.bundle)
        self.proof.executable = self.proof.bundle / "Contents/MacOS/VikingBarApp"
        self.proof.cli = self.proof.bundle / "Contents/MacOS/vikingbar"
        self.proof.preferences_restored = True
        self.proof.settings_file = self.root / "settings.json"
        self.proof.registration_intent = False
        self.proof.check = "smoke"
        self.proof.fresh_install = True
        self.proof.login_baselines = {}
        self.proof.launches, self.proof.workers = [], []

    def test_missing_slots_and_target_fail_before_native_boundary(self):
        for environment in ({}, {"VIKINGBAR_UI_SLOT": "held"},
                            {"VIKINGBAR_UI_SLOT": "held", "VIKINGBAR_CREDENTIAL_SLOT": "held"}):
            with patch.object(PROOF.subprocess, "run") as run:
                with self.assertRaises(PROOF.UIFailure):
                    PROOF.InstalledProof(environment, "smoke")
            run.assert_not_called()

    def test_preferences_reject_identical_serialized_controls_as_ambiguous(self):
        duplicate = {
            "AXIdentifier": "vikingbar.showRemainingGB",
            "AXValue": "0",
            "frame": [[10, 20], [30, 40]],
        }
        tree = {"elements": [
            duplicate,
            dict(duplicate),
            {"AXIdentifier": "vikingbar.dataDisplayMode", "AXValue": "Remaining"},
            {"AXIdentifier": "vikingbar.refreshInterval", "AXValue": "Every 5 minutes"},
        ]}
        with self.assertRaisesRegex(PROOF.UIFailure, "settings-values-missing"):
            PROOF.preferences(tree)

    def test_constructor_proves_absent_target_and_receipt_before_enabling_fresh_policy(self):
        home = self.root.resolve()
        target = home / "Applications/proof/VikingBar.app"
        target.parent.mkdir(parents=True)
        peekaboo = home / "synthetic-peekaboo"
        peekaboo.write_bytes(b"synthetic")
        environment = {"VIKINGBAR_UI_SLOT": "held", "VIKINGBAR_CREDENTIAL_SLOT": "held",
                       "INSTALL_TARGET": str(target), "PEEKABOO_BIN": str(peekaboo)}
        with patch.object(Path, "home", return_value=home), patch.object(PROOF, "ROOT", home):
            fresh = PROOF.InstalledProof(environment, "smoke")
            self.assertTrue(fresh.fresh_install)
            existing = PROOF.InstalledProof(environment, "installed-balance")
            self.assertFalse(existing.fresh_install)
            INSTALL.receipt_path(target).write_bytes(b"external")
            with self.assertRaisesRegex(PROOF.UIFailure, "fresh-absent-target"):
                PROOF.InstalledProof(environment, "smoke")

    def test_not_found_baseline_requires_fresh_scope_and_retains_actual_state(self):
        p = self.proof
        for state in ("notFound", "notRegistered"):
            p.record_login_baseline("candidate", p.bundle, state)
            self.assertEqual(json.loads((self.root / "login-baselines.json").read_text())["candidate"],
                             {"path": str(p.bundle), "status": state})
        for state in ("enabled", "requiresApproval", "unavailable", "unknown"):
            with self.assertRaisesRegex(PROOF.UIFailure, "fresh-login-item-baseline"):
                p.record_login_baseline("installed", p.bundle, state)
        p.fresh_install = False
        with self.assertRaises(PROOF.UIFailure):
            p.record_login_baseline("installed", p.bundle, "notFound")
        p.fresh_install = True
        p.check = "installed-balance"
        with self.assertRaises(PROOF.UIFailure):
            p.record_login_baseline("installed", p.bundle, "notFound")

    def test_not_found_candidate_passes_only_inside_fresh_install_callback(self):
        p = self.proof
        p.bundle = self.root.resolve() / "destination/VikingBar.app"
        candidate = p.bundle.parent / ".vikingbar-install-synthetic/VikingBar.app"
        p.run = Mock(return_value={"passed": True, "schema_version": 1, "status": "notFound"})
        with patch.object(PROOF.INSTALL, "artifact", return_value={"sourceDirty": False, "commit": "a" * 40}), \
                patch.object(PROOF.subprocess, "check_output", return_value="a" * 40):
            p.before_install(candidate)
            p.run.assert_called_once()
            p.run.reset_mock()
            p.bundle.mkdir(parents=True)
            with self.assertRaisesRegex(PROOF.UIFailure, "fresh-task-owned-install"):
                p.before_install(candidate)
            p.run.assert_not_called()
        self.assertFalse(p.registration_intent)

    def test_changed_published_baseline_blocks_toggle_and_never_unregisters(self):
        p = self.proof
        p.login = Mock(side_effect=["notFound", "enabled"])
        p.launch = Mock()
        p.settings = Mock(return_value={"elements": [
            {"AXIdentifier": "vikingbar.showRemainingGB", "AXValue": "0"},
            {"AXIdentifier": "vikingbar.dataDisplayMode", "AXValue": "Remaining"},
            {"AXIdentifier": "vikingbar.refreshInterval", "AXValue": "Every 15 minutes"}]})
        p.apply_preferences = Mock()
        p.press = Mock()
        with self.assertRaisesRegex(PROOF.UIFailure, "fresh-login-item-baseline"):
            p.perform_smoke()
        self.assertFalse(p.registration_intent)
        p.press.assert_not_called()
        p.cleanup()
        self.assertEqual([call.args[0] for call in p.login.call_args_list], ["status", "status"])
        states = json.loads((self.root / "login-baselines.json").read_text())
        self.assertEqual(states["installed"]["status"], "notFound")
        self.assertEqual(states["beforeToggle"]["status"], "enabled")

    def test_attempted_registration_still_requires_not_registered_cleanup(self):
        p = self.proof
        p.registration_intent = True
        p.login = Mock(return_value="notFound")
        with self.assertRaisesRegex(PROOF.UIFailure, "login-registration-restoration-failed"):
            p.cleanup()

    def test_proof_requires_false_dirty_flag_and_exact_head(self):
        with patch.object(PROOF.subprocess, "check_output", return_value="a" * 40 + "\n"):
            PROOF.require_reviewed_artifact({"sourceDirty": False, "commit": "a" * 40})
            invalid = [{"sourceDirty": value, "commit": "a" * 40}
                       for value in (True, None, 0, "false", [], {})]
            invalid += [{"commit": "a" * 40}, {"sourceDirty": False},
                        {"sourceDirty": False, "commit": "b" * 40}]
            for artifact in invalid:
                with self.subTest(artifact=artifact), self.assertRaisesRegex(PROOF.UIFailure, "clean-current"):
                    PROOF.require_reviewed_artifact(artifact)

    def test_dirty_candidate_never_executes_status_or_publishes_install(self):
        self.proof.run = Mock()
        target = self.root.resolve() / "destination/VikingBar.app"
        self.proof.bundle = target
        with patch.object(PROOF.subprocess, "check_output", return_value="a" * 40), \
                patch.object(PROOF.INSTALL, "artifact", return_value={"sourceDirty": True, "commit": "a" * 40}):
            with self.assertRaisesRegex(PROOF.UIFailure, "clean-current"):
                PROOF.INSTALL.install(str(target), builder=synthetic_bundle, verify=lambda _: SEAL,
                                      check_running=lambda _: None, before_publish=self.proof.before_install)
        self.proof.run.assert_not_called()
        self.assertFalse(target.exists())

    def test_dirty_installed_balance_fails_before_native_inspection_or_launch(self):
        p = self.proof
        p.check = "installed-balance"
        p.peek = Mock()
        receipt = {"artifact": {"sourceDirty": True, "commit": "a" * 40}}
        with patch.object(PROOF.subprocess, "check_output", return_value="a" * 40), \
                patch.object(PROOF.INSTALL, "validate_install", return_value=receipt), \
                patch.object(PROOF.subprocess, "Popen") as launch:
            with self.assertRaisesRegex(PROOF.UIFailure, "clean-current"):
                p.perform()
            with self.assertRaisesRegex(PROOF.UIFailure, "clean-current"):
                p.launch()
        p.peek.assert_not_called()
        launch.assert_not_called()

    def test_saved_preferences_require_persisted_values_not_only_ui(self):
        expected = {"showRemainingGB": "0", "dataDisplayMode": "Used", "refreshInterval": "Every 5 minutes"}
        path = self.proof.settings_file
        path.write_text(json.dumps({"dataDisplayMode": "remaining"}))
        with self.assertRaisesRegex(PROOF.UIFailure, "saved-preferences"):
            PROOF.verify_saved_preferences(path, expected)
        path.write_text(json.dumps({"dataDisplayMode": "used"}))
        PROOF.verify_saved_preferences(path, expected)

    def test_absent_preferences_only_match_defaults(self):
        expected = {"showRemainingGB": "0", "dataDisplayMode": "Remaining", "refreshInterval": "Every 5 minutes"}
        PROOF.verify_saved_preferences(self.proof.settings_file, expected)
        with self.assertRaises(PROOF.UIFailure):
            PROOF.verify_saved_preferences(self.proof.settings_file, dict(expected, dataDisplayMode="Used"))

    def test_failed_save_cannot_mark_restoration_complete(self):
        p = self.proof
        p.preferences_restored = False
        p.process = Mock()
        p.process.poll.return_value = None
        p.original_preferences = {"showRemainingGB": "0", "dataDisplayMode": "Used", "refreshInterval": "Every 5 minutes"}
        tree = {"elements": [{"AXIdentifier": "vikingbar." + key, "AXValue": value}
                              for key, value in p.original_preferences.items()]}
        p.settings = Mock(return_value=tree)
        p.inspect = Mock(return_value=tree)
        p.settings_file.write_text(json.dumps({"dataDisplayMode": "remaining"}))
        with self.assertRaisesRegex(PROOF.UIFailure, "saved-preferences"):
            p.restore_preferences()
        self.assertFalse(p.preferences_restored)
        self.assertFalse((self.root / "preferences-restored.json").exists())

    def test_login_receipts_reject_extra_fields_failed_and_fake_status(self):
        valid = {"schema_version": 1, "status": "enabled", "passed": True}
        self.assertEqual(PROOF.login_receipt(valid), "enabled")
        for value in ({}, dict(valid, schema_version=True), dict(valid, status="disabled"),
                      dict(valid, passed=False), dict(valid, error="secret")):
            with self.assertRaises(PROOF.UIFailure):
                PROOF.login_receipt(value)

    def test_cleanup_registration_failure_fails_and_preserves_artifacts(self):
        self.proof.registration_intent = True
        self.proof.login = Mock(return_value="requiresApproval")
        evidence = self.root / "capture.png"
        evidence.write_bytes(b"synthetic")
        with self.assertRaisesRegex(PROOF.UIFailure, "registration-restoration"):
            self.proof.cleanup()
        self.assertTrue(self.proof.bundle.exists())
        self.assertEqual(evidence.read_bytes(), b"synthetic")
        self.assertFalse(json.loads((self.root / "cleanup.json").read_text())["exited"])

    def test_cleanup_rereads_registration_after_disable(self):
        self.proof.registration_intent = True
        self.proof.login = Mock(return_value="notRegistered")
        self.proof.cleanup()
        self.assertEqual([call.args[0] for call in self.proof.login.call_args_list], ["disable", "status"])
        self.assertTrue(json.loads((self.root / "cleanup.json").read_text())["registrationRestored"])

    def test_changed_process_identity_never_signals(self):
        child = Mock(pid=12345)
        child.poll.return_value = None
        record = {"identity": "old", "executableSHA256": INSTALL.digest(self.proof.executable)}
        with patch.object(PROOF.UI, "process_identity", return_value={"identity": "other", "parentPID": os.getpid()}), \
                patch.object(PROOF.os, "kill") as kill:
            with self.assertRaisesRegex(PROOF.UIFailure, "ownership"):
                self.proof.stop_owned(child, record)
        kill.assert_not_called()

    def test_termination_timeout_rechecks_identity_before_escalation(self):
        child = Mock(pid=12345)
        child.poll.return_value = None
        child.wait.side_effect = subprocess.TimeoutExpired("synthetic", 5)
        record = {"identity": "owned", "executableSHA256": INSTALL.digest(self.proof.executable)}
        with patch.object(PROOF.UI, "process_identity", side_effect=[
            {"identity": "owned", "parentPID": os.getpid()}, {"identity": "changed", "parentPID": os.getpid()}]), \
                patch.object(PROOF.os, "kill") as kill:
            with self.assertRaises(PROOF.UIFailure):
                self.proof.stop_owned(child, record)
        kill.assert_called_once_with(12345, signal.SIGTERM)

    def test_swapped_install_refuses_maintenance_execution(self):
        self.proof.install_receipt = {"artifact": "original"}
        self.proof.run = Mock()
        with patch.object(PROOF.INSTALL, "validate_install", return_value={"artifact": "swapped"}):
            with self.assertRaisesRegex(PROOF.UIFailure, "artifact-changed"):
                self.proof.login("disable")
        self.proof.run.assert_not_called()

    def test_graceful_quit_precedes_signal_fallback(self):
        child = Mock(pid=12345)
        child.poll.side_effect = [None, 0]
        self.proof.verify_owned = Mock()
        self.proof.run = Mock(side_effect=[b'{"elements":[{"AXIdentifier":"vikingbar.quit"}]}', b'{}'])
        self.proof.graceful_quit(child, {})
        with patch.object(PROOF.os, "kill") as kill:
            self.proof.stop_owned(child, {})
        kill.assert_not_called()
        self.assertEqual(self.proof.run.call_args_list[-1].args[0][-2:], ["press", "vikingbar.quit"])
        child.wait.assert_called_once_with(timeout=25)

    def test_cleanup_failure_overrides_success_and_retains_false_result(self):
        self.proof.perform = Mock(return_value={"passed": True})
        self.proof.cleanup = Mock(side_effect=PROOF.UIFailure("synthetic-cleanup-failed"))
        with patch.object(PROOF, "InstalledProof", return_value=self.proof):
            with self.assertRaisesRegex(PROOF.UIFailure, "synthetic-cleanup-failed"):
                PROOF.run({})
        self.assertFalse(json.loads((self.root / "result.json").read_text())["passed"])
        self.assertTrue(self.proof.bundle.exists())

    def test_registration_restoration_failure_still_attempts_owned_process_cleanup(self):
        self.proof.registration_intent = True
        self.proof.login = Mock(side_effect=PROOF.UIFailure("synthetic-registration-error"))
        process, record = Mock(), {"workerOwnershipEstablished": True}
        self.proof.launches = [(process, record)]
        self.proof.stop_owned = Mock()
        self.proof.graceful_quit = Mock()
        with self.assertRaises(PROOF.UIFailure):
            self.proof.cleanup()
        self.proof.stop_owned.assert_called_once_with(process, record)

    def test_live_routing_never_enters_password_bootstrap(self):
        with patch.object(ROUTER.importlib.util, "module_from_spec") as load_module:
            module = Mock()
            module.run.return_value = {"passed": True}
            load_module.return_value = module
            with patch.object(ROUTER.importlib.util, "spec_from_file_location"):
                result = ROUTER.run("installed-balance", {})
        module.run.assert_called_once_with({})
        self.assertEqual(result, {"passed": True})

    def test_smoke_approval_required_is_failure_with_restoration_intent(self):
        p = self.proof
        p.login = Mock(side_effect=["notRegistered", "notRegistered", "requiresApproval", "requiresApproval"])
        p.launch = Mock()
        p.settings = Mock(return_value={"elements": [
            {"AXIdentifier": "vikingbar.showRemainingGB", "AXValue": "0"},
            {"AXIdentifier": "vikingbar.dataDisplayMode", "AXValue": "Remaining"},
            {"AXIdentifier": "vikingbar.refreshInterval", "AXValue": "Every 15 minutes"}]})
        p.apply_preferences = Mock()
        p.press = Mock()
        with self.assertRaisesRegex(PROOF.UIFailure, "approval-required"):
            p.perform_smoke()
        self.assertTrue(p.registration_intent)
        self.assertTrue((self.root / "restoration-intent.json").exists())


if __name__ == "__main__":
    unittest.main()
