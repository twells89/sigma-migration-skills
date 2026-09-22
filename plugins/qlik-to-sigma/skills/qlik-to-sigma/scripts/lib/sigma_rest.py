"""Sigma REST API wrapper with automatic 401 retry + token refresh.

Python twin of sigma_rest.rb (P1 runtime-shrink: Ruby -> Python). Stdlib only
(urllib) — no third-party deps, matching the repo's "no Gemfile / no pip install"
contract.

WHAT ACTUALLY ENFORCES PARITY (corrected, issue #753). This docstring used to
claim "byte-for-byte behaviour parity ... enforced by test_sigma_rest.py and the
cross-impl parity harness". There is no cross-impl parity harness — the phrase
appeared nowhere but in this file and tableau_rest.py — and test_sigma_rest.py
never invokes ruby; it hand-encodes the Ruby module's observable behaviour in
Python. Two real guards exist:
  * tools/lint-twin-parity.rb — every public name in the .rb has a counterpart
    here (API surface, not behaviour).
  * test_sigma_rest.py — this module's behaviour against hand-written expectations.
Behavioural equivalence is NOT machine-checked. Treat a change to either twin as
a change to both.

DELIBERATE NON-PORT: `Sigma.list_entries` (sigma_rest.rb) has no twin here. Its
`nextPage`/`page` pagination is documented as WRONG for the columns endpoints,
which use nextPageToken/pageToken — see discover-columns.rb and
discover-warehouse-columns.rb, which hand-roll the loop for exactly that reason.
Port the endpoint-correct loop, not this function. Recorded in ALLOWED in
tools/lint-twin-parity.rb.

Sigma OAuth bearer tokens expire after ~1 hour; long runs outlive a single
token. This module provides:
  - refresh_token()        — re-do the client_credentials exchange, cache token
  - auth_token()           — age-aware: re-mints automatically when the token
                             is older than TOKEN_TTL_SECONDS
  - request(method, path)  — catches 401, refreshes once, retries

Token-freshness semantics (field lesson: sessions repeatedly hit 401s at
~+25min-past-expiry because auth_token kept returning the stale env token):
  - A token minted by THIS process carries a minted-at stamp; when it ages past
    TOKEN_TTL_SECONDS (50 min), auth_token re-mints proactively.
  - The mint time is also surfaced as SIGMA_TOKEN_MINTED_AT (iso8601) so child
    processes inherit the token's AGE along with the token itself.
  - A token loaded from <WORK>/auth.json is aged by the file's mtime
    (get_token.py writes it at mint time, so mtime == mint time).
  - A bare env SIGMA_API_TOKEN with no known age is honored as-is
    (age-unknown) — the request helper's 401 handler re-mints ONCE and
    retries, then fails loudly.

Required env: SIGMA_BASE_URL, SIGMA_CLIENT_ID, SIGMA_CLIENT_SECRET.
Optional env: SIGMA_API_TOKEN (initial token; refreshed on demand).

Usage:
    import sigma_rest
    wb = sigma_rest.request("get", f"/v2/workbooks/{id}")
    sigma_rest.request("post", "/v2/workbooks/spec", body=json.dumps(spec))

All methods return parsed dict/list (or raw bytes for binary endpoints).
"""

import base64
import datetime as _dt
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

NEUTRAL_ENV = os.path.expanduser("~/.sigma-migration/env")
_NEUTRAL_LINE = re.compile(r"\A\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)\Z")

# Sigma bearer tokens live ~60 minutes. Any token older than this is treated
# as stale and re-minted proactively (50 min leaves a safety margin), so long
# phases stop tripping over mid-run 401s from a token that quietly expired.
TOKEN_TTL_SECONDS = 50 * 60


class SigmaError(Exception):
    pass


class SigmaAuthError(SigmaError):
    pass


# --- module state (mirrors the Ruby class ivars) ---------------------------
_token_mutex = threading.Lock()
_token_override = None
_minted_at = None  # epoch seconds when THIS process minted the current token
_refresh_inflight = False


