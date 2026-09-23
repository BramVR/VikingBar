#!/usr/bin/env python3
"""Read-only Telenet proof with redacted output."""

from __future__ import annotations

from copy import copy
from dataclasses import asdict, dataclass
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
from enum import Enum
from http.cookiejar import CookieJar
import json
import re
import sys
import time
from urllib import error, parse, request

API = "https://api.prd.telenet.be"
SECURE = "https://secure.telenet.be"
AUTHORIZATION = (API + "/ocapi/login/authorization/telenet_be?lang=nl&style_hint=care"
                 "&targetUrl=https%3A%2F%2Fwww2.telenet.be%2Fresidential%2Fnl%2Fmytelenet%2F")
MAX_BODY = 262_144
MAX_REQUESTS = 64
MAX_SERVICES = 8
MAX_SECONDS = 150
AUTH_QUERY = {"client_id", "code_challenge", "code_challenge_method", "nonce",
              "redirect_uri", "response_type", "scope", "state"}
SAFE_ID = re.compile(r"[A-Za-z0-9_-]{1,100}\Z")
SAFE_DATE = re.compile(r"\d{4}-\d{2}-\d{2}\Z")


class Failure(str, Enum):
    POLICY = "request-policy"
    TRANSPORT = "transport-failed"
    RATE_LIMIT = "rate-limited"
    AUTH = "authentication-failed"
    MFA = "interactive-auth-required"
    SCHEMA = "provider-schema-unknown"
    BACKEND = "backend-unsupported"
    DISCOVERY = "service-discovery-failed"
    USAGE = "usage-read-failed"
    MISMATCH = "usage-comparison-failed"
    BOUND = "proof-bound-exceeded"


class ProofError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code.value)


class Stage(str, Enum):
    START = "start"
    AUTHORIZATION = "authorization"
    AUTH_STATE = "auth-state"
    INTROSPECT = "introspect"
    IDENTIFY = "identify"
    CHALLENGE = "challenge"
    PASSWORD = "password"
    CALLBACK = "callback"
    DISCOVERY = "discovery"
    INITIAL_READ = "initial-read"
    SESSION_REUSE = "session-reuse"
    RENEWED_READ = "renewed-read"
    COMPLETE = "complete"


class Coverage(str, Enum):
    UNVERIFIED = "unverified"
    ABSENT = "absent"
    VERIFIED = "verified"


class Backend(str, Enum):
    UNKNOWN = "unknown"
    V2 = "product-v2"


@dataclass(frozen=True, repr=False)
class Credentials:
    username: str
    password: str


@dataclass(frozen=True, repr=False)
class Service:
    kind: str
    private_id: str
    start: str = ""
    end: str = ""


@dataclass(frozen=True, repr=False)
class Measure:
    category: str
    consumed: Decimal
    unit: str
    allowance: str
    total: Decimal | None
    remaining: Decimal | None


@dataclass(frozen=True, repr=False)
class Usage:
    service: Service
    period_start: str | None
    period_end: str
    updated_at: str | None
    measures: tuple[Measure, ...]


@dataclass(frozen=True)
class Receipt:
    schema_version: int = 1
    check: str = "telenet-auth-usage"
    passed: bool = False
    stage: str = Stage.START.value
    backend: str = Backend.UNKNOWN.value
    home: str = Coverage.UNVERIFIED.value
    mobile: str = Coverage.UNVERIFIED.value
    service_count: int = 0
    session_reused: bool = False
    renewed_reads: bool = False
    usage_matches: bool = False
    expiry_evidence: str = "unobserved"
    renewal_evidence: str = "unobserved"
    mfa_evidence: str = "unobserved"
    failure: str | None = None


def _identifier(value):
    if not isinstance(value, str) or not SAFE_ID.fullmatch(value):
        raise ProofError(Failure.SCHEMA)
    return value


