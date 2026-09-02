#!/usr/bin/env python3
"""Destination picker for the *-to-sigma migration skills (Python twin).

Python port of pick-destination.rb (P1 Ruby->Python). Produces the folderId
where a migrated data model + workbook should land. The SKILL drives the
*asking*; this script just lists candidates and creates folders.

    python pick_destination.py list
        -> JSON { "workspaces":[{id,name}], "folders":[{id,name,parentId,parentName}],
                  "myDocuments": "<id>"|null }
        Only folders the token can EDIT are returned. folderId in a DM/workbook POST
        accepts either a workspace id (lands in the workspace root) or a folder id.

    python pick_destination.py create --name "<NAME>" [--parent "<workspace-or-folder-id>"]
        -> JSON { "id", "name", "parentId" }

Env: SIGMA_BASE_URL + SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET (or SIGMA_API_TOKEN).
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import sigma_rest  # noqa: E402


def _get(path):
    """GET returning a dict, swallowing errors to {} (mirrors Ruby `rescue {}`)."""
    try:
        return sigma_rest.request("get", path) or {}
    except Exception:
        return {}


def my_documents_id():
    # Only resolvable for a user-bound token; service-account tokens return None.
    try:
        uid = (_get("/v2/whoami") or {}).get("userId")
        if not uid:
            return None
        member = _get(f"/v2/members/{uid}") or {}
        home = member.get("homeFolderId")
        if home:
            return home
        # Legacy fallback: use the folder's id, never its parentId.
        entries = (_get(f"/v2/members/{uid}/files?typeFilters=folder&limit=500")
                   or {}).get("entries") or []
        hit = next((e for e in entries
                    if e.get("name") == "My Documents" or e.get("path") == "My Documents"), None)
        return hit and hit.get("id")
    except Exception:
        return None


def cmd_list():
    ws_entries = (_get("/v2/workspaces?limit=500") or {}).get("entries") or []
    workspaces = [{"id": w.get("workspaceId") or w.get("id"), "name": w.get("name")}
                  for w in ws_entries]
    ws_name = {w["id"]: w["name"] for w in workspaces}
    folder_entries = (_get("/v2/files?typeFilters=folder&limit=500") or {}).get("entries") or []
    folders = [{"id": f.get("id"), "name": f.get("name"), "parentId": f.get("parentId"),
                "parentName": ws_name.get(f.get("parentId"))}
               for f in folder_entries if f.get("permission") == "edit"]
    print(json.dumps({"workspaces": workspaces, "folders": folders,
                      "myDocuments": my_documents_id()}, indent=2))


def cmd_create(argv):
    name = None
    parent = None
    i = 0
    while i < len(argv):
        if argv[i] == "--name":
            name = argv[i + 1] if i + 1 < len(argv) else None
            i += 2
        elif argv[i] == "--parent":
            parent = argv[i + 1] if i + 1 < len(argv) else None
            i += 2
        else:
            i += 1
    if not name:
        sys.exit("pick_destination create: --name is required")
    if not parent:
        parent = my_documents_id()
    body = {"type": "folder", "name": name}
    if parent:
        body["parentId"] = parent
    res = sigma_rest.request("post", "/v2/files", body=json.dumps(body))
    print(json.dumps({"id": res.get("id"), "name": res.get("name"),
                      "parentId": res.get("parentId")}, indent=2))


def main(argv):
    cmd = argv[0] if argv else None
    if cmd in ("list", None):
        cmd_list()
    elif cmd == "create":
        cmd_create(argv[1:])
    else:
        sys.exit("usage: pick_destination.py [list | create --name NAME [--parent ID]]")


if __name__ == "__main__":
    main(sys.argv[1:])