def _iso_z(epoch):
    """Epoch seconds -> UTC iso8601 with Z suffix (matches Ruby's utc.iso8601)."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def _parse_iso_epoch(ts):
    """iso8601 string -> epoch seconds, or None when unparseable."""
    try:
        return _dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _load_neutral_env(env=None):
    """Agent-neutral credential bootstrap. If SIGMA_CLIENT_ID is absent, load
    creds from ~/.sigma-migration/env (written by setup.rb). Existing env always
    wins (mirrors Ruby's `ENV[key] ||= raw` + the `.nil?` — not empty — guard)."""
    env = os.environ if env is None else env
    if "SIGMA_CLIENT_ID" in env or not os.path.exists(NEUTRAL_ENV):
        return
    with open(NEUTRAL_ENV, encoding="utf-8") as fh:
        for line in fh:
            m = _NEUTRAL_LINE.match(line.rstrip("\n"))
            if not m:
                continue
            key, raw = m.group(1), m.group(2).strip()
            if len(raw) >= 2 and (
                (raw.startswith("'") and raw.endswith("'"))
                or (raw.startswith('"') and raw.endswith('"'))
            ):
                raw = raw[1:-1]
            env.setdefault(key, raw)


def _load_auth_json(env=None, cwd=None):
    """File-based token handoff (shell-neutral). get_token.py writes
    <WORK>/auth.json = {"SIGMA_API_TOKEN": ..., "SIGMA_BASE_URL": ...}; read it
    when SIGMA_API_TOKEN is absent. Precedence: explicit env ALWAYS wins ->
    auth.json -> client-credential self-mint. A corrupt/BOM'd file must never
    wedge the run."""
    env = os.environ if env is None else env
    if "SIGMA_API_TOKEN" in env:
        return
    cwd = os.getcwd() if cwd is None else cwd
    candidates = [d for d in (env.get("SIGMA_WORKDIR"), cwd) if d]
    for d in candidates:
        p = os.path.join(d, "auth.json")
        if not os.path.exists(p):
            continue
        try:
            # utf-8-sig strips a UTF-8 BOM if present (Windows PowerShell writes one).
            with open(p, encoding="utf-8-sig") as fh:
                auth = json.load(fh)
        except (OSError, ValueError):
            return  # fall through to self-mint
        if auth.get("SIGMA_API_TOKEN"):
            env.setdefault("SIGMA_API_TOKEN", auth["SIGMA_API_TOKEN"])
            # get_token.py writes auth.json at mint time, so the file's mtime
            # IS the token's mint time — record it so auth_token can age the
            # token out proactively instead of discovering staleness via a
            # mid-phase 401.
            try:
                env.setdefault("SIGMA_TOKEN_MINTED_AT", _iso_z(os.path.getmtime(p)))
            except OSError:
                pass
        if auth.get("SIGMA_BASE_URL"):
            env.setdefault("SIGMA_BASE_URL", auth["SIGMA_BASE_URL"])
        return


def bootstrap_credentials(env=None, cwd=None):
    """Run both credential-bootstrap steps. Called at import; tests call it
    explicitly after arranging env + a temp cwd."""
    _load_neutral_env(env)
    _load_auth_json(env, cwd)


def base_url():
    v = os.environ.get("SIGMA_BASE_URL")
    if not v:
        raise SigmaError("SIGMA_BASE_URL not set")
    return v


def validate_base_url(base):
    """Security (A2): only transmit Sigma credentials to an https://
    sigmacomputing.com host. A poisoned SIGMA_BASE_URL would otherwise
    exfiltrate the client id/secret. Opt out (self-hosted/dev) with
    SIGMA_ALLOW_INSECURE_BASE_URL=1 (loud warning)."""
    if os.environ.get("SIGMA_ALLOW_INSECURE_BASE_URL") == "1":
        print(f"WARNING: SIGMA_ALLOW_INSECURE_BASE_URL=1 — skipping SIGMA_BASE_URL validation ({base})", file=sys.stderr)
        return
    p = urllib.parse.urlparse(base or "")
    host = (p.hostname or "").lower()
    if p.scheme != "https":
        raise SystemExit(f"FATAL: SIGMA_BASE_URL must use https:// (got '{base}') — refusing to send Sigma credentials.")
    if not (host == "sigmacomputing.com" or host.endswith(".sigmacomputing.com")):
        raise SystemExit(f"FATAL: SIGMA_BASE_URL host '{host}' is not a sigmacomputing.com host — refusing to send Sigma credentials. Set SIGMA_ALLOW_INSECURE_BASE_URL=1 to override (self-hosted/dev).")


def token_minted_at():
    """Epoch seconds when the current token was minted, if known. The in-memory
    stamp (set by refresh_token in this process) wins; else SIGMA_TOKEN_MINTED_AT
    (iso8601, set by a parent process's mint or by the auth.json bootstrap from
    mtime). None = age unknown."""
    with _token_mutex:
        m = _minted_at
    if m:
        return m
    ts = os.environ.get("SIGMA_TOKEN_MINTED_AT")
    if not ts:
        return None
    return _parse_iso_epoch(ts)


def _token_stale():
    minted = token_minted_at()
    return minted is not None and (time.time() - minted) > TOKEN_TTL_SECONDS


def auth_token():
    """Return a token that is safe to use RIGHT NOW.
      - No token anywhere -> mint one.
      - Known mint time (this process minted it, a parent surfaced
        SIGMA_TOKEN_MINTED_AT, or auth.json's mtime) and age > TTL -> re-mint
        (requires SIGMA_CLIENT_ID; without creds the stale token is returned
        and the 401 path surfaces the failure loudly).
      - Age unknown (bare env SIGMA_API_TOKEN) -> honored as-is; the request
        helper's 401 handler re-mints once and retries."""
    with _token_mutex:
        tok = _token_override
    tok = tok or os.environ.get("SIGMA_API_TOKEN")
    if not tok:
        return refresh_token()
    if _token_stale() and os.environ.get("SIGMA_CLIENT_ID"):
        return refresh_token()
    return tok


class _Resp:
    __slots__ = ("status", "body", "reason")

    def __init__(self, status, body, reason=""):
        self.status = status
        self.body = body if isinstance(body, (bytes, bytearray)) else str(body).encode()
        self.reason = reason


def _ssl_context():
    """TLS trust resolution (P1.4). Stock macOS/homebrew Python urllib often
    fails CERTIFICATE_VERIFY_FAILED where curl/Ruby succeed. Prefer the OS trust
    store (truststore), then certifi, then the stock verified context. NEVER
    silently downgrades: an unverified context is used ONLY when
    SIGMA_INSECURE_TLS is explicitly set, and it logs loudly."""
    if os.environ.get("SIGMA_INSECURE_TLS"):
        print("WARNING: SIGMA_INSECURE_TLS set — TLS certificate verification is "
              "DISABLED for Sigma requests. Do not use in production.", file=sys.stderr)
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    try:
        import truststore  # OS trust store; the faithful match for curl/Ruby reachability
        return truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    except Exception:
        pass
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        pass
    return ssl.create_default_context()


def _send(method, url, headers, body, timeout):
    """Low-level HTTP seam (tests monkeypatch this). Returns _Resp with a numeric
    status even for 4xx/5xx (urllib raises HTTPError on those — we normalise)."""
    data = body.encode() if isinstance(body, str) else body
    req = urllib.request.Request(url, data=data, method=method.upper())
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_ssl_context()) as resp:
            return _Resp(resp.status, resp.read(), getattr(resp, "reason", ""))
    except urllib.error.HTTPError as e:
        return _Resp(e.code, e.read(), e.reason)