def _day(value):
    if not isinstance(value, str) or not SAFE_DATE.fullmatch(value):
        raise ProofError(Failure.SCHEMA)
    try:
        date.fromisoformat(value)
    except ValueError:
        raise ProofError(Failure.SCHEMA) from None
    return value


def _timestamp(value):
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > 40:
        raise ProofError(Failure.SCHEMA)
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise ProofError(Failure.SCHEMA) from None
    return value


def _quantity(value):
    if isinstance(value, bool) or not isinstance(value, (str, int, float, Decimal)):
        raise ProofError(Failure.SCHEMA)
    try:
        amount = Decimal(str(value))
    except InvalidOperation:
        raise ProofError(Failure.SCHEMA) from None
    if not amount.is_finite() or amount < 0:
        raise ProofError(Failure.SCHEMA)
    return amount


def _object(value):
    if not isinstance(value, dict):
        raise ProofError(Failure.SCHEMA)
    return value


def _array(value):
    if not isinstance(value, list):
        raise ProofError(Failure.SCHEMA)
    return value


def _route(method, url, body):
    if not isinstance(url, str) or len(url) > 16_384:
        raise ProofError(Failure.POLICY)
    parts = parse.urlsplit(url)
    if parts.scheme != "https" or parts.username or parts.password or parts.port or parts.fragment:
        raise ProofError(Failure.POLICY)
    host, path = parts.hostname, parts.path
    if host not in {"api.prd.telenet.be", "secure.telenet.be"} or parts.netloc != host:
        raise ProofError(Failure.POLICY)
    try:
        query = parse.parse_qs(parts.query, keep_blank_values=True, strict_parsing=True)
    except ValueError:
        raise ProofError(Failure.POLICY) from None
    if any(len(values) != 1 or len(values[0]) > 8192 for values in query.values()):
        raise ProofError(Failure.POLICY)
    if method == "POST":
        fields = {
            "/idp/idx/introspect": {"stateToken"},
            "/idp/idx/identify": {"identifier", "stateHandle"},
            "/idp/idx/challenge": {"authenticator", "stateHandle"},
            "/idp/idx/challenge/answer": {"credentials", "stateHandle"},
            "/api/v1/internal/device/nonce": set(),
        }
        if host != "secure.telenet.be" or path not in fields or query or not isinstance(body, dict):
            raise ProofError(Failure.POLICY)
        if set(body) != fields[path]:
            raise ProofError(Failure.POLICY)
        if path == "/idp/idx/challenge" and set(_object(body["authenticator"])) != {"id"}:
            raise ProofError(Failure.POLICY)
        if path == "/idp/idx/challenge/answer" and set(_object(body["credentials"])) != {"passcode"}:
            raise ProofError(Failure.POLICY)
        leaves = [body["authenticator"]["id"]] if path == "/idp/idx/challenge" else []
        if path == "/idp/idx/challenge/answer":
            leaves.append(body["credentials"]["passcode"])
        leaves.extend(value for value in body.values() if not isinstance(value, dict))
        for value in leaves:
            if not isinstance(value, str) or not value or len(value) > 8192:
                raise ProofError(Failure.POLICY)
        return
    if method != "GET" or body is not None:
        raise ProofError(Failure.POLICY)
    if host == "secure.telenet.be":
        if (path == "/oauth2/default/v1/authorize" and set(query) == AUTH_QUERY
                and query["redirect_uri"] == [API + "/ocapi/login/callback/telenet_be"]
                and query["response_type"] == ["code"]
                and query["scope"] == ["openid profile licenses telenet.scopes offline_access"]
                and query["code_challenge_method"] == ["S256"]):
            return
        if path == "/login/token/redirect" and set(query) == {"stateToken"}:
            return
        if path == "/auth/services/devicefingerprint" and not query:
            return
        raise ProofError(Failure.POLICY)
    fixed = {
        "/ocapi/oauth/userdetails": {},
        "/ocapi/login/authorization/telenet_be": {
            "lang": ["nl"], "style_hint": ["care"],
            "targetUrl": ["https://www2.telenet.be/residential/nl/mytelenet/"]},
        "/ocapi/public/api/product-service/v1/product-subscriptions": {"producttypes": ["PLAN"]},
        "/ocapi/public/api/customer-web-billing-mobile-line-selector/v1/mobile-lines": {},
    }
    if path in fixed and query == fixed[path]:
        return
    if path == "/ocapi/login/callback/telenet_be" and set(query) == {"code", "state"}:
        return
    match = re.fullmatch(r"/ocapi/public/api/billing-service/v1/account/products/([^/]+)/billcycle-details", path)
    if match and SAFE_ID.fullmatch(match[1]) and query == {"producttype": ["internet"], "count": ["3"]}:
        return
    match = re.fullmatch(r"/ocapi/public/api/product-service/v1/products/internet/([^/]+)/usage", path)
    if match and SAFE_ID.fullmatch(match[1]) and set(query) == {"fromDate", "toDate"}:
        start, end = _day(query["fromDate"][0]), _day(query["toDate"][0])
        if start <= end:
            return
    match = re.fullmatch(r"/ocapi/public/api/customer-web-billing-mobile-usage/v1/mobile-lines/([^/]+)/usage", path)
    if match and SAFE_ID.fullmatch(match[1]) and not query:
        return
    raise ProofError(Failure.POLICY)


