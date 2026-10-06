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

Auth: resolved by the co-located shared lib/sigma_rest.py browser-first provider.
"""
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
for _lib in (os.path.join(_HERE, "lib"), os.path.join(_HERE, "..", "lib")):
    if os.path.isdir(_lib):
        sys.path.insert(0, _lib)
import sigma_rest


def call(method, path, body=None):
    data = json.dumps(body) if body is not None else None
    try:
        return sigma_rest.request(method.lower(), path, body=data)
    except sigma_rest.SigmaError as exc:
        raise SystemExit(str(exc))

def my_documents_id():
    try:
        uid = (call("GET", "/v2/whoami") or {}).get("userId")
        if not uid:
            return None
        member = call("GET", f"/v2/members/{uid}") or {}
        home = member.get("homeFolderId")
        if home:
            return home
        # Legacy fallback: use the folder's id, never its parentId.
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
