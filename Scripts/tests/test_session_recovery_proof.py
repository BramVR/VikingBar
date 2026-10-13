import contextlib
import copy
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

SPEC = importlib.util.spec_from_file_location("session_recovery", Path(__file__).resolve().parents[1]
                                            / "session-recovery-proof.py")
PROOF = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROOF)


class RecoveryProofTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.directory.chmod(0o700)
        self.check = "mobile-session-recovery"
        slot = str(uuid.uuid4())
        self.account = "mobile-vikings/" + slot
        self.reference = self.directory / "reference.json"
        self.reference.write_text(json.dumps({"vault": "Codex Automation", "item_id": "syntheticitem",
                                              "fields": ["client_id", "username", "password"]}))
        self.reference.chmod(0o600)
        now = datetime.datetime.now(datetime.timezone.utc)
        self.config = {"schema_version": 1, "check": self.check, "source_sha256": "f" * 64,
                       "credential_reference_sha256": hashlib.sha256(self.reference.read_bytes()).hexdigest(),
                       "expires_at": (now + datetime.timedelta(seconds=1800)).isoformat(),
                       "tmux_session": "synthetic-proof", "credential_slot": "synthetic-credential",
                       "mac_ui_slot": "synthetic-native", "evidence_root": str(self.directory),
                       "account": self.account, "account_root": str(self.directory / ("session-recovery-" + slot)),
                       "timeout_seconds": 600}
        self.config_path = self.directory / "config.json"
        self.environment = {"TMUX": "/synthetic/tmux", "BRAM_OP_SERVICE_ACCOUNT_TOKEN": "service-sentinel",
                            "VIKINGBAR_CREDENTIAL_REFERENCE": str(self.reference),
                            "VIKINGBAR_SESSION_RECOVERY_CONFIG": str(self.config_path),
                            "VIKINGBAR_CREDENTIAL_SLOT": "synthetic-credential",
                            "VIKINGBAR_MAC_UI_SLOT": "synthetic-native", "PATH": "/synthetic/bin",
                            "VIKINGBAR_SLOT_BINDINGS_EXPIRES_AT": self.config["expires_at"]}
        self.publish_config()
        self.receipt = {"schema_version": 1, "check": self.check, "phase": "exercise",
                        "account_sha256": hashlib.sha256(self.account.encode()).hexdigest(),
                        "connection_sha256": "a" * 64, "original_connection_sha256": "a" * 64,
                        "passed": True, "bootstrap": True, "owned": True, "savedSignIn": False, "serviceRetained": False,
                        "remembered": False, "restored": True,
                        "loss": "access-rejected", "recovered": True, "usage": True, "disabled": False,
                        "loggedOut": False, "password_grants": 1, "refresh_grants": 1, "failure": "none"}

    def publish_config(self):
        self.config_path.write_text(json.dumps(self.config))
        self.config_path.chmod(0o600)
        self.environment["VIKINGBAR_SESSION_RECOVERY_CONFIG_SHA256"] = hashlib.sha256(
            self.config_path.read_bytes()).hexdigest()

    def read_config(self):
        with patch.object(PROOF.UI, "source_digest", return_value="f" * 64):
            return PROOF.configuration(self.check, self.environment)

    def test_authorized_configuration_binds_fresh_private_storage_and_exact_reference(self):
        config = self.read_config()
        self.assertEqual(config["account"], self.account)
        self.assertEqual(config["reference"]["item_id"], "syntheticitem")
        self.assertEqual(config["timeout_seconds"], 600)
        for mutate in (lambda: self.config.update(account="mobile-vikings/00000000-0000-0000-0000-000000000001"),
                       lambda: self.config.update(credential_slot="PENDING"),
                       lambda: self.config.update(timeout_seconds=True),
                       lambda: self.config.update(credential_reference_sha256="0" * 64)):
            previous = copy.deepcopy(self.config)
            mutate()
            self.publish_config()
            with self.assertRaisesRegex(PROOF.UIFailure, "session-recovery-configuration-required"):
                self.read_config()
            self.config = previous
        self.publish_config()
        Path(self.config["account_root"]).mkdir()
        with self.assertRaises(PROOF.UIFailure):
            self.read_config()

    def test_missing_slot_and_world_readable_reference_are_rejected_before_bootstrap(self):
        with patch.dict(self.environment, {"VIKINGBAR_MAC_UI_SLOT": ""}):
            with self.assertRaises(PROOF.UIFailure):
                self.read_config()
        self.reference.chmod(0o644)
        with self.assertRaises(PROOF.UIFailure):
            self.read_config()

    def test_real_rejection_renewal_and_connection_continuity_required(self):
        self.assertEqual(PROOF.validate_provider(self.receipt, self.check, "exercise", self.account), self.receipt)
        for change in ({"loss": "unobserved"}, {"loss": "fixture-401"}, {"recovered": False},
                       {"restored": False}, {"connection_sha256": "b" * 64}, {"password_grants": 2},
                       {"refresh_grants": 0}, {"password": "secret-sentinel"}, {"schema_version": True}):
            with self.subTest(change=change):
                with self.assertRaises(PROOF.UIFailure):
                    PROOF.validate_provider(dict(self.receipt, **change), self.check, "exercise", self.account)

    def test_omitted_recovery_field_and_wrong_account_cannot_pass(self):
        missing = dict(self.receipt)
        del missing["loss"]
        with self.assertRaises(PROOF.UIFailure):
            PROOF.validate_provider(missing, self.check, "exercise", self.account)
        with self.assertRaises(PROOF.UIFailure):
            PROOF.validate_provider(self.receipt, self.check, "exercise", "mobile-vikings/" + str(uuid.uuid4()))

    def test_remembered_recovery_requires_second_password_grant_and_new_incarnation(self):
        check = "mobile-remembered-sign-in"
        receipt = dict(self.receipt, check=check, remembered=True, savedSignIn=True, serviceRetained=True,
                       loss="grant-rejected", password_grants=2,
                       connection_sha256="b" * 64)
        self.assertEqual(PROOF.validate_provider(receipt, check, "exercise", self.account), receipt)
        for change in ({"remembered": False}, {"password_grants": 1}, {"connection_sha256": "a" * 64}):
            with self.assertRaises(PROOF.UIFailure):
                PROOF.validate_provider(dict(receipt, **change), check, "exercise", self.account)

    def test_unclassified_telenet_cookie_loss_cannot_claim_natural_expiry(self):
        check = "telenet-remembered-sign-in"
        account = "telenet/" + str(uuid.uuid4())
        receipt = dict(self.receipt, check=check, loss="unclassified-cookie-loss", remembered=True,
                       account_sha256=hashlib.sha256(account.encode()).hexdigest())
        with self.assertRaises(PROOF.UIFailure):
            PROOF.validate_provider(receipt, check, "exercise", account)
        receipt.update(passed=False, recovered=False, usage=False, failure="natural-expiry-unverified")
        self.assertEqual(PROOF.validate_provider(receipt, check, "exercise", account)["passed"], False)

    def test_timeout_failure_remains_redacted_and_failed(self):
        receipt = dict(self.receipt, passed=False, loss="unobserved", recovered=False,
                       failure="observation-timeout")
        self.assertEqual(PROOF.validate_provider(receipt, self.check, "exercise", self.account), receipt)
        with self.assertRaises(PROOF.UIFailure):
            PROOF.validate_provider(dict(receipt, failure="private server payload"), self.check, "exercise", self.account)

    def test_final_receipt_requires_every_native_and_cleanup_stage(self):
        receipt = {"schema_version": 1, "check": self.check, "passed": True,
                   "stages": dict.fromkeys(PROOF.STAGES, True), "failure": "none"}
        self.assertEqual(PROOF.validate_final(receipt, self.check), receipt)
        for stage in PROOF.STAGES:
            changed = copy.deepcopy(receipt)
            changed["stages"][stage] = False
            with self.subTest(stage=stage):
                with self.assertRaises(PROOF.UIFailure):
                    PROOF.validate_final(changed, self.check)
        missing = copy.deepcopy(receipt)
        del missing["stages"]["native"]
        with self.assertRaises(PROOF.UIFailure):
            PROOF.validate_final(missing, self.check)

    def test_selected_permission_denial_cannot_use_an_unselected_granted_runtime(self):
        granted = {"isSelected": True, "permissions": [{"name": name, "isRequired": True, "isGranted": True}
                                                       for name in ("Screen Recording", "Accessibility")]}
        PROOF.require_permissions({"sources": [granted]})
        denied = copy.deepcopy(granted)
        denied["permissions"][0]["isGranted"] = False
        granted["isSelected"] = False
        with self.assertRaisesRegex(PROOF.UIFailure, "native-permissions-denied"):
            PROOF.require_permissions({"sources": [denied, granted]})

    def test_phase_preserves_failed_receipt_and_stdin_secret_boundary(self):
        proof = object.__new__(PROOF.RecoveryNative)
        proof.check = self.check
        proof.account_selector = self.account
        proof.account_root = self.config["account_root"]
        proof.config = self.config
        proof.cli = Path("/synthetic/vikingbar")
        proof.directory = self.directory
        calls = []
        receipt = dict(self.receipt, passed=False, loss="unobserved", recovered=False,
                       failure="observation-timeout")
        def execute(command, **options):
            calls.append((command, options))
            return subprocess.CompletedProcess(command, 1, json.dumps(receipt).encode(), b"private-error")
        proof.execute = execute
        proof.environment = dict(self.environment, DYLD_INSERT_LIBRARIES="loader-sentinel")
        self.assertEqual(proof.phase("exercise", {"password": "password-sentinel"})["passed"], False)
        command, options = calls[0]
        self.assertEqual(json.loads(options["input"])["credentials"], {"password": "password-sentinel"})
        self.assertEqual(options["env"], {"PATH": "/synthetic/bin"})
        self.assertNotIn("password-sentinel", json.dumps(command))
        self.assertEqual(json.loads((self.directory / "exercise-receipt.json").read_bytes()), receipt)

    def test_credential_timeout_reports_fixed_error_without_private_subprocess_output(self):
        config = dict(self.config, reference={"item_id": "syntheticitem", "vault": "Codex Automation"})
        calls = []
        def execute(command, **options):
            calls.append(command)
            if command[0] == "tmux":
                return subprocess.CompletedProcess(command, 0, b"synthetic-proof 22", b"")
            raise subprocess.TimeoutExpired(command, 60, output=b"private-sentinel", stderr=b"private-sentinel")
        with patch.object(PROOF.os, "getpid", return_value=22), \
                patch.object(PROOF.shutil, "which", return_value="/synthetic/op"):
            with self.assertRaisesRegex(PROOF.UIFailure, "^credential-read-timeout$"):
                PROOF.credential_once(config, self.environment, execute)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[1], ["/synthetic/op", "item", "get", "syntheticitem", "--vault", "Codex Automation",
                                    "--format", "json"])


class RecoveryWorkerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.proof = object.__new__(PROOF.RecoveryNative)
        self.proof.cli = Path(sys.executable)
        self.proof.directory = Path(self.temporary.name)
        self.proof.phase_processes = []
        self.command = [sys.executable, "-c", "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())"]
        self.options = {"env": {"PATH": "/usr/bin:/bin"}, "input": b"synthetic input", "timeout": 5}
        self.processes = []
        self.original_popen = subprocess.Popen

    def tearDown(self):
        for process in self.processes:
            if process.stdin is not None and not process.stdin.closed:
                process.stdin.close()
            process.wait(timeout=10)
            process.stdout.close()
            process.stderr.close()

    def spawn(self, *arguments, **options):
        process = self.original_popen(*arguments, **options)
        self.processes.append(process)
        return process

    def identity(self, pid):
        return {"pid": pid, "parentPID": PROOF.os.getpid(), "command": " ".join(self.command),
                "identity": "synthetic-owned-child", "startTime": "synthetic-time"}

    def test_initial_ownership_failure_closes_input_and_reaps_real_child_without_signals(self):
        for identity in (None, dict(self.identity(1), parentPID=1), dict(self.identity(1), command="other")):
            with self.subTest(identity=identity), \
                    patch.object(PROOF.subprocess, "Popen", side_effect=self.spawn), \
                    patch.object(PROOF.UI, "process_identity", return_value=identity), \
                    patch.object(subprocess.Popen, "terminate") as terminate, \
                    patch.object(subprocess.Popen, "kill") as kill:
                with self.assertRaisesRegex(PROOF.UIFailure, "proof-cli-ownership-unverified"):
                    self.proof.owned_phase(self.command, self.options, "prepare")
                child = self.processes[-1]
                self.assertEqual(child.poll(), 0)
                self.assertTrue(child.stdin.closed)
                terminate.assert_not_called()
                kill.assert_not_called()
                child.stdout.close()
                child.stderr.close()

    def test_receipt_write_failure_closes_input_and_reaps_real_child_without_signals(self):
        with patch.object(PROOF.subprocess, "Popen", side_effect=self.spawn), \
                patch.object(PROOF.UI, "process_identity", side_effect=self.identity), \
                patch.object(PROOF.UI, "private_write", side_effect=OSError("synthetic disk failure")), \
                patch.object(subprocess.Popen, "terminate") as terminate, \
                patch.object(subprocess.Popen, "kill") as kill:
            with self.assertRaisesRegex(OSError, "synthetic disk failure"):
                self.proof.owned_phase(self.command, self.options, "prepare")
            child = self.processes[-1]
            self.assertEqual(child.poll(), 0)
            self.assertTrue(child.stdin.closed)
            terminate.assert_not_called()
            kill.assert_not_called()
            child.stdout.close()
            child.stderr.close()

    def test_verified_child_receives_input_and_has_an_exited_receipt(self):
        with patch.object(PROOF.subprocess, "Popen", side_effect=self.spawn), \
                patch.object(PROOF.UI, "process_identity", side_effect=self.identity):
            result = self.proof.owned_phase(self.command, self.options, "exercise")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"synthetic input")
        self.assertEqual(result.stderr, b"")
        receipt = json.loads((self.proof.directory / "exercise-cli-process.json").read_bytes())
        self.assertTrue(receipt["exited"])
        self.assertEqual(receipt["returncode"], 0)

    def test_cleanup_cannot_pass_with_an_unreaped_worker(self):
        class Worker:
            stdin = None
            def wait(self, timeout):
                raise subprocess.TimeoutExpired("synthetic worker", timeout)
        self.proof.phase_processes = [Worker()]
        with patch.object(PROOF.UI.NativeProof, "cleanup"), \
                self.assertRaisesRegex(PROOF.UIFailure, "proof-cli-ownership-unverified"):
            self.proof.cleanup()


class RecoveryOrchestrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.events = []
        self.phase_error = None
        self.failed_phase = None
        self.provider = {'passed': False, 'owned': True, 'bootstrap': True, 'restored': True,
                         'recovered': True, 'usage': True, 'remembered': True, 'savedSignIn': True,
                         'serviceRetained': True, 'connection_sha256': 'a' * 64}
        self.mobile_oracle = {'schema_version': 1, 'check': 'balance-api', 'passed': True,
                              'api_matches': True, 'token_refreshed': True, 'bundle_count': 1}
        self.home_oracle = {'schema_version': 1, 'check': 'telenet-home-api', 'passed': True,
                            'api_matches': True, 'service_count': 1, 'daily_usage_matches': True,
                            'daily_row_count': 3, 'daily_history_matches': True, 'forecast_matches': True,
                            'session_reused': True}
        owner = self
        class Native:
            def __init__(self, check, environment, config, execute):
                self.check = check
                self.logged_out = False
                self.directory = owner.directory
                self.account_selector = 'telenet/synthetic'
                self.cli = Path('/synthetic/cli')
                self.bundle = Path('/synthetic/VikingBar.app')
                self.executable = owner.directory / 'synthetic-executable'
                self.executable.write_bytes(b'synthetic executable')
            def prepare(self):
                owner.events.append('prepare')
            def phase(self, phase, credentials=None):
                owner.events.append((phase, credentials))
                if phase == owner.failed_phase:
                    raise owner.phase_error
                if phase == 'exercise':
                    return owner.provider
                if phase == 'logout':
                    self.logged_out = True
                return {'passed': True, 'owned': True, 'disabled': True, 'loggedOut': self.logged_out}
            def launch(self, label):
                owner.events.append(('launch', label))
            def matched(self, label, after=None):
                owner.events.append(('matched', label))
                return {}
            def connect_form(self, credentials):
                owner.events.append(('connect_form', credentials))
            def quit(self):
                owner.events.append('quit')
            def cleanup(self):
                owner.events.append('cleanup')
            def inspect(self, label):
                return {'elements': [{'AXIdentifier': 'vikingbar.connect.direct'}]}
            def run(self, command, *args, **kwargs):
                owner.events.append(('run', command))
                if command[1:2] == ['proof']:
                    return json.dumps(owner.home_oracle if self.check.startswith('telenet-') else owner.mobile_oracle)
                return {}
            def press(self, identifier):
                owner.events.append(('press', identifier))
        self.native = Native

    def patched(self):
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(patch.object(PROOF, 'configuration', return_value={'account': 'synthetic'}))
        self.credentials = stack.enter_context(patch.object(PROOF, 'credential_once', return_value={'password': 'sentinel'}))
        stack.enter_context(patch.object(PROOF, 'RecoveryNative', self.native))
        stack.enter_context(patch.object(PROOF, 'SetupNative', self.native))
        stack.enter_context(patch.object(PROOF.UI, 'successful_timestamp', return_value=datetime.datetime(2020, 1, 1,
                                                                                                       tzinfo=datetime.timezone.utc)))
        stack.enter_context(patch.object(PROOF.HOME, 'home_timestamp', return_value=datetime.datetime(2020, 1, 1,
                                                                                                    tzinfo=datetime.timezone.utc)))
        stack.enter_context(patch.object(PROOF.time, 'sleep'))
        return stack

    def test_unobserved_provider_loss_keeps_native_witnesses_without_passing_expiry(self):
        self.patched()
        result = PROOF.run('telenet-remembered-sign-in', {})
        self.assertEqual(result, {'schema_version': 1, 'check': 'telenet-remembered-sign-in', 'passed': False,
                                 'stages': {'provider': False, 'native': True, 'relaunch': True,
                                            'independent_usage': True, 'option_off': True, 'logout': True,
                                            'cleanup': True}, 'failure': 'provider-failed'})
        self.assertEqual(self.credentials.call_count, 1)
        self.assertEqual([event for event in self.events if isinstance(event, tuple) and event[0] == 'exercise'],
                         [('exercise', {'password': 'sentinel'})])
        self.assertEqual(json.loads((self.directory / 'independent-usage.json').read_bytes()), self.home_oracle)

    def test_incomplete_provider_receipt_skips_native_and_still_cleans_owned_account(self):
        self.patched()
        self.provider['recovered'] = False
        result = PROOF.run('mobile-remembered-sign-in', {})
        self.assertEqual(result['stages'], {'provider': False, 'native': False, 'relaunch': False,
                                          'independent_usage': False, 'option_off': False, 'logout': False,
                                          'cleanup': True})
        self.assertEqual(self.events, ['prepare', ('prepare', None), ('exercise', {'password': 'sentinel'}),
                                       'cleanup', ('logout', None)])
        self.assertEqual(result['passed'], False)

    def test_interrupted_or_invalid_exercise_still_cleans_prepared_owned_credentials(self):
        self.patched()
        self.failed_phase = 'exercise'
        for error in (subprocess.TimeoutExpired('synthetic-cli', 10),
                      PROOF.UIFailure('session-recovery-receipt-invalid')):
            with self.subTest(error=type(error).__name__):
                self.events.clear()
                self.credentials.reset_mock()
                self.phase_error = error
                result = PROOF.run('mobile-remembered-sign-in', {})
                self.assertEqual(result['passed'], False)
                self.assertEqual(result['failure'], 'native-failed')
                self.assertEqual(result['stages']['cleanup'], True)
                self.assertFalse(any(flag for stage, flag in result['stages'].items() if stage != 'cleanup'))
                self.credentials.assert_called_once()
                self.assertEqual(self.events, ['prepare', ('prepare', None),
                                               ('exercise', {'password': 'sentinel'}), 'cleanup', ('logout', None)])
                self.assertNotIn('sentinel', (self.directory / 'result.json').read_text())

    def test_failed_preparation_never_reads_credentials_or_deletes_unowned_records(self):
        self.patched()
        self.failed_phase = 'prepare'
        self.phase_error = PROOF.UIFailure('session-recovery-receipt-invalid')
        result = PROOF.run('mobile-remembered-sign-in', {})
        self.assertEqual(result['passed'], False)
        self.assertEqual(result['failure'], 'native-failed')
        self.credentials.assert_not_called()
        self.assertEqual(self.events, ['prepare', ('prepare', None), 'cleanup'])

    def test_isolated_direct_setup_completes_native_refresh_and_rebuild_with_one_read(self):
        self.patched()
        result = PROOF.run_setup('direct-connect-ui', {})
        self.assertEqual(result['passed'], True)
        self.assertEqual(result['failure'], 'none')
        self.assertEqual(result['stages'], {'native_connect': True, 'native_values': True, 'independent_usage': True,
                                          'native_refresh': True, 'stored_relaunch': True, 'release_relaunch': True,
                                          'cleanup': True})
        self.assertEqual(self.credentials.call_count, 1)
        self.assertIn(('connect_form', {'password': 'sentinel'}), self.events)
        self.assertIn(('press', 'vikingbar.refresh'), self.events)
        self.assertEqual([event for event in self.events if isinstance(event, tuple) and event[0] == 'launch'],
                         [('launch', 'native-setup'), ('launch', 'stored-session'), ('launch', 'release-relaunch')])
        self.assertEqual(self.events[-2:], ['cleanup', ('logout', None)])
        self.assertNotIn('sentinel', (self.directory / 'result.json').read_text())

    def test_one_slot_telenet_setup_cannot_pass_provider_switching_or_native_history(self):
        self.patched()
        result = PROOF.run_setup('telenet-home-ui', {})
        self.assertEqual(result, {'schema_version': 1, 'check': 'telenet-home-ui', 'passed': False,
                                 'stages': {'native_connect': True, 'native_values': True, 'independent_usage': True,
                                            'native_refresh': True, 'stored_relaunch': True, 'release_relaunch': True,
                                            'provider_switching': False, 'native_history': False, 'cleanup': True},
                                 'failure': 'isolated-provider-switching-and-history-unverified'})
        self.assertEqual(self.credentials.call_count, 1)
        self.assertEqual(json.loads((self.directory / 'independent-usage.json').read_bytes()), self.home_oracle)


class PreexistingApplicationTests(unittest.TestCase):
    def test_stale_launch_services_entry_does_not_block_but_live_instance_does(self):
        apps = {"apps": [{"bundle_id": "be.bram.vikingbar", "pid": 55728},
                         {"bundle_id": "be.bram.vikingbar", "pid": 12345}]}
        def probe(pid, signal):
            if pid == 55728:
                raise ProcessLookupError()
        self.assertEqual(PROOF.UI.UI.live_bundle_processes(apps, "be.bram.vikingbar", probe), [12345])

    def test_permission_denial_means_potentially_live_and_missing_identity_fails(self):
        def probe(_pid, _signal):
            raise PermissionError()
        apps = [{"bundleIdentifier": "be.bram.vikingbar", "processIdentifier": 12345}]
        self.assertEqual(PROOF.UI.UI.live_bundle_processes(apps, "be.bram.vikingbar", probe), [12345])
        with self.assertRaises(PROOF.UIFailure):
            PROOF.UI.UI.live_bundle_processes([{"bundle_id": "be.bram.vikingbar"}], "be.bram.vikingbar", probe)


if __name__ == "__main__":
    unittest.main()
