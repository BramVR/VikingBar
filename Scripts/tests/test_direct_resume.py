import copy
import datetime
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import subprocess
import tarfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("resume_ui", ROOT / "Scripts/balance-ui-proof.py")
UI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UI)
R = UI.RESUME


class ResumeAdmissionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.root = self.base / "repo"
        self.root.mkdir()
        self.directory = self.root / ".build/proof/run"
        self.directory.mkdir(parents=True, mode=0o700)
        self.now = datetime.datetime.now(datetime.timezone.utc)
        expires = (self.now + datetime.timedelta(minutes=30)).isoformat()
        self.prior = {"schema_version": 1, "check": "direct-connect-ui", "source_sha256": "a" * 64,
                      "credential_reference_sha256": "b" * 64, "expires_at": expires, "tmux_session": "old",
                      "credential_slot": "credential", "mac_ui_slot": "mac"}
        prior_hash = self.write(self.base / "prior.json", self.prior)
        executable = str(self.root / ".build/app/VikingBar.app/Contents/MacOS/VikingBarApp")
        cli = str(self.root / ".build/app/VikingBar.app/Contents/MacOS/vikingbar")
        policy = UI.direct_sandbox(executable, cli)
        initial = {"pid": 123, "parentPID": 100, "arguments": ["/usr/bin/sandbox-exec", "-p", policy, executable,
                   "--proof-directory", str(self.directory)], "startedAt": self.now.isoformat(),
                   "executableSHA256": "c" * 64, "cliSHA256": "d" * 64, "cli": cli,
                   "workerOwnershipEstablished": True, "identity": "123 100 Wed Sep 9 10:00:00 2026 " + executable + " --proof-directory " + str(self.directory)}
        workers = [{"pid": pid, "parentPID": 123, "startTime": "Wed Sep 9 10:00:00 2026", "command": cli + " " + command,
                    "identity": str(pid) + " 123 Wed Sep 9 10:00:00 2026 " + cli + " " + command, "cliSHA256": "d" * 64}
                   for pid, command in ((124, "session"), (125, "connect"))]
        self.evidence = {"initial-process.json": initial,
            "direct-configuration.json": {"sourceSHA256": "a" * 64, "configurationSHA256": prior_hash,
                "sandboxSHA256": hashlib.sha256(policy.encode()).hexdigest(), "processExecRestricted": True},
            "direct-connect-launch.json": dict(initial, connectOwnershipRequired=True, connectOwnershipEstablished=False),
            "direct-connect-child.json": {"schema_version": 1, "pid": 125, "parentPID": 123},
            "direct-connect-child-ready.json": {"schema_version": 1, "pid": 125},
            "direct-connect-process.json": workers[1],
            "connect-result.json": {"schema_version": 1, "check": "connect", "passed": True, "connected": True},
            "direct-input.json": {"credentialReads": 1, "privatePipe": True, "formCaptureSkipped": True,
                "appCredentialReference": False, "processExecRestricted": True},
            "cleanup.json": {"exited": True, "workers": workers, "apps": [dict(initial,
                connectOwnershipRequired=True, connectOwnershipEstablished=True)]}}
        self.manifest = {"schema_version": 1, "prior_revision": "e" * 40, "prior_directory": str(self.directory),
                         "prior_config_path": str(self.base / "prior.json"), "prior_config_sha256": prior_hash,
                         "artifacts": {}, "build_policy": "reviewed-debug-same-product-release",
                         "reviewed_debug_build": {"revision": "1" * 40, "product_sha256": "2" * 64,
                             "build_manifest_sha256": "3" * 64, "app_sha256": "4" * 64, "cli_sha256": "5" * 64}}
        self.config = {"schema_version": 1, "check": "direct-connect-ui", "mode": "stored-session",
                       "source_sha256": "f" * 64, "manifest_path": str(self.base / "manifest.json"),
                       "manifest_sha256": "", "credential_slot": "credential", "mac_ui_slot": "mac",
                       "expires_at": expires}
        self.environment = {"VIKINGBAR_DIRECT_RESUME_CONFIG": str(self.base / "config.json"),
                            "VIKINGBAR_CREDENTIAL_SLOT": "credential", "VIKINGBAR_MAC_UI_SLOT": "mac",
                            "VIKINGBAR_SLOT_BINDINGS_EXPIRES_AT": expires}
        self.publish()

    def write(self, path, value):
        path.write_text(json.dumps(value))
        path.chmod(0o600)
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def publish(self):
        self.manifest["artifacts"] = {name: self.write(self.directory / name, value)
                                      for name, value in self.evidence.items()}
        self.config["manifest_sha256"] = self.write(self.base / "manifest.json", self.manifest)
        self.environment["VIKINGBAR_DIRECT_RESUME_CONFIG_SHA256"] = self.write(self.base / "config.json", self.config)

    def validate(self):
        with patch.object(R, "source_binding", return_value=("a" * 64, "f" * 64, "2" * 64)), \
                patch.object(R, "current_revision", return_value="1" * 40):
            return R.validate(self.environment, self.root, self.now)

    def test_complete_private_evidence_without_any_credential_environment(self):
        with patch.object(UI.shutil, "which", side_effect=AssertionError("dependency lookup")), \
                patch.object(UI.CONNECT, "reference_at", side_effect=AssertionError("credential reference")):
            result = self.validate()
        self.assertEqual(result["directory"], self.directory)

    def test_resume_configuration_rejects_prior_drift_and_new_connect_receipt(self):
        proof = object.__new__(UI.NativeProof)
        proof.resume = self.validate()
        proof.environment = self.environment
        proof.directory = self.base / "new-proof"
        proof.directory.mkdir()
        prior_result = self.directory / "connect-result.json"
        original = prior_result.read_bytes()
        with patch.object(R, "source_binding", return_value=("a" * 64, "f" * 64, "2" * 64)), \
                patch.object(R, "current_revision", return_value="1" * 40):
            prior_result.write_text("{}")
            with self.assertRaisesRegex(UI.UIFailure, "direct-resume-evidence-invalid"):
                proof.resume_configuration()
            prior_result.write_bytes(original)
            (proof.directory / "connect-result.json").write_text("{}")
            with self.assertRaisesRegex(UI.UIFailure, "direct-resume-evidence-invalid"):
                proof.resume_configuration()

    def test_changed_hash_missing_extra_and_wrong_types_fail_closed(self):
        original = copy.deepcopy(self.evidence)
        mutations = [("connect-result.json", "passed", 1), ("connect-result.json", "schema_version", True),
                     ("direct-input.json", "credentialReads", True), ("direct-input.json", "privatePipe", 1),
                     ("cleanup.json", "exited", False), ("direct-connect-child-ready.json", "pid", 999),
                     ("direct-connect-process.json", "parentPID", 9), ("initial-process.json", "extra", True)]
        for name, field, value in mutations:
            self.evidence = copy.deepcopy(original)
            self.evidence[name][field] = value
            self.publish()
            with self.subTest(name=name, field=field), self.assertRaises(R.ResumeFailure):
                self.validate()
        self.evidence = original
        for name in R.ARTIFACTS:
            self.publish()
            (self.directory / name).write_text("{}")
            with self.subTest(name=name), self.assertRaises(R.ResumeFailure):
                self.validate()
        self.publish()
        del self.manifest["artifacts"]["cleanup.json"]
        self.config["manifest_sha256"] = self.write(self.base / "manifest.json", self.manifest)
        self.environment["VIKINGBAR_DIRECT_RESUME_CONFIG_SHA256"] = self.write(self.base / "config.json", self.config)
        with self.assertRaises(R.ResumeFailure):
            self.validate()

    def test_permissions_symlinks_and_existing_result_rejected(self):
        path = self.directory / "connect-result.json"
        path.chmod(0o644)
        with self.assertRaises(R.ResumeFailure):
            self.validate()
        self.publish()
        target = self.base / "alias-target.json"
        path.rename(target)
        path.symlink_to(target)
        with self.assertRaises(R.ResumeFailure):
            self.validate()
        path.unlink()
        self.publish()
        (self.directory / "result.json").symlink_to(self.base / "absent")
        with self.assertRaises(R.ResumeFailure):
            self.validate()

    def test_prior_directory_must_be_direct_child_of_checkout_proof_root(self):
        unrelated = self.base / "unrelated-proof"
        unrelated.mkdir(mode=0o700)
        for name in R.ARTIFACTS:
            target = unrelated / name
            target.write_bytes((self.directory / name).read_bytes())
            target.chmod(0o600)
        self.manifest["prior_directory"] = str(unrelated)
        self.config["manifest_sha256"] = self.write(self.base / "manifest.json", self.manifest)
        self.environment["VIKINGBAR_DIRECT_RESUME_CONFIG_SHA256"] = self.write(
            self.base / "config.json", self.config)
        with self.assertRaises(R.ResumeFailure):
            self.validate()

    def test_source_mismatch_and_debug_build_mismatch_rejected(self):
        with patch.object(R, "source_binding", return_value=("0" * 64, "f" * 64, "2" * 64)), \
                patch.object(R, "current_revision", return_value="1" * 40):
            with self.assertRaises(R.ResumeFailure):
                R.validate(self.environment, self.root, self.now)
        executable, cli = self.base / "app", self.base / "cli"
        executable.write_bytes(b"different")
        cli.write_bytes(b"different")
        with self.assertRaises(R.ResumeFailure):
            R.verify_debug(self.validate(), executable, cli)

    def test_reviewed_build_preserves_prior_hashes_and_binds_new_artifacts(self):
        bundle = self.base / "Reviewed.app/Contents"
        (bundle / "MacOS").mkdir(parents=True)
        (bundle / "Resources").mkdir()
        executable, cli = bundle / "MacOS/VikingBarApp", bundle / "MacOS/vikingbar"
        executable.write_bytes(b"reviewed app")
        cli.write_bytes(b"reviewed cli")
        build_path = bundle / "Resources/build-manifest.json"
        build = {"schemaVersion": 1, "commit": "1" * 40, "configuration": "debug", "sourceDirty": False}
        reviewed = self.manifest["reviewed_debug_build"]
        reviewed.update(app_sha256=hashlib.sha256(executable.read_bytes()).hexdigest(),
                        cli_sha256=hashlib.sha256(cli.read_bytes()).hexdigest(),
                        build_manifest_sha256=self.write(build_path, build))
        self.publish()
        admitted = self.validate()
        R.verify_debug(admitted, executable, cli)
        self.assertNotEqual(reviewed["app_sha256"], admitted["evidence"]["initial-process.json"]["executableSHA256"])
        for path in (executable, cli, build_path):
            original = path.read_bytes()
            path.write_bytes(original + b"changed")
            with self.subTest(path=path.name), self.assertRaises(R.ResumeFailure):
                R.verify_debug(admitted, executable, cli)
            path.write_bytes(original)
        for key, value in (("sourceDirty", True), ("configuration", "release"), ("commit", "9" * 40)):
            changed = dict(build, **{key: value})
            reviewed["build_manifest_sha256"] = self.write(build_path, changed)
            self.publish()
            with self.subTest(key=key), self.assertRaises(R.ResumeFailure):
                R.verify_debug(self.validate(), executable, cli)

    def test_reviewed_build_schema_product_and_revision_must_match(self):
        original = copy.deepcopy(self.manifest["reviewed_debug_build"])
        for key, value in (("product_sha256", "9" * 64), ("revision", "9" * 40), ("app_sha256", True),
                           ("extra", "unexpected")):
            self.manifest["reviewed_debug_build"] = dict(original, **{key: value})
            self.publish()
            with self.subTest(key=key), self.assertRaises(R.ResumeFailure):
                self.validate()

    def test_additional_connect_worker_is_rejected(self):
        worker = copy.deepcopy(self.evidence["direct-connect-process.json"])
        worker.update(pid=126, identity=worker["identity"].replace("125 123", "126 123", 1))
        self.evidence["cleanup.json"]["workers"].append(worker)
        self.publish()
        with self.assertRaises(R.ResumeFailure):
            self.validate()

    def test_private_files_and_directory_require_current_owner(self):
        with patch.object(R.os, "getuid", return_value=R.os.getuid() + 1):
            with self.assertRaises(R.ResumeFailure):
                self.validate()
        original = R.Path.stat
        def wrong_directory_owner(path, *args, **kwargs):
            info = original(path, *args, **kwargs)
            if path == self.directory:
                return Mock(st_mode=info.st_mode, st_uid=R.os.getuid() + 1)
            return info
        with patch.object(R.Path, "stat", wrong_directory_owner):
            with self.assertRaises(R.ResumeFailure):
                self.validate()

    def test_duplicate_json_keys_rejected_even_with_matching_hash(self):
        path = self.base / "config.json"
        text = path.read_text()
        path.write_text(text[:-1] + ', "schema_version": 1}')
        self.environment["VIKINGBAR_DIRECT_RESUME_CONFIG_SHA256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaises(R.ResumeFailure):
            self.validate()

    def test_hard_linked_private_json_is_rejected(self):
        alias = self.base / "config-alias.json"
        os.link(self.base / "config.json", alias)
        self.environment["VIKINGBAR_DIRECT_RESUME_CONFIG"] = str(alias)
        with self.assertRaises(R.ResumeFailure):
            self.validate()

    def test_case_alias(self):
        path = self.base / "case-aliased-root/config.json"
        path.parent.mkdir()
        path.write_text("{}")
        real_samefile = os.path.samefile
        def samefile(left, right):
            if Path(left) == path.parent and Path(right) == self.root:
                return True
            return real_samefile(left, right)
        with patch.object(R.os.path, "samefile", side_effect=samefile):
            self.assertFalse(R.outside_root(path, self.root))

    def test_source_binding_allows_harness_only_changes_and_rejects_product_changes(self):
        (self.root / "Sources").mkdir()
        (self.root / "Scripts").mkdir()
        original = {"Package.swift": b"package", "Sources/App.swift": b"product", "Scripts/proof.py": b"old"}
        for name, data in original.items():
            (self.root / name).write_bytes(data)
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w") as archive:
            for name, data in original.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        (self.root / "Scripts/proof.py").write_bytes(b"new")
        with patch.object(R.subprocess, "run", return_value=Mock(returncode=0, stdout=output.getvalue())):
            old, new, product = R.source_binding(self.root, "e" * 40)
            self.assertNotEqual(old, new)
            (self.root / "Sources/App.swift").write_bytes(b"changed")
            with self.assertRaises(R.ResumeFailure):
                R.source_binding(self.root, "e" * 40)

    def test_invalid_admission_never_constructs_or_launches_app(self):
        with patch.object(UI.subprocess, "Popen") as launch, patch.object(UI.subprocess, "run") as execute:
            with self.assertRaises(UI.UIFailure):
                UI.NativeProof({}, direct_resume=True)
        launch.assert_not_called()
        execute.assert_not_called()


class ResumeReadinessTests(unittest.TestCase):
    def test_process_identity_uses_remaining_human_window(self):
        proof = object.__new__(UI.NativeProof)
        proof.human_deadline = 12
        with patch.object(UI.time, "monotonic", return_value=10), \
                patch.object(UI, "process_identity", return_value=None) as identity:
            self.assertIsNone(proof.bounded_process_identity(123))
        identity.assert_called_once_with(123, timeout=2)

    def test_quit_wait_uses_remaining_human_window(self):
        proof = object.__new__(UI.NativeProof)
        proof.human_deadline = 15
        process = Mock(returncode=0)
        proof.process = process
        with patch.object(UI.time, "monotonic", return_value=10), patch.object(proof, "press"):
            proof.quit()
        process.wait.assert_called_once_with(timeout=5)
        self.assertIsNone(proof.process)


    def test_live_report_requires_nonempty_string_connection_id(self):
        snapshot = {"source": {"live": {}},
                    "freshness": {"current": {"lastUpdated": "2026-09-09T00:00:00Z"}}}
        for connection_id in (None, "", " ", False, True, 0, 1):
            report = {"schemaVersion": 1, "snapshot": snapshot,
                      "state": {"snapshot": snapshot, "connectionID": connection_id, "balance": {"ok": 1},
                                "selectedSubscriptionID": "sim", "selectedBundleIndex": 0}}
            with self.subTest(connection_id=connection_id), self.assertRaisesRegex(UI.UIFailure, "live-report-invalid"):
                UI.successful_timestamp(report)

    def test_prompt_blocked_commands_use_remaining_window_instead_of_default_timeout(self):
        proof = object.__new__(UI.NativeProof)
        proof.environment = {}
        proof.human_deadline = 600
        result = subprocess.CompletedProcess(["synthetic"], 0, b"ok", b"")
        with patch.object(UI.time, "monotonic", return_value=10), \
                patch.object(UI.subprocess, "run", return_value=result) as execute:
            self.assertEqual(proof.run(["synthetic"]), b"ok")
        self.assertEqual(execute.call_args.kwargs["timeout"], 590)
        proof.human_deadline = None
        with patch.object(UI.subprocess, "run", return_value=result) as execute:
            proof.run(["synthetic"])
        self.assertEqual(execute.call_args.kwargs["timeout"], 120)

    def test_helper_inspect_and_refresh_inherit_the_human_deadline(self):
        proof = object.__new__(UI.NativeProof)
        proof.human_deadline = 600
        proof.process = Mock(pid=123)
        with patch.object(UI.time, "monotonic", return_value=10), \
                patch.object(proof, "verify_process") as verify, patch.object(proof, "run") as execute:
            proof.inspect()
            proof.press("vikingbar.refresh")
        self.assertEqual(verify.call_count, 2)
        for call in verify.call_args_list:
            self.assertEqual(call.kwargs, {"deadline": 600})
        for call in execute.call_args_list:
            self.assertEqual(call.kwargs["timeout"], 590)

    def test_only_actual_deadline_timeout_becomes_readiness_timeout(self):
        proof = object.__new__(UI.NativeProof)
        proof.environment = {}
        proof.human_deadline = 600
        early = subprocess.TimeoutExpired(["synthetic"], 120)
        with patch.object(UI.time, "monotonic", side_effect=[10, 130]), \
                patch.object(UI.subprocess, "run", side_effect=early):
            with self.assertRaises(subprocess.TimeoutExpired) as raised:
                proof.run(["synthetic"])
        self.assertIs(raised.exception, early)
        with patch.object(UI.time, "monotonic", side_effect=[10, 600]), \
                patch.object(UI.subprocess, "run", side_effect=subprocess.TimeoutExpired(["synthetic"], 590)):
            with self.assertRaisesRegex(UI.UIFailure, "human-readiness-timeout"):
                proof.run(["synthetic"])
        result = subprocess.CompletedProcess(["synthetic"], 0, b"late", b"")
        with patch.object(UI.time, "monotonic", side_effect=[10, 601]), \
                patch.object(UI.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(UI.UIFailure, "human-readiness-timeout"):
                proof.run(["synthetic"])

    def popover_retry_fixture(self):
        proof = object.__new__(UI.NativeProof)
        proof.resume = {"synthetic": True}
        proof.human_deadline = 600
        proof.screens = [{"bounds": {"x": 0, "y": 0, "width": 1000, "height": 800}}]
        status = {"AXIdentifier": "vikingbar.status", "frame": [[10, 0], [30, 24]]}
        closed = {"activationPolicy": 1, "elements": [status], "windows": []}
        opened = copy.deepcopy(closed)
        opened["elements"] += [{"AXRole": "AXPopover", "frame": [[10, 24], [300, 400]]},
                               {"AXIdentifier": "vikingbar.remaining", "frame": [[20, 40], [100, 20]]}]
        opened["windows"] = [{"kCGWindowNumber": 42,
                              "kCGWindowBounds": {"X": 10, "Y": 24, "Width": 300, "Height": 400}}]
        return proof, closed, opened

    def test_resume_retries_blocked_or_ineffective_press_after_allow_without_capture(self):
        for first_result in (None, UI.UIFailure("proof-command-failed")):
            proof, closed, opened = self.popover_retry_fixture()
            with self.subTest(first_result=first_result), patch.object(UI.time, "monotonic", return_value=0), \
                    patch.object(UI.time, "sleep"), patch.object(proof, "peek") as capture, \
                    patch.object(proof, "inspect", side_effect=[closed, closed, opened]) as inspect, \
                    patch.object(proof, "press", side_effect=[first_result, None]) as press:
                self.assertEqual(proof.open_resume_popover(), opened)
            self.assertEqual(press.call_count, 2)
            for call in press.call_args_list:
                self.assertEqual(call.kwargs, {"deadline": 600})
            for call in inspect.call_args_list:
                self.assertEqual(call.kwargs, {"deadline": 600})
            capture.assert_not_called()
            self.assertEqual(proof.human_deadline, 600)

    def test_resume_retry_collapses_identical_physical_status_records(self):
        proof, closed, opened = self.popover_retry_fixture()
        for tree in (closed, opened):
            tree["elements"][0].update(AXRole="AXMenuBarItem", AXSubrole="AXUnknown", AXEnabled=True)
            tree["elements"].append(copy.deepcopy(tree["elements"][0]))
        with patch.object(UI.time, "monotonic", return_value=0), patch.object(UI.time, "sleep"), \
                patch.object(proof, "inspect", side_effect=[closed, opened]), patch.object(proof, "press") as press:
            self.assertEqual(proof.open_resume_popover(), opened)
        press.assert_called_once_with("vikingbar.status", deadline=600)

    def test_resume_retry_rejects_distinct_physical_status_signatures(self):
        for field, value in (("frame", [[50, 0], [30, 24]]), ("AXRole", "AXButton"),
                             ("AXSubrole", "different"), ("AXEnabled", False)):
            proof, closed, _opened = self.popover_retry_fixture()
            closed["elements"][0].update(AXRole="AXMenuBarItem", AXSubrole="AXUnknown", AXEnabled=True)
            second = copy.deepcopy(closed["elements"][0])
            second[field] = value
            closed["elements"].append(second)
            with self.subTest(field=field), patch.object(UI.time, "monotonic", return_value=0), \
                    patch.object(proof, "inspect", return_value=closed), patch.object(proof, "press") as press:
                with self.assertRaisesRegex(UI.UIFailure, "resume-status-ambiguous"):
                    proof.open_resume_popover()
            press.assert_not_called()

    def test_resume_retry_propagates_terminal_failures_and_ambiguity(self):
        for code in ("process-identity-changed", "running-artifact-changed", "cleanup-process-inspection-failed",
                     "proof-json-invalid", "human-readiness-timeout"):
            proof, closed, _opened = self.popover_retry_fixture()
            with self.subTest(code=code), patch.object(UI.time, "monotonic", return_value=0), \
                    patch.object(proof, "inspect", return_value=closed), \
                    patch.object(proof, "press", side_effect=UI.UIFailure(code)) as press:
                with self.assertRaisesRegex(UI.UIFailure, "^" + code + "$"):
                    proof.open_resume_popover()
            press.assert_called_once()
        proof, closed, opened = self.popover_retry_fixture()
        opened["windows"].append(dict(opened["windows"][0], kCGWindowNumber=43))
        with patch.object(UI.time, "monotonic", return_value=0), patch.object(UI.time, "sleep"), \
                patch.object(proof, "inspect", side_effect=[closed, opened]), \
                patch.object(proof, "press", side_effect=UI.UIFailure("proof-command-failed")) as press:
            with self.assertRaisesRegex(UI.UIFailure, "native-popover-ambiguous"):
                proof.open_resume_popover()
        press.assert_called_once()

    def test_resume_retry_cannot_overrun_the_existing_human_deadline(self):
        proof, closed, _opened = self.popover_retry_fixture()
        proof.human_deadline = 1
        now = [0]
        def inspect(**kwargs):
            now[0] += 0.4
            return closed
        def press(*args, **kwargs):
            now[0] += 0.4
        def sleep(seconds):
            now[0] += seconds
        with patch.object(UI.time, "monotonic", side_effect=lambda: now[0]), \
                patch.object(UI.time, "sleep", side_effect=sleep), \
                patch.object(proof, "inspect", side_effect=inspect) as observe, \
                patch.object(proof, "press", side_effect=press) as action:
            with self.assertRaisesRegex(UI.UIFailure, "human-readiness-timeout"):
                proof.open_resume_popover()
        self.assertEqual(now[0], 1)
        observe.assert_called_once()
        action.assert_called_once()

    def test_resume_sequence_skips_credentials_and_enforces_connection_continuity(self):
        for changed_stage in (None, "api", "refreshed", "resumed", "rebuilt"):
            with self.subTest(changed_stage=changed_stage), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                proof = object.__new__(UI.NativeProof)
                proof.directory = base / "new"
                proof.directory.mkdir()
                prior = base / "prior"
                prior.mkdir()
                (prior / "connect-result.json").write_text("prior successful connection")
                proof.resume = {"directory": prior, "config": {"manifest_sha256": "a" * 64}}
                proof.bundle = base / "app"
                proof.executable, proof.cli = base / "executable", base / "cli"
                proof.executable.write_bytes(b"app")
                proof.cli.write_bytes(b"debug")
                proof.environment = {}
                events = []
                def report(stage):
                    order = {"connected": 1, "api": 2, "refreshed": 3, "resumed": 4, "rebuilt": 5}
                    timestamp = "2026-09-09T00:00:0" + str(order[stage]) + "Z"
                    snapshot = {"source": {"live": {}}, "freshness": {"current": {"lastUpdated": timestamp}}}
                    return {"schemaVersion": 1, "snapshot": snapshot, "state": {"snapshot": snapshot,
                        "connectionID": "changed" if stage == changed_stage else "original", "balance": {"ok": 1},
                        "selectedSubscriptionID": "sim", "selectedBundleIndex": 0}}
                api = {"schema_version": 1, "check": "balance-api", "passed": True,
                       "api_matches": True, "token_refreshed": True, "bundle_count": 1}
                def run(command, name=None, timeout=120):
                    events.append(command)
                    if "package-artifacts.py" in " ".join(command):
                        proof.cli.write_bytes(b"release")
                    if "balance-api" in command:
                        return json.dumps(api)
                    if "--cached" in command:
                        return report("api")
                    return b""
                def peek(command, name):
                    return {"screens": []} if command == ["screen", "list"] else {}
                with patch.object(proof, "run", side_effect=run), patch.object(proof, "peek", side_effect=peek), \
                        patch.object(proof, "resume_configuration"), \
                        patch.object(proof, "begin_human_window") as window, \
                        patch.object(proof, "prepare_sandbox") as sandbox, patch.object(proof, "launch") as launch, \
                        patch.object(proof, "matched_balance", side_effect=lambda stage, *args: report(stage)), \
                        patch.object(proof, "press") as press, patch.object(proof, "quit") as quit_app, \
                        patch.object(proof, "connect_direct", side_effect=AssertionError("credential path")), \
                        patch.object(proof, "connect_with_one_password", side_effect=AssertionError("credential path")), \
                        patch.object(UI.RESUME, "verify_debug") as debug, patch.object(UI.time, "sleep"), \
                        patch.object(UI.shutil, "which", side_effect=AssertionError("credential executable lookup")):
                    if changed_stage:
                        with self.assertRaisesRegex(UI.UIFailure, "reconnected"):
                            proof.perform()
                    else:
                        result = proof.perform()
                        self.assertEqual(result["check"], "direct-connect-ui")
                        self.assertEqual(result["credential_reads_total"], 1)
                        self.assertEqual(result["resume_manifest_sha256"], "a" * 64)
                        self.assertEqual(launch.call_count, 3)
                        self.assertEqual(quit_app.call_count, 3)
                        window.assert_any_call("release-build")
                        sandbox.assert_called_once()
                        debug.assert_called_once()
                        press.assert_called_once_with("vikingbar.refresh")
                self.assertTrue(any("balance-api" in command for command in events))

    def test_readiness_prevents_capture_and_timeout_cleanup_still_runs(self):
        proof = object.__new__(UI.NativeProof)
        proof.resume = {"config": {"manifest_sha256": "a" * 64,
                                   "expires_at": (datetime.datetime.now(datetime.timezone.utc)
                                                  + datetime.timedelta(minutes=30)).isoformat()}}
        proof.environment = {"VIKINGBAR_DIRECT_RESUME_CONFIG_SHA256": "b" * 64}
        proof.directory = Path("/synthetic")
        proof.peekaboo = "/synthetic/peekaboo"
        with patch.object(proof, "resume_configuration"), patch.object(UI, "private_write") as write, \
                patch.object(UI.time, "monotonic", return_value=10):
            proof.begin_human_window("initial")
        self.assertEqual(proof.human_deadline, 610)
        self.assertTrue(write.call_args.args[1]["capture_suppressed"])
        self.assertEqual(write.call_args.args[1]["configuration_sha256"], "b" * 64)
        self.assertEqual(write.call_args.args[1]["manifest_sha256"], "a" * 64)
        with patch.object(proof, "run") as execute:
            with self.assertRaisesRegex(UI.UIFailure, "capture-forbidden"):
                proof.peek(["see"], "bad.json")
        execute.assert_not_called()
        proof.capture_suppressed = False
        with patch.object(proof, "run", return_value={"success": True, "data": {}}) as execute:
            self.assertEqual(proof.peek(["see"], "card.json"), {})
        execute.assert_called_once()
        with patch.object(UI.time, "monotonic", return_value=611):
            with self.assertRaisesRegex(UI.UIFailure, "human-readiness-timeout"):
                proof.human_remaining()
        instance = Mock(launch_in_progress=False)
        instance.perform.side_effect = UI.UIFailure("human-readiness-timeout")
        with patch.object(UI, "NativeProof", return_value=instance):
            with self.assertRaisesRegex(UI.UIFailure, "human-readiness-timeout"):
                UI.run({}, direct_resume=True)
        instance.cleanup.assert_called_once()

    def test_readiness_window_does_not_outlive_slot_binding(self):
        proof = object.__new__(UI.NativeProof)
        expires = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=30)
        proof.resume = {"config": {"manifest_sha256": "a" * 64, "expires_at": expires.isoformat()}}
        proof.environment = {"VIKINGBAR_DIRECT_RESUME_CONFIG_SHA256": "b" * 64}
        proof.directory = Path("/synthetic")
        with patch.object(proof, "resume_configuration"), patch.object(UI, "private_write") as write, \
                patch.object(UI.time, "monotonic", return_value=10):
            proof.begin_human_window("initial")
        self.assertGreater(proof.human_deadline, 10)
        self.assertLessEqual(proof.human_deadline, 40)
        receipt_expires = datetime.datetime.fromisoformat(write.call_args.args[1]["expires_at"])
        self.assertLessEqual(receipt_expires, expires)


if __name__ == "__main__":
    unittest.main()