@dataclass(frozen=True, repr=False)
class Response:
    status: int
    headers: dict[str, str]
    body: bytes


class _NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Exchange:
    def __init__(self, cookies=None, budget=None):
        self.cookies = CookieJar()
        if cookies:
            for cookie in cookies:
                self.cookies.set_cookie(copy(cookie))
        self.opener = request.build_opener(request.ProxyHandler({}), request.HTTPCookieProcessor(self.cookies),
                                           _NoRedirect())
        self.budget = budget if budget is not None else [0, time.monotonic()]

    def send(self, method, url, body=None):
        _route(method, url, body)
        self.budget[0] += 1
        if self.budget[0] > MAX_REQUESTS or time.monotonic() - self.budget[1] > MAX_SECONDS:
            raise ProofError(Failure.BOUND)
        data = json.dumps(body, separators=(",", ":")).encode() if body is not None else None
        headers = {"User-Agent": "VikingBar-Telenet-Proof/1", "Accept": "application/json,text/html",
                   "Origin": "https://www2.telenet.be", "Referer": "https://www2.telenet.be",
                   "X-Requested-With": "XMLHttpRequest",
                   "x-alt-referer": "https://www2.telenet.be/residential/nl/mijn-telenet/"}
        if data is not None:
            headers["Content-Type"] = "application/json;charset=UTF-8"
        req = request.Request(url, data=data, headers=headers, method=method)
        try:
            try:
                response = self.opener.open(req, timeout=12)
            except error.HTTPError as caught:
                response = caught
            with response:
                payload = response.read(MAX_BODY + 1)
                if len(payload) > MAX_BODY:
                    raise ProofError(Failure.BOUND)
                return Response(response.status, {key.lower(): value for key, value in response.headers.items()}, payload)
        except ProofError:
            raise
        except (OSError, ValueError):
            raise ProofError(Failure.TRANSPORT) from None

    def renewed(self):
        return Exchange(self.cookies, self.budget)


def _json(response):
    if response.status == 429:
        raise ProofError(Failure.RATE_LIMIT)
    if response.status in {401, 403}:
        raise ProofError(Failure.AUTH)
    if response.status != 200:
        raise ProofError(Failure.TRANSPORT)
    try:
        return json.loads(response.body)
    except (ValueError, UnicodeDecodeError):
        raise ProofError(Failure.SCHEMA) from None


def _send_json(exchange, method, url, body=None):
    return _json(exchange.send(method, url, body))


