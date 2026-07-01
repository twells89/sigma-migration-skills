#!/usr/bin/env python3
"""Fetch Sigma table inode IDs + warehouse paths for a schema.
Writes inodes.json {TABLE_UPPER: {inodeId, path:[db,schema,table]}}.

Portable (issue #229): the output path and the db/schema are arguments, not
hardcoded to one machine/dataset. Defaults match the SISENSE_ECOMMERCE sample so
the reference demo still runs with no flags; override for any other tenant."""
import os, json, subprocess, sys, argparse

ap = argparse.ArgumentParser(description="Resolve Sigma table inode ids for a schema")
ap.add_argument("--database", default="CSA", help="warehouse database (default: CSA)")
ap.add_argument("--schema", default="SISENSE_ECOMMERCE",
                help="warehouse schema to match (default: SISENSE_ECOMMERCE)")
ap.add_argument("--out", default=os.path.expanduser("~/sisense-migration/inodes.json"),
                help="output path (default: ~/sisense-migration/inodes.json)")
ap.add_argument("--min", type=int, default=1,
                help="exit non-zero if fewer than this many tables resolve (default: 1)")
a = ap.parse_args()

BASE = os.environ["SIGMA_BASE_URL"].rstrip("/")
TOK = os.environ["SIGMA_API_TOKEN"]


def files():
    out = subprocess.run(
        ["curl", "-s", f"{BASE}/v2/files?typeFilters=table&limit=2000",
         "-H", f"Authorization: Bearer {TOK}"],
        capture_output=True, text=True).stdout
    return json.loads(out).get("entries", [])


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
