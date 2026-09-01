"""Tableau REST API wrapper for tableau-to-sigma when the MCP isn't available.

Python twin of tableau_rest.rb (P1 runtime-shrink: Ruby -> Python). Stdlib only
(urllib) — no third-party deps.

WHAT ACTUALLY ENFORCES PARITY (corrected, issue #753): there is no "cross-impl
parity harness" — the phrase existed only in this docstring and sigma_rest.py's —
and test_tableau_rest.py does not invoke ruby. API-surface parity is checked by
tools/lint-twin-parity.rb; behavioural equivalence is not machine-checked.

The Tableau-first no-Ruby path now exercises the complete public discovery
surface: contentUrl workbook resolution, workbook/datasource/virtual
connections, filtered view data, VDS queries, and dashboard membership.

Requires TABLEAU_SERVER_URL, TABLEAU_SITE_ID, TABLEAU_AUTH_TOKEN,
TABLEAU_API_VERSION in env (set by scripts/get-tableau-token.sh). PAT refresh
additionally needs TABLEAU_PAT_NAME, TABLEAU_PAT_SECRET, TABLEAU_SITE_CONTENT_URL.

All methods return parsed dict/list (or raw bytes for view_image / *_content).
Network/HTTP errors raise TableauError with the response body included.
"""

import json
import os
import re
import ssl
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request

NEUTRAL_ENV = os.path.expanduser("~/.sigma-migration/env")
_NEUTRAL_LINE = re.compile(r"\A\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)\Z")


class TableauError(Exception):
    pass


class TableauAuthError(TableauError):
    pass


_token_mutex = threading.Lock()
_token_override = None
_site_id_override = None
_refresh_inflight = False


def _load_neutral_env(env=None):
    """Agent-neutral credential bootstrap. Load Tableau PAT creds from
    ~/.sigma-migration/env when TABLEAU_PAT_SECRET is absent. Existing env wins
    (mirrors Ruby's `.nil?` guard + `ENV[key] ||= raw`)."""
    env = os.environ if env is None else env
    if "TABLEAU_PAT_SECRET" in env or not os.path.exists(NEUTRAL_ENV):
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


def bootstrap_credentials(env=None):
    _load_neutral_env(env)


def _require(key, hint="run get-tableau-token.sh"):
    v = os.environ.get(key)
    if not v:
        raise TableauError(f"{key} not set — {hint}")
    return v


def server_url():
    return _require("TABLEAU_SERVER_URL")


def site_id():
    with _token_mutex:
        if _site_id_override:
            return _site_id_override
    return _require("TABLEAU_SITE_ID")


def auth_token():
    with _token_mutex:
        if _token_override:
            return _token_override
    return _require("TABLEAU_AUTH_TOKEN")


def api_version():
    return os.environ.get("TABLEAU_API_VERSION", "3.22")


def base_path():
    return f"/api/{api_version()}/sites/{site_id()}"


def _dig(obj, *keys):
    """Ruby Hash#dig equivalent — nil-safe nested lookup."""
    for k in keys:
        if not isinstance(obj, dict):
            return None
        obj = obj.get(k)
    return obj


class _Resp:
    __slots__ = ("status", "body", "reason")

    def __init__(self, status, body, reason=""):
        self.status = status
        self.body = body if isinstance(body, (bytes, bytearray)) else str(body).encode()
        self.reason = reason