def _state(value):
    text = _object(value).get("stateHandle")
    if not isinstance(text, str) or not 1 <= len(text) <= 8192:
        raise ProofError(Failure.SCHEMA)
    return text


def _login(exchange, credentials):
    exchange.stage = Stage.AUTHORIZATION
    first = exchange.send("GET", API + "/ocapi/oauth/userdetails")
    if first.status != 401:
        raise ProofError(Failure.AUTH)
    if first.body.count(b",") != 1 or len(first.body) > 4096:
        raise ProofError(Failure.SCHEMA)
    auth = exchange.send("GET", AUTHORIZATION)
    if auth.status not in {302, 303}:
        raise ProofError(Failure.AUTH)
    location = auth.headers.get("location", "")
    _route("GET", location, None)
    if parse.urlsplit(location).path != "/oauth2/default/v1/authorize":
        raise ProofError(Failure.POLICY)
    state = parse.parse_qs(parse.urlsplit(location).query)["state"][0]
    exchange.stage = Stage.AUTH_STATE
    page = exchange.send("GET", location)
    if page.status != 200:
        raise ProofError(Failure.AUTH)
    match = re.search(rb'"stateToken"\s*:\s*"((?:[^"\\]|\\.){1,8192})"', page.body)
    if not match:
        raise ProofError(Failure.SCHEMA)
    try:
        # The login page embeds JavaScript hex escapes, which JSON does not accept.
        escaped = re.sub(rb"\\x([0-9a-fA-F]{2})", rb"\\u00\1", match[1])
        token = json.loads(b'"' + escaped + b'"')
    except (ValueError, UnicodeDecodeError):
        raise ProofError(Failure.SCHEMA) from None
    exchange.stage = Stage.INTROSPECT
    handle = _state(_send_json(exchange, "POST", SECURE + "/idp/idx/introspect", {"stateToken": token}))
    for method, url, body in (("GET", SECURE + "/auth/services/devicefingerprint", None),
                              ("POST", SECURE + "/api/v1/internal/device/nonce", {})):
        response = exchange.send(method, url, body)
        if response.status == 429:
            raise ProofError(Failure.RATE_LIMIT)
        if response.status != 200:
            raise ProofError(Failure.AUTH)
    exchange.stage = Stage.IDENTIFY
    identified = _object(_send_json(exchange, "POST", SECURE + "/idp/idx/identify",
                                    {"identifier": credentials.username, "stateHandle": handle}))
    handle = _state(identified)
    authenticators = _array(_object(identified.get("authenticators")).get("value"))
    passwords = [entry.get("id") for entry in authenticators if isinstance(entry, dict)
                 and entry.get("type") == "password"]
    if len(passwords) != 1 or not isinstance(passwords[0], str):
        raise ProofError(Failure.MFA)
    exchange.stage = Stage.CHALLENGE
    challenged = _object(_send_json(exchange, "POST", SECURE + "/idp/idx/challenge",
                                    {"authenticator": {"id": passwords[0]}, "stateHandle": handle}))
    handle = _state(challenged)
    exchange.stage = Stage.PASSWORD
    answer = _object(_send_json(exchange, "POST", SECURE + "/idp/idx/challenge/answer",
                                {"credentials": {"passcode": credentials.password}, "stateHandle": handle}))
    if "success" not in answer:
        raise ProofError(Failure.MFA)
    success = _object(answer["success"]).get("href")
    if not isinstance(success, str):
        raise ProofError(Failure.SCHEMA)
    exchange.stage = Stage.CALLBACK
    _route("GET", success, None)
    if parse.urlsplit(success).path not in {"/login/token/redirect", "/ocapi/login/callback/telenet_be"}:
        raise ProofError(Failure.POLICY)
    current = success
    callback_seen = False
    for _ in range(3):
        if parse.urlsplit(current).path == "/ocapi/login/callback/telenet_be":
            if parse.parse_qs(parse.urlsplit(current).query).get("state") != [state]:
                raise ProofError(Failure.POLICY)
        response = exchange.send("GET", current)
        if parse.urlsplit(current).path == "/ocapi/login/callback/telenet_be":
            callback_seen = True
            if response.status in {200, 302, 303}:
                break
            raise ProofError(Failure.AUTH)
        if response.status not in {302, 303}:
            raise ProofError(Failure.AUTH)
        current = response.headers.get("location", "")
        _route("GET", current, None)
        if parse.urlsplit(current).path != "/ocapi/login/callback/telenet_be":
            raise ProofError(Failure.POLICY)
    if not callback_seen:
        raise ProofError(Failure.AUTH)
    if not _object(_send_json(exchange, "GET", API + "/ocapi/oauth/userdetails")):
        raise ProofError(Failure.SCHEMA)


