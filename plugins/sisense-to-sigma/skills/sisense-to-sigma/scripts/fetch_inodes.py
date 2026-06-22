#!/usr/bin/env python3
"""Fetch Sigma table inode IDs + warehouse paths for the SISENSE_ECOMMERCE schema.
Writes inodes.json {TABLE_UPPER: {inodeId, path:[db,schema,table]}}."""
import os, json, subprocess, sys
BASE=os.environ["SIGMA_BASE_URL"].rstrip("/"); TOK=os.environ["SIGMA_API_TOKEN"]
def files():
    out=subprocess.run(["curl","-s",f"{BASE}/v2/files?typeFilters=table&limit=2000",
        "-H",f"Authorization: Bearer {TOK}"],capture_output=True,text=True).stdout
    return json.loads(out).get("entries",[])
ents=[e for e in files() if 'SISENSE_ECOMMERCE' in (e.get('path') or '')]
inodes={}
for e in ents:
    name=e.get("name")
    inodes[name.upper()]={"inodeId":e.get("id"),"path":["CSA","SISENSE_ECOMMERCE",name]}
json.dump(inodes,open("/Users/tjwells/sisense-migration/inodes.json","w"),indent=2)
print(f"{len(inodes)}/4 tables:", list(inodes.keys()))
sys.exit(0 if len(inodes)>=4 else 1)