def _ssl_context():
    """TLS trust resolution (P1.4). Ruby's Net::HTTP and curl validate Tableau
    Cloud's chain fine, but Python's stricter OpenSSL 3.x rejects a Tableau
    intermediate ("Basic Constraints not marked critical") under the default
    bundle. Prefer the OS trust store (truststore — matches curl/Ruby), then
    certifi, then the stock verified context. NEVER silently downgrades: an
    unverified context is used ONLY when TABLEAU_INSECURE_TLS is explicitly set,
    and it logs loudly."""
    if os.environ.get("TABLEAU_INSECURE_TLS"):
        print("WARNING: TABLEAU_INSECURE_TLS set — TLS certificate verification is "
              "DISABLED for Tableau requests. Do not use in production.", file=sys.stderr)
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
    """Low-level HTTP seam (tests monkeypatch this)."""
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
    """Re-sign in with the PAT env vars and cache token + site id. Single-flight."""
    global _refresh_inflight, _token_override, _site_id_override
    with _token_mutex:
        if _refresh_inflight:
            return _token_override
        _refresh_inflight = True
    try:
        name = os.environ.get("TABLEAU_PAT_NAME")
        if not name:
            raise TableauAuthError("TABLEAU_PAT_NAME not set — cannot refresh")
        secret = os.environ.get("TABLEAU_PAT_SECRET")
        if not secret:
            raise TableauAuthError("TABLEAU_PAT_SECRET not set — cannot refresh")
        site_content = os.environ.get("TABLEAU_SITE_CONTENT_URL")
        if site_content is None:
            raise TableauAuthError("TABLEAU_SITE_CONTENT_URL not set")
        url = urllib.parse.urljoin(server_url(), f"/api/{api_version()}/auth/signin")
        body = (f'<tsRequest><credentials personalAccessTokenName="{name}" '
                f'personalAccessTokenSecret="{secret}"><site contentUrl="{site_content}"/>'
                f'</credentials></tsRequest>')
        resp = _send("POST", url,
                     {"Content-Type": "application/xml", "Accept": "application/json"},
                     body, 30)
        if not (200 <= resp.status < 300):
            raise TableauAuthError(f"signin -> {resp.status} {resp.body.decode(errors='replace')}")
        j = json.loads(resp.body or b"{}")
        with _token_mutex:
            _token_override = _dig(j, "credentials", "token")
            _site_id_override = _dig(j, "credentials", "site", "id")
        return _token_override
    finally:
        with _token_mutex:
            _refresh_inflight = False


def request(method, path, body=None, content_type="application/json",
            accept="application/json", binary=False):
    url = urllib.parse.urljoin(server_url(), path)
    if method.lower() not in ("get", "post", "put", "delete"):
        raise ValueError(f"unsupported method {method}")
    attempts = 0
    while True:
        attempts += 1
        headers = {"X-Tableau-Auth": auth_token(), "Accept": accept}
        if body is not None:
            headers["Content-Type"] = content_type
        resp = _send(method, url, headers, body, 120)
        if resp.status == 401 and attempts == 1 and os.environ.get("TABLEAU_PAT_NAME"):
            refresh_token()
            continue
        if not (200 <= resp.status < 300):
            raise TableauError(f"{method.upper()} {path} -> {resp.status} {resp.reason}\n"
                               f"{resp.body.decode(errors='replace')}")
        if binary:
            return resp.body
        text = resp.body.decode(errors="replace")
        if accept != "application/json":
            return text
        return None if text == "" else json.loads(text)


def _as_list(v):
    """Tableau REST returns a bare object for single-element collections and a
    list for many — normalise to a list."""
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


# ---- workbooks ------------------------------------------------------------

def find_workbook_by_name(name):
    # A comma is the REST filter predicate DELIMITER - a name containing one
    # breaks `name:eq:` unrecoverably (round-5 field-caught). Fall back to a
    # paged client-side scan for such names.
    if "," in str(name):
        return scan_workbooks_for_name(name)
    encoded = urllib.parse.quote_plus(f"name:eq:{name}")
    j = request("get", f"{base_path()}/workbooks?filter={encoded}")
    lst = _as_list(_dig(j, "workbooks", "workbook"))
    # not-found stays ONE filtered request (v5.3.1: an unconditional scan
    # fallback paged the whole site on every legitimate miss)
    return lst[0] if lst else None


def scan_workbooks_for_name(name):
    """Paged client-side name match: exact wins across ALL pages; a
    case-insensitive hit is only returned after the full scan (v5.3.1: a
    per-page short-circuit let an early case-variant beat a later exact)."""
    ci_hit = None
    page = 1
    while True:
        j = request("get", f"{base_path()}/workbooks?pageSize=100&pageNumber={page}")
        lst = _as_list(_dig(j, "workbooks", "workbook"))
        exact = next((w for w in lst if w.get("name") == name), None)
        if exact:
            return exact
        if ci_hit is None:
            ci_hit = next((w for w in lst if str(w.get("name", "")).strip().lower() == str(name).strip().lower()), None)
        total = int((_dig(j, "pagination", "totalAvailable") or 0))
        if not lst or page * 100 >= total:
            return ci_hit
        page += 1