def _services(exchange):
    plan = _send_json(exchange, "GET", API + "/ocapi/public/api/product-service/v1/product-subscriptions?producttypes=PLAN")
    if not isinstance(plan, list):
        raise ProofError(Failure.BACKEND)
    result = []
    for product in plan:
        product = _object(product)
        kind = product.get("productType", "").lower()
        if kind == "bundle":
            for child in _array(product.get("products")):
                child = _object(child)
                if child.get("productType", "").lower() == "internet":
                    result.append(Service("home", _identifier(child.get("identifier"))))
        elif kind == "internet":
            result.append(Service("home", _identifier(product.get("identifier"))))
    lines = _array(_send_json(exchange, "GET", API + "/ocapi/public/api/customer-web-billing-mobile-line-selector/v1/mobile-lines"))
    for line in lines:
        result.append(Service("mobile", _identifier(_object(line).get("msisdn"))))
    if not result or len(result) > MAX_SERVICES or len(set((s.kind, s.private_id) for s in result)) != len(result):
        raise ProofError(Failure.DISCOVERY)
    return tuple(result)


def _measure(category, consumed, unit, line_type, total=None, remaining=None):
    if unit not in {"B", "KB", "MB", "GB", "TB", "minutes", "SMS", "units"}:
        raise ProofError(Failure.SCHEMA)
    if line_type not in {"CAP", "FUP", "TURBO", "UNLIMITED", "UNKNOWN"}:
        raise ProofError(Failure.SCHEMA)
    amount = _quantity(consumed)
    maximum = None if total is None else _quantity(total)
    left = None if remaining is None else _quantity(remaining)
    if line_type == "CAP" and maximum is None:
        raise ProofError(Failure.SCHEMA)
    return Measure(category, amount, unit, line_type, maximum, left)


def decode_usage(payload, service):
    root = _object(json.loads(payload, parse_float=Decimal))
    if service.kind == "home":
        internet = _object(root.get("internet"))
        total = _object(internet.get("totalUsage"))
        allocated = _object(internet.get("allocatedUsage"))
        if total.get("units") is None or allocated.get("units") is None:
            raise ProofError(Failure.SCHEMA)
        category = internet.get("category")
        if category not in {"CAP", "FUP", "TURBO", "UNLIMITED"}:
            raise ProofError(Failure.SCHEMA)
        # The upstream sensor interprets v2 `units` as GB, including its FUP counter.
        return Usage(service, service.start, service.end, _timestamp(total.get("lastUsageDate")),
                     (_measure("DATA", total["units"], "GB", category, allocated["units"]),))
    if root.get("msisdn") != service.private_id:
        raise ProofError(Failure.MISMATCH)
    subscription = _object(_object(root.get("usage")).get("subscription"))
    bars = _array(_object(_object(subscription.get("breakdown")).get("barsSummary")).get("bars"))
    measures = []
    for bar in bars:
        bar = _object(bar)
        category = bar.get("category")
        if category not in {"DATA", "CALL", "SMS"} or category in [m.category for m in measures]:
            raise ProofError(Failure.SCHEMA)
        measures.append(_measure(category, bar.get("consumed"), bar.get("unit"), bar.get("lineType"),
                                 bar.get("total"), bar.get("remaining")))
    if not measures:
        raise ProofError(Failure.SCHEMA)
    period_end = _timestamp(subscription.get("nextBillingDate"))
    if period_end is None:
        raise ProofError(Failure.SCHEMA)
    return Usage(service, None, period_end,
                 _timestamp(subscription.get("lastUpdated")), tuple(measures))


