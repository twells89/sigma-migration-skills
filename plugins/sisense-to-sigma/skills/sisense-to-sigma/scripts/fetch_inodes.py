#!/usr/bin/env python3
"""Fetch Sigma table inode IDs + warehouse paths for a schema.
Writes inodes.json {TABLE_UPPER: {inodeId, path:[db,schema,table]}}.

Portable (issue #229): the output path and the db/schema are arguments, not
hardcoded to one machine/dataset. Defaults match the SISENSE_ECOMMERCE sample so
the reference demo still runs with no flags; override for any other tenant.

Sigma auth is resolved by the co-located shared client: valid token first,
browser refresh second, and client credentials as the unattended fallback."""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import sigma_rest

ap = argparse.ArgumentParser(description="Resolve Sigma table inode ids for a schema")
ap.add_argument("--database", default="DEMO_DB", help="warehouse database (default: DEMO_DB)")
ap.add_argument("--schema", default="SISENSE_ECOMMERCE",
                help="warehouse schema to match (default: SISENSE_ECOMMERCE)")
ap.add_argument("--out", default=os.path.expanduser("~/sisense-migration/inodes.json"),
                help="output path (default: ~/sisense-migration/inodes.json)")
ap.add_argument("--min", type=int, default=1,
                help="exit non-zero if fewer than this many tables resolve (default: 1)")
a = ap.parse_args()

def files():
    try:
        response = sigma_rest.request(
            "get", "/v2/files?typeFilters=table&limit=2000"
        )
    except (sigma_rest.SigmaError, SystemExit) as exc:
        sys.exit(
            f"Sigma table scout authentication/request failed: {exc}\n"
            "Run scripts/browser-login.sh once, or configure SIGMA_BASE_URL / "
            "SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET for unattended auth."
        )
    return (response or {}).get("entries", [])


ents = [e for e in files() if a.schema in (e.get("path") or "")]
inodes = {}
for e in ents:
    name = e.get("name")
    inodes[name.upper()] = {"inodeId": e.get("id"),
                            "path": [a.database, a.schema, name]}

os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
json.dump(inodes, open(a.out, "w"), indent=2)
print(f"{len(inodes)} table(s) → {a.out}:", list(inodes.keys()))
sys.exit(0 if len(inodes) >= a.min else 1)