def refresh_token():
    """Re-do the OAuth client_credentials exchange and cache the new token.
    Single-flight: a re-entrant call while a refresh is in progress returns the
    current override rather than launching a second exchange."""
    global _refresh_inflight, _token_override, _minted_at
    with _token_mutex:
        if _refresh_inflight:
            return _token_override
        _refresh_inflight = True
    try:
        cid = os.environ.get("SIGMA_CLIENT_ID")
        if not cid:
            raise SigmaAuthError("SIGMA_CLIENT_ID not set")
        secret = os.environ.get("SIGMA_CLIENT_SECRET")
        if not secret:
            raise SigmaAuthError("SIGMA_CLIENT_SECRET not set")
        validate_base_url(base_url())
        creds = base64.b64encode(f"{cid}:{secret}".encode()).decode()
        resp = _send(
            "POST",
            f"{base_url()}/v2/auth/token",
            {
                "Authorization": f"Basic {creds}",
                "Content-Type": "application/x-www-form-urlencoded",
            },
            "grant_type=client_credentials",
            30,
        )
        if not (200 <= resp.status < 300):
            raise SigmaAuthError(f"token exchange -> {resp.status} {resp.body.decode(errors='replace')}")
        tok = (json.loads(resp.body or b"{}") or {}).get("access_token")
        if not tok:
            raise SigmaAuthError(f"token exchange returned no access_token: {resp.body.decode(errors='replace')}")
        now = time.time()
        with _token_mutex:
            _token_override = tok
            _minted_at = now
        # Surface the refreshed token — and its mint time, so child processes
        # inherit the token's AGE and re-mint on schedule too.
        os.environ["SIGMA_API_TOKEN"] = tok
        os.environ["SIGMA_TOKEN_MINTED_AT"] = _iso_z(now)
        return tok
    finally:
        with _token_mutex:
            _refresh_inflight = False


def request(method, path, body=None, content_type="application/json",
            accept="application/json", binary=False):
    url = f"{base_url()}{path}"
    if method.lower() not in ("get", "post", "put", "patch", "delete"):
        raise ValueError(f"unsupported method {method}")
    attempts = 0
    while True:
        attempts += 1
        headers = {"Authorization": f"Bearer {auth_token()}", "Accept": accept}
        if body is not None:
            headers["Content-Type"] = content_type
        resp = _send(method, url, headers, body, 120)

        # Sigma returns 401 when the bearer expires. Refresh once and retry; on a
        # second 401, surface the error. (Only retry when we can self-mint.)
        if resp.status == 401 and attempts == 1 and os.environ.get("SIGMA_CLIENT_ID"):
            refresh_token()
            continue
        if not (200 <= resp.status < 300):
            raise SigmaError(f"{method.upper()} {path} -> {resp.status} {resp.reason}\n"
                             f"{resp.body.decode(errors='replace')}")
        if binary:
            return resp.body
        text = resp.body.decode(errors="replace")
        if accept != "application/json":
            return text
        return None if text == "" else json.loads(text)


bootstrap_credentials()