def raw_oracle(payload, normalized):
    data = json.loads(payload, parse_float=Decimal)
    if normalized.service.kind == "home":
        raw = data["internet"]
        return (len(normalized.measures) == 1 and normalized.period_start == normalized.service.start
                and normalized.period_end == normalized.service.end
                and normalized.updated_at == raw["totalUsage"].get("lastUsageDate")
                and normalized.measures[0].consumed == Decimal(str(raw["totalUsage"]["units"]))
                and normalized.measures[0].total == Decimal(str(raw["allocatedUsage"]["units"]))
                and normalized.measures[0].unit == "GB"
                and normalized.measures[0].allowance == raw["category"])
    if data.get("msisdn") != normalized.service.private_id:
        return False
    raw = data["usage"]["subscription"]
    bars = raw["breakdown"]["barsSummary"]["bars"]
    if normalized.period_end != raw.get("nextBillingDate") or normalized.updated_at != raw.get("lastUpdated"):
        return False
    if len(normalized.measures) != len(bars):
        return False
    return all(measure.category == bar["category"] and measure.unit == bar["unit"]
               and measure.allowance == bar["lineType"] and measure.consumed == Decimal(str(bar["consumed"]))
               and measure.total == (None if bar.get("total") is None else Decimal(str(bar["total"])))
               and measure.remaining == (None if bar.get("remaining") is None else Decimal(str(bar["remaining"])))
               for measure, bar in zip(normalized.measures, bars))


def _usage(exchange, service):
    if service.kind == "mobile":
        url = (API + "/ocapi/public/api/customer-web-billing-mobile-usage/v1/mobile-lines/"
               + service.private_id + "/usage")
        return exchange.send("GET", url), service
    cycle_url = (API + "/ocapi/public/api/billing-service/v1/account/products/" + service.private_id
                 + "/billcycle-details?producttype=internet&count=3")
    cycle = _object(_send_json(exchange, "GET", cycle_url))
    periods = _array(cycle.get("billCycles"))
    if not periods:
        raise ProofError(Failure.SCHEMA)
    current = _object(periods[0])
    start, end = _day(current.get("startDate")), _day(current.get("endDate"))
    if start > end:
        raise ProofError(Failure.SCHEMA)
    url = (API + "/ocapi/public/api/product-service/v1/products/internet/" + service.private_id
           + "/usage?" + parse.urlencode({"fromDate": start, "toDate": end}))
    return exchange.send("GET", url), Service("home", service.private_id, start, end)


def _read_all(exchange, services):
    for service in services:
        response, keyed = _usage(exchange, service)
        _json(response)
        payload = response.body
        usage = decode_usage(payload, keyed)
        try:
            matches = raw_oracle(payload, usage)
        except (KeyError, TypeError, ValueError, InvalidOperation):
            matches = False
        if not matches:
            raise ProofError(Failure.MISMATCH)