def find_workbook_by_content_url(content_url):
    encoded = urllib.parse.quote_plus(f"contentUrl:eq:{content_url}")
    j = request("get", f"{base_path()}/workbooks?filter={encoded}")
    workbooks = _as_list(_dig(j, "workbooks", "workbook"))
    if workbooks:
        return workbooks[0]
    page = 1
    while True:
        j = request("get", f"{base_path()}/workbooks?pageSize=100&pageNumber={page}")
        workbooks = _as_list(_dig(j, "workbooks", "workbook"))
        hit = next(
            (
                workbook
                for workbook in workbooks
                if str(workbook.get("contentUrl")) == str(content_url)
            ),
            None,
        )
        if hit:
            return hit
        total = int(_dig(j, "pagination", "totalAvailable") or 0)
        if not workbooks or page * 100 >= total:
            return None
        page += 1


def get_workbook(workbook_id):
    return request("get", f"{base_path()}/workbooks/{workbook_id}")["workbook"]


def workbook_connections(workbook_id):
    j = request("get", f"{base_path()}/workbooks/{workbook_id}/connections")
    return _as_list(_dig(j, "connections", "connection"))


def datasource_connections(datasource_id):
    j = request("get", f"{base_path()}/datasources/{datasource_id}/connections")
    return _as_list(_dig(j, "connections", "connection"))


def virtual_connections(page_size=100):
    entries = []
    page = 1
    while True:
        j = request(
            "get",
            f"{base_path()}/virtualConnections?pageSize={page_size}&pageNumber={page}",
        )
        batch = _as_list(_dig(j, "virtualConnections", "virtualConnection"))
        entries.extend(batch)
        total = int(_dig(j, "pagination", "totalAvailable") or 0)
        if not batch or page * page_size >= total:
            return entries
        page += 1


def virtual_connection_connections(virtual_connection_id):
    j = request(
        "get",
        f"{base_path()}/virtualConnections/{virtual_connection_id}/connections",
    )
    return _as_list(_dig(j, "virtualConnectionConnections", "connection"))


def download_workbook_content(workbook_id, include_extract=False):
    qs = "" if include_extract else "?includeExtract=false"
    return request("get", f"{base_path()}/workbooks/{workbook_id}/content{qs}",
                   accept="*/*", binary=True)


# ---- views ----------------------------------------------------------------

def view_data(view_id):
    return request("get", f"{base_path()}/views/{view_id}/data", accept="*/*")


def view_data_filtered(view_id, filters=None):
    qs = "?maxAge=1"
    for field, value in (filters or {}).items():
        qs += (
            f"&vf_{urllib.parse.quote(str(field))}="
            f"{urllib.parse.quote(str(value))}"
        )
    return request("get", f"{base_path()}/views/{view_id}/data{qs}", accept="*/*")


def view_image(view_id, resolution="high", filters=None):
    # NOTE: /image has NO size params — the old vf_width/vf_height pair were
    # silent NO-OPS (vf_* is the view-FILTER prefix; 'width'/'height' are not
    # fields — live-verified 2026-07-11, fixed in lock-step with the Ruby
    # twin). `filters` applies real vf_ view filters: {"Region": "West"}.
    qs = f"?resolution={resolution}&maxAge=1"
    for f, v in (filters or {}).items():
        qs += f"&vf_{urllib.parse.quote(str(f))}={urllib.parse.quote(str(v))}"
    return request("get", f"{base_path()}/views/{view_id}/image{qs}", accept="*/*", binary=True)


def view_pdf(view_id, viz_width, viz_height, type_="Unspecified", orientation="Landscape", filters=None):
    # Exact-size render: the ONLY REST path honoring authored canvas dims
    # (renders at 0.75pt/px + 36pt margins — rasterize at 4/3 and crop).
    qs = (f"?type={type_}&orientation={orientation}"
          f"&vizWidth={int(viz_width)}&vizHeight={int(viz_height)}&maxAge=1")
    for f, v in (filters or {}).items():
        qs += f"&vf_{urllib.parse.quote(str(f))}={urllib.parse.quote(str(v))}"
    return request("get", f"{base_path()}/views/{view_id}/pdf{qs}", accept="*/*", binary=True)


