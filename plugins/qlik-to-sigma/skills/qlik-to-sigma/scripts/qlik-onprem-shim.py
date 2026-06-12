#!/usr/bin/env python3
"""qlik-onprem-shim.py — qlik-cli-compatible shim for CLIENT-MANAGED Qlik Sense
(Enterprise on Windows). qlik-cli only speaks Qlik Cloud; this shim accepts the
exact qlik-cli command subset the discovery scripts use and backs it with the
on-prem APIs (QRS REST + Engine/QIX JSON-RPC over WebSocket), emitting the SAME
output shapes — so qlik-discover.py runs unchanged:

    export QLIK_BIN="$PWD/scripts/qlik-onprem-shim.py"     # discover honors QLIK_BIN
    python3 scripts/qlik-discover.py --app <appId> --out extract/

Supported commands (the discovery surface — anything else exits 2 loudly):
    item ls --resourceType app [--limit N]      QRS /qrs/app/full → Cloud item shape
    app script get -a <app>                     Engine GetScript
    app object ls -a <app> --json               Engine GetAllInfos
    app object properties <qId> -a <app>        Engine GetObject→GetProperties
    app measure ls -a <app> --json              Engine MeasureList session object
    app dimension ls -a <app> --json            Engine DimensionList session object
    app measure properties <qId> -a <app>       Engine GetMeasure→GetProperties
    app dimension properties <qId> -a <app>     Engine GetDimension→GetProperties
    app eval <expr> -a <app>                    Engine Evaluate

NOT supported on-prem (clear error, never silent): `raw get` (Cloud REST only —
qlik-screenshot.py is a Cloud nicety, skip it), `app object set/rm` (the
assessment temp-object trick would require DoSave WRITES to the customer app).

Config — environment (put these in ~/.sigma-migration/qlik-onprem.env and
`source` it; see refs/connection-onprem.md for the QMC setup on each path):

  QLIK_ONPREM_SERVER=qlik.example.com          # host only, no scheme
  QLIK_ONPREM_AUTH=certs | jwt

  # certs mode (QMC → Certificates export; PEM format):
  QLIK_ONPREM_CERTS=/path/to/certs             # client.pem, client_key.pem, root.pem
  QLIK_ONPREM_USER_DIRECTORY=ACME              # service user with read access
  QLIK_ONPREM_USER_ID=svc_migration
  # ports (defaults): QRS 4242, Engine 4747

  # jwt mode (JWT virtual proxy on the central proxy, everything over 443):
  QLIK_ONPREM_VPROXY=jwt                       # virtual proxy prefix
  QLIK_ONPREM_JWT=<token>

  QLIK_ONPREM_INSECURE=1                       # skip TLS verify (self-signed QRS/proxy)

Engine transport needs the `websocket-client` package: pip3 install websocket-client
(stdlib has no WebSocket). Each invocation is one engine session, mirroring
qlik-cli — the caller's retry/backoff semantics still apply.
"""
import json
import os
import ssl
import sys
import urllib.request

XRF = "abcdefghij123456"  # QRS CSRF pair — any 16 chars, query param must match header


def die(msg, code=2):
    sys.stderr.write(f"qlik-onprem-shim: {msg}\n")
    sys.exit(code)


def env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        die(f"missing env {name} — see refs/connection-onprem.md")
    return v


SERVER = env("QLIK_ONPREM_SERVER", required=True)
AUTH = env("QLIK_ONPREM_AUTH", "certs")
INSECURE = env("QLIK_ONPREM_INSECURE") == "1"


def ssl_ctx(with_client_cert):
    ctx = ssl.create_default_context()
    if INSECURE:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    elif AUTH == "certs":
        root = os.path.join(env("QLIK_ONPREM_CERTS", required=True), "root.pem")
        if os.path.exists(root):
            ctx.load_verify_locations(root)
    if with_client_cert and AUTH == "certs":
        d = env("QLIK_ONPREM_CERTS", required=True)
        ctx.load_cert_chain(os.path.join(d, "client.pem"), os.path.join(d, "client_key.pem"))
    return ctx


def auth_headers():
    if AUTH == "certs":
        ud = env("QLIK_ONPREM_USER_DIRECTORY", required=True)
        uid = env("QLIK_ONPREM_USER_ID", required=True)
        return {"X-Qlik-User": f"UserDirectory={ud}; UserId={uid}"}
    if AUTH == "jwt":
        return {"Authorization": f"Bearer {env('QLIK_ONPREM_JWT', required=True)}"}
    die(f"QLIK_ONPREM_AUTH must be certs or jwt (got {AUTH!r})")