def prove(credentials, exchange=None, delay=time.sleep):
    stage = Stage.START
    backend = Backend.UNKNOWN
    home = mobile = Coverage.UNVERIFIED
    count = 0
    reused = renewed = matched = False
    failure = None
    try:
        if not isinstance(credentials, Credentials) or not credentials.username or not credentials.password:
            raise ProofError(Failure.AUTH)
        exchange = exchange or Exchange()
        stage = Stage.AUTHORIZATION
        _login(exchange, credentials)
        stage = Stage.DISCOVERY
        services = _services(exchange)
        backend = Backend.V2
        count = len(services)
        stage = Stage.INITIAL_READ
        _read_all(exchange, services)
        stage = Stage.SESSION_REUSE
        delay(5)
        second = exchange.renewed()
        _json(second.send("GET", API + "/ocapi/oauth/userdetails"))
        reused = True
        if {(s.kind, s.private_id) for s in _services(second)} != {(s.kind, s.private_id) for s in services}:
            raise ProofError(Failure.DISCOVERY)
        stage = Stage.RENEWED_READ
        _read_all(second, services)
        renewed = matched = True
        home = Coverage.VERIFIED if any(s.kind == "home" for s in services) else Coverage.ABSENT
        mobile = Coverage.VERIFIED if any(s.kind == "mobile" for s in services) else Coverage.ABSENT
        stage = Stage.COMPLETE
    except ProofError as caught:
        if stage == Stage.AUTHORIZATION:
            stage = getattr(exchange, "stage", stage)
        failure = caught.code.value
    except (KeyError, TypeError, ValueError, UnicodeDecodeError):
        if stage == Stage.AUTHORIZATION:
            stage = getattr(exchange, "stage", stage)
        failure = Failure.SCHEMA.value
    return Receipt(passed=failure is None, stage=stage.value, backend=backend.value,
                   home=home.value, mobile=mobile.value, service_count=count,
                   session_reused=reused, renewed_reads=renewed, usage_matches=matched,
                   mfa_evidence="challenge" if failure == Failure.MFA.value else "unobserved", failure=failure)


def validate_receipt(value):
    if not isinstance(value, dict) or set(value) != set(Receipt.__dataclass_fields__):
        raise ValueError()
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise ValueError()
    if value["check"] != "telenet-auth-usage" or type(value["passed"]) is not bool:
        raise ValueError()
    for key, allowed in {"stage": Stage, "backend": Backend, "home": Coverage, "mobile": Coverage}.items():
        if type(value[key]) is not str or value[key] not in {item.value for item in allowed}:
            raise ValueError()
    for key in ("session_reused", "renewed_reads", "usage_matches"):
        if type(value[key]) is not bool:
            raise ValueError()
    if type(value["service_count"]) is not int or not 0 <= value["service_count"] <= MAX_SERVICES:
        raise ValueError()
    if value["expiry_evidence"] != "unobserved" or value["renewal_evidence"] != "unobserved":
        raise ValueError()
    if value["mfa_evidence"] not in {"unobserved", "challenge"}:
        raise ValueError()
    if value["failure"] is not None and value["failure"] not in {item.value for item in Failure}:
        raise ValueError()
    if value["passed"]:
        if (value["failure"] is not None or value["stage"] != Stage.COMPLETE.value
                or value["backend"] == Backend.UNKNOWN.value or value["service_count"] < 1
                or Coverage.VERIFIED.value not in {value["home"], value["mobile"]}
                or Coverage.UNVERIFIED.value in {value["home"], value["mobile"]}
                or sum(value[key] == Coverage.VERIFIED.value for key in ("home", "mobile")) > value["service_count"]
                or not all(value[key] for key in ("session_reused", "renewed_reads", "usage_matches"))
                or value["mfa_evidence"] != "unobserved"):
            raise ValueError()
    elif value["failure"] is None or value["stage"] == Stage.COMPLETE.value:
        raise ValueError()
    return value


def main():
    try:
        source = json.loads(sys.stdin.buffer.read(8192))
        if not isinstance(source, dict) or set(source) != {"username", "password"}:
            raise ValueError()
        receipt = prove(Credentials(source["username"], source["password"]))
        print(json.dumps(asdict(receipt), sort_keys=True))
        return 0 if receipt.passed else 1
    except Exception:
        print(json.dumps(asdict(Receipt(failure=Failure.SCHEMA.value)), sort_keys=True))
        return 1


if __name__ == "__main__":
    sys.exit(main())
