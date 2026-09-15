#!/usr/bin/env python3
"""Minimal Looker API 4.0 client driven by ~/.looker/looker.ini (no SDK dep).

Usage:
  python3 looker_api.py whoami
  python3 looker_api.py get  /connections
  python3 looker_api.py post /connections '<json>'
  python3 looker_api.py put  /connections/<name>/test
  python3 looker_api.py raw  GET /lookml_models
"""
import json
import os
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
from configparser import ConfigParser

INI = os.path.expanduser("~/.looker/looker.ini")

# In-process token cache (same pattern as fetch_looker_dashboard.get._cache):
# login ONCE per process instead of once per call() — Looker bearers live ~1h,
# so for a multi-call run (parity fetches, estate walks) this removes a full
# network round-trip per call. call() retries once with a fresh login on 401.
# DEV-WORKSPACE CAVEAT: caching keeps ONE session across calls, which is what
# dev-workspace flows REQUIRE (`PATCH /session {workspace_id: dev}` only sticks
# within a session) — but a forced re-login (the 401 retry, or login(force=True))
# starts a NEW session that resets the workspace to production; re-PATCH after.
_token_lock = threading.Lock()
_token_cache = {}  # base_url -> access_token


def _api_base(base):
    base = base.rstrip("/")
    if not base.endswith("/api/4.0"):
        base += "/api/4.0"
    return base


def _strip_port(base):
    """`base` with an explicit port removed (→ default 443), or None if there is
    no explicit port. Used to self-heal a stale Looker API port: modern
    Google-hosted Looker serves the API on 443, not the legacy :19999."""
    p = urllib.parse.urlsplit(base)
    if not p.port:
        return None
    return urllib.parse.urlunsplit((p.scheme, p.hostname, p.path, p.query, p.fragment))


def _cfg():
    c = ConfigParser()
    c.read(INI)
    s = c["Looker"]
    # An env override wins over the ini (LOOKER_BASE_URL; also accept the Looker
    # SDK's LOOKERSDK_BASE_URL) so a stale/bad ini port can be corrected without
    # editing the shared config.
    raw_base = (os.environ.get("LOOKER_BASE_URL")
                or os.environ.get("LOOKERSDK_BASE_URL")
                or s["base_url"])
    return _api_base(raw_base), s["client_id"], s["client_secret"], s.getboolean("verify_ssl", True)


_ctx_cache = {}


def _ctx(verify):
    """SSL context for Looker requests. When verify is on (the default), delegate
    to the OS trust store via `truststore` — it accepts chains that Python's
    stricter OpenSSL 3.x default bundle rejects (e.g. a CA cert whose Basic
    Constraints aren't marked critical), matching curl/Ruby — then fall back to
    certifi and finally the stock verified context. verify=False (ini
    `verify_ssl=false`) DISABLES verification: opt-in only, and it warns once."""
    import ssl
    if verify in _ctx_cache:
        return _ctx_cache[verify]
    if not verify:
        print("looker_api: verify_ssl=false — TLS certificate verification is "
              "DISABLED for Looker requests. Do not use in production.", file=sys.stderr)
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    else:
        ctx = None
        try:
            import truststore
            ctx = truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        except Exception:
            ctx = None
        if ctx is None:
            try:
                import certifi
                ctx = ssl.create_default_context(cafile=certifi.where())
            except Exception:
                ctx = ssl.create_default_context()
    _ctx_cache[verify] = ctx
    return ctx


# configured api-base -> reachable api-base (memoizes a successful port fallback)
_resolved_base = {}


def _do_login(base, cid, csec, verify):
    data = urllib.parse.urlencode({"client_id": cid, "client_secret": csec}).encode()
    req = urllib.request.Request(base + "/login", data=data, method="POST")
    with urllib.request.urlopen(req, context=_ctx(verify), timeout=30) as r:
        return json.load(r)["access_token"]


def login(force=False):
    """Return (base, token, verify), reusing the per-process cached token.

    force=True mints a fresh token (NEW Looker session — see the dev-workspace
    caveat above). Thread-safe: parallel callers share one login. If the
    configured API base is unreachable AND carries an explicit port (e.g. the
    legacy :19999), retries once on the port-stripped (443) base and remembers it.
    """
    cfg_base, cid, csec, verify = _cfg()
    base = _resolved_base.get(cfg_base, cfg_base)
    with _token_lock:
        if not force and base in _token_cache:
            return base, _token_cache[base], verify
        try:
            tok = _do_login(base, cid, csec, verify)
        except urllib.error.URLError as e:
            if isinstance(e, urllib.error.HTTPError):
                raise  # a real HTTP response (bad creds, etc.), not a connectivity problem
            alt = _strip_port(base)
            if not alt or alt == base:
                raise
            print(f"looker_api: {base} unreachable ({getattr(e, 'reason', e)}); "
                  f"retrying on {alt}. Update base_url in ~/.looker/looker.ini to "
                  f"drop the legacy API port.", file=sys.stderr)
            tok = _do_login(alt, cid, csec, verify)
            _resolved_base[cfg_base] = alt
            base = alt
        _token_cache[base] = tok
    return base, tok, verify


def call(method, path, body=None, _retry=True):
    base, tok, verify = login()
    if not path.startswith("/"):
        path = "/" + path
    url = base + path
    data = None
    headers = {"Authorization": "Bearer " + tok}
    if body is not None:
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=_ctx(verify), timeout=60) as r:
            raw = r.read().decode()
            code = r.status
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        code = e.code
    if code == 401 and _retry:
        # cached token expired (~1h TTL) — re-login once and retry.
        login(force=True)
        return call(method, path, body, _retry=False)
    try:
        parsed = json.loads(raw)
    except Exception:
        parsed = raw
    return code, parsed


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "whoami"
    if cmd == "whoami":
        code, me = call("GET", "/user")
        _, roles = call("GET", "/user/roles")
        _, perms = call("GET", "/user/roles")  # placeholder
        print("HTTP", code)
        print("user:", me.get("display_name"), "| id", me.get("id"), "|", me.get("email"))
        if isinstance(roles, list):
            print("roles:", ", ".join(r.get("name", "?") for r in roles))
        else:
            print("roles raw:", roles)
    elif cmd == "raw":
        code, out = call(sys.argv[2].upper(), sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
        print("HTTP", code)
        print(json.dumps(out, indent=2)[:6000])
    else:  # get/post/put/patch/delete
        code, out = call(cmd.upper(), sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
        print("HTTP", code)
        print(json.dumps(out, indent=2)[:8000] if not isinstance(out, str) else out[:8000])