# ---- datasources ----------------------------------------------------------

def list_datasources(page_size=100, page=1):
    return request("get", f"{base_path()}/datasources?pageSize={page_size}&pageNumber={page}")


def find_datasource_by_name(name):
    encoded = urllib.parse.quote_plus(f"name:eq:{name}")
    j = request("get", f"{base_path()}/datasources?filter={encoded}")
    lst = _as_list(_dig(j, "datasources", "datasource"))
    return lst[0] if lst else None


def find_datasource_by_content_url(content_url):
    encoded = urllib.parse.quote_plus(f"contentUrl:eq:{content_url}")
    j = request("get", f"{base_path()}/datasources?filter={encoded}")
    lst = _as_list(_dig(j, "datasources", "datasource"))
    if lst:
        return lst[0]
    # Fallback: scan pages and match contentUrl exactly.
    page = 1
    while True:
        jj = list_datasources(page_size=100, page=page)
        ds = _as_list(_dig(jj, "datasources", "datasource"))
        hit = next((d for d in ds if str(d.get("contentUrl")) == str(content_url)), None)
        if hit:
            return hit
        total = int(_dig(jj, "pagination", "totalAvailable") or 0)
        if not ds or page * 100 >= total:
            break
        page += 1
    return None


def download_datasource_content(datasource_id, include_extract=False):
    qs = "" if include_extract else "?includeExtract=false"
    return request("get", f"{base_path()}/datasources/{datasource_id}/content{qs}",
                   accept="*/*", binary=True)


# ---- server capabilities --------------------------------------------------

def serverinfo():
    return request("get", f"/api/{api_version()}/serverinfo")["serverInfo"]


def metadata_api_available():
    try:
        r = graphql("{ __typename }")
    except TableauError:
        return False
    return r is not None and not _dig(r, "errors")


def capabilities():
    try:
        info = serverinfo() or {}
    except TableauError:
        info = {}
    try:
        meta = metadata_api_available()
    except TableauError:
        meta = False
    return {
        "product_version": _dig(info, "productVersion", "value"),
        "rest_api_version": info.get("restApiVersion") or api_version(),
        "metadata_api": meta,
    }


def read_metadata(datasource_luid):
    body = json.dumps({"datasource": {"datasourceLuid": datasource_luid}})
    return request("post", "/api/v1/vizql-data-service/read-metadata", body=body)


def query_datasource(datasource_luid, query):
    body = json.dumps(
        {"datasource": {"datasourceLuid": datasource_luid}, "query": query}
    )
    return request(
        "post",
        "/api/v1/vizql-data-service/query-datasource",
        body=body,
    )


# ---- metadata GraphQL -----------------------------------------------------

def graphql_datasource_fields(datasource_luid):
    query = (
        "{\n"
        f'  publishedDatasources(filter:{{luid:"{datasource_luid}"}}) {{\n'
        "    name luid\n"
        "    fields {\n"
        "      name\n"
        "      fullyQualifiedName\n"
        "      ... on CalculatedField { formula isHidden }\n"
        "    }\n"
        "  }\n"
        "}\n"
    )
    return request("post", "/api/metadata/graphql", body=json.dumps({"query": query}))


def graphql(query, variables=None):
    payload = {"query": query}
    if variables:
        payload["variables"] = variables
    return request("post", "/api/metadata/graphql", body=json.dumps(payload))


def graphql_workbook_dashboards(workbook_luid):
    query = (
        "{\n"
        f'  workbooks(filter:{{luid:"{workbook_luid}"}}) {{\n'
        "    dashboards { name sheets { name luid } }\n"
        "  }\n"
        "}\n"
    )
    result = graphql(query)
    if not result or result.get("errors"):
        return None
    workbooks = _dig(result, "data", "workbooks")
    if not workbooks:
        return None
    return workbooks[0].get("dashboards")


bootstrap_credentials()
