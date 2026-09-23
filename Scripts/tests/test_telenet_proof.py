"""Synthetic boundary and full-flow tests for the Telenet proof."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
from urllib.parse import urlencode
import sys

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


PROOF = load("telenet_proof_test", "telenet-proof.py")
RUNNER = load("telenet_runner_test", "proof-live.py")
AUTH_URL = PROOF.SECURE + "/oauth2/default/v1/authorize?" + urlencode({
    "client_id": "client", "code_challenge": "challenge", "code_challenge_method": "S256",
    "nonce": "nonce", "redirect_uri": PROOF.API + "/ocapi/login/callback/telenet_be",
    "response_type": "code", "scope": "openid profile licenses telenet.scopes offline_access", "state": "state123",
})
CALLBACK = PROOF.API + "/ocapi/login/callback/telenet_be?code=code123&state=state123"
SUCCESS = PROOF.SECURE + "/login/token/redirect?stateToken=token123"
HOME = "home123"
MOBILE = "32470000000"
CYCLE = (PROOF.API + "/ocapi/public/api/billing-service/v1/account/products/" + HOME
         + "/billcycle-details?producttype=internet&count=3")
HOME_USAGE = (PROOF.API + "/ocapi/public/api/product-service/v1/products/internet/" + HOME
              + "/usage?fromDate=2026-09-01&toDate=2026-09-30")
MOBILE_USAGE = (PROOF.API + "/ocapi/public/api/customer-web-billing-mobile-usage/v1/mobile-lines/"
                + MOBILE + "/usage")
PLAN = PROOF.API + "/ocapi/public/api/product-service/v1/product-subscriptions?producttypes=PLAN"
LINES = PROOF.API + "/ocapi/public/api/customer-web-billing-mobile-line-selector/v1/mobile-lines"
USER = PROOF.API + "/ocapi/oauth/userdetails"
HOME_BODY = {"internet": {"category": "FUP", "totalUsage": {"units": 12.5,
             "lastUsageDate": "2026-09-20T12:00:00Z"}, "allocatedUsage": {"units": 100}}}
MOBILE_BODY = {"msisdn": MOBILE, "usage": {"subscription": {"nextBillingDate": "2026-09-30T00:00:00Z",
               "lastUpdated": "2026-09-20T12:00:00Z", "breakdown": {"barsSummary": {"bars": [
                   {"category": "DATA", "consumed": 2, "unit": "GB", "lineType": "CAP",
                    "total": 10, "remaining": 8}]}}}}}


def row(method, url, body=None, status=200, headers=None):
    payload = body if isinstance(body, bytes) else json.dumps(body).encode()
    return (method, url, PROOF.Response(status, {k.lower(): v for k, v in (headers or {}).items()}, payload))


def trace(home=True, mobile=True):
    steps = [
        row("GET", USER, b"state,nonce", 401),
        row("GET", PROOF.AUTHORIZATION, b"", 302, {"location": AUTH_URL}),
        row("GET", AUTH_URL, b'<html>"stateToken":"token123","helpLinks":[]</html>'),
        row("POST", PROOF.SECURE + "/idp/idx/introspect", {"stateHandle": "handle1"}),
        row("GET", PROOF.SECURE + "/auth/services/devicefingerprint", {}),
        row("POST", PROOF.SECURE + "/api/v1/internal/device/nonce", {}),
        row("POST", PROOF.SECURE + "/idp/idx/identify", {"stateHandle": "handle2",
            "authenticators": {"value": [{"type": "password", "id": "password1"}]}}),
        row("POST", PROOF.SECURE + "/idp/idx/challenge", {"stateHandle": "handle3"}),
        row("POST", PROOF.SECURE + "/idp/idx/challenge/answer", {"success": {"href": SUCCESS}}),
        row("GET", SUCCESS, b"", 302, {"location": CALLBACK}),
        row("GET", CALLBACK, b"", 302, {"location": "https://www2.telenet.be/residential/nl/mytelenet/"}),
        row("GET", USER, {"customerNumber": "private"}),
    ]
    services = []
    if home:
        services.append({"productType": "INTERNET", "identifier": HOME})
    lines = [{"msisdn": MOBILE}] if mobile else []
    for pass_number in (1, 2):
        if pass_number == 2:
            steps.append(row("GET", USER, {"customerNumber": "private"}))
        steps.extend([row("GET", PLAN, services), row("GET", LINES, lines)])
        if home:
            steps.extend([row("GET", CYCLE, {"billCycles": [{"startDate": "2026-09-01",
                            "endDate": "2026-09-30"}]}), row("GET", HOME_USAGE, HOME_BODY)])
        if mobile:
            steps.append(row("GET", MOBILE_USAGE, MOBILE_BODY))
    return steps


class ScriptedExchange:
    def __init__(self, steps, shared=None):
        self.shared = shared or {"steps": steps, "index": 0, "openers": 1}

    def send(self, method, url, body=None):
        PROOF._route(method, url, body)
        index = self.shared["index"]
        expected_method, expected_url, response = self.shared["steps"][index]
        assert (method, url) == (expected_method, expected_url)
        self.shared["index"] += 1
        return response

    def renewed(self):
        self.shared["openers"] += 1
        return ScriptedExchange([], self.shared)


class TelenetProofTests(unittest.TestCase):
    def test_unlimited_home_preserves_reported_category(self):
        body = json.loads(json.dumps(HOME_BODY))
        body["internet"]["category"] = "UNLIMITED"
        service = PROOF.Service("home", HOME, "2026-09-01", "2026-09-30")
        payload = json.dumps(body).encode()
        usage = PROOF.decode_usage(payload, service)
        self.assertEqual(usage.measures[0].allowance, "UNLIMITED")
        self.assertTrue(PROOF.raw_oracle(payload, usage))

    def test_mobile_identity_must_match(self):
        for identity in (None, "32479999999"):
            body = json.loads(json.dumps(MOBILE_BODY))
            body["msisdn"] = identity
            with self.assertRaises(PROOF.ProofError):
                PROOF.decode_usage(json.dumps(body).encode(), PROOF.Service("mobile", MOBILE))

    def test_full_success_two_passes_and_coverage(self):
        exchange = ScriptedExchange(trace())
        delays = []
        receipt = PROOF.prove(PROOF.Credentials("canary-user", "canary-password"), exchange=exchange,
                              delay=delays.append)
        self.assertTrue(receipt.passed, receipt)
        self.assertEqual((receipt.home, receipt.mobile, receipt.service_count), ("verified", "verified", 2))
        self.assertEqual((receipt.session_reused, receipt.renewed_reads, receipt.usage_matches), (True, True, True))
        self.assertEqual((receipt.expiry_evidence, receipt.renewal_evidence), ("unobserved", "unobserved"))
        self.assertEqual(exchange.shared["openers"], 2)
        self.assertEqual(exchange.shared["index"], len(exchange.shared["steps"]))
        self.assertEqual(delays, [5])
        self.assertNotIn("canary", json.dumps(PROOF.asdict(receipt)))
        PROOF.validate_receipt(PROOF.asdict(receipt))

    def test_absent_service_is_explicit(self):
        receipt = PROOF.prove(PROOF.Credentials("user", "password"), ScriptedExchange(trace(mobile=False)),
                              delay=lambda _: None)
        self.assertTrue(receipt.passed)
        self.assertEqual((receipt.home, receipt.mobile), ("verified", "absent"))

    def test_javascript_hex_escapes_in_login_state(self):
        steps = trace()
        steps[2] = row("GET", AUTH_URL, rb'<html>"stateToken":"token\x31\x32\x33"</html>')

        class TokenExchange(ScriptedExchange):
            def send(inner, method, url, body=None):
                if url.endswith("/idp/idx/introspect"):
                    self.assertEqual(body, {"stateToken": "token123"})
                return super().send(method, url, body)

        receipt = PROOF.prove(PROOF.Credentials("user", "password"), TokenExchange(steps), delay=lambda _: None)
        self.assertTrue(receipt.passed, receipt)

    def test_discovered_service_failure_is_not_absence(self):
        steps = trace()
        position = next(i for i, step in enumerate(steps) if step[1] == MOBILE_USAGE)
        steps[position] = row("GET", MOBILE_USAGE, {}, 429)
        receipt = PROOF.prove(PROOF.Credentials("user", "password"), ScriptedExchange(steps), delay=lambda _: None)
        self.assertFalse(receipt.passed)
        self.assertEqual((receipt.stage, receipt.failure, receipt.mobile),
                         ("initial-read", "rate-limited", "unverified"))

    def test_mfa_and_malformed_provider_data_fail_closed(self):
        steps = trace()
        steps[6] = row("POST", PROOF.SECURE + "/idp/idx/identify",
                       {"stateHandle": "handle2", "authenticators": {"value": [{"type": "otp", "id": "one"}]}})
        receipt = PROOF.prove(PROOF.Credentials("user", "password"), ScriptedExchange(steps))
        self.assertEqual((receipt.failure, receipt.mfa_evidence), ("interactive-auth-required", "challenge"))
        steps = trace()
        index = next(i for i, step in enumerate(steps) if step[1] == HOME_USAGE)
        steps[index] = row("GET", HOME_USAGE, {"internet": {"category": "WRONG"}})
        receipt = PROOF.prove(PROOF.Credentials("user", "password"), ScriptedExchange(steps))
        self.assertEqual(receipt.failure, "provider-schema-unknown")

    def test_policy_rejects_writes_open_redirect_and_bad_fields(self):
        cases = [
            ("PATCH", PROOF.API + "/ocapi/public/api/resource-service/v1/modems/a/wireless-status", {}),
            ("POST", PROOF.SECURE + "/idp/idx/challenge/answer", {"credentials": {"passcode": "x"},
                                                                  "stateHandle": "h", "admin": True}),
            ("GET", "https://evil.example/ocapi/oauth/userdetails", None),
            ("GET", PROOF.API + "/ocapi/public/api/product-service/v1/products/internet/x/usage"
             "?fromDate=2026-09-01&toDate=2026-10-01&write=true", None),
            ("GET", PROOF.API + "/ocapi/public/api/product-service/v1/products/internet/%2Fadmin/usage"
             "?fromDate=2026-09-01&toDate=2026-09-30", None),
        ]
        for method, url, body in cases:
            with self.subTest(url=url), self.assertRaises(PROOF.ProofError):
                PROOF._route(method, url, body)

    def test_redirect_and_callback_state_rejected_before_send(self):
        steps = trace()
        steps[1] = row("GET", PROOF.AUTHORIZATION, b"", 302, {"location": "https://evil.example/"})
        exchange = ScriptedExchange(steps)
        receipt = PROOF.prove(PROOF.Credentials("user", "password"), exchange)
        self.assertEqual(receipt.failure, "request-policy")
        self.assertEqual(exchange.shared["index"], 2)
        steps = trace()
        steps[9] = row("GET", SUCCESS, b"", 302, {"location": CALLBACK.replace("state123", "bad")})
        exchange = ScriptedExchange(steps)
        receipt = PROOF.prove(PROOF.Credentials("user", "password"), exchange)
        self.assertEqual(receipt.failure, "request-policy")
        self.assertEqual(exchange.shared["index"], 10)

    def test_receipt_rejects_unknown_fields_and_fake_success(self):
        receipt = PROOF.asdict(PROOF.Receipt())
        receipt["passed"] = True
        with self.assertRaises(ValueError):
            PROOF.validate_receipt(receipt)
        receipt = PROOF.asdict(PROOF.Receipt(failure="transport-failed"))
        receipt["private_id"] = MOBILE
        with self.assertRaises(ValueError):
            PROOF.validate_receipt(receipt)

    def test_wrapper_single_read_and_minimal_child_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            reference = Path(directory) / "reference.json"
            reference.write_text(json.dumps({"vault": "Codex Automation", "item_id": "example-telenet-login",
                                             "fields": ["username", "password"]}))
            environment = {"TMUX": "named", "BRAM_OP_SERVICE_ACCOUNT_TOKEN": "service-canary",
                           "VIKINGBAR_TELENET_CREDENTIAL_REFERENCE": str(reference),
                           "PATH": "/synthetic/bin", "DYLD_LIBRARY_PATH": "bad", "SECRET": "bad"}
            calls = []
            success = PROOF.asdict(PROOF.Receipt(passed=True, stage="complete", backend="product-v2",
                home="verified", mobile="absent", service_count=1, session_reused=True,
                renewed_reads=True, usage_matches=True))

            def execute(argv, **kwargs):
                calls.append((argv, kwargs))
                if len(calls) == 1:
                    return SimpleNamespace(returncode=0, stdout=json.dumps({"fields": [
                        {"label": "username", "value": "user-canary"},
                        {"label": "password", "value": "pass-canary"}]}).encode())
                return SimpleNamespace(returncode=0, stdout=json.dumps(success).encode())

            with patch.object(RUNNER.shutil, "which", return_value="/synthetic/bin/op"):
                self.assertEqual(RUNNER.run("telenet-auth-usage", environment, execute), success)
            self.assertEqual(len(calls), 2)
            self.assertEqual(calls[0][0][2], "get")
            self.assertEqual(calls[0][1]["env"]["OP_SERVICE_ACCOUNT_TOKEN"], "service-canary")
            self.assertEqual(calls[1][1]["env"], {"PATH": "/synthetic/bin"})
            self.assertEqual(json.loads(calls[1][1]["input"]),
                             {"username": "user-canary", "password": "pass-canary"})
            self.assertNotIn("pass-canary", json.dumps(success))


if __name__ == "__main__":
    unittest.main()