# ── QRS (Repository Service) ──────────────────────────────────────────────────

def qrs_get(path):
    if AUTH == "certs":
        base = f"https://{SERVER}:{env('QLIK_ONPREM_QRS_PORT', '4242')}"
    else:
        vp = env("QLIK_ONPREM_VPROXY", "")
        base = f"https://{SERVER}/{vp}" if vp else f"https://{SERVER}"
    sep = "&" if "?" in path else "?"
    url = f"{base}{path}{sep}xrfkey={XRF}"
    req = urllib.request.Request(url, headers={"X-Qlik-Xrfkey": XRF, **auth_headers()})
    with urllib.request.urlopen(req, context=ssl_ctx(with_client_cert=True)) as r:
        return json.loads(r.read())


# ── Engine (QIX) JSON-RPC over WebSocket ──────────────────────────────────────

class Engine:
    def __init__(self, app_id):
        try:
            import websocket  # websocket-client
        except ImportError:
            die("the Engine transport needs websocket-client: pip3 install websocket-client")
        if AUTH == "certs":
            url = f"wss://{SERVER}:{env('QLIK_ONPREM_ENGINE_PORT', '4747')}/app/{app_id}"
        else:
            vp = env("QLIK_ONPREM_VPROXY", "")  # empty = proxy mounted at root
            url = f"wss://{SERVER}/{vp}/app/{app_id}" if vp else f"wss://{SERVER}/app/{app_id}"
        sslopt = {}
        if INSECURE:
            sslopt = {"cert_reqs": ssl.CERT_NONE, "check_hostname": False}
        elif AUTH == "certs":
            d = env("QLIK_ONPREM_CERTS", required=True)
            sslopt = {"certfile": os.path.join(d, "client.pem"),
                      "keyfile": os.path.join(d, "client_key.pem")}
            if os.path.exists(os.path.join(d, "root.pem")):
                sslopt["ca_certs"] = os.path.join(d, "root.pem")
        if AUTH == "certs":
            d = env("QLIK_ONPREM_CERTS", required=True)
            sslopt.setdefault("certfile", os.path.join(d, "client.pem"))
            sslopt.setdefault("keyfile", os.path.join(d, "client_key.pem"))
        headers = [f"{k}: {v}" for k, v in auth_headers().items()]
        self.ws = websocket.create_connection(url, sslopt=sslopt, header=headers, timeout=60)
        self._id = 0
        self.app_handle = None
        self._open(app_id)

    def call(self, handle, method, params=None):
        self._id += 1
        self.ws.send(json.dumps({"jsonrpc": "2.0", "id": self._id, "handle": handle,
                                 "method": method, "params": params or []}))
        while True:  # skip engine push notifications (no id / other ids)
            msg = json.loads(self.ws.recv())
            if msg.get("id") == self._id:
                if "error" in msg:
                    die(f"engine {method}: {msg['error'].get('message')} "
                        f"(code {msg['error'].get('code')})", code=1)
                return msg.get("result", {})

    def _open(self, app_id):
        r = self.call(-1, "OpenDoc", {"qDocName": app_id})
        self.app_handle = r["qReturn"]["qHandle"]

    def obj_handle(self, getter, q_id, required=True):
        r = self.call(self.app_handle, getter, {"qId": q_id})
        h = r.get("qReturn", {}).get("qHandle")
        if h is None or h < 0:
            if required:
                die(f"{getter}({q_id}): not found", code=1)
            return None
        return h

    def any_handle(self, q_id):
        """qlik-cli resolves `app object properties` for ANY object kind —
        GetAllInfos includes master measures/dimensions, whose ids only resolve
        via their own getters."""
        for getter in ("GetObject", "GetMeasure", "GetDimension", "GetVariableById"):
            h = self.obj_handle(getter, q_id, required=False)
            if h is not None:
                return h
        die(f"object {q_id}: not found via GetObject/GetMeasure/GetDimension/GetVariableById", code=1)

    def session_list(self, list_def_key, q_type, items_key):
        props = {"qInfo": {"qType": f"{q_type}List"},
                 list_def_key: {"qType": q_type, "qData": {"title": "/qMetaDef/title"}}}
        h = self.call(self.app_handle, "CreateSessionObject", {"qProp": props})["qReturn"]["qHandle"]
        layout = self.call(h, "GetLayout")["qLayout"]
        items = (layout.get(items_key) or {}).get("qItems") or []
        return [{"qId": it.get("qInfo", {}).get("qId"),
                 "title": (it.get("qData") or {}).get("title")
                          or (it.get("qMeta") or {}).get("title")} for it in items]

    def close(self):
        try:
            self.ws.close()
        except Exception:
            pass


