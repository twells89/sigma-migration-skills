#!/usr/bin/env python3
"""Shared destination picker for the *-to-sigma migration skills (Python port).
Produces the folderId where a migrated data model + workbook should land.
The SKILL drives the *asking*; this script lists candidates and creates folders.

  python3 pick_destination.py list
      -> {"workspaces":[{id,name}], "folders":[{id,name,parentId,parentName}],
          "myDocuments": "<id>"|null}
      Only EDIT-able folders are returned. folderId in a DM/workbook POST accepts
      a workspace id (lands in the workspace root) or a folder id.

  python3 pick_destination.py create --name "<NAME>" [--parent "<workspace-or-folder-id>"]
      -> {"id","name","parentId"}

Auth: SIGMA_API_TOKEN + SIGMA_BASE_URL if set (e.g. via get-token.sh); otherwise
minted from SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET (sourced from ~/.sigma-migration/env).
"""
import json, os, sys, urllib.request, urllib.parse, urllib.error

def _load_neutral_env():
    if os.environ.get("SIGMA_CLIENT_ID") or os.environ.get("SIGMA_API_TOKEN"):
        return
    p = os.path.expanduser("~/.sigma-migration/env")
    if os.path.exists(p):
        for line in open(p):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

def _base():
    return os.environ.get("SIGMA_BASE_URL", "https://aws-api.sigmacomputing.com").rstrip("/")

def _token():
    tok = os.environ.get("SIGMA_API_TOKEN")
    if tok:
        return tok
    _load_neutral_env()
    data = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": os.environ["SIGMA_CLIENT_ID"],
        "client_secret": os.environ["SIGMA_CLIENT_SECRET"],
    }).encode()
    req = urllib.request.Request(_base() + "/v2/auth/token", data=data)
    return json.load(urllib.request.urlopen(req))["access_token"]

_TOK = None
def call(method, path, body=None):
    global _TOK
    if _TOK is None:
        _TOK = _token()
    url = _base() + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
        headers={"Authorization": "Bearer " + _TOK, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path} -> {e.code} {e.read().decode()[:300]}")

def my_documents_id():
    try:
        uid = (call("GET", "/v2/whoami") or {}).get("userId")
        if not uid:
            return None
        entries = (call("GET", f"/v2/members/{uid}/files?typeFilters=folder&limit=500") or {}).get("entries", [])
        for e in entries:
            if e.get("name") == "My Documents" or e.get("path") == "My Documents":
                return e.get("id")
    except Exception:
        return None
    return None

def cmd_list():
    ws = (call("GET", "/v2/workspaces?limit=500") or {}).get("entries", [])
    workspaces = [{"id": w.get("workspaceId") or w.get("id"), "name": w.get("name")} for w in ws]
    ws_name = {w["id"]: w["name"] for w in workspaces}
    fl = (call("GET", "/v2/files?typeFilters=folder&limit=500") or {}).get("entries", [])
    folders = [{"id": f["id"], "name": f["name"], "parentId": f.get("parentId"),
                "parentName": ws_name.get(f.get("parentId"))}
               for f in fl if f.get("permission") == "edit"]
    print(json.dumps({"workspaces": workspaces, "folders": folders,
                      "myDocuments": my_documents_id()}, indent=2))

def cmd_create(argv):
    name = parent = None
    i = 0
    while i < len(argv):
        if argv[i] == "--name":
            name = argv[i + 1]; i += 2
        elif argv[i] == "--parent":
            parent = argv[i + 1]; i += 2
        else:
            i += 1
    if not name:
        raise SystemExit("pick_destination create: --name is required")
    if not parent:
        parent = my_documents_id()
    body = {"type": "folder", "name": name}
    if parent:
        body["parentId"] = parent
    res = call("POST", "/v2/files", body)
    print(json.dumps({"id": res.get("id"), "name": res.get("name"), "parentId": res.get("parentId")}, indent=2))

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "list":
        cmd_list()
    elif cmd == "create":
        cmd_create(sys.argv[2:])
    else:
        raise SystemExit("usage: pick_destination.py [list | create --name NAME [--parent ID]]")
