#!/usr/bin/env bash
# Metabase REST discovery helper (converter-side; the assessment skill has the
# full estate walker). Read-only GETs.
#
#   export MB_BASE="https://<host>"           # plus MB_KEY or MB_USER/MB_PASS
#   eval "$(scripts/get-metabase-session.sh)"
#
#   metabase-discover.sh collections                 # collection tree (id, name, location)
#   metabase-discover.sh items     <collectionId>    # cards/dashboards/models in a collection
#   metabase-discover.sh card      <cardId>          # full card JSON (question/model)  → stdout
#   metabase-discover.sh dashboard <dashboardId>     # full dashboard JSON              → stdout
#   metabase-discover.sh databases                   # list databases (find the warehouse conn)
#   metabase-discover.sh metadata  <databaseId>      # schema metadata (FIELD IDS — converter needs this)
set -euo pipefail
if ! command -v mb_get >/dev/null 2>&1 && [ -z "${MB_AUTH_HDR:-}" ]; then
  echo "Run: eval \"\$(scripts/get-metabase-session.sh)\" first" >&2; exit 1
fi
req() { curl -s "$MB_BASE$1" -H 'Accept: application/json' -H "$MB_AUTH_HDR"; }
cmd="${1:-}"; id="${2:-}"
case "$cmd" in
  collections)
    req "/api/collection" | python3 -c '
import sys,json
for c in json.load(sys.stdin):
    if isinstance(c, dict):
        kind = "personal" if c.get("personal_owner_id") else "shared"
        cid, loc, name = str(c.get("id")), c.get("location") or "/", c.get("name")
        print(f"{cid:>6}  {kind:8}  {loc:12}  {name}")' ;;
  items)
    req "/api/collection/$id/items?models=card&models=dashboard&models=dataset&limit=200" | python3 -c '
import sys,json
d=json.load(sys.stdin)
for i in d.get("data", []):
    model, iid, name = i.get("model", "?"), str(i.get("id")), i.get("name")
    print(f"{model:10} {iid:>6}  {name}")
t=d.get("total"); n=len(d.get("data", []))
if t and t > n: print(f"… {t-n} more — paginate with &offset={n}", file=sys.stderr)' ;;
  card)      req "/api/card/$id" ;;
  dashboard) req "/api/dashboard/$id" ;;
  databases)
    req "/api/database" | python3 -c '
import sys,json
d=json.load(sys.stdin); rows=d.get("data") if isinstance(d, dict) else d
for db in rows or []:
    did, eng, name = str(db.get("id")), db.get("engine", "?"), db.get("name")
    print(f"{did:>4}  {eng:12}  {name}")' ;;
  metadata)  req "/api/database/$id/metadata" ;;
  *) echo "usage: metabase-discover.sh {collections | items <id> | card <id> | dashboard <id> | databases | metadata <dbId>}" >&2; exit 1 ;;
esac
