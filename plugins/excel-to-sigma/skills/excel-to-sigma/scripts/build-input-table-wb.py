#!/usr/bin/env python3
"""Phase 3 — POST a workbook with an input table at the fact grain.

Two modes (see refs/input-tables.md):

  LINKED (⚠️ scaffold only — inherited columns do NOT resolve via POST):
    builds a custom-SQL spine element + a linked input table off it. The PK/grain
    and entry columns populate, but linked context columns render "multiple values"
    (verified 2026-06-10; publish doesn't fix). Add the real linked columns in the
    UI. Prefer building linked input tables entirely in the UI for now.
    python build-input-table-wb.py --name "Forecast Entry" --connection <writeConn> \
      --spine-sql spine.sql --spine-cols REGION,BRANCH,SUB_BRANCH,MONTH_DATE,CATEGORY_CODE \
      --key MONTH_DATE --entry-cols FORECAST_AMOUNT:number
    (--linked-cols defaults to all spine cols except --key)

  EMPTY (seed starting values via UI CSV paste afterward):
    python build-input-table-wb.py --name "Forecast Entry" --connection <writeConn> \
      --columns REGION:text,MONTH_DATE:datetime,CATEGORY_CODE:number,FORECAST_AMOUNT:number

Auth: reads ~/.sigma-migration/env (SIGMA_BASE_URL/CLIENT_ID/CLIENT_SECRET).
"""
import argparse
import json
import os
import sys
import urllib.request
import urllib.parse
from pathlib import Path

SYSTEM_COLS = ["ID", "CREATED_AT", "CREATED_BY", "UPDATED_AT", "UPDATED_BY"]

_LIB = Path(__file__).resolve().parent / "lib"
if str(_LIB) not in sys.path:
    sys.path.insert(0, str(_LIB))
import workbook_wire  # noqa: E402