# ── command dispatch (argv-compatible with the qlik-cli subset) ───────────────

def parse(argv):
    """Split argv into positional words and the flags we honor; swallow
    qlik-cli flags that don't apply on-prem (--context/-c, --json, --limit…)."""
    words, flags, i = [], {}, 0
    swallow_with_value = {"--context", "-c", "--limit", "--resourceType"}
    bare = {"--json", "-q", "--quiet"}
    while i < len(argv):
        a = argv[i]
        if a in ("-a", "--app"):
            flags["app"] = argv[i + 1]; i += 2
        elif a in swallow_with_value:
            flags[a.lstrip("-")] = argv[i + 1]; i += 2
        elif a in bare or a.startswith("--"):
            i += 1
        else:
            words.append(a); i += 1
    return words, flags


def main():
    words, flags = parse(sys.argv[1:])
    if not words:
        die("no command")

    if words[0] == "item" and words[1:2] == ["ls"]:
        apps = qrs_get("/qrs/app/full")
        out = [{"resourceId": a.get("id"), "name": a.get("name"), "resourceType": "app",
                "resourceAttributes": {
                    "name": a.get("name"), "description": a.get("description"),
                    "ownerName": (a.get("owner") or {}).get("name"),
                    "publishTime": a.get("publishTime"),
                    "spaceName": (a.get("stream") or {}).get("name"),  # stream ≈ space
                    "lastReloadTime": a.get("lastReloadTime"),
                }} for a in apps]
        limit = int(flags.get("limit") or 0)
        print(json.dumps(out[:limit] if limit else out))
        return

    if words[0] != "app":
        die(f"unsupported command: {' '.join(words)} (on-prem shim covers the discovery surface only)")

    sub = words[1:]
    KNOWN = (["script", "get"], ["object", "ls"], ["object", "properties"],
             ["measure", "ls"], ["dimension", "ls"], ["measure", "properties"],
             ["dimension", "properties"], ["eval"])
    if sub[:2] in (["object", "set"], ["object", "rm"]):
        die("app object set/rm not supported on-prem (would require DoSave WRITES "
            "to the customer app) — the assessment temp-object flow is Cloud-only.")
    if not any(sub[:len(k)] == k for k in KNOWN):
        die(f"unsupported command: app {' '.join(sub)}")
    app = flags.get("app") or die("missing -a <appId>")
    eng = Engine(app)
    try:
        if sub[:2] == ["script", "get"]:
            print(eng.call(eng.app_handle, "GetScript")["qScript"])
        elif sub[:2] == ["object", "ls"]:
            infos = eng.call(eng.app_handle, "GetAllInfos")["qInfos"]
            # GetAllInfos includes master measures/dimensions/variables; qlik-cli's
            # `app object ls` lists generic objects only — match it (verified by
            # diffing a full discovery run against qlik-cli on the same app).
            skip = {"measure", "dimension", "variable"}
            print(json.dumps([{"qId": i["qId"], "qType": i["qType"]}
                              for i in infos if i["qType"] not in skip]))
        elif sub[:2] == ["object", "properties"]:
            h = eng.any_handle(sub[2])
            print(json.dumps(eng.call(h, "GetProperties")["qProp"]))
        elif sub[:2] == ["measure", "ls"]:
            print(json.dumps(eng.session_list("qMeasureListDef", "measure", "qMeasureList")))
        elif sub[:2] == ["dimension", "ls"]:
            print(json.dumps(eng.session_list("qDimensionListDef", "dimension", "qDimensionList")))
        elif sub[:2] == ["measure", "properties"]:
            h = eng.obj_handle("GetMeasure", sub[2])
            print(json.dumps(eng.call(h, "GetProperties")["qProp"]))
        elif sub[:2] == ["dimension", "properties"]:
            h = eng.obj_handle("GetDimension", sub[2])
            print(json.dumps(eng.call(h, "GetProperties")["qProp"]))
        elif sub[:1] == ["eval"]:
            # qlik-cli format: line 1 = the expression echoed, line 2 = the value
            # (qlik_eval in discover/migrate parses lines[1])
            val = eng.call(eng.app_handle, "Evaluate", {"qExpression": sub[1]}).get("qReturn", "")
            print(sub[1])
            print(val)
    finally:
        eng.close()


if __name__ == "__main__":
    main()