def token():
    env = {}
    with open(os.path.expanduser("~/.sigma-migration/env")) as f:
        for line in f:
            line = line.strip().replace("export ", "")
            if "=" in line:
                k, v = line.split("=", 1)
                env[k] = v.strip().strip('"').strip("'")
    data = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": env["SIGMA_CLIENT_ID"],
        "client_secret": env["SIGMA_CLIENT_SECRET"],
    }).encode()
    req = urllib.request.Request(env["SIGMA_BASE_URL"] + "/v2/auth/token", data=data,
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    return env["SIGMA_BASE_URL"], json.load(urllib.request.urlopen(req))["access_token"]


def home_folder(base, tok):
    req = urllib.request.Request(base + "/v2/whoami", headers={"Authorization": f"Bearer {tok}"})
    uid = json.load(urllib.request.urlopen(req))["userId"]
    req = urllib.request.Request(base + f"/v2/members/{uid}", headers={"Authorization": f"Bearer {tok}"})
    return json.load(urllib.request.urlopen(req)).get("homeFolderId")


def title(alias):
    return alias.replace("_", " ").title()


def build_empty(args):
    cols = [{"id": "ID"}]
    for spec in args.columns.split(","):
        name, _, typ = spec.partition(":")
        cols.append({"id": name.strip(), "type": (typ or "text").strip()})
    for sc in SYSTEM_COLS[1:]:
        cols.append({"id": sc})
    desc = "Excel→Sigma input table (empty). Paste/upload the seed CSV, publish, then create a warehouse view."
    elements = [{
        "id": "inputTable", "kind": "input-table", "name": args.name,
        "source": {"kind": "empty", "connectionId": args.connection},
        "inputMode": "explore", "columns": cols,
    }]
    nxt = "open the input table → paste the seed CSV → PUBLISH → Warehouse views → Create new → copy the view path."
    return desc, elements, nxt


def build_linked(args):
    spine_cols = [c.strip() for c in args.spine_cols.split(",")]
    if args.key not in spine_cols:
        raise SystemExit(f"--key {args.key} must be one of --spine-cols ({spine_cols})")
    linked = ([c.strip() for c in args.linked_cols.split(",")]
              if args.linked_cols else [c for c in spine_cols if c != args.key])
    stmt = open(args.spine_sql).read() if args.spine_sql else args.spine_statement
    if not stmt:
        raise SystemExit("linked mode needs --spine-sql <file> or --spine-statement")

    spine = {
        "id": "spine", "kind": "table", "name": "Spine",
        "source": {"kind": "sql", "connectionId": args.connection, "statement": stmt},
        "columns": [{"id": a, "formula": f"[Custom SQL/{a}]", "name": title(a)} for a in spine_cols],
    }
    it_cols = [{"id": "pk", "key": args.key}]                       # primary key → spine column id
    for a in linked:                                               # linked (inherited, non-editable) columns
        it_cols.append({"id": f"lk_{a}", "formula": f"[Spine/{title(a)}]"})
    for spec in args.entry_cols.split(","):                        # own editable entry columns
        name, _, typ = spec.partition(":")
        it_cols.append({"id": name.strip(), "type": (typ or "number").strip()})
    it_cols += [{"id": "UPDATED_AT"}, {"id": "UPDATED_BY"}]
    elements = [spine, {
        "id": "inputTable", "kind": "input-table", "name": args.name,
        "source": {"kind": "linked", "from": "spine"},
        "inputMode": "explore", "columns": it_cols,
    }]
    desc = "Excel→Sigma linked input table SCAFFOLD — PK/grain + entry cols only; linked context cols do NOT resolve via POST (add in UI)."
    nxt = ("⚠️ Linked CONTEXT columns will show 'multiple values' (POST can't author the "
           "link — verified). This built the PK/grain + entry columns; add linked columns "
           "in the UI, or rebuild the whole linked table in the UI. Then Publish + Create warehouse view.")
    return desc, elements, nxt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--connection", required=True, help="write-enabled connectionId")
    ap.add_argument("--folder", default=None)
    # empty mode
    ap.add_argument("--columns", help="empty mode: comma list of NAME:type")
    # linked mode
    ap.add_argument("--spine-sql", help="linked mode: path to a .sql file for the spine")
    ap.add_argument("--spine-statement", help="linked mode: inline spine SQL (alt to --spine-sql)")
    ap.add_argument("--spine-cols", help="linked mode: comma list of spine SELECT aliases")
    ap.add_argument("--key", help="linked mode: spine alias used as the primary key")
    ap.add_argument("--linked-cols", help="linked mode: spine aliases to inherit (default: all but --key)")
    ap.add_argument("--entry-cols", help="linked mode: comma list of NAME:type entry columns")
    args = ap.parse_args()

    base, tok = token()
    folder = args.folder or home_folder(base, tok)

    if args.spine_cols or args.spine_sql or args.spine_statement:
        desc, elements, nxt = build_linked(args)
    elif args.columns:
        desc, elements, nxt = build_empty(args)
    else:
        raise SystemExit("provide --columns (empty mode) or --spine-cols/--spine-sql + --key + --entry-cols (linked mode)")

    # Nested draft → released document wrapper (code_rep). Layout is assembled
    # as the last write inside wire_workbook before the POST body is built.
    spec = {"name": args.name, "description": desc, "folderId": folder,
            "schemaVersion": 1, "kind": "workbook",
            "pages": [{"id": "entryPage", "name": args.name, "elements": elements}]}
    post_body = workbook_wire.wire_workbook(spec)

    body = json.dumps(post_body).encode()
    req = urllib.request.Request(base + "/v2/workbooks/spec", data=body, method="POST",
                                 headers={"Authorization": f"Bearer {tok}",
                                          "Content-Type": "application/json",
                                          "Accept": "application/json"})
    resp = json.load(urllib.request.urlopen(req))
    wbid = resp.get("workbookId")
    print("workbookId:", wbid)
    if wbid:
        req = urllib.request.Request(base + f"/v2/workbooks/{wbid}", headers={"Authorization": f"Bearer {tok}"})
        print("url:", json.load(urllib.request.urlopen(req)).get("url"))
        print(f"\nNEXT (UI): {nxt}")


if __name__ == "__main__":
    main()
